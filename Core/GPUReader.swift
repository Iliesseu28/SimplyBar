import Foundation
import IOKit

/// GPU utilization from the IOKit registry (`IOAccelerator` services, read-only, allowed in the App Sandbox).
nonisolated enum GPUReader {
    /// Keys drivers use for overall utilization, in order of preference.
    static let utilizationKeys = ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"]

    static func read() -> [GPUSample] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var samples: [GPUSample] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            guard let stats = property(entry, "PerformanceStatistics", searchParents: false) as? [String: Any],
                  let percent = utilization(in: stats) else { continue }
            samples.append(GPUSample(model: model(of: entry), utilization: Format.clamp(percent / 100)))
        }
        return samples
    }

    static func utilization(in stats: [String: Any]) -> Double? {
        for key in utilizationKeys {
            if let number = stats[key] as? NSNumber { return number.doubleValue }
        }
        return nil
    }

    private static func model(of entry: io_registry_entry_t) -> String {
        switch property(entry, "model", searchParents: true) {
        case let text as String:
            return text
        case let data as Data:
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        default:
            return "GPU"
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String, searchParents: Bool) -> Any? {
        if searchParents {
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            return IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
        }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
