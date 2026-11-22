// Connects to the PS5 with libchiaki, using the pairing that chiaki-ng already saved.

import CPS5
import Foundation

struct Pairing {
    let registKey: Data
    let morning: Data
    /// The PS5 profile's login passcode, if it was saved in chiaki-ng.
    let loginPin: String?

    /// Reads the first console registered in chiaki-ng's preferences.
    static func fromChiakiNG() -> Pairing? {
        let app = "com.chiaki.Chiaki" as CFString
        func data(_ key: String) -> Data? {
            CFPreferencesCopyAppValue("registered_hosts.1.\(key)" as CFString, app) as? Data
        }
        guard let regist = data("rp_regist_key"), let morning = data("rp_key"),
              regist.count == 16, morning.count == 16
        else { return nil }
        let pin = CFPreferencesCopyAppValue("registered_hosts.1.console_pin" as CFString, app) as? String
        return Pairing(registKey: regist, morning: morning,
                       loginPin: pin.flatMap { $0.count == 4 && $0.allSatisfy(\.isNumber) ? $0 : nil })
    }
}

enum Console {
    enum WakeResult { case awake, timedOut, networkBlocked }

    /// Wakes the PS5 from rest mode if needed. Blocks up to `timeout` seconds.
    static func ensureAwake(host: String, pairing: Pairing, timeout: Double = 45,
                            onWaitingForPermission: (() -> Void)? = nil) -> WakeResult {
        // A new app's first packet makes macOS ask for Local Network access; give the user
        // up to a minute to answer that prompt before giving up.
        var state = ps_probe(host, 1500)
        if state == PS_HOST_BLOCKED {
            print("console: waiting for Local Network permission…")
            onWaitingForPermission?()
            let deadline = Date().addingTimeInterval(60)
            while state == PS_HOST_BLOCKED, Date() < deadline {
                Thread.sleep(forTimeInterval: 1)
                state = ps_probe(host, 1500)
            }
        }
        switch state {
        case PS_HOST_READY: return .awake
        case PS_HOST_BLOCKED: return .networkBlocked
        case PS_HOST_STANDBY: print("console: in rest mode, waking it up…")
        default: print("console: no reply, sending wake-up anyway…")
        }
        _ = pairing.registKey.withUnsafeBytes { ps_wakeup(host, $0.bindMemory(to: UInt8.self).baseAddress) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch ps_probe(host, 1000) {
            case PS_HOST_READY:
                print("console: awake")
                Thread.sleep(forTimeInterval: 2)  // Remote Play needs a moment after wake-up
                return .awake
            case PS_HOST_BLOCKED:
                return .networkBlocked
            default:
                Thread.sleep(forTimeInterval: 1)
            }
        }
        return .timedOut
    }
}

final class StreamClient {
    let decoder = HEVCDecoder()
    let audio = AudioPlayer()
    let feedback = DualSenseFeedback()
    let mic = Microphone()
    var onQuit: ((String) -> Void)?
    /// The PS5 opened its on-screen keyboard; argument is the current text.
    var onKeyboard: ((String) -> Void)?
    /// The PS5 wants the profile passcode; argument is true if the last one was wrong.
    var onLoginPin: ((Bool) -> Void)?
    private var savedPin: String?
    var verbose = false

    private var session: OpaquePointer?
    private(set) var framesLost = 0
    private(set) var decodeFailures = 0
    private(set) var videoCallbacks = 0
    private(set) var bytesReceived = 0
    private(set) var largestFrame = 0
    private(set) var micMuted = true
    private var keyboardShown = false

    func start(host: String, pairing: Pairing, hdr: Bool, dualsense: Bool, bitrateKbps: UInt32,
               width: UInt32 = 1920, height: UInt32 = 1080) -> Bool {
        decoder.tenBit = hdr
        savedPin = pairing.loginPin
        mic.onFrame = { [weak self] pcm in
            guard let s = self?.session else { return }
            ps_session_mic_frame(s, pcm)
        }
        let user = Unmanaged.passUnretained(self).toOpaque()
        session = host.withCString { hostPtr in
            pairing.registKey.withUnsafeBytes { regist in
                pairing.morning.withUnsafeBytes { morning in
                    var cfg = PSConfig()
                    cfg.host = hostPtr
                    cfg.regist_key = regist.bindMemory(to: UInt8.self).baseAddress
                    cfg.morning = morning.bindMemory(to: UInt8.self).baseAddress
                    cfg.width = width
                    cfg.height = height
                    cfg.fps = 60
                    cfg.bitrate_kbps = bitrateKbps
                    cfg.hdr = hdr
                    cfg.dualsense = dualsense
                    cfg.verbose = verbose
                    cfg.user = user
                    cfg.video_cb = { buf, size, lost, user in
                        let me = Unmanaged<StreamClient>.fromOpaque(user!).takeUnretainedValue()
                        me.videoCallbacks += 1
                        me.bytesReceived += size
                        me.largestFrame = max(me.largestFrame, size)
                        me.framesLost += Int(lost)
                        let ok = me.decoder.decode(UnsafeBufferPointer(start: buf, count: size))
                        if !ok { me.decodeFailures += 1 }
                        return ok
                    }
                    cfg.audio_cb = { pcm, frames, channels, rate, user in
                        let me = Unmanaged<StreamClient>.fromOpaque(user!).takeUnretainedValue()
                        me.audio.play(pcm: pcm!, frames: frames, channels: Int(channels), rate: Double(rate))
                    }
                    cfg.haptics_cb = { pcm, frames, user in
                        let me = Unmanaged<StreamClient>.fromOpaque(user!).takeUnretainedValue()
                        me.feedback.haptics(pcm!, frames: frames)
                    }
                    cfg.event_cb = { event, user in
                        let me = Unmanaged<StreamClient>.fromOpaque(user!).takeUnretainedValue()
                        me.handle(event!.pointee)
                    }
                    return ps_session_start(&cfg)
                }
            }
        }
        return session != nil
    }

    private func handle(_ e: PSEvent) {
        let text = e.message.map { String(cString: $0) } ?? ""
        switch e.type {
        case PS_EVENT_CONNECTED:
            print("stream: connected")
        case PS_EVENT_QUIT:
            print("stream: ended (\(text))")
            DispatchQueue.main.async { self.onQuit?(text) }
        case PS_EVENT_RUMBLE:
            feedback.rumble(left: e.left, right: e.right)
        case PS_EVENT_TRIGGER_EFFECTS:
            var l = e.trigger_left, r = e.trigger_right
            let left = withUnsafeBytes(of: &l) { Array($0) }, right = withUnsafeBytes(of: &r) { Array($0) }
            feedback.triggers(leftType: e.trigger_type_left, left: left, rightType: e.trigger_type_right, right: right)
        case PS_EVENT_LED:
            feedback.light(r: e.rgb.0, g: e.rgb.1, b: e.rgb.2)
        case PS_EVENT_PLAYER_INDEX:
            feedback.player(index: e.player_index)
        case PS_EVENT_HAPTIC_INTENSITY:
            feedback.intensity(haptic: e.intensity)
        case PS_EVENT_TRIGGER_INTENSITY:
            feedback.intensity(trigger: e.intensity)
        case PS_EVENT_KEYBOARD_OPEN:
            DispatchQueue.main.async {
                guard !self.keyboardShown else { return }
                self.keyboardShown = true
                self.onKeyboard?(text)
            }
        case PS_EVENT_KEYBOARD_CLOSE:
            DispatchQueue.main.async { self.keyboardShown = false }
        case PS_EVENT_LOGIN_PIN:
            let wrong = e.intensity != 0
            if !wrong, let pin = savedPin {
                print("stream: sending saved login passcode")
                savedPin = nil  // only try it once
                sendLoginPin(pin)
            } else {
                DispatchQueue.main.async { self.onLoginPin?(wrong) }
            }
        case PS_EVENT_LOG:
            print("chiaki: \(text)")
        default:
            break
        }
    }

    /// Counters since the previous call, for the once-a-second stats line.
    private var last = (bytes: 0, lost: 0, errors: 0)
    func takeInterval() -> (mbits: Double, lost: Int, errors: Int, largestKB: Int) {
        let r = (Double(bytesReceived - last.bytes) * 8 / 1_000_000, framesLost - last.lost,
                 decodeFailures - last.errors, largestFrame / 1024)
        last = (bytesReceived, framesLost, decodeFailures)
        largestFrame = 0
        return r
    }

    func send(_ controller: PSController) {
        guard let session else { return }
        var c = controller
        ps_session_set_controller(session, &c)
    }

    func sendLoginPin(_ pin: String) {
        guard let session else { return }
        ps_session_set_login_pin(session, pin)
    }

    func submitKeyboard(_ text: String?) {
        keyboardShown = false
        guard let session else { return }
        ps_session_keyboard_text(session, text ?? "", text != nil)
    }

    /// Returns the new muted state.
    @discardableResult
    func toggleMic() -> Bool {
        guard let session else { return true }
        if micMuted {
            guard mic.start() else { return true }
            ps_session_set_mic_muted(session, false)
            micMuted = false
        } else {
            ps_session_set_mic_muted(session, true)
            mic.stop()
            micMuted = true
        }
        print("mic: \(micMuted ? "muted" : "live")")
        return micMuted
    }

    func goToRest() {
        guard let session else { return }
        print("console: putting PS5 into rest mode")
        ps_session_goto_bed(session)
    }

    func stop() {
        guard let s = session else { return }
        session = nil
        mic.stop()
        feedback.detach()
        ps_session_stop(s)
    }
}
