import AppKit
import Combine
import Foundation
import IOKit
import SwiftUI

// MARK: - Model

struct SystemMetrics: Sendable {
    var cpuUsage: Double?
    var gpuUsage: Double?
    var temperatureC: Double?
    var uploadBytesPerSecond: Double
    var downloadBytesPerSecond: Double
    var smartStatus: String?
    var battery: BatteryMetrics? = nil
    var sampledAt = Date()

    static let empty = SystemMetrics(
        cpuUsage: nil,
        gpuUsage: nil,
        temperatureC: nil,
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
        smartStatus: nil
    )
}

// MARK: - Sampling

actor SystemSampler {
    private var previousCPUTicks: (total: UInt64, idle: UInt64)?
    private var previousNetworkBytes: (inbound: UInt64, outbound: UInt64)?
    private var previousSampleDate: Date?
    private var cachedSMART: String?

    func sample(includeSMART: Bool) -> SystemMetrics {
        let now = Date()
        let cpu = readCPUUsage()
        let network = readNetworkRate(now: now)
        let gpu = readGPUUsage()
        let temperature = readTemperature()
        if includeSMART { cachedSMART = readSMARTStatus() }

        return SystemMetrics(
            cpuUsage: cpu,
            gpuUsage: gpu,
            temperatureC: temperature,
            uploadBytesPerSecond: network.outbound,
            downloadBytesPerSecond: network.inbound,
            smartStatus: cachedSMART,
            battery: BatteryMetrics.read(),
            sampledAt: now
        )
    }

    private func readCPUUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let ticks = info.cpu_ticks
        let user = UInt64(ticks.0)
        let system = UInt64(ticks.1)
        let idle = UInt64(ticks.2)
        let total = user + UInt64(ticks.3) + system + idle

        defer { previousCPUTicks = (total, idle) }
        guard let previous = previousCPUTicks else { return nil }
        let totalDelta = total >= previous.total ? total - previous.total : 0
        let idleDelta = idle >= previous.idle ? idle - previous.idle : 0
        guard totalDelta > 0 else { return nil }
        return min(100, max(0, Double(totalDelta - min(idleDelta, totalDelta)) / Double(totalDelta) * 100))
    }

    private func readNetworkRate(now: Date) -> (inbound: Double, outbound: Double) {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return (0, 0)
        }
        defer { freeifaddrs(addressList) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var inbound: UInt64 = 0
        var outbound: UInt64 = 0

        while let current = cursor {
            let item = current.pointee
            if let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               let data = item.ifa_data {
                let link = data.assumingMemoryBound(to: if_data.self).pointee
                inbound &+= UInt64(link.ifi_ibytes)
                outbound &+= UInt64(link.ifi_obytes)
            }
            cursor = item.ifa_next
        }

        defer {
            previousNetworkBytes = (inbound, outbound)
            previousSampleDate = now
        }
        guard let previousBytes = previousNetworkBytes,
              let previousDate = previousSampleDate else {
            return (0, 0)
        }
        let elapsed = max(0.001, now.timeIntervalSince(previousDate))
        let inDelta = inbound >= previousBytes.inbound ? inbound - previousBytes.inbound : 0
        let outDelta = outbound >= previousBytes.outbound ? outbound - previousBytes.outbound : 0
        return (Double(inDelta) / elapsed, Double(outDelta) / elapsed)
    }

    private func readGPUUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOAccelerator"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [(priority: Int, value: Double)] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties else { continue }
            let dictionary = properties.takeRetainedValue() as NSDictionary
            collectUtilizationValues(from: dictionary, into: &candidates)
        }

        guard let best = candidates.sorted(by: { $0.priority < $1.priority }).first else { return nil }
        return min(100, max(0, best.value))
    }

    private func collectUtilizationValues(from object: Any, into values: inout [(priority: Int, value: Double)]) {
        if let dictionary = object as? NSDictionary {
            for (key, value) in dictionary {
                let keyName = String(describing: key).lowercased()
                if keyName.contains("utilization"), let number = value as? NSNumber {
                    let raw = number.doubleValue
                    if raw.isFinite, (0...100).contains(raw) {
                        let priority: Int
                        if keyName.contains("device") || keyName.contains("gpu") {
                            priority = 0
                        } else if keyName.contains("renderer") {
                            priority = 1
                        } else {
                            priority = 2
                        }
                        values.append((priority, raw))
                    }
                }
                collectUtilizationValues(from: value, into: &values)
            }
        } else if let array = object as? NSArray {
            for item in array {
                collectUtilizationValues(from: item, into: &values)
            }
        }
    }

    private func readTemperature() -> Double? {
        guard let output = runCommand("/usr/sbin/ioreg", arguments: ["-r", "-c", "IOHWSensor", "-l"]) else {
            return nil
        }

        var values: [Double] = []
        for line in output.split(separator: "\n") {
            let lower = line.lowercased()
            guard lower.contains("temperature") || lower.contains("current-value") || lower.contains("sensor-value") else {
                continue
            }
            guard let rawText = line.split(separator: "=").last,
                  let raw = Double(rawText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")) else {
                continue
            }
            let celsius: Double
            if raw > 10_000 {
                celsius = raw / 1000
            } else if raw > 200 {
                celsius = raw / 100
            } else {
                celsius = raw
            }
            if (10...130).contains(celsius) {
                values.append(celsius)
            }
        }
        return values.max()
    }

    private func readSMARTStatus() -> String? {
        guard let rootInfo = runCommand("/usr/sbin/diskutil", arguments: ["info", "/"]) else { return nil }
        let wholeDisk = rootInfo.split(separator: "\n").first(where: { $0.contains("Part of Whole") })?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let wholeDisk, !wholeDisk.isEmpty,
              let diskInfo = runCommand("/usr/sbin/diskutil", arguments: ["info", wholeDisk]) else {
            return nil
        }
        guard let line = diskInfo.split(separator: "\n").first(where: { $0.contains("SMART Status") }) else {
            return "Unknown"
        }
        return line.split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runCommand(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

@MainActor
final class MetricsStore: ObservableObject {
    @Published private(set) var metrics = SystemMetrics.empty
    @Published private(set) var isSampling = false

    private let sampler = SystemSampler()
    private var timer: AnyCancellable?
    private var sampleCount = 0

    init() {
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sample() }
        sample()
    }

    private func sample() {
        guard !isSampling else { return }
        isSampling = true
        sampleCount += 1
        let includeSMART = sampleCount == 1 || sampleCount % 8 == 0
        let sampler = self.sampler
        Task { [weak self] in
            let next = await sampler.sample(includeSMART: includeSMART)
            guard let self else { return }
            self.metrics = next
            self.isSampling = false
        }
    }
}

// MARK: - UI

@main
struct StatusMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MetricsStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
        } label: {
            MenuBarLabel(metrics: store.metrics)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarLabel: View {
    let metrics: SystemMetrics

    var body: some View {
        HStack(spacing: 5) {
            Text("CPU \(percent(metrics.cpuUsage))")
            Text("GPU \(percent(metrics.gpuUsage))")
            Text("↓\(shortRate(metrics.downloadBytesPerSecond))")
            Text("↑\(shortRate(metrics.uploadBytesPerSecond))")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .monospacedDigit()
    }
}

struct DashboardView: View {
    @ObservedObject var store: MetricsStore
    @State private var showingSettings = false
    @AppStorage("backgroundColor") private var backgroundColor = "0.08,0.09,0.12,0.96"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Status Monitor")
                        .font(.headline)
                    Text("每 2 秒刷新 · 原生菜单栏")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(store.isSampling ? .orange : .green)
                    .frame(width: 8, height: 8)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricCard(title: "CPU", value: percent(store.metrics.cpuUsage), tint: .blue)
                MetricCard(title: "GPU", value: percent(store.metrics.gpuUsage), tint: .purple)
                MetricCard(title: "温度", value: temperature(store.metrics.temperatureC), tint: .orange)
                MetricCard(title: "磁盘 S.M.A.R.T.", value: store.metrics.smartStatus ?? "N/A", tint: .green)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("网络")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    RateView(symbol: "↓", title: "下载", value: shortRate(store.metrics.downloadBytesPerSecond), tint: .cyan)
                    Spacer()
                    RateView(symbol: "↑", title: "上传", value: shortRate(store.metrics.uploadBytesPerSecond), tint: .mint)
                }
            }

            if let battery = store.metrics.battery {
                VStack(alignment: .leading, spacing: 5) {
                    Label("电池 \(battery.level)", systemImage: battery.charging ? "battery.100.bolt" : "battery.100")
                        .font(.headline)
                    Text(battery.status).font(.caption)
                    if let remaining = battery.timeDescription {
                        Text(remaining).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button("设置") { showingSettings.toggle() }
                    .popover(isPresented: $showingSettings) { SettingsView() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }

            HStack {
                Text("数据来自系统公开接口；部分机型可能没有 GPU/温度传感器权限。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(hex: backgroundColor))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct RateView: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Text(symbol).foregroundStyle(tint).font(.title3.weight(.bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(.body, design: .monospaced)).monospacedDigit()
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("backgroundColor") private var backgroundColor = "0.08,0.09,0.12,0.96"
    @State private var color = Color(red: 0.08, green: 0.09, blue: 0.12)

    var body: some View {
        Form {
            Section("显示") {
                ColorPicker("面板背景", selection: $color, supportsOpacity: true)
                    .onChange(of: color) { newValue in
                        backgroundColor = newValue.rgbaString
                    }
                Text("菜单栏文本固定为透明背景；这里控制展开面板的背景色。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { color = Color(hex: backgroundColor) }
    }
}

// MARK: - Formatting

private func percent(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    return "\(Int(value.rounded()))%"
}

private func temperature(_ value: Double?) -> String {
    guard let value else { return "N/A" }
    return "\(Int(value.rounded()))°C"
}

private func shortRate(_ bytesPerSecond: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var value = max(0, bytesPerSecond)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    if value >= 100 || index == 0 {
        return "\(Int(value.rounded())) \(units[index])"
    }
    return String(format: "%.1f %@", value, units[index])
}

extension Color {
    init(hex: String) {
        let components = hex.split(separator: ",").compactMap { Double($0) }
        self.init(
            red: components.indices.contains(0) ? components[0] : 0.08,
            green: components.indices.contains(1) ? components[1] : 0.09,
            blue: components.indices.contains(2) ? components[2] : 0.12,
            opacity: components.indices.contains(3) ? components[3] : 0.96
        )
    }

    var rgbaString: String {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        return "\(nsColor.redComponent),\(nsColor.greenComponent),\(nsColor.blueComponent),\(nsColor.alphaComponent)"
    }
}
