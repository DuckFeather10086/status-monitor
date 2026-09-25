import Foundation
import IOKit.ps

struct BatteryMetrics: Sendable {
    let percentage: Int?
    let charging: Bool
    let externalPower: Bool
    let charged: Bool
    let minutesRemaining: Int?

    init?(description: [String: Any]) {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool != false else { return nil }
        if let current = description[kIOPSCurrentCapacityKey] as? Int,
           let maximum = description[kIOPSMaxCapacityKey] as? Int,
           current >= 0, maximum > 0 {
            percentage = min(100, Int((Double(current) / Double(maximum) * 100).rounded()))
        } else {
            percentage = nil
        }
        charging = description[kIOPSIsChargingKey] as? Bool ?? false
        externalPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        charged = description[kIOPSIsChargedKey] as? Bool ?? false
        let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        minutesRemaining = (!externalPower || charging) && !charged && (minutes ?? 0) > 0 ? minutes : nil
    }

    var level: String { percentage.map { "\($0)%" } ?? "N/A" }
    var status: String {
        if charged { return "已充满" }
        if charging { return "正在充电" }
        return externalPower ? "已接电源 · 未充电" : "电池供电"
    }
    var timeDescription: String? {
        guard let minutesRemaining else { return nil }
        let duration = "\(minutesRemaining / 60) 小时 \(minutesRemaining % 60) 分钟"
        return charging ? "预计 \(duration) 充满" : "预计剩余 \(duration)"
    }

    static func read() -> BatteryMetrics? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let battery = BatteryMetrics(description: description) { return battery }
        }
        return nil
    }
}
