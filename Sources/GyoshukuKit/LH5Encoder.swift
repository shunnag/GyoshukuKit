import Foundation

// KaitoKit の LZSStaticHuffmanDecoder が読む -lh5- 文法の逆変換。
// dictionary は block を跨いで維持し、Huffman 木だけを command 数ごとに作り直す。
enum LH5Encoder {
    static let windowSize = 8192
    static let blockCommands = 32_768

    struct Command {
        let symbol: Int
        let position: Int
        var positionSymbol: Int { position == 0 ? 0 : Int.bitWidth - position.leadingZeroBitCount }
    }

    static func encode(_ input: Data) throws -> Data {
        try Task.checkCancellation()
        guard !input.isEmpty else { return Data() }
        return try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var heads = [Int](repeating: -1, count: 65_536)
            var previous = [Int](repeating: -1, count: windowSize)
            var commands: [Command] = []
            commands.reserveCapacity(blockCommands)
            var bits = Bits()
            var offset = 0
            var checkpoint = 0
            while offset < bytes.count {
                if offset >= checkpoint {
                    try Task.checkCancellation()
                    checkpoint = offset + 4096
                }
                let maximum = min(256, bytes.count - offset)
                var length = 2
                var distance = 0
                if maximum >= 3 {
                    var candidate = heads[hash(bytes, offset)]
                    let oldest = max(0, offset - windowSize)
                    var probes = 0
                    // chain は絶対位置の降順。古い位置で必ず止め、ring の再利用を循環にしない。
                    // 衝突の多い入力でも 256 候補で打ち切るため、探索量は入力長に比例する。
                    while candidate >= oldest, probes < 256 {
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
                        candidate = previous[candidate & (windowSize - 1)]
                        probes += 1
                    }
                }
                let consumed: Int
                if distance > 0 {
                    commands.append(Command(symbol: length + 253, position: distance - 1))
                    consumed = length
                } else {
                    commands.append(Command(symbol: Int(bytes[offset]), position: 0))
                    consumed = 1
                }
                // match で飛ばす byte も登録し、次の探索から dictionary 全体を参照できるようにする。
                for index in offset..<(offset + consumed) where index + 2 < bytes.count {
                    let bucket = hash(bytes, index)
                    previous[index & (windowSize - 1)] = heads[bucket]
                    heads[bucket] = index
                }
                offset += consumed
                if commands.count == blockCommands {
                    try writeBlock(commands, to: &bits)
                    commands.removeAll(keepingCapacity: true)
                }
            }
            if !commands.isEmpty { try writeBlock(commands, to: &bits) }
            try Task.checkCancellation()
            return bits.finish()
        }
    }

    private static func hash(_ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int {
        let value = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
        return Int((value &* 0x1E35_A7BD) >> 16)
    }

    static func writeBlock(_ commands: [Command], to bits: inout Bits) throws {
        try Task.checkCancellation()
        var commandFrequencies = [Int](repeating: 0, count: 510)
        var positionFrequencies = [Int](repeating: 0, count: 14)
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
        // LH5 は NP=14 でも count 欄は 4 bit。LH6/7 の 5 bit を流用すると以降がずれる。
        writeLengths(positionTree, countBits: 4, special: false, to: &bits)
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
        private var bytes: [UInt8] = []
        private var pending: UInt64 = 0
        private var available = 0

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
            return Data(bytes)
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
