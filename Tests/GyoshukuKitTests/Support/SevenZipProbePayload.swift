import Foundation
import CommonCrypto

// P0b と同じ単語・AES-CTR の生成規則（seed 20260925 + file index）。
enum SevenZipProbePayload {
    static let words = WordList()

    static func data(file index: Int, size: Int, words: WordList = Self.words) throws -> Data {
        let random = try BlockRandom(seed: 20_260_925 + UInt64(index))
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { output in
            if index >= 48 { try random.fill(output); return }
            // 単語単位でコピーし、乱数は 64 KiB ずつ生成する。
            var draws = [UInt32](repeating: 0, count: BlockRandom.blockSize / MemoryLayout<UInt32>.size)
            try words.bytes.withUnsafeBytes { dictionary in
                var offset = 0
                while offset < output.count {
                    try draws.withUnsafeMutableBytes { try random.fill($0) }
                    for draw in draws {
                        let word = words.ranges[Int(UInt32(littleEndian: draw)) % words.ranges.count]
                        let count = min(word.count, output.count - offset)
                        output.baseAddress!.advanced(by: offset).copyMemory(
                            from: dictionary.baseAddress!.advanced(by: word.lowerBound), byteCount: count)
                        offset += count
                        if offset == output.count { break }
                    }
                }
            }
        }
        return data
    }

    struct WordList: Sendable {
        let bytes: Data
        let ranges: [Range<Int>]
        let source: String

        init(url: URL = URL(fileURLWithPath: "/usr/share/dict/words")) {
            let dictionary = (try? String(contentsOf: url, encoding: .utf8))?.split(whereSeparator: \.isWhitespace) ?? []
            let available = !dictionary.isEmpty
            let words = available ? dictionary : Self.fallback.split(whereSeparator: \.isWhitespace)
            var bytes = Data(), ranges: [Range<Int>] = []
            ranges.reserveCapacity(words.count)
            for word in words {
                let start = bytes.count
                bytes.append(contentsOf: word.utf8)
                bytes.append(32)
                ranges.append(start..<bytes.count)
            }
            self.bytes = bytes
            self.ranges = ranges
            source = available ? url.path : "builtin"
        }

        private static let fallback = """
        ability absent accept across action address adjust advice afternoon airport amber amount anchor animal answer
        apple archive arrange arrow autumn balance bamboo basket beach before begin below bicycle blanket blossom
        blue boat border bottle branch breeze bridge bright bronze browser build button cabin cable camera canyon
        captain carrot cedar center change chapter cherry circle citizen city clay clear clock cloud coast coffee
        color column common compare compass complete copper coral cotton country cover create crystal current
        dance data dawn decide deep desert design detail device diamond different dinner direction distant divide
        doctor document dragon dream drive early earth east edge editor effort eight electric emerald energy engine
        entry evening every example expect explain factory family feather field figure filter finish fire first
        flower forest format fountain frame fresh friend frost future garden gentle glass golden grain granite
        green group guide harbor harvest hazel heavy hidden history horizon hotel house hundred ice idea image
        include index input island ivory jacket journey judge jungle kernel keyboard kitchen ladder lake language
        lantern large last later lavender layer leader leaf learn lemon letter library light lilac limit linen
        list little local long machine magic marble market meadow measure memory metal midnight minute mirror
        model month morning moss mountain music name narrow nature network night north number ocean office olive
        orange orchid order origin output outside paper parent path pattern peach pearl people pepper period
        person picture pine planet plant pocket poem point pool prepare present process publish purple quartz
        question quiet rabbit rain reader record region replace result return review river road robin rock rose
        round ruby sail salt sample sand save scarlet school science season seed silver simple size sky snow
        source south space spring square stage star station stone store stream string study summer sunset
        surface table target temple text theory thread thunder ticket time tomato topic total tower train tree
        tulip under union unit update valley value velvet verify violet volume walk water wave weather west wheat
        white willow window winter wisdom wonder wood word worker world write year yellow young zebra zero
        """
    }

    private final class BlockRandom {
        static let blockSize = 65_536
        private static let zeros = Data(count: blockSize)
        private var cryptor: CCCryptorRef?

        init(seed: UInt64) throws {
            // 固定鍵とゼロ IV の CTR 出力を再現可能な乱数源としてだけ使う。
            var key = (seed.littleEndian, UInt64(0x4b6169746f507262).littleEndian)
            let status = withUnsafeBytes(of: &key) {
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), nil, $0.baseAddress, $0.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
            guard status == kCCSuccess else { throw GenerationError.crypto(status) }
        }

        deinit { if let cryptor { CCCryptorRelease(cryptor) } }

        func fill(_ output: UnsafeMutableRawBufferPointer) throws {
            try Self.zeros.withUnsafeBytes { zeros in
                for offset in stride(from: 0, to: output.count, by: Self.blockSize) {
                    let count = min(Self.blockSize, output.count - offset)
                    var written = 0
                    let status = CCCryptorUpdate(cryptor, zeros.baseAddress, count,
                        output.baseAddress!.advanced(by: offset), count, &written)
                    guard status == kCCSuccess, written == count else { throw GenerationError.crypto(status) }
                }
            }
        }
    }

    private enum GenerationError: Error { case crypto(CCCryptorStatus) }
}
