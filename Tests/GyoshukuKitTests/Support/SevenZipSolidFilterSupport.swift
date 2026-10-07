import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@testable import GyoshukuKit

enum SevenZipSolidFilterSupport {
    static func macho(arm64: Bool, size: Int = 32_769, alternatingBranches: Bool = false) -> Data {
        var data = Data(count: 32)
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        put(0xFEED_FACF, at: 0); put(arm64 ? 0x0100_000C : 0x0100_0007, at: 4)
        while data.count + 8 <= size {
            let pc = UInt32(data.count)
            if arm64 {
                // BL と正負の ADRP。変換しない範囲の ADRP も混ぜる。
                // 小入力でも 0 / 64 KiB への BL を交互に置き、正負の offset を保つ。
                let branchPC = alternatingBranches && pc & 8 != 0 ? pc &+ 0x1_0000 : pc
                data.le(0x9400_0000 | ((0x4000 &- (branchPC >> 2)) & 0x03FF_FFFF))
                let page = (data.count & 16 == 0) ? UInt32(0x1F_FFFF) : UInt32(0x4_0000)
                data.le(0x9000_0001 | (page & 3) << 29 | ((page >> 2) & 0x7_FFFF) << 5)
            } else {
                let target: UInt32 = alternatingBranches && pc & 8 != 0 ? 0 : 0x2000
                data.append(0xE8); data.le(target &- pc &- 5)
                data.append(contentsOf: [0x90, 0xE9, 0xFF])
            }
        }
        data.append(contentsOf: repeatElement(UInt8(0xE8), count: size - data.count))
        return data
    }

    @discardableResult
    static func verify(_ url: URL, items: [ExpectedEntry], options: WriterOptions,
                       blocks: Int, solid: Bool, filter: String? = nil) throws -> SevenZipEditModel {
        // 同じ書庫の t / l / x と reader を共有し、layout の assertion は残す。
        var listing = ""
        let model = try SevenZipMethodTestSupport.verify(url, items: items, password: options.password,
            observeListing: { listing = $0 })
        XCTAssertEqual(model.folders.count, blocks)
        XCTAssertTrue(listing.contains("Solid = \(solid ? "+" : "-")"), listing)
        XCTAssertTrue(listing.contains("Blocks = \(blocks)"), listing)
        if let filter {
            for entry in SevenZipTestSupport.listingEntries(listing) where entry["Size"] != "0" {
                XCTAssertTrue(entry["Method"]?.contains(filter) == true, entry.description)
            }
        }
        let files = Dictionary(uniqueKeysWithValues: model.files.enumerated().compactMap { index, file in
            file.substreamIndex.map { ($0, index) }
        })
        for (index, stream) in model.substreams.enumerated() {
            let file = try XCTUnwrap(files[index])
            XCTAssertEqual(stream.crc32, CRC32.checksum(items[file].data))
        }
        return model
    }
}
