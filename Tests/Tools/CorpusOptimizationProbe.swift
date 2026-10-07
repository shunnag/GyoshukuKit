// swiftc -Onone [-D OPTIMIZE] Tests/Tools/CorpusOptimizationProbe.swift -o <probe>
// 同じ入力と checksum で @_optimize(speed) の実効性を独立に測る。
import Foundation

#if OPTIMIZE
@_optimize(speed)
#endif
func random(_ count: Int) -> Data {
    var state: UInt64 = 0xD137_923A_6E25_9B41
    var bytes = [UInt8]()
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        bytes.append(UInt8(truncatingIfNeeded: (state &* 0x2545_F491_4F6C_DD1D) >> 56))
    }
    return Data(bytes)
}

#if OPTIMIZE
@_optimize(speed)
#endif
func crc(_ bytes: Data) -> UInt32 {
    var value = UInt32.max
    for byte in bytes {
        value ^= UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ ((0 &- (value & 1)) & 0xEDB8_8320) }
    }
    return ~value
}

for round in 1...5 {
    let start = DispatchTime.now().uptimeNanoseconds
    let bytes = random(8 << 20)
    let generated = DispatchTime.now().uptimeNanoseconds
    let checksum = crc(bytes)
    let finish = DispatchTime.now().uptimeNanoseconds
    print("\(round)\t\(Double(generated - start) / 1e9)\t\(Double(finish - generated) / 1e9)\t\(checksum)")
}
