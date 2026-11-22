// PS5Stream: PS5 Remote Play with GPU upscaling to the Mac's native panel resolution.
//
//   PS5Stream --host 192.168.1.20 [--sdr] [--bitrate 30000] [--resolution 1080|1440|2160] [--on-quit ask|rest|keep] [--verbose]
//   PS5Stream --file clip.mov          (offline test of the render pipeline)
//
// Keys: E cycles the power mode (Max, Balanced, Cool), U cycles the upscaler (Neural HQ, Neural fast, MetalFX, bilinear), I toggles 120 fps interpolation, H toggles the HDR highlight boost, D toggles artifact clean-up, M toggles the microphone, Cmd-Q quits, Cmd-Ctrl-F full screen.
// Without a controller: arrows = d-pad, Return = cross, Esc = circle, P = PS, O = options, T = touchpad.

import AVFoundation
import AppKit
import GameController

enum QuitAction: String {
    case ask, rest, keep
}

struct Options {
    var host: String?
    var file: String?
    var hdr = true
    var verbose = false
    var bitrate: UInt32 = 30000
    var height: UInt32 = 1080  // requested stream height; width follows at 16:9
    var width: UInt32 { height * 16 / 9 }
    var seconds: Double?
    var onQuit: QuitAction?
    var testFeedback = false

    init(_ args: [String]) {
        let saved = UserDefaults.standard.integer(forKey: "resolution")
        if [720, 1080, 1440, 2160].contains(saved) { height = UInt32(saved) }
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--host": host = it.next()
            case "--file": file = it.next()
            case "--hdr": hdr = true
            case "--sdr": hdr = false
            case "--verbose": verbose = true
            case "--bitrate": bitrate = it.next().flatMap { UInt32($0) } ?? bitrate
            case "--resolution":
                height = it.next().flatMap { UInt32($0.replacingOccurrences(of: "p", with: "")) } ?? height
                UserDefaults.standard.set(Int(height), forKey: "resolution")  // remembered for Finder launches
            case "--seconds": seconds = it.next().flatMap { Double($0) }
            case "--test-feedback": testFeedback = true
            case "--on-quit": onQuit = it.next().flatMap { QuitAction(rawValue: $0) }
            default: print("unknown option \(a)")
            }
        }
    }
}

/// Plays a local file through the same renderer, for testing without the console.
final class FileSource {
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var timer: Timer?
    private var looper: NSObjectProtocol?
    private let burst = ProcessInfo.processInfo.environment["PS5STREAM_BURST"] == "1"
    private var held: CVPixelBuffer?

    init(url: URL, view: RenderView) {
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        let item = AVPlayerItem(url: url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        looper = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = self.output.itemTime(forHostTime: CACurrentMediaTime())
            if self.output.hasNewPixelBuffer(forItemTime: t),
               let pb = self.output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                // PS5STREAM_BURST=1 holds every other frame and delivers them in pairs, like Wi-Fi does.
                if self.burst {
                    if let held = self.held { view.submit(held); view.submit(pb); self.held = nil } else { self.held = pb }
                } else {
                    view.submit(pb)
                }
            }
        }
        player.play()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    var window: NSWindow!
    let client = StreamClient()
    let input = Input()
    var fileSource: FileSource?
    private var streaming = false
    private var quitting = false
    private var retries = 0
    private static let quitPrefKey = "quitAction"

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = RenderView(frame: .zero)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1512, height: 850),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "PS5Stream"
        window.contentView = view
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        if options.testFeedback {
            window.title = "PS5Stream — controller self-test (watch the lightbar, feel the motors, press L2/R2)"
            client.feedback.selfTest { NSApp.terminate(nil) }
            return
        }
        if let file = options.file {
            fileSource = FileSource(url: URL(fileURLWithPath: file), view: view)
        } else if let host = options.host ?? UserDefaults.standard.string(forKey: "host") {
            UserDefaults.standard.set(host, forKey: "host")  // so the app can be opened from Finder next time
            startStream(host: host, view: view)
        } else {
            fail("usage: PS5Stream --host <PS5 address> [--sdr] [--bitrate kbps]  |  --file <video>")
        }

        if let s = options.seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSApp.terminate(nil) }
        }
    }

    private func startStream(host: String, view: RenderView) {
        guard let pairing = Pairing.fromChiakiNG() else {
            fail("No paired console found. Pair the PS5 in chiaki-ng first.")
        }
        client.verbose = options.verbose
        client.decoder.onFrame = { [weak view] pb in view?.submit(pb) }
        // Track the source's recent peak for the highlight boost: follow rises at once, let it fall
        // slowly so the boost doesn't pump between bright and dark shots.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak view] _ in
            guard let self, let view, self.client.decoder.tenBit else { return }
            view.sourcePeakNits = max(self.client.decoder.peakNits, view.sourcePeakNits * 0.99)
        }
        client.onQuit = { [weak self] reason in
            guard let self else { return }
            // The PS5 keeps the previous session busy for a few seconds after it ends.
            if reason.localizedCaseInsensitiveContains("already in use"), self.client.videoCallbacks == 0,
               self.retries < 5 {
                self.retries += 1
                print("stream: console busy, retrying in 3 s (\(self.retries)/5)")
                self.client.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    _ = self.client.start(host: host, pairing: pairing, hdr: self.options.hdr,
                                          dualsense: Input.dualSensePresent, bitrateKbps: self.options.bitrate,
                                          width: self.options.width, height: self.options.height)
                }
                return
            }
            self.streaming = false
            print("quitting: \(reason)")
            NSApp.terminate(nil)
        }
        client.onKeyboard = { [weak self] text in self?.showKeyboard(text) }
        client.onLoginPin = { [weak self] wrong in self?.askLoginPin(wrong: wrong) }
        view.onKey = { [weak self] code, down in
            guard let self else { return }
            if code == 46 {  // M
                if down { self.client.toggleMic() }
                return
            }
            self.input.key(code, down: down)
        }
        input.onChange = { [weak self] state in self?.client.send(state) }
        client.feedback.onPSButton = { [weak self] down in
            if down { print("input: PS button") }
            self?.input.psButton(down)
        }
        input.onControllerConnected = { [weak self] c in self?.client.feedback.attach(c) }
        GCController.controllers().filter { $0.extendedGamepad != nil }.forEach { client.feedback.attach($0) }
        view.extraStats = { [weak self] in
            guard let c = self?.client else { return "" }
            let i = c.takeInterval()
            var s = String(format: "net %.1f Mbit/s, biggest frame %d KB | lost %d, decode errors %d | decode %.1f ms",
                           i.mbits, i.largestKB, i.lost, i.errors, c.decoder.lastDecodeMs)
            if c.decoder.tenBit { s += String(format: " | peak %.0f nits", c.decoder.peakNits) }
            if !c.micMuted { s += " | mic live" }
            return s
        }
        if options.verbose {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak view] _ in
                guard let c = self?.client else { return }
                print("dualsense: \(c.feedback.reportsSent) reports sent"); if let v = view { print("render: ticks \(v.ticks), taken \(v.taken), no drawable \(v.noDrawable)") }; print("pipeline: chiaki callbacks \(c.videoCallbacks), decoded in \(c.decoder.samplesIn), out \(c.decoder.framesOut), lost \(c.framesLost), errors \(c.decodeFailures), peak \(Int(c.decoder.peakNits)) nits, 99% \(Int(c.decoder.brightNits)) nits")
            }
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.streaming else { return }
            print(self.client.feedback.summary)
        }

        let hdr = options.hdr, bitrate = options.bitrate, width = options.width, height = options.height
        window.title = "PS5Stream — connecting to \(host)…"
        DispatchQueue.global().async { [weak self] in
            let waiting = {
                DispatchQueue.main.async {
                    self?.window.title = "PS5Stream — allow Local Network access in the macOS prompt to continue"
                }
            }
            switch Console.ensureAwake(host: host, pairing: pairing, onWaitingForPermission: waiting) {
            case .awake: break
            case .timedOut:
                DispatchQueue.main.async {
                    self?.showFatal("The PS5 didn't wake up",
                                    "It didn't respond within 45 seconds. Check that it's on and connected to the network.")
                }
                return
            case .networkBlocked:
                DispatchQueue.main.async {
                    self?.showFatal("macOS is blocking PS5Stream from your network",
                                    "Turn on PS5Stream under System Settings → Privacy & Security → Local Network, then open the app again.",
                                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
                }
                return
            }
            // macOS announces controllers a moment after launch. Wait for the DualSense so the PS5
            // is told it is one; otherwise it sends no haptics or trigger effects all session.
            for _ in 0..<30 where !Input.dualSensePresent { Thread.sleep(forTimeInterval: 0.1) }
            let dualsense = Input.dualSensePresent
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.client.start(host: host, pairing: pairing, hdr: hdr, dualsense: dualsense, bitrateKbps: bitrate,
                                                          width: width, height: height) else {
                    self.fail("Could not start the session.")
                }
                self.streaming = true
                print("stream: DualSense features \(dualsense ? "requested" : "off (no DualSense seen by GameController)")")
                print("stream: connecting to \(host) (\(width)x\(height)@60 requested, \(bitrate) kbps, \(hdr ? "HDR" : "SDR")\(dualsense ? ", DualSense features" : ""))")
            }
        }
    }

    // MARK: On-screen keyboard

    private func showKeyboard(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "PS5 keyboard"
        alert.informativeText = "Type the text to send to the PS5."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = text
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.client.submitKeyboard(response == .alertFirstButtonReturn ? field.stringValue : nil)
            self?.window.makeFirstResponder(self?.window.contentView)
        }
    }

    // MARK: Login passcode

    private func askLoginPin(wrong: Bool) {
        let alert = NSAlert()
        alert.messageText = wrong ? "Wrong passcode — try again" : "PS5 login passcode"
        alert.informativeText = "Your PS5 profile has a passcode. Enter it to start streaming."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.window.makeFirstResponder(self.window.contentView)
            if response == .alertFirstButtonReturn {
                self.client.sendLoginPin(field.stringValue)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Quit / rest mode

    private func quitAction() -> QuitAction? {
        if let a = options.onQuit { return a }
        if options.seconds != nil { return .keep }
        if let saved = UserDefaults.standard.string(forKey: Self.quitPrefKey), let a = QuitAction(rawValue: saved), a != .ask {
            return a
        }
        let alert = NSAlert()
        alert.messageText = "Put the PS5 in rest mode?"
        alert.informativeText = "Rest mode keeps downloads and charging going, and the PS5 wakes up automatically next time you stream."
        alert.addButton(withTitle: "Rest Mode")
        alert.addButton(withTitle: "Leave On")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Remember my choice"
        let response = alert.runModal()
        let action: QuitAction?
        switch response {
        case .alertFirstButtonReturn: action = .rest
        case .alertSecondButtonReturn: action = .keep
        default: action = nil
        }
        if let action, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(action.rawValue, forKey: Self.quitPrefKey)
        }
        return action
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard streaming, !quitting else { return .terminateNow }
        guard let action = quitAction() else { return .terminateCancel }
        quitting = true
        guard action == .rest else { return .terminateNow }
        client.goToRest()
        // Give the PS5 a moment to act on the request, then quit for real. (Not .terminateLater:
        // AppKit's wait loop for that does not run main-queue work, so the reply would never come.)
        window.title = "PS5Stream — putting the PS5 into rest mode…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        return .terminateCancel
    }

    /// Shows a problem the user must fix, then quits (optionally opening a System Settings page).
    func showFatal(_ title: String, _ detail: String, settingsURL: String? = nil) {
        print("error: \(title). \(detail)")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: settingsURL == nil ? "Quit" : "Open Settings")
        alert.runModal()
        if let settingsURL, let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
        NSApp.terminate(nil)
    }

    func fail(_ message: String) -> Never {
        print(message)
        exit(1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Shutting down waits for libchiaki's network threads; never let a sleeping or
        // unreachable console hold the app open for more than a couple of seconds.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [client] in
            client.stop()
            done.signal()
        }
        if done.wait(timeout: .now() + 3) == .timedOut { print("quit: stream shutdown timed out") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// When opened from Finder, stdout goes nowhere; send it to ~/Library/Logs/PS5Stream.log instead.
func redirectOutputIfDetached() {
    var out = stat(), null = stat()
    guard fstat(STDOUT_FILENO, &out) == 0, stat("/dev/null", &null) == 0,
          out.st_dev == null.st_dev, out.st_ino == null.st_ino else { return }
    let path = NSHomeDirectory() + "/Library/Logs/PS5Stream.log"
    freopen(path, "w", stdout)
    freopen(path, "a", stderr)
}

redirectOutputIfDetached()
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
let delegate = AppDelegate(options: Options(CommandLine.arguments))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
