import Foundation
import IOKit.ps

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "BatteryTests", code: 1) }
    return value
}

@main
final class BatteryTests {
    static func main() throws {
        let tests = BatteryTests()
        try tests.testDischarging()
        try tests.testChargingUsesTimeToFull()
        try tests.testPausedChargingHasNoCountdown()
        tests.testMissingInvalidAndExternalSources()
        try tests.testFullyCharged()
        print("PASS: 5 battery scenarios; live internal battery: \(BatteryMetrics.read()?.level ?? "none")")
    }
    private func source(_ values: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 40,
            kIOPSMaxCapacityKey: 80, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue]
        result.merge(values) { _, new in new }
        return result
    }

    func testDischarging() throws {
        let battery = try XCTUnwrap(BatteryMetrics(description: source([kIOPSTimeToEmptyKey: 125])))
        XCTAssertEqual(battery.percentage, 50)
        XCTAssertEqual(battery.minutesRemaining, 125)
        XCTAssertEqual(battery.status, "On battery")
    }

    func testChargingUsesTimeToFull() throws {
        let battery = try XCTUnwrap(BatteryMetrics(description: source([
            kIOPSIsChargingKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue,
            kIOPSTimeToFullChargeKey: 35, kIOPSTimeToEmptyKey: 200])))
        XCTAssertEqual(battery.minutesRemaining, 35)
        XCTAssertEqual(battery.status, "Charging")
    }

    func testPausedChargingHasNoCountdown() throws {
        let battery = try XCTUnwrap(BatteryMetrics(description: source([
            kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSTimeToEmptyKey: 200])))
        XCTAssertNil(battery.minutesRemaining)
        XCTAssertEqual(battery.status, "Plugged in")
    }

    func testMissingInvalidAndExternalSources() {
        XCTAssertNil(BatteryMetrics(description: [:]))
        XCTAssertNil(BatteryMetrics(description: source([kIOPSIsPresentKey: false])))
        XCTAssertNil(BatteryMetrics(description: source([kIOPSTypeKey: kIOPSUPSType])))
        XCTAssertNil(BatteryMetrics(description: source([kIOPSMaxCapacityKey: 0]))?.percentage)
        XCTAssertNil(BatteryMetrics(description: source([kIOPSTimeToEmptyKey: -1]))?.minutesRemaining)
    }

    func testFullyCharged() throws {
        let battery = try XCTUnwrap(BatteryMetrics(description: source([
            kIOPSIsChargedKey: true, kIOPSPowerSourceStateKey: kIOPSACPowerValue])))
        XCTAssertEqual(battery.status, "Full")
        XCTAssertNil(battery.minutesRemaining)
    }
}
