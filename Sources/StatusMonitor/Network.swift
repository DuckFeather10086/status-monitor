import Foundation
import SystemConfiguration

struct NetworkSnapshot: Sendable {
    var download = 0.0
    var upload = 0.0
    var received: UInt64 = 0
    var sent: UInt64 = 0
    var interface = "Offline"
    var interfaces: [String] = []
}

struct NetworkCounters {
    var received: UInt64
    var sent: UInt64
}

struct NetworkDelta {
    private var previous: NetworkCounters?
    private var previousTime: TimeInterval?
    private var previousInterface: String?
    private(set) var received: UInt64 = 0
    private(set) var sent: UInt64 = 0

    mutating func update(_ counters: NetworkCounters?, interface: String?, time: TimeInterval) -> (Double, Double) {
        defer { previous = counters; previousTime = time; previousInterface = interface }
        guard interface == previousInterface else {
            received = 0; sent = 0
            return (0, 0)
        }
        guard let counters, let previous, let previousTime, time > previousTime else { return (0, 0) }
        // Link resets are not traffic; 64-bit counters avoid the old 4 GiB wrap.
        let down = counters.received >= previous.received ? counters.received - previous.received : 0
        let up = counters.sent >= previous.sent ? counters.sent - previous.sent : 0
        received &+= down; sent &+= up
        return (Double(down) / (time - previousTime), Double(up) / (time - previousTime))
    }
}

struct NetworkReader {
    private var delta = NetworkDelta()

    mutating func read(selection: String) -> NetworkSnapshot {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return offline() }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return offline() }
        var counters: [String: NetworkCounters] = [:]
        buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                if header.ifm_type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                    let info = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil,
                       info.ifm_flags & IFF_LOOPBACK == 0, info.ifm_flags & IFF_UP != 0, info.ifm_flags & IFF_RUNNING != 0 {
                        counters[String(cString: name)] = NetworkCounters(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                    }
                }
                offset += length
            }
        }
        let names = counters.keys.sorted()
        let primary = primaryInterface()
        let selected: String? = selection == "auto"
            ? (primary.flatMap { counters[$0] == nil ? nil : $0 } ?? names.first(where: { $0.hasPrefix("en") }))
            : (counters[selection] == nil ? nil : selection)
        let rates = delta.update(selected.flatMap { counters[$0] }, interface: selected, time: ProcessInfo.processInfo.systemUptime)
        return NetworkSnapshot(download: rates.0, upload: rates.1, received: delta.received, sent: delta.sent,
                               interface: selected ?? "Offline", interfaces: names)
    }

    private mutating func offline() -> NetworkSnapshot {
        _ = delta.update(nil, interface: nil, time: ProcessInfo.processInfo.systemUptime)
        return NetworkSnapshot()
    }

    private func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "StatusMonitor" as CFString, nil, nil) else { return nil }
        for protocolName in ["IPv4", "IPv6"] {
            if let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(protocolName)" as CFString) as? [String: Any],
               let name = state["PrimaryInterface"] as? String { return name }
        }
        return nil
    }
}
