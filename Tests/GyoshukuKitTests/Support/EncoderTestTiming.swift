import Foundation

/// GYOSHUKU_ENCODER_TIMING=1 のときだけ、DEBUG 試験の各工程を秒で記録する。
enum EncoderTestTiming {
    static let enabled = OptInGate.isOn("GYOSHUKU_ENCODER_TIMING")

    static func start() -> UInt64 { enabled ? DispatchTime.now().uptimeNanoseconds : 0 }

    static func end(_ label: String, _ start: UInt64, input: Int = 0, output: Int = 0) {
        guard enabled else { return }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        TestSupport.report("ENCODER_PHASE\t\(label)\t\(seconds)\t\(input)\t\(output)")
    }

    static func duration(_ label: String, _ nanoseconds: UInt64, input: Int = 0, output: Int = 0) {
        guard enabled else { return }
        TestSupport.report("ENCODER_PHASE\t\(label)\t\(Double(nanoseconds) / 1_000_000_000)\t\(input)\t\(output)")
    }

    static func measure<T>(_ label: String, input: Int = 0, _ body: () throws -> T) rethrows -> T {
        let begin = start()
        let result = try body()
        end(label, begin, input: input, output: (result as? Data)?.count ?? 0)
        return result
    }
}
