import Foundation

/// Update intervals offered in the settings, kept apart from the UI so the tests can check them.
nonisolated enum Sampling {
    /// Offered for CPU and GPU, in seconds.
    static let intervals = Array(2...59)
    /// Offered for Bluetooth, in seconds: each reading walks the IOKit registry, and battery levels move slowly.
    static let bluetoothIntervals = [30, 60, 120, 300, 600]
    static let defaultBluetoothInterval = 60

    /// The allowed value closest to `value`, the smaller one on a tie. A setting saved by an older version may be
    /// missing from today's list, and a picker shows nothing for a value outside its options.
    static func closest(to value: Int, in allowed: [Int]) -> Int {
        allowed.min { abs($0 - value) < abs($1 - value) } ?? value
    }
}
