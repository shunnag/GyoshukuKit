import Foundation

@inline(never)
func skipBzip2RepeatedBytes(
    _ bytes: UnsafeBufferPointer<UInt8>,
    index: Int,
    length: Int,
    character: Int
) -> (index: Int, length: Int) {
    var index = index
    var length = length
    let repeated = UInt64(character) * 0x0101_0101_0101_0101
    while length < 255, bytes.count - index >= 8 {
        let word = UnsafeRawPointer(bytes.baseAddress! + index)
            .loadUnaligned(as: UInt64.self)
        let difference = UInt64(littleEndian: word) ^ repeated
        let same = difference == 0 ? 8 : difference.trailingZeroBitCount >> 3
        let advance = min(same, 255 - length)
        index += advance
        length += advance
        if difference != 0 { break }
    }
    return (index, length)
}
