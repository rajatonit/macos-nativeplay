// Controller (and fallback keyboard) input -> PS5 controller state.

import CPS5
import GameController

final class Input {
    var onChange: ((PSController) -> Void)?
    var onControllerConnected: ((GCController) -> Void)?
    private var keyButtons: UInt32 = 0
    private var hidPS = false
    private var observers: [NSObjectProtocol] = []
    private var motionTimer: Timer?

    /// True when a DualSense is connected (the PS5 then sends haptics and trigger effects).
    static var dualSensePresent: Bool { GCController.controllers().contains { $0.extendedGamepad is GCDualSenseGamepad } }

    // Keyboard fallback for menus: arrows = d-pad, Return = cross, Esc = circle,
    // P = PS button, O = options, T = touchpad click.
    private let keyMap: [UInt16: Int] = [
        123: PS_BTN_LEFT, 124: PS_BTN_RIGHT, 126: PS_BTN_UP, 125: PS_BTN_DOWN,
        36: PS_BTN_CROSS, 53: PS_BTN_CIRCLE, 35: PS_BTN_PS, 31: PS_BTN_OPTIONS, 17: PS_BTN_TOUCHPAD,
    ]

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) {
            [weak self] note in
            if let c = note.object as? GCController { self?.attach(c) }
        })
        GCController.controllers().forEach(attach)
        // Motion and touch change continuously; send them at 250 Hz rather than on every sensor tick.
        motionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 250, repeats: true) { [weak self] _ in
            guard let pad = GCController.current?.extendedGamepad, pad.controller?.motion != nil else { return }
            self?.publish(pad)
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        print("input: \(controller.vendorName ?? "controller") connected")
        if let motion = controller.motion, motion.sensorsRequireManualActivation { motion.sensorsActive = true }
        // Keep macOS from acting on the PS button (opens Games/Apple Arcade) and the Create button
        // (screenshot/recording) while we're frontmost, so the presses reach the PS5 instead.
        for element in controller.physicalInputProfile.allElements {
            element.preferredSystemGestureState = .disabled
        }
        pad.valueChangedHandler = { [weak self] pad, _ in self?.publish(pad) }
        onControllerConnected?(controller)
    }

    func key(_ code: UInt16, down: Bool) {
        guard let bit = keyMap[code] else { return }
        if down { keyButtons |= UInt32(bit) } else { keyButtons &= ~UInt32(bit) }
        publish(GCController.current?.extendedGamepad)
    }

    /// PS button as read from the DualSense's raw HID reports.
    func psButton(_ down: Bool) {
        hidPS = down
        publish(GCController.current?.extendedGamepad)
    }

    private func publish(_ pad: GCExtendedGamepad?) {
        var s = PSController()
        s.buttons = keyButtons | (hidPS ? UInt32(PS_BTN_PS) : 0)
        if let pad {
            func set(_ pressed: Bool, _ bit: Int) { if pressed { s.buttons |= UInt32(bit) } }
            set(pad.buttonA.isPressed, PS_BTN_CROSS)
            set(pad.buttonB.isPressed, PS_BTN_CIRCLE)
            set(pad.buttonX.isPressed, PS_BTN_SQUARE)
            set(pad.buttonY.isPressed, PS_BTN_TRIANGLE)
            set(pad.dpad.left.isPressed, PS_BTN_LEFT)
            set(pad.dpad.right.isPressed, PS_BTN_RIGHT)
            set(pad.dpad.up.isPressed, PS_BTN_UP)
            set(pad.dpad.down.isPressed, PS_BTN_DOWN)
            set(pad.leftShoulder.isPressed, PS_BTN_L1)
            set(pad.rightShoulder.isPressed, PS_BTN_R1)
            set(pad.leftThumbstickButton?.isPressed ?? false, PS_BTN_L3)
            set(pad.rightThumbstickButton?.isPressed ?? false, PS_BTN_R3)
            set(pad.buttonMenu.isPressed, PS_BTN_OPTIONS)
            set(pad.buttonOptions?.isPressed ?? false, PS_BTN_SHARE)
            set(pad.buttonHome?.isPressed ?? false, PS_BTN_PS)
            s.l2 = UInt8(pad.leftTrigger.value * 255)
            s.r2 = UInt8(pad.rightTrigger.value * 255)
            func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
            s.left_x = axis(pad.leftThumbstick.xAxis.value)
            s.left_y = axis(-pad.leftThumbstick.yAxis.value)  // PS5 expects down = positive
            s.right_x = axis(pad.rightThumbstick.xAxis.value)
            s.right_y = axis(-pad.rightThumbstick.yAxis.value)

            if let ds = pad as? GCDualSenseGamepad {
                set(ds.touchpadButton.isPressed, PS_BTN_TOUCHPAD)
                // GameController reports each finger as -1...1 with (0, 0) meaning no finger.
                func touch(_ p: GCControllerDirectionPad) -> (Bool, UInt16, UInt16) {
                    let x = p.xAxis.value, y = p.yAxis.value
                    let active = x != 0 || y != 0
                    return (active, UInt16((x + 1) / 2 * 1919), UInt16((1 - y) / 2 * 1079))
                }
                let t0 = touch(ds.touchpadPrimary), t1 = touch(ds.touchpadSecondary)
                s.touch_active = (t0.0, t1.0)
                s.touch_x = (t0.1, t1.1)
                s.touch_y = (t0.2, t1.2)
            } else if let ds4 = pad as? GCDualShockGamepad {
                set(ds4.touchpadButton.isPressed, PS_BTN_TOUCHPAD)
            }

            if let motion = pad.controller?.motion, motion.hasRotationRate {
                s.has_motion = true
                let r = motion.rotationRate, a = motion.acceleration
                (s.gyro_x, s.gyro_y, s.gyro_z) = (Float(r.x), Float(r.y), Float(r.z))
                (s.accel_x, s.accel_y, s.accel_z) = (Float(a.x), Float(a.y), Float(a.z))
            }
        }
        onChange?(s)
    }
}
