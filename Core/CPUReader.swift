import Darwin

/// Cumulative scheduler ticks of one core, as `host_processor_info` reports them.
nonisolated struct CPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Turns two tick readings into usage fractions.
nonisolated enum CPULoad {
    /// Usage between two readings, nil when no tick elapsed between them. Counters are 32-bit and may wrap:
    /// deltas use wrapping subtraction.
    static func sample(previous: [CPUTicks], current: [CPUTicks]) -> CPUSample? {
        guard !current.isEmpty, previous.count == current.count else { return nil }

        var user = 0.0, system = 0.0, idle = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)

        for (old, new) in zip(previous, current) {
            let coreUser = Double(new.user &- old.user) + Double(new.nice &- old.nice)
            let coreSystem = Double(new.system &- old.system)
            let coreIdle = Double(new.idle &- old.idle)
            let coreTotal = coreUser + coreSystem + coreIdle
            perCore.append(coreTotal > 0 ? (coreUser + coreSystem) / coreTotal : 0)
            user += coreUser
            system += coreSystem
            idle += coreIdle
        }

        let total = user + system + idle
        // No tick between the two readings (taken a moment apart): no measure, rather than a false 0 %.
        guard total > 0 else { return nil }
        return CPUSample(user: user / total, system: system / total, idle: idle / total, perCore: perCore)
    }
}

/// Reads CPU usage. Needs two calls: the first one only stores the starting ticks.
nonisolated final class CPUReader {
    private let host = mach_host_self()
    private var previous: [CPUTicks] = []

    func read() -> CPUSample? {
        let current = currentTicks()
        defer { previous = current }
        return CPULoad.sample(previous: previous, current: current)
    }

    func currentTicks() -> [CPUTicks] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(currentTask(), vm_address_t(UInt(bitPattern: info)), size)
        }

        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(coreCount)).map { core in
            let base = core * stride
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }
}

/// The current task port (`mach_task_self()` in C).
nonisolated func currentTask() -> mach_port_t {
    mach_task_self_
}
