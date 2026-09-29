import Foundation
import IOKit.pwr_mgt

/// IOKit power assertions (`IOPMAssertionCreateWithName`), public API allowed in the App Sandbox. While one is held,
/// `pmset -g assertions` lists it under its name; macOS drops it if the process ends.
nonisolated enum PowerAssertion {
    /// Keeps the Mac from sleeping when idle; the display may still turn off.
    static let preventSystemSleep = kIOPMAssertionTypePreventUserIdleSystemSleep as String
    /// Keeps the display on, and with it the Mac.
    static let preventDisplaySleep = kIOPMAssertionTypePreventUserIdleDisplaySleep as String

    /// The assertion's identifier, nil when IOKit refuses it.
    static func create(type: String, name: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    static func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }

    /// Names of the assertions this process holds, as `pmset -g assertions` prints them.
    static func namesHeldByThisProcess() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = all[NSNumber(value: getpid())] ?? []
        return mine.compactMap { $0[kIOPMAssertionNameKey as String] as? String }
    }
}
