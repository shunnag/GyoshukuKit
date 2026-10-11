// Swift translation guided by LZMA SDK 26.03 LzmaEnc.c/LzFind.c (public domain, Igor Pavlov)
import Foundation

/// length <= 273、distance <= 1.5 GiB。候補を8 byteに収める。
struct LZMAMatch {
    private var storedLength: UInt16
    private let storedDistance: UInt32
    var length: Int {
        get { Int(storedLength) }
        set { storedLength = UInt16(truncatingIfNeeded: newValue) }
    }
    var distance: Int { Int(storedDistance) }
    init(length: Int, distance: Int) {
        storedLength = UInt16(truncatingIfNeeded: length)
        storedDistance = UInt32(truncatingIfNeeded: distance)
    }
}

/// 未整列の8 byte比較。差の最初の byteを little endian の下位 bitから求める。
/// limit 内だけを読み、window末尾や重なる repでも同じ長さを返す。
@inline(__always) func lzmaMatchLength(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>,
                                     start: Int = 0, limit: Int, checkFirstByte: Bool = true) -> Int {
    var length = start
    if checkFirstByte && length < limit && a[length] != b[length] { return length }
    while length &+ 8 <= limit {
        let difference = UInt64(littleEndian: UnsafeRawPointer(a + length).loadUnaligned(as: UInt64.self))
            ^ UInt64(littleEndian: UnsafeRawPointer(b + length).loadUnaligned(as: UInt64.self))
        if difference != 0 { return length &+ difference.trailingZeroBitCount / 8 }
        length &+= 8
    }
    while length < limit && a[length] == b[length] { length &+= 1 }
    return length
}

/// LzFind の HASH4、HC chain、BT の左右枝。位置は 1 始まりで 0 を空とする。
struct LZMAMatchFinder {
    let dictionarySize: Int
    let cyclicSize: Int
    let hashMask: UInt32
    let hashCount: Int
    let tree: Bool
    let niceLen: Int
    let cutValue: Int
    let hash: UnsafeMutablePointer<UInt32>
    let son: UnsafeMutablePointer<UInt32>
    let crc: UnsafeMutablePointer<UInt32>
    /// 対で走査するときの後の位置の自分の slot。走査中は旧 node の内容を保ち、終了後に son へ写す。
    let scratch: UnsafeMutablePointer<UInt32>
    var position: UInt32 = 1
    var cyclic = 0
    /// 先読みのための読取りを束ねる。値は使わないが、store が残ることで load が最適化で消えない。
    var prefetchSink: UInt32 = 0

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
            + 2 * MemoryLayout<UInt32>.stride // scratch
    }
    init(properties p: LZMAEncoderProperties, dictionary: Int) throws {
        dictionarySize = dictionary; cyclicSize = dictionary + 1
        hashMask = UInt32(Self.mask(for: dictionary)); hashCount = Int(hashMask) + 1 + 1024 + 65536
        tree = p.matchFinder == .bt4; niceLen = p.niceLen; cutValue = p.cutValue
        hash = try lzmaAllocate(UInt32.self, count: hashCount)
        do { son = try lzmaAllocate(UInt32.self, count: cyclicSize * (tree ? 2 : 1)) }
        catch { free(hash); throw error }
        do { crc = try lzmaAllocate(UInt32.self, count: 256) }
        catch { free(hash); free(son); throw error }
        do { scratch = try lzmaAllocate(UInt32.self, count: 2) }
        catch { free(hash); free(son); free(crc); throw error }
        for i in 0..<256 {
            var v = UInt32(i)
            for _ in 0..<8 { v = (v >> 1) ^ (v & 1 == 0 ? 0 : 0xEDB8_8320) }
            crc[i] = v
        }
    }
    func release() { free(hash); free(son); free(crc); free(scratch) }
    @inline(__always) mutating func advance() {
        // 正規化まで位置は UInt32 内、cyclic は辞書内。
        position &+= 1
        cyclic &+= 1
        if cyclic == cyclicSize { cyclic = 0 }
        if position >= UInt32.max - 65536 { normalize() }
    }
    /// 巨大な表の正規化を hot loop の inline 本体から分ける。
    @inline(never) private mutating func normalize() {
        let sub = position - UInt32(cyclicSize)
        for i in 0..<hashCount { hash[i] = hash[i] <= sub ? 0 : hash[i] - sub }
        for i in 0..<(cyclicSize * (tree ? 2 : 1)) { son[i] = son[i] <= sub ? 0 : son[i] - sub }
        position -= sub
    }

    /// cur の前に dictionarySize、後に available byte がある。結果は長さが増える順。
    @inline(__always) mutating func matches(_ cur: UnsafePointer<UInt8>, available: Int,
                                           into result: UnsafeMutablePointer<LZMAMatch>, record: Bool = true,
                                           extendMatches: Bool = true, recordShortMatches: Bool = true) -> Int {
        guard available >= 4 else { advance(); return 0 }
        // hash / son の書込みにまたがる不変値を register に保持する。
        let dictionarySize = self.dictionarySize, cyclicSize = self.cyclicSize
        let limit = min(available, niceLen)
        let word = UInt32(littleEndian: UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self))
        let crc0 = crc[Int(word & 255)]
        let temp = crc0 ^ ((word >> 8) & 255)
        let h2 = Int(temp & 1023)
        let temp3 = crc0 ^ ((word >> 8) & 65535)
        let h3 = 1024 + Int(temp3 & 65535)
        let h4 = 1024 + 65536 + Int((temp3 ^ (crc[Int(word >> 24)] << 5)) & hashMask)
        let m2 = hash[h2], m3 = hash[h3]
        var candidate = hash[h4]
        hash[h2] = position; hash[h3] = position; hash[h4] = position
        if available >= 6 {
            // 二つ先の位置の 4 byte hash の行を先読みする。表は L2 より大きく、位置ごとに一度 miss する。
            // Swift に prefetch 命令はないので、値を prefetchSink に畳み込む読取りで代用する。
            let next = UInt32(littleEndian: UnsafeRawPointer(cur + 2).loadUnaligned(as: UInt32.self))
            let t = crc[Int(next & 255)] ^ ((next >> 8) & 65535)
            prefetchSink &+= hash[1024 + 65536 + Int((t ^ (crc[Int(next >> 24)] << 5)) & hashMask)]
        }
        // HC の skip はリンク保存だけで同じ chain を作る。候補走査は不要。
        if !tree && !record { son[cyclic] = candidate; advance(); return 0 }
        var count = 0
        var best = 3
        if record && tree && !recordShortMatches {
            // BTの走査は短いhashのbestに依存しない。headの距離を保存し、読取時に候補列を復元する。
            let d2 = Int(position &- m2), d3 = Int(position &- m3)
            result[0] = LZMAMatch(length: 0, distance: m2 != 0 && d2 <= dictionarySize ? d2 : 0)
            result[1] = LZMAMatch(length: 0, distance: m3 != 0 && d3 <= dictionarySize ? d3 : 0)
            count = 2
        }
        if record && tree && recordShortMatches {
            best = shortMatches(cur, position: position, m2: m2, m3: m3, limit: limit, into: result, count: &count)
        }
        if record && !tree {
            // HC は長い best を先に得るほど chain の候補を早く除外できる。
            best = 1
            for i in 0..<2 {
                if best == limit || (i == 1 && m2 == m3) { break }
                let m = i == 0 ? m2 : m3
                let delta = Int(position &- m)
                if m != 0 && delta <= dictionarySize && cur[0] == cur[-delta] {
                    let len = lzmaMatchLength(cur, cur - delta, start: i + 2, limit: limit)
                    if len > best {
                        best = len; result[count] = LZMAMatch(length: len, distance: delta); count &+= 1
                    }
                }
            }
        }
        if !tree {
            son[cyclic] = candidate
            var depth = cutValue
            while candidate != 0 && depth > 0 && best < limit {
                let delta = Int(position &- candidate)
                if delta > dictionarySize { break }
                let offset = cyclic &- delta
                // HC の循環 index は sign mask で選び、履歴距離による分岐を省く。
                let index = offset &+ ((offset >> (Int.bitWidth - 1)) & cyclicSize)
                let candidateData = cur - delta
                candidate = son[index]
                if cur[best] == candidateData[best] {
                    let len = lzmaMatchLength(cur, candidateData, limit: limit, checkFirstByte: false)
                    if len > best {
                        best = len
                        if record { result[count] = LZMAMatch(length: len, distance: delta); count &+= 1 }
                    }
                }
                depth -= 1
            }
        } else {
            // BTの枝更新・打切りはbest/count/recordを参照しない。
            // 全位置でrecord:trueにしても、skipと同じ表を次位置へ渡す。
            var ptr0 = son + (cyclic &* 2 &+ 1)
            var ptr1 = son + (cyclic &* 2)
            var len0 = 0, len1 = 0
            var depth = cutValue
            var sink: UInt32 = 0
            while candidate != 0 && depth > 0 {
                let delta = Int(position &- candidate)
                if delta > dictionarySize { break }
                let offset = cyclic &- delta
                let index = offset < 0 ? offset &+ cyclicSize : offset
                let candidateData = cur - delta
                let pair = son + (index &* 2)
                // 両方の子を先に読み、次段で選ばれる方の枝の行を分岐の確定前に先読みする。
                // 木の進行方向は予測しにくく、son の行は L2 に収まらないため、読み外しの度に待たない。
                let c0 = pair[0], c1 = pair[1]
                let d0 = Int(position &- c0), d1 = Int(position &- c1)
                let o0 = cyclic &- d0, o1 = cyclic &- d1
                let i0 = d0 <= dictionarySize ? o0 &+ ((o0 >> (Int.bitWidth - 1)) & cyclicSize) : cyclic
                let i1 = d1 <= dictionarySize ? o1 &+ ((o1 >> (Int.bitWidth - 1)) & cyclicSize) : cyclic
                sink &+= son[i0 &* 2] &+ son[i1 &* 2]
                let len = lzmaMatchLength(cur, candidateData, start: min(len0, len1), limit: limit, checkFirstByte: false)
                if record && len > best {
                    best = len; result[count] = LZMAMatch(length: len, distance: delta); count &+= 1
                }
                if len == limit {
                    ptr1.pointee = c0; ptr0.pointee = c1
                    prefetchSink &+= sink
                    advance()
                    // SDK の ReadMatchDistances と同じく niceLen の一致だけ 273 まで延長する。
                    if record && extendMatches && count > 0 { extend(cur, available: available, result: result, count: count) }
                    return count
                }
                if candidateData[len] < cur[len] {
                    ptr1.pointee = candidate; ptr1 = pair + 1; candidate = c1; len1 = len
                } else {
                    ptr0.pointee = candidate; ptr0 = pair; candidate = c0; len0 = len
                }
                depth -= 1
            }
            ptr0.pointee = 0; ptr1.pointee = 0
            prefetchSink &+= sink
        }
        advance()
        if record && extendMatches && count > 0 { extend(cur, available: available, result: result, count: count) }
        return count
    }

    /// 連続する二つの位置を一つの loop で交互に走査する。4 byte hash の bucket が異なれば二つの木は node を共有せず、
    /// 逐次と同じ比較・同じ表の更新を、memory の待ち時間を重ねて行える。後の位置が自分の slot へ書く値だけは
    /// scratch に留める。その slot は前の位置から見て辞書内の最古の node で、前の走査が旧内容を読み得るためである。
    /// 適用できないときは nil を返し、呼出側は一つずつ処理する。
    @inline(__always) mutating func treeMatchesPair(_ cur: UnsafePointer<UInt8>, available: Int,
                                                   into result: UnsafeMutablePointer<LZMAMatch>,
                                                   second: UnsafeMutablePointer<LZMAMatch>, record: Bool,
                                                   extendMatches: Bool, recordShortMatches: Bool) -> (Int, Int)? {
        guard tree, available >= 5, position < UInt32.max - 65536 - 2 else { return nil }
        let dictionarySize = self.dictionarySize, cyclicSize = self.cyclicSize
        let hashMask = self.hashMask, niceLen = self.niceLen
        let wordA = UInt32(littleEndian: UnsafeRawPointer(cur).loadUnaligned(as: UInt32.self))
        let wordB = UInt32(littleEndian: UnsafeRawPointer(cur + 1).loadUnaligned(as: UInt32.self))
        let crcA = crc[Int(wordA & 255)], crcB = crc[Int(wordB & 255)]
        let temp3A = crcA ^ ((wordA >> 8) & 65535), temp3B = crcB ^ ((wordB >> 8) & 65535)
        let h4A = 1024 + 65536 + Int((temp3A ^ (crc[Int(wordA >> 24)] << 5)) & hashMask)
        let h4B = 1024 + 65536 + Int((temp3B ^ (crc[Int(wordB >> 24)] << 5)) & hashMask)
        guard h4A != h4B else { return nil }
        let h2A = Int((crcA ^ ((wordA >> 8) & 255)) & 1023), h2B = Int((crcB ^ ((wordB >> 8) & 255)) & 1023)
        let h3A = 1024 + Int(temp3A & 65535), h3B = 1024 + Int(temp3B & 65535)
        let posA = position, posB = position &+ 1
        let cyclicA = cyclic, cyclicB = cyclic &+ 1 == cyclicSize ? 0 : cyclic &+ 1
        let curB = cur + 1
        let limitA = min(available, niceLen), limitB = min(available &- 1, niceLen)
        // hash head は逐次と同じ順に読み書きする。
        let m2A = hash[h2A], m3A = hash[h3A]
        var candA = hash[h4A]
        hash[h2A] = posA; hash[h3A] = posA; hash[h4A] = posA
        let m2B = hash[h2B], m3B = hash[h3B]
        var candB = hash[h4B]
        hash[h2B] = posB; hash[h3B] = posB; hash[h4B] = posB
        if available >= 7 {
            let next = UInt32(littleEndian: UnsafeRawPointer(cur + 3).loadUnaligned(as: UInt32.self))
            let t = crc[Int(next & 255)] ^ ((next >> 8) & 65535)
            prefetchSink &+= hash[1024 + 65536 + Int((t ^ (crc[Int(next >> 24)] << 5)) & hashMask)]
        }
        var countA = 0, countB = 0, bestA = 3, bestB = 3
        if record && !recordShortMatches {
            let d2 = Int(posA &- m2A), d3 = Int(posA &- m3A)
            result[0] = LZMAMatch(length: 0, distance: m2A != 0 && d2 <= dictionarySize ? d2 : 0)
            result[1] = LZMAMatch(length: 0, distance: m3A != 0 && d3 <= dictionarySize ? d3 : 0)
            countA = 2
            let e2 = Int(posB &- m2B), e3 = Int(posB &- m3B)
            second[0] = LZMAMatch(length: 0, distance: m2B != 0 && e2 <= dictionarySize ? e2 : 0)
            second[1] = LZMAMatch(length: 0, distance: m3B != 0 && e3 <= dictionarySize ? e3 : 0)
            countB = 2
        }
        if record && recordShortMatches {
            bestA = shortMatches(cur, position: posA, m2: m2A, m3: m3A, limit: limitA, into: result, count: &countA)
            bestB = shortMatches(curB, position: posB, m2: m2B, m3: m3B, limit: limitB, into: second, count: &countB)
        }
        var ptr0A = son + (cyclicA &* 2 &+ 1), ptr1A = son + (cyclicA &* 2)
        var ptr0B = scratch + 1, ptr1B = scratch
        var len0A = 0, len1A = 0, len0B = 0, len1B = 0
        var depthA = cutValue, depthB = cutValue
        var activeA = true, activeB = true
        var sink: UInt32 = 0
        while activeA || activeB {
            if activeA {
                if candA == 0 || depthA <= 0 { ptr0A.pointee = 0; ptr1A.pointee = 0; activeA = false }
                else {
                    let delta = Int(posA &- candA)
                    if delta > dictionarySize { ptr0A.pointee = 0; ptr1A.pointee = 0; activeA = false }
                    else {
                        let offset = cyclicA &- delta
                        let index = offset < 0 ? offset &+ cyclicSize : offset
                        let candidateData = cur - delta
                        let pair = son + (index &* 2)
                        let c0 = pair[0], c1 = pair[1]
                        let d0 = Int(posA &- c0), d1 = Int(posA &- c1)
                        let o0 = cyclicA &- d0, o1 = cyclicA &- d1
                        let i0 = d0 <= dictionarySize ? o0 &+ ((o0 >> (Int.bitWidth - 1)) & cyclicSize) : cyclicA
                        let i1 = d1 <= dictionarySize ? o1 &+ ((o1 >> (Int.bitWidth - 1)) & cyclicSize) : cyclicA
                        sink &+= son[i0 &* 2] &+ son[i1 &* 2]
                        let len = lzmaMatchLength(cur, candidateData, start: min(len0A, len1A), limit: limitA, checkFirstByte: false)
                        if record && len > bestA {
                            bestA = len; result[countA] = LZMAMatch(length: len, distance: delta); countA &+= 1
                        }
                        if len == limitA {
                            ptr1A.pointee = c0; ptr0A.pointee = c1; activeA = false
                        } else {
                            if candidateData[len] < cur[len] {
                                ptr1A.pointee = candA; ptr1A = pair + 1; candA = c1; len1A = len
                            } else {
                                ptr0A.pointee = candA; ptr0A = pair; candA = c0; len0A = len
                            }
                            depthA -= 1
                        }
                    }
                }
            }
            if activeB {
                if candB == 0 || depthB <= 0 { ptr0B.pointee = 0; ptr1B.pointee = 0; activeB = false }
                else {
                    let delta = Int(posB &- candB)
                    if delta > dictionarySize { ptr0B.pointee = 0; ptr1B.pointee = 0; activeB = false }
                    else {
                        let offset = cyclicB &- delta
                        let index = offset < 0 ? offset &+ cyclicSize : offset
                        let candidateData = curB - delta
                        let pair = son + (index &* 2)
                        let c0 = pair[0], c1 = pair[1]
                        let d0 = Int(posB &- c0), d1 = Int(posB &- c1)
                        let o0 = cyclicB &- d0, o1 = cyclicB &- d1
                        let i0 = d0 <= dictionarySize ? o0 &+ ((o0 >> (Int.bitWidth - 1)) & cyclicSize) : cyclicB
                        let i1 = d1 <= dictionarySize ? o1 &+ ((o1 >> (Int.bitWidth - 1)) & cyclicSize) : cyclicB
                        sink &+= son[i0 &* 2] &+ son[i1 &* 2]
                        let len = lzmaMatchLength(curB, candidateData, start: min(len0B, len1B), limit: limitB, checkFirstByte: false)
                        if record && len > bestB {
                            bestB = len; second[countB] = LZMAMatch(length: len, distance: delta); countB &+= 1
                        }
                        if len == limitB {
                            ptr1B.pointee = c0; ptr0B.pointee = c1; activeB = false
                        } else {
                            if candidateData[len] < curB[len] {
                                ptr1B.pointee = candB; ptr1B = pair + 1; candB = c1; len1B = len
                            } else {
                                ptr0B.pointee = candB; ptr0B = pair; candB = c0; len0B = len
                            }
                            depthB -= 1
                        }
                    }
                }
            }
        }
        prefetchSink &+= sink
        // 後の位置の自分の slot を、前の走査が終わった後に確定する。
        son[cyclicB &* 2] = scratch[0]; son[cyclicB &* 2 &+ 1] = scratch[1]
        position &+= 2
        cyclic = cyclicB &+ 1 == cyclicSize ? 0 : cyclicB &+ 1
        if record && extendMatches {
            if countA > 0 { extend(cur, available: available, result: result, count: countA) }
            if countB > 0 { extend(curB, available: available &- 1, result: second, count: countB) }
        }
        return (countA, countB)
    }
    /// SDK の短い hash: 2 byte 候補が3 byteも一致すれば、その候補だけを延長する。
    /// それ以外は2 byteを保存し、3 byte候補を一度延長する。BT は4 byte以上を補う。戻り値は best。
    @inline(__always) func shortMatches(_ cur: UnsafePointer<UInt8>, position: UInt32, m2: UInt32, m3: UInt32, limit: Int,
                                       into result: UnsafeMutablePointer<LZMAMatch>, count: inout Int) -> Int {
        let d2 = Int(position &- m2), d3 = Int(position &- m3)
        var shortDistance = 0, best = 3
        if m2 != 0 && d2 <= dictionarySize && cur[0] == cur[-d2] {
            if cur[2] == cur[2 &- d2] {
                shortDistance = d2
            } else {
                result[0] = LZMAMatch(length: 2, distance: d2); count = 1
                if m3 != 0 && d3 <= dictionarySize && cur[0] == cur[-d3] { shortDistance = d3 }
            }
        } else if m3 != 0 && d3 <= dictionarySize && cur[0] == cur[-d3] {
            shortDistance = d3
        }
        if shortDistance != 0 {
            best = lzmaMatchLength(cur, cur - shortDistance, start: 3, limit: limit)
            result[count] = LZMAMatch(length: best, distance: shortDistance); count &+= 1
        }
        return best
    }
    /// workerが保存したBT候補と短いhash headから、逐次と同じ候補順・同距離の優先を復元する。
    /// shortのbest以下のBT候補だけを除外する。書込位置は常に読取位置以下なのでin-placeでよい。
    @inline(__always) func finalizeTreeMatches(_ cur: UnsafePointer<UInt8>, available: Int,
                                              result: UnsafeMutablePointer<LZMAMatch>, count: Int) -> Int {
        guard count >= 2 else { return count }
        let d2 = result[0].distance, d3 = result[1].distance
        var written = 0, best = 3, shortDistance = 0
        if d2 != 0 && cur[0] == cur[-d2] {
            if cur[2] == cur[2 - d2] { shortDistance = d2 }
            else {
                result[0] = LZMAMatch(length: 2, distance: d2); written = 1
                if d3 != 0 && cur[0] == cur[-d3] { shortDistance = d3 }
            }
        } else if d3 != 0 && cur[0] == cur[-d3] { shortDistance = d3 }
        if shortDistance != 0 {
            best = lzmaMatchLength(cur, cur - shortDistance, start: 3, limit: min(available, niceLen))
            result[written] = LZMAMatch(length: best, distance: shortDistance); written += 1
        }
        for i in 2..<count {
            let match = result[i]
            if match.length > best { result[written] = match; written += 1; best = match.length }
        }
        if written > 0 { extend(cur, available: available, result: result, count: written) }
        return written
    }
    @inline(__always) func extend(_ cur: UnsafePointer<UInt8>, available: Int,
                                 result: UnsafeMutablePointer<LZMAMatch>, count: Int) {
        if result[count - 1].length == niceLen {
            let distance = result[count - 1].distance
            let limit = min(273, available)
            result[count - 1].length = lzmaMatchLength(cur, cur - distance, start: niceLen, limit: limit)
        }
    }
}
