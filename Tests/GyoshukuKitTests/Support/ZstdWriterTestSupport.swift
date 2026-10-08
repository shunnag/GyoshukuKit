import Foundation
import XCTest

enum ZstdWriterTestSupport {
    struct Frame {
        let range: Range<Int>
        let contentSize: UInt64
    }

    /// RFC 8878 の header と block 長だけで frame を辿る。製品の serializer は使わない。
    static func frames(_ data: Data) throws -> [Frame] {
        var cursor = data.startIndex
        func integer(_ count: Int) throws -> UInt64 {
            guard count <= data.endIndex - cursor else { throw CocoaError(.fileReadCorruptFile) }
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(data[cursor + i]) << (i * 8) }
            cursor += count
            return value
        }
        var result: [Frame] = []
        while cursor < data.endIndex {
            let start = cursor
            XCTAssertEqual(try integer(4), 0xFD2FB528)
            let descriptor = try integer(1)
            XCTAssertEqual(descriptor & 0x1C, 4) // checksum 有効、予約 bit は0。
            let single = descriptor & 32 != 0
            if !single { _ = try integer(1) }
            let dictionaryBytes = [0, 1, 2, 4][Int(descriptor & 3)]
            XCTAssertEqual(try integer(dictionaryBytes), 0)
            let flag = Int(descriptor >> 6)
            let sizeBytes = [single ? 1 : 0, 2, 4, 8][flag]
            XCTAssertGreaterThan(sizeBytes, 0)
            let size = try integer(sizeBytes) + (flag == 1 ? 256 : 0)
            var last = false
            repeat {
                let block = try integer(3)
                last = block & 1 != 0
                let type = (block >> 1) & 3
                guard type != 3 else { throw CocoaError(.fileReadCorruptFile) }
                let length = type == 1 ? 1 : Int(block >> 3)
                guard length <= data.endIndex - cursor else { throw CocoaError(.fileReadCorruptFile) }
                cursor += length
            } while !last
            _ = try integer(4)
            result.append(.init(range: start..<cursor, contentSize: size))
        }
        return result
    }
}
