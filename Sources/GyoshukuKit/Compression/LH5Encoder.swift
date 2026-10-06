import Foundation

// KaitoKit の LHAStaticHuffmanDecoder が読む -lh5- / -lh6- / -lh7- 文法の逆変換。
// 辞書と最大一致長は LHa for UNIX header.doc.md、文法は既存 LH5 と task の parameter に基づく。
// https://github.com/jca02266/lha/blob/master/header.doc.md
// https://github.com/fragglet/lhasa/blob/master/doc/lha.1
// dictionary は block を跨いで維持し、Huffman 木だけを command 数ごとに作り直す。
enum LH5Encoder {
    static let windowSize = 8192
    static let blockCommands = 32_768

    struct Configuration: Sendable {
        let method: LHACompressionMethod
        let probeCount: Int
        let lazyMatching: Bool
        var windowSize: Int { method.windowSize }
        var positionSymbols: Int { method.dictionaryBits + 1 }
        var positionCountBits: Int { method == .lh5 ? 4 : 5 }

        init(method: LHACompressionMethod = .lh5, level: Int = 6) {
            precondition((1...9).contains(level))
            self.method = method
            probeCount = 8 << (level - 1)
            lazyMatching = level >= 8
        }
    }

    struct Command {
        let symbol: Int
        let position: Int
        var positionSymbol: Int { position == 0 ? 0 : Int.bitWidth - position.leadingZeroBitCount }
    }

    static func encode(_ input: Data) throws -> Data {
        try encode(input, configuration: Configuration())
    }

    static func encode(_ input: Data, configuration: Configuration) throws -> Data {
        if configuration.method == .stored { return input }
        var bits = Bits()
        try write(input, configuration: configuration, to: &bits)
        return bits.finish()
    }

    // streaming の入力は、既に出力した history を window 一つ分まで先頭に含めてよい。その prefix は match の
    // 種にするだけで、再出力しない。各方式の block に byte padding は無いので、bit writer は入力を跨いで保つ。
    static func write(_ input: Data, startingAt initialOffset: Int = 0,
                      configuration: Configuration = Configuration(), to bits: inout Bits) throws {
        try Task.checkCancellation()
        let windowSize = configuration.windowSize
        guard configuration.method != .stored,
              initialOffset >= 0, initialOffset <= windowSize, initialOffset <= input.count else {
            throw WriterError.invalidState
        }
        guard initialOffset < input.count else { return }
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var heads = [Int](repeating: -1, count: 65_536)
            var previous = [Int](repeating: -1, count: windowSize)
            var commands: [Command] = []
            commands.reserveCapacity(blockCommands)
            var offset = initialOffset
            for index in 0..<initialOffset where index + 2 < bytes.count {
                let bucket = hash(bytes, index)
                previous[index & (windowSize - 1)] = heads[bucket]
                heads[bucket] = index
            }
            var checkpoint = initialOffset
            while offset < bytes.count {
                if offset >= checkpoint {
                    try Task.checkCancellation()
                    checkpoint = offset + 4096
                }
                var match = findMatch(bytes, at: offset, heads: heads, previous: previous, configuration: configuration)
                var registered = false
                if configuration.lazyMatching, match.distance > 0, match.length < 256,
                   offset + 3 < bytes.count {
                    // 次の位置の探索には現在の byte も辞書へ入れる。消費後の登録で二重に chain を結ばない。
                    let bucket = hash(bytes, offset)
                    previous[offset & (windowSize - 1)] = heads[bucket]
                    heads[bucket] = offset
                    registered = true
                    let next = findMatch(bytes, at: offset + 1, heads: heads, previous: previous, configuration: configuration)
                    if next.length > match.length { match = (2, 0) }
                }
                let consumed: Int
                if match.distance > 0 {
                    commands.append(Command(symbol: match.length + 253, position: match.distance - 1))
                    consumed = match.length
                } else {
                    commands.append(Command(symbol: Int(bytes[offset]), position: 0))
                    consumed = 1
                }
                // match で飛ばす byte も登録し、次の探索から dictionary 全体を参照できるようにする。
                for index in (offset + (registered ? 1 : 0))..<(offset + consumed) where index + 2 < bytes.count {
                    let bucket = hash(bytes, index)
                    previous[index & (windowSize - 1)] = heads[bucket]
                    heads[bucket] = index
                }
                offset += consumed
                if commands.count == blockCommands {
                    try writeBlock(commands, configuration: configuration, to: &bits)
                    commands.removeAll(keepingCapacity: true)
                }
            }
            if !commands.isEmpty { try writeBlock(commands, configuration: configuration, to: &bits) }
            try Task.checkCancellation()
        }
    }

    private static func findMatch(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int,
                                  heads: [Int], previous: [Int], configuration: Configuration) -> (length: Int, distance: Int) {
        let maximum = min(256, bytes.count - offset)
        var length = 2, distance = 0
        guard maximum >= 3 else { return (length, distance) }
        var candidate = heads[hash(bytes, offset)]
        let oldest = max(0, offset - configuration.windowSize)
        var probes = 0
        // chain は絶対位置の降順。古い位置で止め、ring の再利用を循環にしない。
        // level ごとの候補数で打ち切るため、衝突の多い入力でも探索量は入力長に比例する。
        while candidate >= oldest, probes < configuration.probeCount {
            if bytes[candidate] == bytes[offset], bytes[candidate + 1] == bytes[offset + 1],
               bytes[candidate + length] == bytes[offset + length] {
                var count = 2
                // distance より長い一致も許す。decoder の前向きコピーで同じ byte が再生される。
                while count < maximum, bytes[candidate + count] == bytes[offset + count] { count += 1 }
                if count > length {
                    length = count
                    distance = offset - candidate
                    if length == maximum { break }
                }
            }
            candidate = previous[candidate & (configuration.windowSize - 1)]
            probes += 1
        }
        return (length, distance)
    }

    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int {
        let value = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
        return Int((value &* 0x1E35_A7BD) >> 16)
    }

    static func writeBlock(_ commands: [Command], configuration: Configuration = Configuration(), to bits: inout Bits) throws {
        try Task.checkCancellation()
        var commandFrequencies = [Int](repeating: 0, count: 510)
        var positionFrequencies = [Int](repeating: 0, count: configuration.positionSymbols)
        for command in commands {
            commandFrequencies[command.symbol] += 1
            if command.symbol >= 256 { positionFrequencies[command.positionSymbol] += 1 }
        }
        let commandTree = Huffman(commandFrequencies)
        let positionTree = Huffman(positionFrequencies)
        bits.write(commands.count, count: 16)
        if let symbol = commandTree.constant {
            // count=0 は「空の木」ではなく固定 symbol。実際の command は 0 bit になる。
            writeLengths(Huffman([Int](repeating: 0, count: 19)), countBits: 5, special: true, to: &bits)
            bits.write(0, count: 9)
            bits.write(symbol, count: 9)
        } else {
            let lengths = commandLengths(commandTree.lengths)
            var frequencies = [Int](repeating: 0, count: 19)
            for token in lengths { frequencies[token.symbol] += 1 }
            let lengthTree = Huffman(frequencies)
            writeLengths(lengthTree, countBits: 5, special: true, to: &bits)
            bits.write(commandTree.count, count: 9)
            for token in lengths {
                lengthTree.write(token.symbol, to: &bits)
                bits.write(token.extra, count: token.bits)
            }
        }
        // LH5 は NP=14・count 4 bit、LH6 は NP=16・count 5 bit、LH7 は NP=17・count 5 bit。
        writeLengths(positionTree, countBits: configuration.positionCountBits, special: false, to: &bits)
        for (index, command) in commands.enumerated() {
            if index & 4095 == 0 { try Task.checkCancellation() }
            commandTree.write(command.symbol, to: &bits)
            if command.symbol >= 256 {
                let symbol = command.positionSymbol
                positionTree.write(symbol, to: &bits)
                if symbol > 1 { bits.write(command.position - (1 << (symbol - 1)), count: symbol - 1) }
            }
        }
        // block 間に byte padding は入れない。次の 16 bit count は直後の bit から始まる。
    }

    struct LengthToken {
        let symbol: Int
        var extra = 0
        var bits = 0
    }

    static func commandLengths(_ lengths: [Int]) -> [LengthToken] {
        let count = (lengths.lastIndex { $0 != 0 } ?? -1) + 1
        var result: [LengthToken] = []
        var index = 0
        while index < count {
            if lengths[index] > 0 {
                result.append(LengthToken(symbol: lengths[index] + 2))
                index += 1
            } else {
                let start = index
                while index < count, lengths[index] == 0 { index += 1 }
                let run = index - start
                switch run {
                case 1...2:
                    for _ in 0..<run { result.append(LengthToken(symbol: 0)) }
                case 3...18:
                    result.append(LengthToken(symbol: 1, extra: run - 3, bits: 4))
                case 19:
                    // 4 bit escape は最大 18、9 bit escape は最小 20。19 は 1+18 に分ける。
                    result.append(LengthToken(symbol: 0))
                    result.append(LengthToken(symbol: 1, extra: 15, bits: 4))
                default:
                    result.append(LengthToken(symbol: 2, extra: run - 20, bits: 9))
                }
            }
        }
        return result
    }

    private static func writeLengths(_ tree: Huffman, countBits: Int, special: Bool, to bits: inout Bits) {
        if let symbol = tree.constant {
            bits.write(0, count: countBits)
            bits.write(symbol, count: countBits)
            return
        }
        bits.write(tree.count, count: countBits)
        var index = 0
        while index < tree.count {
            let length = tree.lengths[index]
            if length < 7 {
                bits.write(length, count: 3)
            } else {
                bits.write(7, count: 3)
                for _ in 7..<length { bits.write(1, count: 1) }
                bits.write(0, count: 1)
            }
            index += 1
            if special, index == 3 {
                let start = index
                while index < min(6, tree.count), tree.lengths[index] == 0 { index += 1 }
                // NT の index 3 にだけ存在する 2 bit のゼロ省略。省略数 0 の場合も欄が必要。
                bits.write(index - start, count: 2)
            }
        }
    }

    struct Bits {
        struct Remainder: Sendable {
            let value: UInt64
            let count: Int
        }

        private var bytes: [UInt8] = []
        private var pending: UInt64 = 0
        private var available = 0

        var remainder: Remainder { Remainder(value: pending, count: available) }

        mutating func append(_ completeBytes: Data, remainder: Remainder) {
            precondition((0..<8).contains(remainder.count) && remainder.value < (1 << remainder.count))
            bytes.reserveCapacity(bytes.count + completeBytes.count + 1)
            if available == 0 {
                bytes.append(contentsOf: completeBytes)
            } else {
                // 境界に padding を入れず、前の端数 bit と次の byte を順に継ぐ。
                let shift = 8 - available, mask = UInt64((1 << available) - 1)
                for byte in completeBytes {
                    bytes.append(UInt8(truncatingIfNeeded: (pending << shift) | UInt64(byte >> available)))
                    pending = UInt64(byte) & mask
                }
            }
            write(Int(remainder.value), count: remainder.count)
        }

        mutating func write(_ value: Int, count: Int) {
            guard count > 0 else { return }
            // LHA は MSB first。canonical code を反転する deflate の規約とは異なる。
            pending = (pending << count) | UInt64(value)
            available += count
            while available >= 8 {
                available -= 8
                bytes.append(UInt8(truncatingIfNeeded: pending >> available))
            }
            pending &= (1 << available) - 1
        }

        mutating func finish() -> Data {
            if available > 0 { write(0, count: 8 - available) }
            return takeCompleteBytes()
        }

        mutating func takeCompleteBytes() -> Data {
            let result = Data(bytes)
            bytes.removeAll(keepingCapacity: true)
            return result
        }
    }

    struct Huffman {
        let lengths: [Int]
        let codes: [Int]
        let constant: Int?
        var count: Int { (lengths.lastIndex { $0 != 0 } ?? -1) + 1 }

        init(_ frequencies: [Int]) {
            let symbols = frequencies.indices.filter { frequencies[$0] > 0 }.sorted {
                frequencies[$0] == frequencies[$1] ? $0 < $1 : frequencies[$0] < frequencies[$1]
            }
            if symbols.count <= 1 {
                constant = symbols.first ?? 0
                lengths = [Int](repeating: 0, count: frequencies.count)
                codes = lengths
                return
            }
            constant = nil
            lengths = Self.limitedLengths(frequencies, symbols: symbols)
            var counts = [Int](repeating: 0, count: 17)
            for length in lengths where length > 0 { counts[length] += 1 }
            var next = [Int](repeating: 0, count: 17)
            for length in 1...16 { next[length] = (next[length - 1] + counts[length - 1]) << 1 }
            var codes = [Int](repeating: 0, count: frequencies.count)
            // 同じ長さは symbol 昇順に連番を割り当て、reader の canonical table と一致させる。
            for symbol in lengths.indices where lengths[symbol] > 0 {
                let length = lengths[symbol]
                codes[symbol] = next[length]
                next[length] += 1
            }
            self.codes = codes
        }

        func write(_ symbol: Int, to bits: inout Bits) {
            bits.write(codes[symbol], count: lengths[symbol])
        }

        private struct Package {
            let weight: Int
            let symbol: Int
            var left = -1
            var right = -1
        }

        private static func limitedLengths(_ frequencies: [Int], symbols: [Int]) -> [Int] {
            // package-merge の 16 段で長さ制限を直接解く。深い木を単に 16 に丸めると
            // Kraft の等式を壊し、複数 symbol に同じ bit 列を割り当ててしまう。
            var nodes = symbols.map { Package(weight: frequencies[$0], symbol: $0) }
            let leaves = Array(nodes.indices)
            var list = leaves
            for _ in 1..<16 {
                var packages: [Int] = []
                for index in stride(from: 0, to: list.count - 1, by: 2) {
                    let left = list[index]
                    let right = list[index + 1]
                    packages.append(nodes.count)
                    nodes.append(Package(weight: nodes[left].weight + nodes[right].weight,
                                         symbol: -1, left: left, right: right))
                }
                // 隣り合う最小二個を束ねた列も重み順なので、再 sort せず線形に merge できる。
                var merged: [Int] = []
                var leaf = 0
                var package = 0
                while leaf < leaves.count || package < packages.count {
                    if leaf < leaves.count,
                       package == packages.count || nodes[leaves[leaf]].weight <= nodes[packages[package]].weight {
                        merged.append(leaves[leaf])
                        leaf += 1
                    } else {
                        merged.append(packages[package])
                        package += 1
                    }
                }
                list = merged
            }
            // 最上段の 2n-2 個を展開し、各 leaf が現れた回数を符号長にする。
            var pending = Array(list.prefix(2 * symbols.count - 2))
            var lengths = [Int](repeating: 0, count: frequencies.count)
            while let index = pending.popLast() {
                let node = nodes[index]
                if node.symbol >= 0 {
                    lengths[node.symbol] += 1
                } else {
                    pending.append(node.left)
                    pending.append(node.right)
                }
            }
            return lengths
        }
    }
}
