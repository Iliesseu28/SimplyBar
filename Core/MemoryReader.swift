// `vm_kernel_page_size` is a C global the kernel sets once at launch: read-only in practice.
@preconcurrency import Darwin
import Foundation

/// Page counters of `host_statistics64(HOST_VM_INFO64)`, the ones `vm_stat` prints.
nonisolated struct MemoryPages: Equatable, Sendable {
    /// "Anonymous pages" of `vm_stat`.
    var internalPages: UInt64
    /// "Pages purgeable".
    var purgeable: UInt64
    /// "Pages wired down".
    var wired: UInt64
    /// "Pages occupied by compressor".
    var compressor: UInt64
    var pageSize: UInt64
}

nonisolated enum MemoryMath {
    /// App memory = anonymous pages minus purgeable ones, as Activity Monitor counts it.
    static func sample(pages: MemoryPages, physicalMemory: UInt64) -> MemorySample {
        let size = Double(pages.pageSize)
        let app = Double(pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0) * size
        return MemorySample(
            total: Double(physicalMemory),
            app: app,
            wired: Double(pages.wired) * size,
            compressed: Double(pages.compressor) * size
        )
    }
}

nonisolated enum MemoryReader {
    static func pages() -> MemoryPages? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(currentTask(), host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryPages(
            internalPages: UInt64(stats.internal_page_count),
            purgeable: UInt64(stats.purgeable_count),
            wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count),
            // Counters are in kernel pages. getpagesize() gives the process's page size, 4 KB under Rosetta
            // on a 16 KB kernel.
            pageSize: UInt64(vm_kernel_page_size)
        )
    }

    static func read() -> MemorySample? {
        guard let pages = pages() else { return nil }
        return MemoryMath.sample(pages: pages, physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }
}
