// Whether the Mac is running on battery, kept current by an IOKit power-source notification
// (cheap to read every frame).

import Foundation
import IOKit.ps

enum PowerSource {
    private(set) static var onBattery = read()
    private static var source: CFRunLoopSource?

    /// Starts watching for the charger being connected or removed. Call once, on the main thread.
    static func startWatching() {
        guard source == nil else { return }
        let s = IOPSNotificationCreateRunLoopSource({ _ in
            let now = PowerSource.read()
            if now != PowerSource.onBattery {
                PowerSource.onBattery = now
                print("power: \(now ? "on battery" : "charger connected")")
            }
        }, nil)?.takeRetainedValue()
        if let s { CFRunLoopAddSource(CFRunLoopGetMain(), s, .defaultMode) }
        source = s
    }

    private static func read() -> Bool {
        // For testing the higher power modes unplugged.
        if ProcessInfo.processInfo.environment["PS5STREAM_IGNORE_BATTERY"] == "1" { return false }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
