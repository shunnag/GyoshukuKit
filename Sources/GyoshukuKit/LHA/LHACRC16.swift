import Foundation

// data と header は同じ CRC-16/ARC。反射形 0xA001、初期値 0、終端 XOR なし。
enum LHACRC16 {
    private static let table: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xA001) }
        return crc
    }

    static func update(_ initial: UInt16 = 0, _ data: Data) -> UInt16 {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var crc = initial
            for byte in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(byte)) & 0xFF)] }
            return crc
        }
    }
}
