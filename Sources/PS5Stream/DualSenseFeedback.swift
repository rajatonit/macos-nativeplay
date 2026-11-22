// Feedback from the PS5 to the DualSense: rumble, adaptive triggers, lightbar and player LEDs.
//
// The controller is driven directly with HID output reports (the same "effects" report the PS5
// itself sends), so the PS5's raw adaptive-trigger data reaches the triggers unchanged.
// Layout follows SDL's DualSense driver: 47 bytes of effect state, wrapped in report 0x02 over
// USB or report 0x31 (with a CRC32) over Bluetooth.

import Foundation
import GameController
import IOKit.hid
import zlib

final class DualSenseFeedback {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var bluetooth = false
    private var started = false
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dualsense.feedback")

    // Current effect state (guarded by queue).
    private var rumble: (left: UInt8, right: UInt8) = (0, 0)
    private var triggerRight = [UInt8](repeating: 0, count: 11)
    private var triggerLeft = [UInt8](repeating: 0, count: 11)
    private var triggersDirty = false
    private var led: (UInt8, UInt8, UInt8)?
    private var playerLights: UInt8?
    private var hapticScale: Float = 1
    private var intensityByte: UInt8 = 0  // upper nibble: trigger reduction, lower: rumble reduction
    private var dirty = false
    private var seq: UInt8 = 0
    private(set) var reportsSent = 0
    // Diagnostics: what the PS5 has sent us.
    private(set) var rumbleEvents = 0
    private(set) var hapticFrames = 0
    private(set) var hapticActiveFrames = 0
    private(set) var triggerEvents = 0
    private(set) var ledEvents = 0
    private(set) var hasDevice = false
    /// PS button state read straight from the controller's HID input reports (called on main).
    /// GameController doesn't reliably pass the PS button to apps on macOS, so we read it ourselves.
    var onPSButton: ((Bool) -> Void)?
    private var psDown = false
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)

    var summary: String {
        "dualsense \(hasDevice ? "connected" : "NOT FOUND") | from PS5: rumble \(rumbleEvents), haptic frames \(hapticFrames) (\(hapticActiveFrames) non-silent), trigger effects \(triggerEvents), lightbar \(ledEvents) | reports sent \(reportsSent)"
    }

    /// Starts looking for a DualSense over USB or Bluetooth. Safe to call repeatedly.
    func attach(_ controller: GCController? = nil) {
        queue.async { [self] in
            guard !started else { return }
            started = true
            let matches = [0x0CE6, 0x0DF2].map {  // DualSense, DualSense Edge
                [kIOHIDVendorIDKey: 0x054C, kIOHIDProductIDKey: $0] as CFDictionary
            }
            IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
                let me = Unmanaged<DualSenseFeedback>.fromOpaque(ctx!).takeUnretainedValue()
                me.listenForInput(dev)
                me.queue.async { me.use(dev) }
            }, ctx)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
                let me = Unmanaged<DualSenseFeedback>.fromOpaque(ctx!).takeUnretainedValue()
                me.queue.async { if me.device == dev { me.device = nil; me.hasDevice = false } }
            }, ctx)
            DispatchQueue.main.async { [self] in
                IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                if status != kIOReturnSuccess { print("dualsense: cannot open HID manager (\(String(status, radix: 16)))") }
            }

            // Send at most 100 reports per second, only when something changed.
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.flush() }
            t.resume()
            timer = t
        }
    }

    /// Watches input reports for the PS button: USB report 0x01 has it at byte 10 bit 0,
    /// Bluetooth report 0x31 one byte later.
    private func listenForInput(_ dev: IOHIDDevice) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, 128, { ctx, _, _, _, _, report, length in
            let me = Unmanaged<DualSenseFeedback>.fromOpaque(ctx!).takeUnretainedValue()
            let index: Int
            switch report[0] {
            case 0x01 where length >= 11: index = 10
            case 0x31 where length >= 12: index = 11
            default: return
            }
            let down = report[index] & 0x01 != 0
            guard down != me.psDown else { return }
            me.psDown = down
            me.onPSButton?(down)
        }, ctx)
    }

    private func use(_ dev: IOHIDDevice) {
        let transport = IOHIDDeviceGetProperty(dev, kIOHIDTransportKey as CFString) as? String ?? ""
        bluetooth = transport.lowercased().contains("bluetooth")
        device = dev
        hasDevice = true
        dirty = true
        triggersDirty = true
        print("dualsense: feedback over \(bluetooth ? "Bluetooth" : "USB")")
    }

    func detach() {
        queue.sync {
            rumble = (0, 0)
            triggerLeft = [0x05] + [UInt8](repeating: 0, count: 10)
            triggerRight = triggerLeft
            triggersDirty = true
            dirty = true
            flush()
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Inputs from the PS5

    func rumble(left: UInt8, right: UInt8) {
        queue.async { self.rumbleEvents += 1; self.setRumble(left, right) }
    }

    /// DualSense haptics arrive as a 3 kHz stereo waveform; without USB audio we follow its envelope.
    func haptics(_ pcm: UnsafePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        var l: Float = 0, r: Float = 0
        for i in 0..<frames {
            l += abs(Float(pcm[i * 2]))
            r += abs(Float(pcm[i * 2 + 1]))
        }
        let scale = 2 * 255 / (Float(frames) * 32768)
        func level(_ v: Float) -> UInt8 { v < 8 ? 0 : UInt8(min(255, v)) }
        let left = level(l * scale), right = level(r * scale)
        queue.async {
            self.hapticFrames += 1
            if left > 0 || right > 0 { self.hapticActiveFrames += 1 }
            self.setRumble(left, right)
        }
    }

    private func setRumble(_ left: UInt8, _ right: UInt8) {
        let l = UInt8(Float(left) * hapticScale), r = UInt8(Float(right) * hapticScale)
        guard (l, r) != rumble else { return }
        rumble = (l, r)
        dirty = true
    }

    func intensity(haptic level: UInt8) {
        queue.async { self.hapticScale = [0, 0.33, 0.5, 1][Int(min(level, 3))] }
    }

    func intensity(trigger level: UInt8) {
        queue.async {
            // Trigger strength reduction lives in the upper nibble (0 = full strength).
            let reduction: UInt8 = [0x0F, 0x06, 0x03, 0x00][Int(min(level, 3))]
            self.intensityByte = (self.intensityByte & 0x0F) | (reduction << 4)
            self.triggersDirty = true
            self.dirty = true
        }
    }

    func triggers(leftType: UInt8, left: [UInt8], rightType: UInt8, right: [UInt8]) {
        queue.async {
            self.triggerEvents += 1
            self.triggerLeft = [leftType] + left.prefix(10)
            self.triggerRight = [rightType] + right.prefix(10)
            self.triggersDirty = true
            self.dirty = true
        }
    }

    func light(r: UInt8, g: UInt8, b: UInt8) {
        queue.async {
            self.ledEvents += 1
            self.led = (r, g, b)
            self.dirty = true
        }
    }

    func player(index: UInt8) {
        // Player-indicator LED patterns for players 1–4.
        let patterns: [UInt8] = [0x04, 0x0A, 0x15, 0x1B]
        queue.async {
            self.playerLights = index >= 1 && index <= 4 ? patterns[Int(index) - 1] : (index == 0 ? 0x04 : 0x1F)
            self.dirty = true
        }
    }

    // MARK: Self-test

    /// Drives the controller directly, without the PS5: lightbar colours, each motor, then trigger resistance.
    func selfTest(done: @escaping () -> Void) {
        attach()
        let steps: [(String, Double, () -> Void)] = [
            ("waiting for the controller", 1.5, {}),
            ("lightbar RED", 0.8, { self.led = (255, 0, 0) }),
            ("lightbar GREEN", 0.8, { self.led = (0, 255, 0) }),
            ("lightbar BLUE", 0.8, { self.led = (0, 0, 255) }),
            ("LEFT motor full", 1.0, { self.rumble = (255, 0) }),
            ("RIGHT motor full", 1.0, { self.rumble = (0, 255) }),
            ("motors off", 0.5, { self.rumble = (0, 0) }),
            ("TRIGGERS: press L2/R2, they should feel stiff", 4.0, {
                // Simple feedback: resistance from the start of travel at full strength.
                self.triggerLeft = [0x01, 0x00, 0xFF] + [UInt8](repeating: 0, count: 8)
                self.triggerRight = self.triggerLeft
                self.triggersDirty = true
            }),
            ("TRIGGERS: vibrating", 3.0, {
                self.triggerLeft = [0x06, 0x28, 0xFF, 0x00] + [UInt8](repeating: 0, count: 7)
                self.triggerRight = self.triggerLeft
                self.triggersDirty = true
            }),
            ("everything off", 0.5, {
                self.triggerLeft = [0x05] + [UInt8](repeating: 0, count: 10)
                self.triggerRight = self.triggerLeft
                self.triggersDirty = true
                self.led = (0, 0, 64)
            }),
        ]
        var t = 0.0
        for (name, duration, action) in steps {
            queue.asyncAfter(deadline: .now() + t) {
                print("self-test: \(name)\(self.device == nil ? "  [no controller found]" : "")")
                action()
                self.dirty = true
            }
            t += duration
        }
        queue.asyncAfter(deadline: .now() + t) {
            print("self-test: done, \(self.reportsSent) reports sent")
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: Output report

    private func flush() {
        guard dirty, let device else { return }
        dirty = false

        var e = [UInt8](repeating: 0, count: 47)
        e[0] = 0x01 | 0x02  // rumble emulation on, audio haptics off
        e[2] = rumble.right
        e[3] = rumble.left
        if triggersDirty {
            e[0] |= 0x04 | 0x08
            e.replaceSubrange(10..<21, with: triggerRight)
            e.replaceSubrange(21..<32, with: triggerLeft)
            triggersDirty = false
        }
        e[1] |= 0x40  // apply the intensity byte
        e[36] = intensityByte
        e[38] |= 0x04  // improved rumble emulation (firmware 2.24+)
        if let led {
            e[1] |= 0x04
            (e[44], e[45], e[46]) = led
        }
        if let playerLights {
            e[1] |= 0x10
            e[43] = playerLights
        }

        var report: [UInt8]
        if bluetooth {
            report = [UInt8](repeating: 0, count: 78)
            report[0] = 0x31
            report[1] = (seq << 4) | 0x02
            seq = (seq + 1) & 0x0F
            report.replaceSubrange(2..<49, with: e)
            var crc = crc32(0, [0xA2], 1)
            crc = report.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, 74) }
            withUnsafeBytes(of: UInt32(crc).littleEndian) { report.replaceSubrange(74..<78, with: $0) }
        } else {
            report = [0x02] + e
        }
        let status = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), $0.baseAddress!, report.count)
        }
        if status == kIOReturnSuccess {
            reportsSent += 1
        } else {
            print("dualsense: output report failed (\(String(UInt32(bitPattern: status), radix: 16)))")
        }
    }
}
