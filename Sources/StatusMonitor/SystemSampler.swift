import Combine
import Foundation
import IOKit

struct GPUMetrics: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let usage: Double?
    let renderer: Double?
    let tiler: Double?
}

struct SystemMetrics: Sendable {
    var cpuUsage: Double?
    var cores: [Double?] = []
    var gpus: [GPUMetrics] = []
    var thermal = ThermalMetrics()
    var network = NetworkSnapshot()
    var smartStatus = "—"
    var battery: BatteryMetrics?
    var sampledAt = Date()
    var gpuUsage: Double? { gpus.compactMap(\.usage).max() }
    static let empty = SystemMetrics()

    func temperature(sensor: String) -> Double? {
        if sensor == "cpu" { return thermal.cpu }
        if sensor == "gpu" { return thermal.gpu }
        return thermal.sensors.first(where: { $0.id == sensor })?.value
    }
}

struct CPUTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    func delta(from previous: CPUTicks) -> (busy: UInt64, total: UInt64) {
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system) + UInt64(nice &- previous.nice)
        return (busy, busy + UInt64(idle &- previous.idle))
    }
}

actor SystemSampler {
    private var previousCores: [CPUTicks] = []
    private var networkReader = NetworkReader()
    private let sensors = SensorReader()
    private var cachedSMART = "—"
    private var lastSMART = Date.distantPast

    func sample(interface: String, smartInterval: Double) -> SystemMetrics {
        let cpu = readCPU()
        let thermal = sensors.read()
        if Date().timeIntervalSince(lastSMART) >= smartInterval {
            cachedSMART = readSMART()
            lastSMART = Date()
        }
        return SystemMetrics(cpuUsage: cpu.total, cores: cpu.cores, gpus: readGPU(), thermal: thermal,
                             network: networkReader.read(selection: interface), smartStatus: cachedSMART,
                             battery: BatteryMetrics.read(), sampledAt: Date())
    }

    private func readCPU() -> (total: Double?, cores: [Double?]) {
        var processors: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processors, &info, &count) == KERN_SUCCESS,
              let info else { return (nil, []) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        guard Int(count) >= Int(processors) * Int(CPU_STATE_MAX) else { return (nil, []) }
        let current = (0..<Int(processors)).map { core -> CPUTicks in
            let offset = core * Int(CPU_STATE_MAX)
            return CPUTicks(user: UInt32(bitPattern: info[offset + Int(CPU_STATE_USER)]),
                            system: UInt32(bitPattern: info[offset + Int(CPU_STATE_SYSTEM)]),
                            idle: UInt32(bitPattern: info[offset + Int(CPU_STATE_IDLE)]),
                            nice: UInt32(bitPattern: info[offset + Int(CPU_STATE_NICE)]))
        }
        defer { previousCores = current }
        guard previousCores.count == current.count else { return (nil, current.map { _ in nil }) }
        var total: UInt64 = 0
        var busy: UInt64 = 0
        let cores = zip(current, previousCores).map { ticks, previous -> Double? in
            let delta = ticks.delta(from: previous)
            total += delta.total; busy += delta.busy
            return delta.total > 0 ? Double(delta.busy) / Double(delta.total) * 100 : nil
        }
        return (total > 0 ? Double(busy) / Double(total) * 100 : nil, cores)
    }

    private func readGPU() -> [GPUMetrics] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var values: [GPUMetrics] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            var raw: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = raw?.takeRetainedValue() as? [String: Any],
                  let stats = properties["PerformanceStatistics"] as? [String: Any] else { continue }
            func usage(_ keys: [String]) -> Double? {
                for key in keys {
                    if let value = (stats[key] as? NSNumber)?.doubleValue, value.isFinite, (0...100).contains(value) { return value }
                }
                return nil
            }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            let model = properties["model"] as? String
                ?? (properties["model"] as? Data).flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
                ?? "GPU"
            values.append(GPUMetrics(id: id, name: model,
                                     usage: usage(["Device Utilization %", "GPU Activity(%)"]),
                                     renderer: usage(["Renderer Utilization %"]), tiler: usage(["Tiler Utilization %"])))
        }
        return values.sorted { $0.id < $1.id }
    }

    private func readSMART() -> String {
        guard let root = CommandRunner.plist(["info", "-plist", "/"]) else { return "Unavailable" }
        let containerID = root["APFSContainerReference"] as? String ?? root["ParentWholeDisk"] as? String
        var disks: [String] = []
        if let containerID, let listing = CommandRunner.plist(["apfs", "list", "-plist"]),
           let containers = listing["Containers"] as? [[String: Any]],
           let container = containers.first(where: { $0["ContainerReference"] as? String == containerID }),
           let physical = container["PhysicalStores"] as? [[String: Any]] {
            disks = physical.compactMap { $0["DeviceIdentifier"] as? String }
        }
        if disks.isEmpty, let parent = root["ParentWholeDisk"] as? String { disks = [parent] }
        let statuses = disks.map { disk -> String in
            guard let info = CommandRunner.plist(["info", "-plist", disk]) else { return "Unavailable" }
            if let status = info["SMARTStatus"] as? String { return status }
            if let parent = info["ParentWholeDisk"] as? String,
               let status = CommandRunner.plist(["info", "-plist", parent])?["SMARTStatus"] as? String { return status }
            return "Unsupported"
        }
        if statuses.contains(where: { $0.lowercased().contains("fail") }) { return "Failing" }
        if !statuses.isEmpty, statuses.allSatisfy({ $0 == "Verified" }) { return "Verified" }
        return statuses.first(where: { $0 != "Verified" }) ?? "Unavailable"
    }
}

// diskutil output is drained concurrently; a hung subprocess cannot stall all sampling.
enum CommandRunner {
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        func set(_ new: Data) { lock.lock(); defer { lock.unlock() }; data = new }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }
    static func plist(_ arguments: [String]) -> [String: Any]? {
        let process = Process()
        let pipe = Pipe()
        let ended = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let output = Output()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in ended.signal() }
        do { try process.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        guard ended.wait(timeout: .now() + 4) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + 0.5) != .success { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: output.get(), format: nil)) as? [String: Any]
    }
}

struct HistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let temperature: Double?
    let download: Double
    let upload: Double
}

@MainActor
final class MetricsStore: ObservableObject {
    @Published private(set) var metrics = SystemMetrics.empty
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var isSampling = false
    private let sampler = SystemSampler()
    private let preferences: Preferences
    private var timer: AnyCancellable?
    private var lastSample = Date.distantPast
    private var historyKey = ""

    init(preferences: Preferences) {
        self.preferences = preferences
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.sample() }
        sample()
    }

    func sample(force: Bool = false) {
        let settings = preferences.settings
        guard !isSampling, force || Date().timeIntervalSince(lastSample) >= settings.interval - 0.05 else { return }
        isSampling = true
        lastSample = Date()
        Task { [weak self, sampler] in
            let next = await sampler.sample(interface: settings.interface, smartInterval: settings.smartInterval)
            guard let self else { return }
            let key = "\(next.network.interface)|\(settings.sensor)|\(settings.interval)"
            if historyKey != key { history.removeAll(); historyKey = key }
            metrics = next
            history.append(HistoryPoint(date: next.sampledAt, cpu: next.cpuUsage, gpu: next.gpuUsage,
                                        temperature: next.temperature(sensor: settings.sensor),
                                        download: next.network.download, upload: next.network.upload))
            history.removeAll { next.sampledAt.timeIntervalSince($0.date) > 120 }
            isSampling = false
        }
    }
}
