// Pulls training frames out of PS5Stream recordings (~/Movies, R key) for the neural grade.
//
//   swift Tools/relight/extract.swift <out dir> <recording.mp4>... [--every 0.5]
//
// Uses only the part of each frame the app didn't alter: in split-screen recordings (C) the left,
// standard half; otherwise the whole frame. The top band is dropped when the fps counter (F) is
// burned in. Frames are saved as PNGs about 1024 px wide.

import AVFoundation
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
var every = 0.5
if let i = args.firstIndex(of: "--every"), i + 1 < args.count { every = Double(args[i + 1])!; args.removeSubrange(i...(i + 1)) }
guard args.count >= 2 else { print("usage: extract.swift <out dir> <recording.mp4>... [--every s]"); exit(1) }
let outDir = URL(fileURLWithPath: args[0])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sem = DispatchSemaphore(value: 0)
Task {
    var total = 0
    for path in args.dropFirst() {
        let url = URL(fileURLWithPath: path)
        let stats = (try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("stats.txt"), encoding: .utf8)) ?? ""
        let compare = stats.contains("| compare"), overlay = stats.contains("fps overlay")
        if stats.contains(" look") && !compare { print("skip \(url.lastPathComponent): enhanced look is baked in"); continue }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let stem = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_")
        var t = 1.0, n = 0
        while t < duration - 0.5 {
            defer { t += every }
            guard let (img, _) = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)) else { continue }
            let w = CGFloat(img.width), h = CGFloat(img.height)
            // Left half minus the divider in compare mode; below the fps counter's band otherwise.
            var crop = CGRect(x: 0, y: 0, width: compare ? w / 2 - 4 : w, height: h)
            if overlay && !compare { crop.origin.y = h * 0.08; crop.size.height = h * 0.92 }
            guard let part = img.cropping(to: crop.integral) else { continue }
            let scale = 1024 / CGFloat(part.width)
            let ow = 1024, oh = Int((CGFloat(part.height) * scale / 16).rounded()) * 16
            guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: ow, height: oh))
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            let file = outDir.appendingPathComponent(String(format: "%@_%06.1f.png", stem, t))
            try rep.representation(using: .png, properties: [:])!.write(to: file)
            n += 1
        }
        print("\(url.lastPathComponent): \(n) frames\(compare ? " (left half)" : "")\(overlay && !compare ? " (top band dropped)" : "")")
        total += n
    }
    print("total \(total) frames in \(outDir.path)")
    sem.signal()
}
sem.wait()
