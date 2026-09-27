import CoreAudio
import Foundation
import IOKit
import IOKit.ps

/// Connected Bluetooth devices and their battery levels, from the sources an app can still read inside the App
/// Sandbox, in order of preference:
/// - the IOKit registry (Apple keyboards, mice and trackpads publish `BatteryPercent`);
/// - IOPowerSources (accessories macOS lists as power sources, the ones `pmset -g accps` prints);
/// - devices connected without a battery level: Bluetooth HID devices (IOKit) and audio devices (Core Audio).
///
/// No external tool is started: `system_profiler` answers a sandboxed app with an empty report.
nonisolated enum BluetoothReader {
    /// Runs away from the main actor: the IOKit walks and Core Audio are not free.
    @concurrent static func read() async -> [BluetoothDevice] {
        merge([hidBatteryDevices(), powerSourceDevices(), connectedHIDDevices(), audioDevices()])
    }

    // MARK: - IOKit

    /// Apple keyboards, mice and trackpads.
    static func hidBatteryDevices() -> [BluetoothDevice] {
        registryDevices(matching: "AppleDeviceManagementHIDEventService") { entry in
            guard let percent = (property(entry, "BatteryPercent") as? NSNumber)?.intValue,
                  let name = property(entry, "Product") as? String else { return nil }
            let address = (property(entry, "DeviceAddress") as? String).flatMap(normalizedAddress)
            return BluetoothDevice(name: name, address: address,
                                   levels: [.init(part: .main, percent: min(100, max(0, percent)))])
        }
    }

    /// Keyboards, mice and game controllers connected over Bluetooth, battery or not.
    static func connectedHIDDevices() -> [BluetoothDevice] {
        registryDevices(matching: "IOHIDDevice") { entry in
            guard let transport = property(entry, "Transport") as? String, transport.hasPrefix("Bluetooth"),
                  let name = property(entry, "Product") as? String else { return nil }
            let address = (property(entry, "SerialNumber") as? String).flatMap(normalizedAddress)
            return BluetoothDevice(name: name, address: address, levels: [])
        }
    }

    private static func registryDevices(matching className: String,
                                        _ device: (io_registry_entry_t) -> BluetoothDevice?) -> [BluetoothDevice] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [BluetoothDevice] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            if let found = device(entry) { devices.append(found) }
        }
        return devices
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - Power sources

    /// Accessories with a battery that macOS publishes as power sources (not the Mac's own battery or a UPS).
    static func powerSourceDevices() -> [BluetoothDevice] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return sources.compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let type = description[kIOPSTypeKey] as? String,
                  type != kIOPSInternalBatteryType, type != kIOPSUPSType,
                  description[kIOPSIsPresentKey] as? Bool != false,
                  let name = description[kIOPSNameKey] as? String,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }
            let percent = batteryPercent(current, of: maximum)
            return BluetoothDevice(name: name, levels: [.init(part: .main, percent: percent)])
        }
    }

    /// `current` over `maximum` as a whole percent between 0 and 100. Computed in floating point: an accessory
    /// reporting an absurd capacity must not overflow an integer multiplication.
    static func batteryPercent(_ current: Int, of maximum: Int) -> Int {
        guard maximum > 0 else { return 0 }
        return Int(min(100, max(0, Double(current) * 100 / Double(maximum))))
    }

    // MARK: - Core Audio

    /// Headphones and speakers connected over Bluetooth. Core Audio gives no battery level.
    static func audioDevices() -> [BluetoothDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        return objects.compactMap { object in
            guard let transport = audioUInt32(object, kAudioDevicePropertyTransportType),
                  transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                  let name = audioString(object, kAudioObjectPropertyName) else { return nil }
            let address = audioString(object, kAudioDevicePropertyDeviceUID).flatMap(normalizedAddress)
            return BluetoothDevice(name: name, address: address, levels: [])
        }
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func audioString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - Merge

    /// `"0a-1b-2c-3d-4e-5f"`, `"0A:1B:2C:3D:4E:5F"` or an audio device UID such as `"0A-1B-2C-3D-4E-5F:output"`
    /// give `"0A:1B:2C:3D:4E:5F"`; anything else gives nil.
    static func normalizedAddress(_ text: String) -> String? {
        let candidate = text.uppercased().replacingOccurrences(of: "-", with: ":").prefix(17)
        let bytes = candidate.split(separator: ":", omittingEmptySubsequences: false)
        guard bytes.count == 6, bytes.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return String(candidate)
    }

    /// One row per device, sources in order of preference: a later source only adds devices the earlier ones missed
    /// (same address, or same name when one of them has no address). Identifiers end up unique even when two devices
    /// share a name.
    static func merge(_ sources: [[BluetoothDevice]]) -> [BluetoothDevice] {
        var merged: [BluetoothDevice] = []
        for source in sources {
            let earlier = merged.count
            for device in source {
                // Within one source, only an address proves two entries are one device (Core Audio lists a headset
                // once for output and once for its microphone).
                let known = merged[..<earlier].contains { $0.isSameDevice(as: device) }
                    || merged[earlier...].contains { device.address != nil && $0.address == device.address }
                if !known { merged.append(device) }
            }
        }
        var seen: [String: Int] = [:]
        for index in merged.indices {
            let id = merged[index].id
            seen[id, default: 0] += 1
            if let count = seen[id], count > 1 { merged[index].id = "\(id) #\(count)" }
        }
        return merged.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

private extension BluetoothDevice {
    func isSameDevice(as other: BluetoothDevice) -> Bool {
        if let address, let otherAddress = other.address { return address == otherAddress }
        return name == other.name
    }
}
