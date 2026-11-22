// Turns a PS5Stream recording (R key, saved in ~/Movies) into a short captioned 1080p clip for sharing.
//
//   swift Tools/make-demo.swift "<recording>.mp4" [--start 12] [--duration 20] [--out demo.mp4] [--title "..."]
//                               [--no-title] [--no-link] [--captions]
//
// - Scales to 1920x1080 H.264 (plays everywhere), keeping the recording's frame rate.
// - If the recording was made in compare mode (C), labels the two halves.
// - Shows the real per-second stats from the recording's .stats.txt (mode, frames shown, GPU time),
//   so the caption numbers are measured, not typed in. Skipped when the recording already has the
//   app's on-screen fps counter (F) burned in, unless --captions is given.
// - Title for the first 3 seconds, link to the project for the last 3.

import AVFoundation
import AppKit
import QuartzCore

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
let start = Double(option("--start") ?? "0")!
let wanted = option("--duration").flatMap(Double.init)
let title = option("--title") ?? "PS5 Remote Play on a Mac: neural upscaling, native app"
let link = option("--link") ?? "github.com/rajatonit/macos-nativeplay"
let outArg = option("--out")
let forceCaptions = args.contains("--captions")
let noTitle = args.contains("--no-title"), noLink = args.contains("--no-link")
args.removeAll { ["--captions", "--no-title", "--no-link"].contains($0) }
guard let inPath = args.first else {
    print("usage: swift Tools/make-demo.swift <recording.mp4> [--start s] [--duration s] [--out file.mp4] [--title text]")
    exit(1)
}
let inURL = URL(fileURLWithPath: inPath)
let outURL = URL(fileURLWithPath: outArg ?? inURL.deletingPathExtension().path + " demo.mp4")

// Stats: "<seconds>\t<window title line>" per second.
struct Stat { var t: Double; var text: String; var compare: Bool; var overlay: Bool }
func caption(_ line: String) -> (String, Bool)? {
    let parts = line.components(separatedBy: " | ")
    guard parts.count > 3 else { return nil }
    let power = parts[0].split(separator: " ").dropFirst().joined(separator: " ")  // drop the clock
    func find(_ pattern: String) -> String? {
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[r])
    }
    let shown = find("shown [0-9]+ fps").map { $0.replacingOccurrences(of: "shown ", with: "") } ?? ""
    let gpu = find("GPU [0-9.]+ ms") ?? ""
    let interp = line.contains("120 fps (interp")
    // The upscaler segment follows the power (and the 120 fps note when present).
    let seg = parts[1].replacingOccurrences(of: #"120 fps \(interp [0-9.]+ ms\) "#, with: "", options: .regularExpression)
    var upscaler = seg.replacingOccurrences(of: #" (HDR|SDR).*$"#, with: "", options: .regularExpression)
    if upscaler == "Neural HQ + fast in-between" { upscaler = "Neural HQ" }
    var bits = ["\(power) mode", upscaler]
    if seg.contains(" clean") { bits.append("artifact clean-up") }
    if seg.contains(" look") { bits.append("enhanced look") }
    if seg.contains("boost") { bits.append("HDR boost") }
    let game = find("game [0-9]+ fps").map { " from a " + $0.replacingOccurrences(of: "game ", with: "") + " game" } ?? ""
    bits.append(interp ? "\(shown) on screen\(game) (frame generation)" : "\(shown) on screen\(game)")
    let ms = gpu.replacingOccurrences(of: "GPU ", with: "")
    // Frame generation runs in VideoToolbox, outside the render time, so report it separately.
    if let interpMs = find(#"interp [0-9.]+ ms"#)?.replacingOccurrences(of: "interp ", with: ""), !ms.isEmpty {
        bits.append("\(ms) upscaling + \(interpMs) frame generation")
    } else if !ms.isEmpty {
        bits.append("\(ms) of GPU work per frame")
    }
    return (bits.joined(separator: "  ·  "), line.contains("| compare"))
}
let statsURL = inURL.deletingPathExtension().appendingPathExtension("stats.txt")
let stats: [Stat] = ((try? String(contentsOf: statsURL, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
    let f = $0.split(separator: "\t", maxSplits: 1)
    guard f.count == 2, let t = Double(f[0]), let (c, cmp) = caption(String(f[1])) else { return nil }
    return Stat(t: t, text: c, compare: cmp, overlay: f[1].contains("| fps overlay"))
}
if stats.isEmpty { print("note: no stats file next to the recording; captions will only have the title and link") }

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let asset = AVURLAsset(url: inURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let (size, fps, total) = try await (track.load(.naturalSize), track.load(.nominalFrameRate), asset.load(.duration))
        let duration = min(wanted ?? (total.seconds - start), total.seconds - start)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))

        let comp = AVMutableComposition()
        let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try ct.insertTimeRange(range, of: track, at: .zero)

        let W: CGFloat = 1920, H: CGFloat = 1080
        let scale = min(W / size.width, H / size.height)
        let li = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
        li.setTransform(CGAffineTransform(scaleX: scale, y: scale)
            .translatedBy(x: (W / scale - size.width) / 2, y: (H / scale - size.height) / 2), at: .zero)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: range.duration)
        ins.layerInstructions = [li]

        // Overlays (Core Animation, origin bottom-left).
        let parent = CALayer(), video = CALayer()
        parent.frame = CGRect(x: 0, y: 0, width: W, height: H)
        video.frame = parent.frame
        parent.addSublayer(video)
        /// A caption: white text on a rounded dark pill, drawn into an image (CATextLayer text doesn't
        /// render reliably in exports). `anchor` is where the pill goes: x is left/centre/right per `align`.
        enum Align { case left, center, right }
        func pill(_ text: String, size fs: CGFloat, weight: NSFont.Weight, x: CGFloat, y: CGFloat, align: Align = .left) -> CALayer {
            let attr = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fs, weight: weight), .foregroundColor: NSColor.white])
            let ts = attr.size()
            let padX = fs * 0.6, padY = fs * 0.3
            let w = ceil(ts.width + 2 * padX), h = ceil(ts.height + 2 * padY), sc: CGFloat = 2
            let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
                NSColor(white: 0, alpha: 0.55).setFill()
                NSBezierPath(roundedRect: r, xRadius: h * 0.3, yRadius: h * 0.3).fill()
                attr.draw(at: NSPoint(x: padX, y: padY))
                return true
            }
            let l = CALayer()
            var rect = CGRect(x: 0, y: 0, width: w * sc, height: h * sc)
            l.contents = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            let ox = align == .left ? x : align == .center ? x - w / 2 : x - w
            l.frame = CGRect(x: ox, y: y, width: w, height: h)
            return l
        }
        /// Visible from t0 to t1 (seconds into the clip), with a short fade.
        func show(_ l: CALayer, _ t0: Double, _ t1: Double, fade wanted: Double = 0.25) {
            let fade = max(wanted, 0.02)  // keyframes at the same time make Core Animation ignore the hide
            l.opacity = 0
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0, 1, 1, 0]
            let len = max(t1 - t0, 0.01)
            a.keyTimes = [0, NSNumber(value: min(fade / len, 0.5)), NSNumber(value: max(1 - fade / len, 0.5)), 1]
            a.beginTime = AVCoreAnimationBeginTimeAtZero + max(t0, 0)
            a.duration = len
            a.isRemovedOnCompletion = false
            a.fillMode = .both
            l.add(a, forKey: "show")
            parent.addSublayer(l)
        }

        // Title (first 3 s) and link (last 3 s).
        if !noTitle { show(pill(title, size: 44, weight: .semibold, x: W / 2, y: H / 2 - 30, align: .center), 0, min(3, duration)) }
        if !noLink {
            show(pill("Free & open source  ·  \(link)", size: 44, weight: .semibold, x: W / 2, y: H / 2 - 30, align: .center),
                 max(duration - 3, 0), duration)
        }

        // Compare labels.
        if stats.contains(where: \.compare) {
            // Name what actually ran on the right half, and keep clear of the app's fps counter (top right).
            let neuralRan = stats.contains { $0.text.contains("Neural") }
            let lookRan = stats.contains { $0.text.contains("enhanced look") }
            let right = (neuralRan ? "Neural upscaling + " : "") + (lookRan ? "enhanced look" : "clean-up")
            let rightY = stats.contains(where: \.overlay) ? H - 150 : H - 80
            show(pill("Standard (plain scaling)", size: 30, weight: .semibold, x: 30, y: H - 80), 0, duration, fade: 0)
            show(pill(right.prefix(1).uppercased() + right.dropFirst(), size: 30, weight: .semibold, x: W - 30, y: rightY, align: .right),
                 0, duration, fade: 0)
        }

        // Live stats, one caption per measured second.
        let inClip = stats.filter { $0.t >= start - 1 && $0.t <= start + duration && (forceCaptions || !$0.overlay) }
        for (i, s) in inClip.enumerated() {
            let t0 = (i == 0 ? 0 : s.t - start)
            let t1 = i + 1 < inClip.count ? inClip[i + 1].t - start : duration
            // Bottom right: games usually put the minimap bottom left.
            show(pill(s.text, size: 24, weight: .medium, x: W - 30, y: 30, align: .right), t0, t1, fade: 0)
        }

        let vc = AVMutableVideoComposition()
        vc.renderSize = CGSize(width: W, height: H)
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(fps.rounded(), 30)))
        vc.instructions = [ins]
        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)

        try? FileManager.default.removeItem(at: outURL)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPreset1920x1080) else { throw NSError(domain: "export", code: 1) }
        ex.videoComposition = vc
        try await ex.export(to: outURL, as: .mp4)
        print(String(format: "wrote %@ (%.1f s at %.0f fps)", outURL.path, duration, fps))
    } catch {
        print("failed: \(error)")
    }
    sem.signal()
}
sem.wait()
