import AppKit
import Foundation

@main
struct MonitorTests {
    @MainActor
    static func main() async throws {
        testCounters()
        testDiskInfo()
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


    static func testDiskInfo() {
        let root: [String: Any] = [
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]],
            "CapacityInUse": 152_700_000_000,
            "APFSContainerSize": 245_107_195_904,
            "APFSContainerFree": 64_000_000_000,
            "VolumeName": "Macintosh HD",
        ]
        let whole: [String: Any] = [
            "SMARTStatus": "Verified",
            "MediaName": "APPLE SSD AP0256Z",
            "SolidState": true,
            "BusProtocol": "Apple Fabric",
            "TotalSize": 251_000_193_024,
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "AVAILABLE_SPARE": 100, "AVAILABLE_SPARE_THRESHOLD": 99, "PERCENTAGE_USED": 2,
                "DATA_UNITS_READ_0": 85_213_391, "DATA_UNITS_WRITTEN_0": 50_351_265,
                "POWER_ON_HOURS_0": 1072, "POWER_CYCLES_0": 193,
                "UNSAFE_SHUTDOWNS_0": 14, "MEDIA_ERRORS_0": 0, "TEMPERATURE": 309,
                "CONTROLLER_BUSY_TIME_0": 7,
            ],
        ]
        precondition(DiskInfoParser.physicalStoreID(root: root) == "disk0s2")
        precondition(DiskInfoParser.wholeDisk(of: "disk0s2") == "disk0")
        precondition(DiskInfoParser.wholeDisk(of: "disk3s1s1") == "disk3")
        precondition(DiskInfoParser.wholeDisk(of: "disk0") == "disk0")
        guard let disk = DiskInfoParser.parse(root: root, apfsListing: nil, wholeDisk: whole) else {
            preconditionFailure("valid diskutil payload must parse")
        }
        precondition(disk.status == "Verified" && disk.isHealthy && !disk.isFailing)
        precondition(disk.mediaName == "APPLE SSD AP0256Z" && disk.solidState == true)
        precondition(disk.percentageUsed == 2 && disk.availableSpare == 100 && disk.spareThreshold == 99)
        precondition(disk.powerOnHours == 1072 && disk.powerCycles == 193 && disk.unsafeShutdowns == 14)
        precondition(disk.mediaErrors == 0 && disk.supportsSMARTCounters)
        precondition(abs((disk.temperature ?? 0) - 35.85) < 0.01, "TEMPERATURE is Kelvin")
        precondition(disk.dataUnitsWritten == 50_351_265)
        precondition(abs((disk.hostBytesWritten ?? 0) - 50_351_265 * 512 * 1024) < 1, "data units are 512 KiB")
        // 13.65 GB of 245.1 GB container: the boot snapshot must not be shown as ~18%.
        let used = disk.usedFraction ?? 0
        precondition(abs(used - 152_700_000_000.0 / 245_107_195_904.0) < 1e-9, "usage uses the whole container")
        precondition(disk.remaining.contains { $0.key == "CONTROLLER_BUSY_TIME_0" }, "unknown NVMe keys stay visible")
        precondition(!disk.remaining.contains { $0.key == "PERCENTAGE_USED" }, "claimed keys must not repeat")

        // Splitting a 64-bit counter across the low/high NVMe halves.
        let lowWord = UInt32.max
        let wide: [String: Any] = [
            "SMARTStatus": "Verified",
            "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": [
                "DATA_UNITS_WRITTEN_0": lowWord, "DATA_UNITS_WRITTEN_1": UInt64(2),
            ],
        ]
        let split = DiskInfoParser.parse(root: root, apfsListing: nil, wholeDisk: wide)
        let expected = (UInt64(2) << 32) | UInt64(lowWord)
        precondition(split?.dataUnitsWritten == expected, "high word must shift by 32, got \(split?.dataUnitsWritten as Any)")

        // Missing S.M.A.R.T. keys must degrade, never invent values.
        let bare = DiskInfoParser.parse(root: root, apfsListing: nil, wholeDisk: ["SMARTStatus": "Not Supported"])
        precondition(bare?.status == "Not Supported" && bare?.supportsSMARTCounters == false)
        precondition(bare?.percentageUsed == nil && bare?.temperature == nil)
        precondition(DiskInfoParser.parse(root: root, apfsListing: nil, wholeDisk: [:]) == nil, "empty info is unavailable")
        print("PASS: disk usage, NVMe counters, Kelvin->Celsius, 64-bit word halves, degradation")
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
