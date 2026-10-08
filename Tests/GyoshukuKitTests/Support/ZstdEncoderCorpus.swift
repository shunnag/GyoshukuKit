import Foundation

/// 16 MiB の tar 風入力。圧縮済み風の乱数・text・binary を256 KiBごとに交互配置する。
enum ZstdEncoderCorpus {
    static func mixed(text: Data, binary: Data) -> Data {
        precondition(!text.isEmpty && !binary.isEmpty)
        let payloadSize = (256 << 10) - 512
        var result = Data(); result.reserveCapacity(16 << 20)
        var state: UInt64 = 0x726F_756E_6433_0001
        for section in 0..<64 {
            let kind = section % 4
            var header = Data(repeating: 0, count: 512)
            func field(_ value: String, at offset: Int) {
                header.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
            }
            field("section-\(section)." + (kind == 1 ? "txt" : kind == 2 ? "bin" : "jpg-like"), at: 0)
            field("0000644", at: 100); field("0000000", at: 108); field("0000000", at: 116)
            field(String(format: "%011o", payloadSize), at: 124); field("00000000000", at: 136)
            field("        ", at: 148); field("0", at: 156); field("ustar", at: 257); field("00", at: 263)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", at: 148)
            result.append(header)
            if kind == 1 || kind == 2 {
                let source = kind == 1 ? text : binary
                var offset = ((section / 4) * payloadSize) % source.count, remaining = payloadSize
                while remaining > 0 {
                    let n = min(remaining, source.count - offset)
                    result.append(source.subdata(in: offset..<(offset + n)))
                    remaining -= n; offset = 0
                }
            } else {
                for _ in 0..<payloadSize {
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    result.append(UInt8(truncatingIfNeeded: state))
                }
            }
        }
        return result
    }
}
