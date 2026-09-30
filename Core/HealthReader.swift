import Foundation
import IOKit
import IOKit.ps

/// Heat level and the Mac's own battery, from public APIs the App Sandbox lets an app read:
/// - `ProcessInfo.thermalState` for the heat level (no temperature: the SMC is closed to sandboxed apps);
/// - IOPowerSources for the charge, charging and the condition macOS reports;
/// - the `AppleSmartBattery` entry of the IOKit registry for the cycle count and the capacities.
///
/// A Mac without a battery (Mac mini, iMac, Mac Studio) has no internal battery power source, yet may still publish an
/// `AppleSmartBattery` entry with `BatteryInstalled` = No and zeros: without the power source there is no battery.
nonisolated enum HealthReader {
    /// `battery` false reads the heat level only (the power sources and the registry are left alone).
    static func read(battery: Bool) -> HealthSample {
        HealthSample(thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
                     battery: battery ? MacBatteryReader.read() : nil)
    }
}

nonisolated enum MacBatteryReader {
    /// Registry keys read one by one: the entry also holds large telemetry dictionaries not worth copying.
    static let registryKeys = ["BatteryInstalled", "CycleCount", "DesignCapacity", "NominalChargeCapacity",
                               "AppleRawMaxCapacity"]

    static func read() -> MacBattery? {
        battery(powerSources: powerSourceDescriptions(), registry: registryProperties())
    }

    /// The battery described by the power sources and, when readable, the registry. Nil without an internal battery.
    static func battery(powerSources: [[String: Any]], registry: [String: Any]?) -> MacBattery? {
        guard let source = powerSources.first(where: isInternalBattery),
              let current = source[kIOPSCurrentCapacityKey] as? Int,
              let maximum = source[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
        let charge = Int(min(100, max(0, (Double(current) * 100 / Double(maximum)).rounded())))
        var battery = MacBattery(charge: charge, isCharging: source[kIOPSIsChargingKey] as? Bool ?? false,
                                 condition: condition(source))
        // The registry only counts when it agrees a battery is there.
        if let registry, registry["BatteryInstalled"] as? Bool == true {
            battery.cycleCount = (registry["CycleCount"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            battery.maximumCapacity = maximumCapacity(registry)
        }
        return battery
    }

    private static func isInternalBattery(_ source: [String: Any]) -> Bool {
        source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && source[kIOPSIsPresentKey] as? Bool != false
    }

    /// "Service Recommended" in System Settings: a failure condition, or a health below "Good". Nil when macOS says
    /// nothing.
    static func condition(_ source: [String: Any]) -> MacBattery.Condition? {
        if let failure = source[kIOPSBatteryHealthConditionKey] as? String, !failure.isEmpty { return .serviceRecommended }
        switch source[kIOPSBatteryHealthKey] as? String {
        case kIOPSGoodValue: return .normal
        case kIOPSFairValue, kIOPSPoorValue: return .serviceRecommended
        default: return nil
        }
    }

    /// Full-charge capacity (`NominalChargeCapacity`, else `AppleRawMaxCapacity`) over `DesignCapacity`, in mAh.
    /// A new battery may hold a little more than its design capacity: System Settings shows 100 % then, so does this.
    static func maximumCapacity(_ registry: [String: Any]) -> Int? {
        guard let design = registry["DesignCapacity"] as? Int, design > 0 else { return nil }
        let full = [registry["NominalChargeCapacity"], registry["AppleRawMaxCapacity"]]
            .compactMap { $0 as? Int }.first { $0 > 0 }
        guard let full else { return nil }
        return Int(min(100, (Double(full) * 100 / Double(design)).rounded()))
    }

    // MARK: - System

    private static func powerSourceDescriptions() -> [[String: Any]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// The registry keys of `AppleSmartBattery`, nil when there is no such entry.
    static func registryProperties() -> [String: Any]? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        var properties: [String: Any] = [:]
        for key in registryKeys {
            if let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                properties[key] = value
            }
        }
        return properties
    }
}
