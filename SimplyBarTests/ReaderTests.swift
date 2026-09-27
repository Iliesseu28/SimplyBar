@preconcurrency import Darwin
import Foundation
import Testing

struct CPUTests {
    @Test func loadComesFromTickDeltas() throws {
        let previous = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CPUTicks(user: 160, system: 70, idle: 870, nice: 0), CPUTicks(user: 10, system: 10, idle: 80, nice: 0)]
        let sample = try #require(CPULoad.sample(previous: previous, current: current))
        // Core 1: 60 user, 20 system, 20 idle. Core 2: 10, 10, 80. Sum: 70, 30, 100.
        #expect(abs(sample.user - 0.35) < 1e-9)
        #expect(abs(sample.system - 0.15) < 1e-9)
        #expect(abs(sample.idle - 0.5) < 1e-9)
        #expect(sample.perCore.count == 2)
        #expect(abs(sample.perCore[0] - 0.8) < 1e-9)
        #expect(abs(sample.perCore[1] - 0.2) < 1e-9)
    }

    @Test func niceTimeCountsAsUserAndCountersWrap() throws {
        let previous = [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 5)]
        let current = [CPUTicks(user: 10, system: 0, idle: 60, nice: 25)]
        let sample = try #require(CPULoad.sample(previous: previous, current: current))
        // 20 user after the wrap, plus 20 nice, against 60 idle.
        #expect(abs(sample.user - 0.4) < 1e-9)
        #expect(abs(sample.idle - 0.6) < 1e-9)
    }

    @Test func noElapsedTickGivesNothingRatherThanZero() {
        let ticks = [CPUTicks(user: 100, system: 50, idle: 850, nice: 0), CPUTicks(user: 7, system: 3, idle: 90, nice: 1)]
        #expect(CPULoad.sample(previous: ticks, current: ticks) == nil)
    }

    @Test func mismatchedReadingsGiveNothing() {
        #expect(CPULoad.sample(previous: [], current: []) == nil)
        let one = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]
        #expect(CPULoad.sample(previous: one, current: one + one) == nil)
    }
}

struct MemoryTests {
    @Test func appMemoryIsAnonymousMinusPurgeable() {
        // Figures read from vm_stat on the reference Mac (16 KB pages).
        let pages = MemoryPages(internalPages: 269_911, purgeable: 20_786, wired: 118_319, compressor: 117_195, pageSize: 16_384)
        let sample = MemoryMath.sample(pages: pages, physicalMemory: 17_179_869_184)
        #expect(sample.app == Double(269_911 - 20_786) * 16_384)
        #expect(sample.wired == 118_319 * 16_384)
        #expect(sample.compressed == 117_195 * 16_384)
        #expect(abs(sample.pressure - Double(118_319 + 117_195) * 16_384 / 17_179_869_184) < 1e-12)
    }

    @Test func purgeableAboveAnonymousDoesNotUnderflow() {
        let pages = MemoryPages(internalPages: 10, purgeable: 50, wired: 0, compressor: 0, pageSize: 16_384)
        #expect(MemoryMath.sample(pages: pages, physicalMemory: 1).app == 0)
    }
}

struct NetworkTests {
    @Test func speedIsTheDeltaOverTime() throws {
        let previous = ["en0": InterfaceCounters(received: 1_000, sent: 500)]
        let current = ["en0": InterfaceCounters(received: 21_000, sent: 4_500)]
        let sample = try #require(NetworkMath.sample(previous: previous, current: current, elapsed: 2))
        #expect(sample.download == 10_000)
        #expect(sample.upload == 2_000)
    }

    @Test func thirtyTwoBitCountersWrap() throws {
        let previous = ["en0": InterfaceCounters(received: UInt32.max - 999, sent: 0)]
        let current = ["en0": InterfaceCounters(received: 1_000, sent: 0)]
        let sample = try #require(NetworkMath.sample(previous: previous, current: current, elapsed: 1))
        #expect(sample.download == 2_000)
    }

    @Test func newInterfacesAndFirstReadingAreIgnored() throws {
        #expect(NetworkMath.sample(previous: [:], current: ["en0": .init(received: 5, sent: 5)], elapsed: 1) == nil)
        #expect(NetworkMath.sample(previous: ["en0": .init(received: 0, sent: 0)], current: [:], elapsed: 0) == nil)
        let sample = try #require(NetworkMath.sample(
            previous: ["en0": .init(received: 0, sent: 0)],
            current: ["en0": .init(received: 100, sent: 0), "en5": .init(received: 9_999, sent: 9_999)],
            elapsed: 1
        ))
        #expect(sample.download == 100 && sample.upload == 0)
    }

    @Test func readingsTooCloseGiveNothing() throws {
        let previous = ["en0": InterfaceCounters(received: 0, sent: 0)]
        let current = ["en0": InterfaceCounters(received: 1_000, sent: 0)]
        #expect(NetworkMath.sample(previous: previous, current: current, elapsed: 0.001) == nil)
        #expect(NetworkMath.sample(previous: previous, current: current, elapsed: 0.49) == nil)
        let sample = try #require(NetworkMath.sample(previous: previous, current: current, elapsed: 0.5))
        #expect(sample.download == 2_000)
    }

    @Test func readerWaitsHalfASecondBetweenReadings() {
        let reader = NetworkReader()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(reader.read(now: start) != nil)
        // Too soon: nothing read, and the first reading stays the reference.
        #expect(reader.read(now: start.addingTimeInterval(0.2)) == nil)
        let third = reader.read(now: start.addingTimeInterval(0.6))
        #expect(third != nil)
        if !NetworkReader.counters().isEmpty { #expect(third?.sample != nil) }
    }

    @Test func onlyPhysicalInterfacesCount() {
        #expect(NetworkMath.isCounted(interface: "en0"))
        #expect(NetworkMath.isCounted(interface: "en8"))
        #expect(!NetworkMath.isCounted(interface: "lo0"))
        #expect(!NetworkMath.isCounted(interface: "utun3"))
        #expect(!NetworkMath.isCounted(interface: "awdl0"))
    }
}

struct BluetoothTests {
    @Test func batteryPercentStaysInRange() {
        #expect(BluetoothReader.batteryPercent(55, of: 100) == 55)
        #expect(BluetoothReader.batteryPercent(29, of: 30) == 96)
        #expect(BluetoothReader.batteryPercent(-5, of: 100) == 0)
        #expect(BluetoothReader.batteryPercent(150, of: 100) == 100)
        // An absurd capacity must not overflow the multiplication.
        #expect(BluetoothReader.batteryPercent(Int.max, of: 1) == 100)
        #expect(BluetoothReader.batteryPercent(10, of: 0) == 0)
    }

    @Test func earlierSourceWinsForTheSameDevice() {
        let later = [BluetoothDevice(name: "Mouse", levels: [.init(part: .main, percent: 50)]),
                     BluetoothDevice(name: "Trackpad", levels: [.init(part: .main, percent: 90)])]
        let earlier = [BluetoothDevice(name: "Mouse", levels: [.init(part: .main, percent: 55)])]
        let merged = BluetoothReader.merge([earlier, later])
        #expect(merged.count == 2)
        #expect(merged.first { $0.name == "Mouse" }?.levels.first?.percent == 55)
    }

    @Test func devicesSharingANameKeepDistinctIdentifiers() {
        let twins = [BluetoothDevice(name: "Earbuds", address: "AA:00:00:00:00:01", levels: []),
                     BluetoothDevice(name: "Earbuds", address: "AA:00:00:00:00:02", levels: [])]
        let mice = [BluetoothDevice(name: "Mouse", levels: []), BluetoothDevice(name: "Mouse", levels: [])]
        let merged = BluetoothReader.merge([twins, mice])
        #expect(merged.count == 4)
        #expect(Set(merged.map(\.id)).count == 4)
        #expect(merged.filter { $0.name == "Mouse" }.map(\.id) == ["Mouse", "Mouse #2"])
    }

    @Test func laterSourcesOnlyAddMissingDevices() {
        let address = "EC:A1:2F:54:96:BF"
        let powerSources = [BluetoothDevice(name: "Headset", levels: [.init(part: .main, percent: 40)])]
        let audio = [BluetoothDevice(name: "Headset", address: address, levels: []),
                     BluetoothDevice(name: "Headset", address: address, levels: []),
                     BluetoothDevice(name: "Speaker", address: "AA:BB:CC:DD:EE:FF", levels: [])]
        let merged = BluetoothReader.merge([powerSources, audio])
        #expect(merged.map(\.name) == ["Headset", "Speaker"])
        #expect(merged.first?.lowest == 40)
    }

    @Test func addressesAreNormalized() {
        #expect(BluetoothReader.normalizedAddress("ec-a1-2f-54-96-bf") == "EC:A1:2F:54:96:BF")
        #expect(BluetoothReader.normalizedAddress("EC-A1-2F-54-96-BF:output") == "EC:A1:2F:54:96:BF")
        #expect(BluetoothReader.normalizedAddress("BuiltInSpeakerDevice") == nil)
        #expect(BluetoothReader.normalizedAddress("EC:A1:2F:54:96") == nil)
    }
}

struct DiskTests {
    @Test func wholeDiskNamesDropSlices() {
        #expect(VolumeReader.wholeDiskName(of: "disk3s1s1") == "disk3")
        #expect(VolumeReader.wholeDiskName(of: "disk12s2") == "disk12")
        #expect(VolumeReader.wholeDiskName(of: "disk5") == "disk5")
        #expect(VolumeReader.wholeDiskName(of: "devfs") == nil)
    }

    @Test func sandboxRoundingDoesNotFlash() {
        // One rounding step of the sandbox: 100 000 blocks of 4 KiB.
        let step = 100_000.0 * 4_096
        #expect(DiskReader.significantChange > step)
        #expect(!DiskReader.isSignificantChange(step))
        #expect(!DiskReader.isSignificantChange(-step))
        #expect(DiskReader.isSignificantChange(500_000_000))
        #expect(DiskReader.isSignificantChange(-2_000_000_000))
    }
}

/// The live readers run on this Mac; they must give plausible numbers, not exact ones.
struct LiveReaderTests {
    @Test func diskReadingIsPlausible() throws {
        let disk = try #require(DiskReader.read())
        #expect(disk.total > 10_000_000_000)
        #expect(disk.free > 0 && disk.free <= disk.total)
        let blocks = try #require(DiskReader.freeBlocks())
        // Important-usage space adds purgeable space to the free blocks, never less.
        #expect(disk.free >= blocks * 0.95)
    }

    @Test func memoryReadingIsPlausible() throws {
        let pages = try #require(MemoryReader.pages())
        #expect(pages.pageSize == UInt64(vm_kernel_page_size))
        #if arch(arm64)
        #expect(pages.pageSize == 16_384)
        #endif
        let sample = try #require(MemoryReader.read())
        #expect(sample.total == Double(ProcessInfo.processInfo.physicalMemory))
        #expect(sample.used > 0 && sample.used <= sample.total)
    }

    @Test func cpuReadingIsPlausible() throws {
        let reader = CPUReader()
        #expect(reader.read() == nil)
        Thread.sleep(forTimeInterval: 0.3)
        let sample = try #require(reader.read())
        #expect(sample.perCore.count == ProcessInfo.processInfo.activeProcessorCount)
        #expect(abs(sample.user + sample.system + sample.idle - 1) < 0.001)
    }

    @Test func volumesStartWithTheStartupDisk() throws {
        let volumes = VolumeReader.read()
        let startup = try #require(volumes.first)
        #expect(startup.id == "/")
        #expect(startup.isInternal)
        for volume in volumes {
            #expect(volume.total > 0)
            #expect(volume.free >= 0 && volume.free <= volume.total)
            #expect((volume.purgeable ?? 0) <= volume.free)
        }
        // APFS volumes of one container are counted once: no two disks at the same mount path.
        #expect(Set(volumes.map(\.id)).count == volumes.count)
    }

    @Test func networkCountersExist() {
        #expect(NetworkReader.counters().keys.allSatisfy { NetworkMath.isCounted(interface: $0) })
    }
}

struct SamplingTests {
    @Test func bluetoothHasItsOwnIntervals() {
        #expect(Sampling.bluetoothIntervals == [30, 60, 120, 300, 600])
        #expect(Sampling.bluetoothIntervals.contains(Sampling.defaultBluetoothInterval))
        // The CPU and GPU list stops at 59 s: the Bluetooth default would have no row in it.
        #expect(!Sampling.intervals.contains(Sampling.defaultBluetoothInterval))
    }

    @Test func savedIntervalSnapsToTheClosestOption() {
        #expect(Sampling.closest(to: 6, in: Sampling.bluetoothIntervals) == 30)
        #expect(Sampling.closest(to: 59, in: Sampling.bluetoothIntervals) == 60)
        #expect(Sampling.closest(to: 90, in: Sampling.bluetoothIntervals) == 60)
        #expect(Sampling.closest(to: 100, in: Sampling.bluetoothIntervals) == 120)
        #expect(Sampling.closest(to: 5_000, in: Sampling.bluetoothIntervals) == 600)
        #expect(Sampling.closest(to: 300, in: Sampling.bluetoothIntervals) == 300)
        // A hand-edited CPU or GPU interval of 0 would make a timer fire in a tight loop.
        #expect(Sampling.closest(to: 0, in: Sampling.intervals) == 2)
        #expect(Sampling.closest(to: 3_600, in: Sampling.intervals) == 59)
    }
}
