// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

struct LZMAMatch { var length: Int; var distance: Int }

/// LzFind の HASH4、HC chain、BT の左右枝。位置は 1 始まりで 0 を空とする。
struct LZMAMatchFinder {
    let dictionarySize: Int
    let cyclicSize: Int
    let hashMask: Int
    let hashCount: Int
    let tree: Bool
    let niceLen: Int
    let cutValue: Int
    let hash: UnsafeMutablePointer<UInt32>
    let son: UnsafeMutablePointer<UInt32>
    let crc: UnsafeMutablePointer<UInt32>
    var position: UInt32 = 1
    var cyclic = 0

    static func mask(for dictionary: Int) -> Int {
        var value = UInt32(dictionary - 1)
        value |= value >> 1; value |= value >> 2; value |= value >> 4
        value |= value >> 8; value |= value >> 16
        value >>= 1
        value |= 0xFFFF
        if value > 1 << 24 { value >>= 1 }
        return Int(value)
    }
    static func memorySize(dictionary: Int, tree: Bool) -> Int {
        (mask(for: dictionary) + 1 + 1024 + 65536) * 4 + (dictionary + 1) * (tree ? 8 : 4) + 1024
    }
    init(properties p: LZMAEncoderProperties, dictionary: Int) throws {
        dictionarySize = dictionary; cyclicSize = dictionary + 1
        hashMask = Self.mask(for: dictionary); hashCount = hashMask + 1 + 1024 + 65536
        tree = p.matchFinder == .bt4; niceLen = p.niceLen; cutValue = p.cutValue
        hash = try lzmaAllocate(UInt32.self, count: hashCount)
        do { son = try lzmaAllocate(UInt32.self, count: cyclicSize * (tree ? 2 : 1)) }
        catch { free(hash); throw error }
        do { crc = try lzmaAllocate(UInt32.self, count: 256) }
        catch { free(hash); free(son); throw error }
        for i in 0..<256 {
            var v = UInt32(i)
            for _ in 0..<8 { v = (v >> 1) ^ (v & 1 == 0 ? 0 : 0xEDB8_8320) }
            crc[i] = v
        }
    }
    func release() { free(hash); free(son); free(crc) }
    mutating func advance() {
        position += 1
        cyclic += 1
        if cyclic == cyclicSize { cyclic = 0 }
        if position >= UInt32.max - 65536 {
            let sub = position - UInt32(cyclicSize)
            for i in 0..<hashCount { hash[i] = hash[i] <= sub ? 0 : hash[i] - sub }
            for i in 0..<(cyclicSize * (tree ? 2 : 1)) { son[i] = son[i] <= sub ? 0 : son[i] - sub }
            position -= sub
        }
    }

    /// cur の前に dictionarySize、後に available byte がある。結果は長さが増える順。
    @inline(__always) mutating func matches(_ cur: UnsafePointer<UInt8>, available: Int,
                                           into result: UnsafeMutablePointer<LZMAMatch>, record: Bool = true) -> Int {
        guard available >= 4 else { advance(); return 0 }
        let limit = min(available, niceLen)
        let temp = crc[Int(cur[0])] ^ UInt32(cur[1])
        let h2 = Int(temp & 1023)
        let temp3 = temp ^ (UInt32(cur[2]) << 8)
        let h3 = 1024 + Int(temp3 & 65535)
        let h4 = 1024 + 65536 + Int((temp3 ^ (crc[Int(cur[3])] << 5)) & UInt32(hashMask))
        let m2 = hash[h2], m3 = hash[h3]
        var candidate = hash[h4]
        hash[h2] = position; hash[h3] = position; hash[h4] = position
        var count = 0
        var best = 1
        // 小さい hash の候補を先に出す。2/3 byte の一致も literal より安い場合がある。
        if record {
            for i in 0..<2 {
                let m = i == 0 ? m2 : m3
                let delta = Int(position - m)
                if m != 0 && delta <= dictionarySize && cur[0] == cur[-delta] {
                    var len = 1
                    while len < limit && cur[len] == cur[len - delta] { len += 1 }
                    if len > best {
                        best = len
                        result[count] = LZMAMatch(length: len, distance: delta)
                        count += 1
                    }
                }
            }
        }
        if !tree {
            son[cyclic] = candidate
            var depth = cutValue
            while candidate != 0 && depth > 0 && best < limit {
                let delta = Int(position - candidate)
                if delta > dictionarySize { break }
                let index = cyclic >= delta ? cyclic - delta : cyclic - delta + cyclicSize
                candidate = son[index]
                if cur[best] == cur[best - delta] {
                    var len = 0
                    while len < limit && cur[len] == cur[len - delta] { len += 1 }
                    if len > best {
                        best = len
                        if record { result[count] = LZMAMatch(length: len, distance: delta); count += 1 }
                    }
                }
                depth -= 1
            }
        } else {
            var ptr0 = son + cyclic * 2 + 1
            var ptr1 = son + cyclic * 2
            var len0 = 0, len1 = 0
            var depth = cutValue
            while candidate != 0 && depth > 0 {
                let delta = Int(position - candidate)
                if delta > dictionarySize { break }
                let index = cyclic >= delta ? cyclic - delta : cyclic - delta + cyclicSize
                let pair = son + index * 2
                var len = min(len0, len1)
                while len < limit && cur[len] == cur[len - delta] { len += 1 }
                if record && len > best {
                    best = len; result[count] = LZMAMatch(length: len, distance: delta); count += 1
                }
                if len == limit {
                    ptr1.pointee = pair[0]; ptr0.pointee = pair[1]
                    advance()
                    // SDK の ReadMatchDistances と同じく niceLen の一致だけ 273 まで延長する。
                    if record && count > 0 { extend(cur, available: available, result: result, count: count) }
                    return count
                }
                if cur[len - delta] < cur[len] {
                    ptr1.pointee = candidate; ptr1 = pair + 1; candidate = pair[1]; len1 = len
                } else {
                    ptr0.pointee = candidate; ptr0 = pair; candidate = pair[0]; len0 = len
                }
                depth -= 1
            }
            ptr0.pointee = 0; ptr1.pointee = 0
        }
        advance()
        if record && count > 0 { extend(cur, available: available, result: result, count: count) }
        return count
    }
    @inline(__always) func extend(_ cur: UnsafePointer<UInt8>, available: Int,
                                 result: UnsafeMutablePointer<LZMAMatch>, count: Int) {
        if result[count - 1].length == niceLen {
            let distance = result[count - 1].distance
            var len = niceLen
            let limit = min(273, available)
            while len < limit && cur[len] == cur[len - distance] { len += 1 }
            result[count - 1].length = len
        }
    }
}
