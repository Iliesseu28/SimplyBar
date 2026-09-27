import Foundation
import IOKit

/// Every disk the user sees in Finder, for the Storage widget: the startup disk and the external drives, the APFS
/// volumes of one container counted once. Disk images, network shares and hidden system volumes are left out.
///
/// All readable inside the App Sandbox: `getfsstat` gives each file system's device and block counts (the numbers
/// of `df`), URL resource values its name and purgeable space, the IOKit registry whether it is internal or a
/// mounted disk image.
nonisolated enum VolumeReader {
    /// Mount points that are never a disk the user cares about, even when the system marks them browsable.
    private static let excludedMountPrefixes = [
        "/System/Volumes/",
        "/Library/Developer/CoreSimulator/",
        "/private/var/",
        "/Volumes/Recovery",
    ]

    static func read() -> [VolumeSample] {
        var stores: [String: [MountedVolume]] = [:]
        var disks: [String: DiskHardware] = [:]
        for volume in mountedVolumes() {
            let hardware = disks[volume.wholeDisk] ?? DiskHardware(wholeDisk: volume.wholeDisk)
            disks[volume.wholeDisk] = hardware
            guard !hardware.isDiskImage else { continue }
            stores[volume.storeKey, default: []].append(volume)
        }
        return stores.values.compactMap { members in
            makeSample(members, isInternal: disks[members[0].wholeDisk]?.isInternal)
        }
        .sorted { lhs, rhs in
            if (lhs.id == "/") != (rhs.id == "/") { return lhs.id == "/" }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `disk3s1s1` gives `disk3`, `disk5s2` gives `disk5`.
    static func wholeDiskName(of bsdName: String) -> String? {
        guard bsdName.hasPrefix("disk") else { return nil }
        let digits = bsdName.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? nil : "disk\(digits)"
    }

    // MARK: - Grouping

    /// One sample per store: the volumes of an APFS container share its space, a plain partition has its own.
    private static func makeSample(_ members: [MountedVolume], isInternal: Bool?) -> VolumeSample? {
        let sorted = members.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
        // Named after the startup volume, else a volume Finder shows under /Volumes.
        guard let main = sorted.first(where: { $0.mountPath == "/" })
                ?? sorted.first(where: { $0.mountPath.hasPrefix("/Volumes/") }) ?? sorted.first,
              let total = sorted.map(\.total).max(), total > 0 else { return nil }
        let blocksFree = sorted.map(\.available).max() ?? 0

        let url = URL(fileURLWithPath: main.mountPath, isDirectory: true)
        let values = try? url.resourceValues(forKeys: [
            .volumeLocalizedNameKey, .volumeIsInternalKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        // Free space for important usage adds what macOS purges on demand; the sandbox may not say.
        let important = values?.volumeAvailableCapacityForImportantUsage.map { Double($0) } ?? 0
        let free = min(total, max(blocksFree, important))
        let purgeable: Double? = important > 0 ? max(0, important - blocksFree) : nil

        let fallbackName = main.mountPath == "/" ? "Macintosh HD" : url.lastPathComponent
        return VolumeSample(
            id: main.mountPath,
            name: values?.volumeLocalizedName ?? fallbackName,
            isInternal: isInternal ?? values?.volumeIsInternal ?? (main.mountPath == "/"),
            total: total,
            free: free,
            purgeable: purgeable
        )
    }

    // MARK: - Mounted volumes

    private struct MountedVolume {
        var bsdName: String
        var wholeDisk: String
        var mountPath: String
        var total: Double
        /// Free blocks, the "Avail" column of `df`.
        var available: Double
        /// APFS volumes share their container's space; any other file system has its own partition.
        var storeKey: String
    }

    /// `statfs` names both a C struct and a C function; the alias picks the struct.
    private typealias FileSystemInfo = statfs

    private static func mountedVolumes() -> [MountedVolume] {
        let expected = getfsstat(nil, 0, MNT_NOWAIT)
        guard expected > 0 else { return [] }
        var buffer = [FileSystemInfo](repeating: FileSystemInfo(), count: Int(expected) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer { pointer in
            getfsstat(pointer.baseAddress, Int32(pointer.count * MemoryLayout<FileSystemInfo>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).compactMap(makeVolume(from:))
    }

    private static func makeVolume(from info: FileSystemInfo) -> MountedVolume? {
        let device = cString(info.f_mntfromname)
        let mountPath = cString(info.f_mntonname)
        // Local block devices only (no devfs, autofs, network shares), and no hidden system volume.
        guard device.hasPrefix("/dev/disk"), info.f_flags & UInt32(MNT_DONTBROWSE) == 0,
              !excludedMountPrefixes.contains(where: { mountPath.hasPrefix($0) }) else { return nil }
        let bsdName = String(device.dropFirst("/dev/".count))
        guard let wholeDisk = wholeDiskName(of: bsdName) else { return nil }
        let blockSize = Double(info.f_bsize)
        let total = Double(info.f_blocks) * blockSize
        guard total > 0 else { return nil }
        return MountedVolume(
            bsdName: bsdName,
            wholeDisk: wholeDisk,
            mountPath: mountPath,
            total: total,
            available: Double(info.f_bavail) * blockSize,
            storeKey: cString(info.f_fstypename) == "apfs" ? wholeDisk : bsdName
        )
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// What the IOKit registry says about the hardware under a whole disk (for APFS, under its physical store).
private nonisolated struct DiskHardware {
    var isInternal: Bool?
    var isDiskImage = false

    init(wholeDisk: String) {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, wholeDisk) else { return }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func search(_ key: String) -> [String: Any]? {
            IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, kCFAllocatorDefault, options)
                as? [String: Any]
        }
        let device = search("Device Characteristics")
        let transport = search("Protocol Characteristics")
        let interconnect = transport?["Physical Interconnect"] as? String
        let location = transport?["Physical Interconnect Location"] as? String
        isDiskImage = device?["Product Name"] as? String == "Disk Image" || interconnect == "Virtual Interface"
            || location == "File"
        if let location { isInternal = location == "Internal" }
    }
}
