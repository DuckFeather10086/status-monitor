import AppKit
import Foundation

@main
struct MonitorTests {
    @MainActor
    static func main() async throws {
        testCounters()
        testMenuImage()
        try testImagePersistence()
        let sampler = SystemSampler()
        _ = await sampler.sample(interface: "auto", smartInterval: 60)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let live = await sampler.sample(interface: "auto", smartInterval: 60)
        precondition(!live.cores.isEmpty)
        precondition(live.cpuUsage.map { (0...100).contains($0) } == true)
        precondition(live.cores.allSatisfy { $0.map { (0...100).contains($0) } == true })
        print("PASS: live sampling · \(live.cores.count) cores · CPU \(live.cpuUsage!)% · GPU \(live.gpuUsage.map(String.init(describing:)) ?? "unavailable")% · \(live.network.interface) · SMART \(live.smartStatus)")
        precondition(live.gpus.allSatisfy { $0.usage.map { (0...100).contains($0) } ?? true })
        if CommandLine.arguments.contains("--require-temperature") { precondition(live.thermal.cpu != nil) }
    }

    static func testCounters() {
        let old = CPUTicks(user: .max - 4, system: 10, idle: 100, nice: 0)
        let now = CPUTicks(user: 5, system: 15, idle: 105, nice: 0)
        let cpu = now.delta(from: old)
        precondition(cpu.busy == 15 && cpu.total == 20, "CPU must survive tick wrap")
        var network = NetworkDelta()
        let initial = network.update(NetworkCounters(received: 4_294_967_000, sent: 100), interface: "en0", time: 0)
        precondition(initial.0 == 0 && initial.1 == 0)
        let crossing = network.update(NetworkCounters(received: 4_294_968_000, sent: 300), interface: "en0", time: 2)
        precondition(crossing.0 == 500 && crossing.1 == 100, "Network must survive 4 GiB")
        let reset = network.update(NetworkCounters(received: 10, sent: 10), interface: "en0", time: 4)
        precondition(reset.0 == 0 && reset.1 == 0, "Counter resets are not traffic")
        let switched = network.update(NetworkCounters(received: 10_000, sent: 10_000), interface: "utun0", time: 6)
        precondition(switched.0 == 0 && network.received == 0 && network.sent == 0, "Interface changes need a new baseline")
        let vpn = network.update(NetworkCounters(received: 11_000, sent: 10_500), interface: "utun0", time: 8)
        precondition(vpn.0 == 500 && vpn.1 == 250)
        _ = network.update(nil, interface: nil, time: 10)
        precondition(network.received == 0)
        print("PASS: CPU tick wrap, 64-bit traffic, link reset, interface switch, offline")
    }

    static func testMenuImage() {
        precondition(NetworkMenuImage.rate(0) == "0B/s")
        precondition(NetworkMenuImage.rate(1536) == "1.5K/s")
        precondition(NetworkMenuImage.rate(.nan) == "0B/s")
        precondition(NetworkMenuImage.rate(-1) == "0B/s")
        precondition(NetworkMenuImage.rate(1e20) == "999T/s")
        let image = NetworkMenuImage.make(download: 1e20, upload: 1536)
        precondition(image.size == NSSize(width: 72, height: 22) && image.isTemplate)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)]
        for text in ["↑ 999T/s", "↓ 9.9M/s"] {
            precondition((text as NSString).size(withAttributes: attributes).width + 6 <= image.size.width)
        }
        print("PASS: fixed-width two-line network label and invalid rate handling")
    }

    @MainActor
    static func testImagePersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("status-monitor-test-\(UUID().uuidString)", isDirectory: true)
        let suite = "StatusMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 200,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.bitmapData!.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let source = directory.appendingPathComponent("source.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        var legacy = MonitorSettings()
        legacy.showCPU = true
        legacy.showGPU = true
        legacy.showTemperature = true
        legacy.compact = true
        legacy.overlay = 0.72
        legacy.pinned = true
        defaults.set(try JSONEncoder().encode(legacy), forKey: "settings.v2")
        let preferences = Preferences(defaults: defaults, directory: directory.appendingPathComponent("AppSupport"))
        precondition(!preferences.settings.showCPU && !preferences.settings.showGPU && !preferences.settings.showTemperature)
        precondition(preferences.settings.showNetwork && !preferences.settings.compact)
        precondition(preferences.settings.overlay == 0.72 && preferences.settings.pinned)
        preferences.settings.showCPU = true // A subsequent manual choice must persist.
        preferences.importImage(source)
        precondition(preferences.image != nil && preferences.imageError == nil)
        precondition(preferences.image!.size.width <= 1600)
        preferences.settings.blur = 7
        preferences.settings.overlay = 0.4
        preferences.settings.sensor = "Te05"
        try FileManager.default.removeItem(at: source)
        let restored = Preferences(defaults: defaults, directory: directory.appendingPathComponent("AppSupport"))
        precondition(restored.image != nil, "Imported image must survive moving/deleting the original")
        precondition(restored.settings.blur == 7 && restored.settings.overlay == 0.4 && restored.settings.sensor == "Te05")
        precondition(restored.settings.showCPU && !restored.settings.showGPU)
        restored.importImage(directory.appendingPathComponent("missing.png"))
        precondition(restored.image != nil && restored.imageError != nil, "Invalid imports must preserve the existing image")
        restored.removeImage()
        precondition(restored.image == nil)
        precondition(Preferences(defaults: defaults, directory: directory.appendingPathComponent("AppSupport")).image == nil)
        print("PASS: image persistence, invalid import, removal, one-time network-menu migration and manual settings reload")
    }
}
