import CSMC
import Foundation
import IOKit

struct SensorReading: Identifiable, Sendable {
    let id: String
    let value: Double
}

struct ThermalMetrics: Sendable {
    var sensors: [SensorReading] = []
    var cpu: Double?
    var gpu: Double?
    var fans: [SensorReading] = []
    var status = "Unavailable"
}

enum SMCDecoder {
    static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? ""
    }
    static func number(type: String, bytes: [UInt8]) -> Double? {
        let value: Double
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        case "ui8 ":
            guard let byte = bytes.first else { return nil }
            value = Double(byte)
        case "ui16", "ui32":
            let count = type == "ui16" ? 2 : 4
            guard bytes.count >= count else { return nil }
            value = Double(bytes.prefix(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            let chars = Array(type)
            guard bytes.count >= 2, chars.count == 4,
                  let fraction = chars[3].hexDigitValue,
                  let integer = chars[2].hexDigitValue else { return nil }
            let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            if type.hasPrefix("sp"), integer + fraction == 15 {
                value = Double(Int16(bitPattern: raw)) / Double(1 << fraction)
            } else if type.hasPrefix("fp"), integer + fraction == 16 {
                value = Double(raw) / Double(1 << fraction)
            } else { return nil }
        }
        return value.isFinite ? value : nil
    }
}

// Accessed only by SystemSampler's actor, or synchronously by --diagnostics.
final class SensorReader {
    private var connection: io_connect_t = 0
    private var keys: [String] = []
    private var lastDiscovery = Date.distantPast
    private var lastOpenAttempt = Date.distantPast
    private var openResult: kern_return_t = KERN_SUCCESS
    private let cpuKeys: Set<String>
    private let gpuKeys: Set<String>

    init() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        let chip = String(cString: name)
        // These are sensor identifiers, not assumptions about physical core numbering.
        if chip.contains("M3") {
            cpuKeys = Set("Te05 Te0L Te0P Te0S Tf04 Tf09 Tf0A Tf0B Tf0D Tf0E Tf44 Tf49 Tf4A Tf4B Tf4D Tf4E".split(separator: " ").map(String.init))
            gpuKeys = Set("Tf14 Tf18 Tf19 Tf1A Tf24 Tf28 Tf29 Tf2A".split(separator: " ").map(String.init))
        } else if chip.contains("M5") {
            cpuKeys = Set("Tp00 Tp04 Tp08 Tp0C Tp0G Tp0K Tp0O Tp0R Tp0U Tp0X Tp0a Tp0d Tp0g Tp0j Tp0m Tp0p Tp0u Tp0y".split(separator: " ").map(String.init))
            gpuKeys = Set("Tg0U Tg0X Tg0d Tg0g Tg0j Tg1Y Tg1c Tg1g".split(separator: " ").map(String.init))
        } else if chip.contains("M4") {
            cpuKeys = Set("Te05 Te0S Te09 Te0H Tp01 Tp05 Tp09 Tp0D Tp0V Tp0Y Tp0b Tp0e".split(separator: " ").map(String.init))
            gpuKeys = Set("Tg0G Tg0H Tg1U Tg1k Tg0K Tg0L Tg0d Tg0e Tg0j Tg0k".split(separator: " ").map(String.init))
        } else if chip.contains("M2") {
            cpuKeys = Set("Tp1h Tp1t Tp1p Tp1l Tp01 Tp05 Tp09 Tp0D Tp0X Tp0b Tp0f Tp0j".split(separator: " ").map(String.init))
            gpuKeys = ["Tg0f", "Tg0j"]
        } else if chip.contains("M1") {
            cpuKeys = Set("Tp09 Tp0T Tp01 Tp05 Tp0D Tp0H Tp0L Tp0P Tp0X Tp0b".split(separator: " ").map(String.init))
            gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        } else if chip.contains("A18") {
            cpuKeys = ["Te05", "Te0S", "Tp05", "Tp0D"]
            gpuKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0e"]
        } else {
            cpuKeys = ["TC0D", "TC0E", "TC0F", "TC0P", "TCAD"]
            gpuKeys = ["TCGC", "TG0D", "TGDD", "TG0P"]
        }
    }

    deinit { SMClose(connection) }

    private func value(_ key: String) -> Double? {
        guard key.utf8.count == 4, connection != 0 else { return nil }
        var raw = SMValue()
        guard SMRead(connection, SMCDecoder.code(key), &raw) == KERN_SUCCESS else { return nil }
        let bytes = withUnsafeBytes(of: raw.bytes) { Array($0.prefix(Int(raw.size))) }
        return SMCDecoder.number(type: SMCDecoder.string(raw.type), bytes: bytes)
    }

    func read() -> ThermalMetrics {
        let now = Date()
        if connection == 0, now.timeIntervalSince(lastOpenAttempt) > 30 {
            lastOpenAttempt = now
            openResult = SMOpen(&connection)
            if openResult != KERN_SUCCESS { connection = 0 }
        }
        guard connection != 0 else {
            return ThermalMetrics(status: String(format: "SMC 0x%08x", UInt32(bitPattern: openResult)))
        }
        if now.timeIntervalSince(lastDiscovery) > 300 {
            lastDiscovery = now
            var found = cpuKeys.union(gpuKeys)
            // Enumerate once, so a new chip can still offer manually selected sensors.
            if let count = value("#KEY"), count > 0, count < 32768 {
                for index in 0..<UInt32(count) {
                    var rawKey: UInt32 = 0
                    if SMKeyAt(connection, index, &rawKey) == KERN_SUCCESS {
                        let key = SMCDecoder.string(rawKey)
                        if key.hasPrefix("T") { found.insert(key) }
                    }
                }
            }
            keys = found.sorted().filter { key in
                guard let number = value(key) else { return false }
                return number >= 10 && number < 150
            }
        }
        let sensors = keys.compactMap { key -> SensorReading? in
            guard let number = value(key), number >= 10, number < 150 else { return nil }
            return SensorReading(id: key, value: number)
        }
        func average(_ selection: Set<String>) -> Double? {
            let values = sensors.filter { selection.contains($0.id) }.map(\.value)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let fanCount = min(8, max(0, Int(value("FNum") ?? 0)))
        let fans = (0..<fanCount).compactMap { index -> SensorReading? in
            guard let rpm = value("F\(index)Ac"), (0...20000).contains(rpm) else { return nil }
            return SensorReading(id: "Fan \(index + 1)", value: rpm)
        }
        if sensors.isEmpty {
            // Invalidate a stale connection after sleep; retry on the next sample.
            SMClose(connection)
            connection = 0
            lastDiscovery = .distantPast
        }
        return ThermalMetrics(sensors: sensors, cpu: average(cpuKeys), gpu: average(gpuKeys), fans: fans,
                              status: sensors.isEmpty ? "No sensors" : "SMC")
    }
}
