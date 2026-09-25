import Foundation

@main
struct SensorTests {
    static func main() {
        precondition(SMCDecoder.number(type: "sp78", bytes: [0x32, 0x80]) == 50.5)
        precondition(SMCDecoder.number(type: "sp78", bytes: [0xfe, 0x80]) == -1.5)
        precondition(SMCDecoder.number(type: "fpe2", bytes: [0x1f, 0x40]) == 2000)
        precondition(SMCDecoder.number(type: "flt ", bytes: [0, 0, 0x48, 0x42]) == 50)
        precondition(SMCDecoder.number(type: "flt ", bytes: [0, 0, 0x80, 0x7f]) == nil)
        precondition(SMCDecoder.number(type: "sp78", bytes: [0]) == nil)
        precondition(SMCDecoder.number(type: "????", bytes: [1, 2]) == nil)
        precondition(SMCDecoder.string(SMCDecoder.code("Tp01")) == "Tp01")
        print("PASS: SMC numeric decoding")
        let live = SensorReader().read()
        print("Live: \(live.status), CPU \(live.cpu.map { String(format: "%.1f°C", $0) } ?? "N/A"), GPU \(live.gpu.map { String(format: "%.1f°C", $0) } ?? "N/A"), \(live.sensors.count) sensors")
        print("Fans: \(live.fans.map { "\($0.id): \($0.value) RPM" }.joined(separator: ", "))")
        if CommandLine.arguments.contains("--require-temperature") {
            precondition(live.cpu != nil, "Expected CPU temperature on this development Mac")
        }
    }
}
