import Foundation

// data と header は同じ CRC-16/ARC。反射形 0xA001、初期値 0、終端 XOR なし。
enum LHACRC16 {
    // 初期化後は不変。表の寿命を所有者に結び、各 byte の Array 添字を避ける。
    private final class Tables: @unchecked Sendable {
        let pointer: UnsafePointer<UInt16>

        init() {
            let storage = UnsafeMutablePointer<UInt16>.allocate(capacity: 8 * 256)
            storage.initialize(repeating: 0, count: 8 * 256)
            for value in 0..<256 {
                var crc = UInt16(value)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xA001) }
                storage[value] = crc
            }
            for value in 0..<256 {
                var crc = storage[value]
                for slice in 1..<8 {
                    crc = (crc >> 8) ^ storage[Int(crc & 0xFF)]
                    storage[slice * 256 + value] = crc
                }
            }
            pointer = UnsafePointer(storage)
        }

        deinit {
            let storage = UnsafeMutablePointer(mutating: pointer)
            storage.deinitialize(count: 8 * 256)
            storage.deallocate()
        }
    }
    private static let tables = Tables()

    static func update(_ initial: UInt16 = 0, _ data: Data) -> UInt16 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var crc = initial
            guard let base = bytes.baseAddress else { return crc }
            let table = tables.pointer
            var offset = 0
            // 反射形なので最初の byte を最も遠い slice へ入れる。非整列入力も同じ経路。
            while bytes.count - offset >= 8 {
                let word = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) ^ UInt64(crc)
                let low = table[7 * 256 + Int(word & 0xFF)] ^ table[6 * 256 + Int((word >> 8) & 0xFF)]
                    ^ table[5 * 256 + Int((word >> 16) & 0xFF)] ^ table[4 * 256 + Int((word >> 24) & 0xFF)]
                let high = table[3 * 256 + Int((word >> 32) & 0xFF)] ^ table[2 * 256 + Int((word >> 40) & 0xFF)]
                    ^ table[256 + Int((word >> 48) & 0xFF)] ^ table[Int(word >> 56)]
                crc = low ^ high
                offset += 8
            }
            let input = base.assumingMemoryBound(to: UInt8.self)
            while offset < bytes.count {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt16(input[offset])) & 0xFF)]
                offset += 1
            }
            return crc
        }
    }
}
