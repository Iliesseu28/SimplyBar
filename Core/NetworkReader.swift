import Darwin
import Foundation

/// Byte counters of one interface. `if_data` keeps them on 32 bits, so they wrap after 4 GB.
nonisolated struct InterfaceCounters: Equatable, Sendable {
    var received: UInt32
    var sent: UInt32
}

nonisolated enum NetworkMath {
    /// Shortest time between two readings that gives a speed: over a shorter window, a few packets (or none)
    /// read as an absurd or a false zero speed.
    static let minimumElapsed: TimeInterval = 0.5

    /// Speed between two readings. Interfaces missing from either reading are ignored (plugged or unplugged).
    static func sample(previous: [String: InterfaceCounters], current: [String: InterfaceCounters],
                       elapsed: TimeInterval) -> NetworkSample? {
        guard elapsed >= minimumElapsed, !previous.isEmpty else { return nil }
        var received = 0.0, sent = 0.0
        for (name, new) in current {
            guard let old = previous[name] else { continue }
            received += Double(new.received &- old.received)
            sent += Double(new.sent &- old.sent)
        }
        return NetworkSample(upload: sent / elapsed, download: received / elapsed)
    }

    /// Physical interfaces only (Ethernet and Wi-Fi are `en*`): VPN tunnels would count the same bytes twice.
    static func isCounted(interface name: String) -> Bool {
        name.hasPrefix("en")
    }
}

/// What one pass over the interface list gives.
nonisolated struct NetworkReading: Equatable, Sendable {
    /// Speed since the previous reading, nil for the first one.
    var sample: NetworkSample?
    /// IPv4 address of the main interface, only looked up when asked for.
    var localIP: String?
}

/// Reads network throughput and the local IPv4 address.
nonisolated final class NetworkReader {
    private var previous: [String: InterfaceCounters] = [:]
    private var previousDate: Date?

    /// Speed since the previous reading and, when `localIP` is true, the local address, from one `getifaddrs` call.
    /// Nil, without reading anything, when the previous reading is less than `NetworkMath.minimumElapsed` old:
    /// that one stays the reference.
    func read(now: Date = .now, localIP: Bool = false) -> NetworkReading? {
        if let previousDate, now.timeIntervalSince(previousDate) < NetworkMath.minimumElapsed { return nil }
        let snapshot = Self.snapshot(localIP: localIP)
        defer {
            previous = snapshot.counters
            previousDate = now
        }
        let sample = previousDate.flatMap {
            NetworkMath.sample(previous: previous, current: snapshot.counters, elapsed: now.timeIntervalSince($0))
        }
        return NetworkReading(sample: sample, localIP: snapshot.localIP)
    }

    static func counters() -> [String: InterfaceCounters] {
        snapshot(localIP: false).counters
    }

    /// IPv4 address of the main interface (`en0` first), or nil when offline.
    static func localIPAddress() -> String? {
        snapshot(localIP: true).localIP
    }

    /// Byte counters of the counted interfaces and, when asked, the local IPv4 address, in one pass.
    static func snapshot(localIP: Bool) -> (counters: [String: InterfaceCounters], localIP: String?) {
        var counters: [String: InterfaceCounters] = [:]
        var candidates: [(name: String, address: String)] = []
        forEachInterface { name, flags, address, data in
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 else { return }
            if address.sa_family == UInt8(AF_LINK) {
                guard let data, NetworkMath.isCounted(interface: name) else { return }
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = InterfaceCounters(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
            } else if localIP, address.sa_family == UInt8(AF_INET), let text = ipv4Text(address) {
                candidates.append((name, text))
            }
        }
        return (counters, localIP ? preferredAddress(in: candidates) : nil)
    }

    /// Dotted text of an IPv4 address, nil for a link-local one (no DHCP answer).
    private static func ipv4Text(_ address: sockaddr) -> String? {
        var ipv4 = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.hasPrefix("169.254.") ? nil : text
    }

    static func preferredAddress(in candidates: [(name: String, address: String)]) -> String? {
        candidates.first { $0.name == "en0" }?.address
            ?? candidates.first { $0.name.hasPrefix("en") }?.address
            ?? candidates.first?.address
    }

    private static func forEachInterface(_ body: (String, UInt32, sockaddr, UnsafeMutableRawPointer?) -> Void) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let item = entry.pointee
            if let address = item.ifa_addr {
                body(String(cString: item.ifa_name), item.ifa_flags, address.pointee, item.ifa_data)
            }
            cursor = item.ifa_next
        }
    }
}
