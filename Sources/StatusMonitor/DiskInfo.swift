import Foundation

/// S.M.A.R.T. health plus the NVMe counters Apple exposes through `diskutil`.
///
/// Apple never exposes the raw ATA attribute table; the per-device NVMe log pages
/// surfaced as `SMARTDeviceSpecificKeysMayVaryNotGuaranteed` are the whole story.
struct DiskMetrics: Sendable, Equatable {
    struct KeyValue: Sendable, Equatable, Identifiable {
        let key: String
        let value: UInt64
        var id: String { key }
    }

    var status = "—"
    var mediaName: String?
    var solidState: Bool?
    var bus: String?
    var physicalBytes: UInt64?
    var usedBytes: UInt64?
    var containerBytes: UInt64?
    var freeBytes: UInt64?
    var volumeName: String?
    var temperature: Double?
    var percentageUsed: Double?
    var availableSpare: Double?
    var spareThreshold: Double?
    var dataUnitsRead: UInt64?
    var dataUnitsWritten: UInt64?
    var powerCycles: UInt64?
    var powerOnHours: UInt64?
    var unsafeShutdowns: UInt64?
    var mediaErrors: UInt64?
    var remaining: [KeyValue] = []

    static let unavailable = DiskMetrics()

    var isHealthy: Bool { status.caseInsensitiveCompare("Verified") == .orderedSame }
    var isFailing: Bool { status.lowercased().contains("fail") }
    var isReported: Bool { status != "—" }
    var supportsSMARTCounters: Bool { percentageUsed != nil || availableSpare != nil || powerOnHours != nil }

    /// NVMe data units are 512 KiB by definition of the specification.
    static let bytesPerDataUnit = 512.0 * 1024.0

    var hostBytesRead: Double? { dataUnitsRead.map { Double($0) * Self.bytesPerDataUnit } }
    var hostBytesWritten: Double? { dataUnitsWritten.map { Double($0) * Self.bytesPerDataUnit } }

    /// Capacity denominator: the APFS container when known, else the whole device.
    var capacityBytes: UInt64? { containerBytes ?? physicalBytes }

    var usedFraction: Double? {
        guard let usedBytes, let capacity = capacityBytes, capacity > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(capacity)))
    }

    var freeFraction: Double? {
        guard let freeBytes, let capacity = capacityBytes, capacity > 0 else { return nil }
        return min(1, max(0, Double(freeBytes) / Double(capacity)))
    }

    /// 0–100 wear gauge derived from `PERCENTAGE_USED`, as vendors report it.
    var wearFraction: Double? { percentageUsed.map { min(1, max(0, $0 / 100)) } }
}

enum DiskInfoParser {
    /// Physical store identifier (`disk0s2`) backing the volume described by `root`.
    static func physicalStoreID(root: [String: Any]) -> String? {
        if let stores = root["APFSPhysicalStores"] as? [[String: Any]],
           let first = stores.first?["APFSPhysicalStore"] as? String { return first }
        if let reference = root["APFSContainerReference"] as? String,
           let listing = CommandRunner.plist(["apfs", "list", "-plist"]),
           let containers = listing["Containers"] as? [[String: Any]],
           let match = containers.first(where: { ($0["ContainerReference"] as? String) == reference }),
           let stores = match["PhysicalStores"] as? [[String: Any]],
           let first = stores.first?["DeviceIdentifier"] as? String { return first }
        return root["ParentWholeDisk"] as? String
    }

    static func wholeDisk(of device: String) -> String {
        // disk0s2 -> disk0, disk3s1s1 -> disk3, disk0 -> disk0
        guard device.hasPrefix("disk") else { return device }
        let head = device.dropFirst(4).prefix { $0.isNumber }
        return "disk\(head)"
    }

    static func parse(root: [String: Any], apfsListing: [String: Any]?, wholeDisk: [String: Any]) -> DiskMetrics? {
        guard !wholeDisk.isEmpty else { return nil }
        var metrics = DiskMetrics()
        metrics.status = (wholeDisk["SMARTStatus"] as? String)
            ?? (root["SMARTStatus"] as? String)
            ?? "Unsupported"
        metrics.mediaName = (wholeDisk["MediaName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        metrics.solidState = wholeDisk["SolidState"] as? Bool
        metrics.bus = wholeDisk["BusProtocol"] as? String
        metrics.physicalBytes = uint64(wholeDisk["TotalSize"]) ?? uint64(wholeDisk["Size"])
        metrics.usedBytes = uint64(root["CapacityInUse"])
        metrics.containerBytes = uint64(root["APFSContainerSize"])
        metrics.freeBytes = uint64(root["APFSContainerFree"])
        metrics.volumeName = root["VolumeName"] as? String

        let containerID = root["APFSContainerReference"] as? String
        if let containerID, let containers = apfsListing?["Containers"] as? [[String: Any]],
           let container = containers.first(where: { ($0["ContainerReference"] as? String) == containerID }) {
            metrics.containerBytes = metrics.containerBytes ?? uint64(container["CapacityCeiling"])
        }
        if metrics.freeBytes == nil, let containerID,
           let containers = apfsListing?["Containers"] as? [[String: Any]],
           let container = containers.first(where: { ($0["ContainerReference"] as? String) == containerID }),
           let stores = container["PhysicalStores"] as? [[String: Any]] {
            let sizes = stores.compactMap { uint64($0["Size"]) }
            if !sizes.isEmpty { metrics.physicalBytes = metrics.physicalBytes ?? sizes.reduce(0, +) }
        }

        if let raw = wholeDisk["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] {
            apply(smartKeys: raw, to: &metrics)
        }
        return metrics
    }

    private static func apply(smartKeys raw: [String: Any], to metrics: inout DiskMetrics) {
        func number(_ key: String) -> UInt64? { uint64(raw[key]) }
        // The NVMe log pages are split into low/high 32-bit halves on Apple silicon,
        // but the high word is often omitted entirely when it is zero.
        func wide(_ base: String) -> UInt64? {
            if let low = number("\(base)_0") {
                let high = number("\(base)_1") ?? 0
                return (high << 32) | (low & 0xFFFF_FFFF)
            }
            return number(base)
        }

        metrics.availableSpare = percent(number("AVAILABLE_SPARE"))
        metrics.spareThreshold = percent(number("AVAILABLE_SPARE_THRESHOLD"))
        metrics.percentageUsed = percent(number("PERCENTAGE_USED"))
        metrics.dataUnitsRead = wide("DATA_UNITS_READ")
        metrics.dataUnitsWritten = wide("DATA_UNITS_WRITTEN")
        metrics.powerCycles = wide("POWER_CYCLES")
        metrics.powerOnHours = wide("POWER_ON_HOURS")
        metrics.unsafeShutdowns = wide("UNSAFE_SHUTDOWNS")
        metrics.mediaErrors = wide("MEDIA_ERRORS")
        // Apple reports degrees Kelvin here.
        if let kelvin = number("TEMPERATURE") { metrics.temperature = Double(kelvin) - 273.15 }

        let claimed: Set<String> = [
            "AVAILABLE_SPARE", "AVAILABLE_SPARE_THRESHOLD", "PERCENTAGE_USED",
            "DATA_UNITS_READ_0", "DATA_UNITS_READ_1", "DATA_UNITS_WRITTEN_0", "DATA_UNITS_WRITTEN_1",
            "POWER_CYCLES_0", "POWER_CYCLES_1", "POWER_ON_HOURS_0", "POWER_ON_HOURS_1",
            "UNSAFE_SHUTDOWNS_0", "UNSAFE_SHUTDOWNS_1", "MEDIA_ERRORS_0", "MEDIA_ERRORS_1",
            "TEMPERATURE",
        ]
        metrics.remaining = raw
            .filter { !claimed.contains($0.key) }
            .compactMap { key, value in uint64(value).map { DiskMetrics.KeyValue(key: key, value: $0) } }
            .sorted { $0.key < $1.key }
    }

    /// `UInt64` -> `Double` conversion can overflow to garbage for out-of-range keys;
    /// these fields are percentages, so clamp to a sane range instead.
    private static func percent(_ raw: UInt64?) -> Double? {
        guard let raw else { return nil }
        let value = Double(raw)
        guard value.isFinite, (0...1000).contains(value) else { return nil }
        return value
    }

    static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber: return number.uint64Value
        case let value as Int: return UInt64(max(0, value))
        case let value as UInt64: return value
        case let value as String: return UInt64(value)
        default: return nil
        }
    }
}
