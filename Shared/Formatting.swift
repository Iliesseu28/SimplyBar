import Foundation

/// Number formatting shared by the menu bar, the popups and the widgets.
///
/// Units are split from numbers so the numbers stay testable in any locale and the unit labels come from the
/// string catalog ("GB" reads "Go" in French).
nonisolated enum Format {

    /// Decimal gigabyte, the unit Finder uses for disks.
    static let decimalGigabyte = 1_000_000_000.0
    /// Binary gigabyte (GiB), the unit Activity Monitor uses for memory.
    static let binaryGigabyte = 1_073_741_824.0

    static func number(_ value: Double, decimals: Int, locale: Locale = .current) -> String {
        let safe = value.isFinite ? value : 0
        return safe.formatted(.number.precision(.fractionLength(decimals)).grouping(.never).locale(locale))
    }

    /// `0.237` gives `24%`; `decimals: 1` gives `23.7%`.
    static func percent(_ fraction: Double, decimals: Int = 0, locale: Locale = .current) -> String {
        number(clamp(fraction) * 100, decimals: decimals, locale: locale) + "%"
    }

    /// Disk bytes as decimal gigabytes, number only.
    static func diskGigabytes(_ bytes: Double, decimals: Int = 2, locale: Locale = .current) -> String {
        number(bytes / decimalGigabyte, decimals: decimals, locale: locale)
    }

    /// Memory bytes as binary gigabytes, number only.
    static func memoryGigabytes(_ bytes: Double, decimals: Int = 1, locale: Locale = .current) -> String {
        number(bytes / binaryGigabyte, decimals: decimals, locale: locale)
    }

    // MARK: - Speeds

    enum SpeedUnit: Equatable, Sendable {
        case kilobytes, megabytes, gigabytes

        var divisor: Double {
            switch self {
            case .kilobytes: 1_000
            case .megabytes: 1_000_000
            case .gigabytes: 1_000_000_000
            }
        }

        var label: String {
            switch self {
            case .kilobytes: String(localized: "KB/s")
            case .megabytes: String(localized: "MB/s")
            case .gigabytes: String(localized: "GB/s")
            }
        }
    }

    /// Picks the unit the way the menu bar reads best: KB/s under 1 MB/s, MB/s under 1 GB/s.
    static func speedUnit(for bytesPerSecond: Double) -> SpeedUnit {
        switch bytesPerSecond {
        case ..<999_950: .kilobytes
        case ..<999_950_000: .megabytes
        default: .gigabytes
        }
    }

    /// `1_500` bytes per second gives `("1.5", .kilobytes)`.
    static func speed(_ bytesPerSecond: Double, decimals: Int = 1, locale: Locale = .current) -> (value: String, unit: SpeedUnit) {
        let safe = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        let unit = speedUnit(for: safe)
        return (number(safe / unit.divisor, decimals: decimals, locale: locale), unit)
    }

    static func speedText(_ bytesPerSecond: Double, decimals: Int = 1, locale: Locale = .current) -> String {
        let parts = speed(bytesPerSecond, decimals: decimals, locale: locale)
        return "\(parts.value) \(parts.unit.label)"
    }

    static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }
}

/// Scale of a history chart: the top guide line and its half, like the popups show them.
nonisolated struct ChartScale: Equatable, Sendable {
    let top: Double

    /// Rounds the largest value up to a readable top (1, 2, 2.5, 5 times a power of ten), never below `minimum`.
    init(values: [Double], minimum: Double) {
        let largest = max(values.filter(\.isFinite).max() ?? 0, minimum)
        guard largest > 0 else {
            top = 1
            return
        }
        let magnitude = pow(10, floor(log10(largest)))
        let steps: [Double] = [1, 2, 2.5, 5, 10]
        let step = steps.first { $0 * magnitude >= largest } ?? 10
        top = step * magnitude
    }

    var half: Double { top / 2 }

    /// Height fraction of a value in this scale.
    func fraction(of value: Double) -> Double {
        guard top > 0, value.isFinite else { return 0 }
        return min(1, max(0, value / top))
    }
}
