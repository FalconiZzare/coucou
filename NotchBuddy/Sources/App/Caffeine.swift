import Foundation
import IOKit.pwr_mgt

/// Caffeine (the cup in the island header): while on, the Mac and its display do not go to
/// sleep when idle. An IOKit power assertion, released when turned off; macOS also drops it
/// when Coucou quits, so it never outlives the app. Closing the lid still sleeps the Mac.
@MainActor
enum Caffeine {
    /// kIOPMNullAssertionID (0) while off.
    private static var assertion: IOPMAssertionID = 0

    /// Turns it on or off. Returns false when macOS refused the assertion.
    static func set(_ on: Bool) -> Bool {
        if on {
            guard assertion == 0 else { return true }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Coucou caffeine is keeping the Mac awake" as CFString,
                &id)
            guard result == kIOReturnSuccess else { return false }
            assertion = id
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        return true
    }
}
