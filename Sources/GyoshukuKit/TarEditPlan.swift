import Foundation
internal import KaitoKit

struct TarEditPlan {
    struct ChangedUnit {
        let index: Int
        let outputOffset: UInt64
        let headerLength: UInt64
        let name: Data?
        let link: Data?
        let materializedTarget: Int?
    }
    struct Boundary { let source: UInt64; let output: UInt64 }
    let prefix: [SplicedSegment]
    let membersEnd: UInt64
    let unitOffsets: [UInt64?]
    let changed: [ChangedUnit]
    let boundaries: [Boundary]
    let terminal: Data
    let isChanged: Bool

    static func make(layout: TarLayout, source: any ByteSource, names: [String], rawNames: [Data],
                     hardLinkTargets: [Int: Int], dataTargets: [Int: Int], removed: Set<Int>,
                     renamed: [Int: String], additionLength: UInt64 = 0) throws -> TarEditPlan {
        var segments: [SplicedSegment] = []
        var offsets: [UInt64?] = []
        var changed: [ChangedUnit] = []
        var position: UInt64 = 0
        var holders: [Int: Int] = [:]
        for target in dataTargets.values where !removed.contains(target) { holders[target] = target }
        func finalBytes(_ index: Int) -> Data {
            if let name = renamed[index], name != names[index] { return Data(name.utf8) }
            return rawNames[index]
        }
        func append(_ segment: SplicedSegment) throws {
            guard segment.length > 0 else { return }
            position = try checkedAdd(position, segment.length)
            if case .source(let next) = segment, let last = segments.last, case .source(let previous) = last,
               previous.upperBound == next.lowerBound {
                segments[segments.count - 1] = .source(previous.lowerBound..<next.upperBound)
            } else { segments.append(segment) }
        }
        var index = 0
        for unit in layout.units {
            if offsets.count & 1023 == 0 { try Task.checkCancellation() }
            if unit.isGlobal { offsets.append(position); try append(.source(unit.range)); continue }
            defer { index += 1 }
            if removed.contains(index) { offsets.append(nil); continue }
            offsets.append(position)
            let newName = renamed[index].flatMap { $0 != names[index] ? Data($0.utf8) : nil }
            var newLink: Data?
            var materialized: Int?
            if let direct = hardLinkTargets[index], let target = dataTargets[index] {
                if !removed.contains(direct) {
                    if let name = renamed[direct], name != names[direct] { newLink = Data(name.utf8) }
                } else if let holder = holders[target] { newLink = finalBytes(holder) }
                else { materialized = target; holders[target] = index }
            }
            guard newName != nil || newLink != nil || materialized != nil else {
                try append(.source(unit.range)); continue
            }
            let materializedSize = materialized.map { layout.member($0).storedSize }
            let generate = {
                try TarHeaderRewrite.rewrite(source: source, unit: unit, name: newName, link: newLink,
                                             materializedSize: materializedSize)
            }
            let length = UInt64(try generate().count)
            changed.append(ChangedUnit(index: index, outputOffset: position, headerLength: length,
                                       name: newName, link: newLink, materializedTarget: materialized))
            try append(.literal(length: length, bytes: generate))
            if let target = materialized {
                let data = layout.member(target)
                try append(.source(data.dataStart..<(data.dataStart + data.storedSize)))
                let padding = TarRecords.padding(data.storedSize)
                try append(.literal(length: UInt64(padding), bytes: { Data(count: padding) }))
            } else { try append(.source(unit.dataStart..<unit.paddedEnd)) }
        }
        let isChanged = !removed.isEmpty || !changed.isEmpty || additionLength != 0
        let unitStarts = Set(layout.units.map(\.groupStart))
        var boundaries: [Boundary] = []
        var cursor: UInt64 = 0
        if isChanged {
            for segment in segments {
                if case .source(let range) = segment, unitStarts.contains(range.lowerBound) {
                    boundaries.append(.init(source: range.lowerBound, output: cursor))
                }
                cursor += segment.length
            }
        }
        let end = try checkedAdd(position, additionLength)
        let afterEOF = try checkedAdd(end, 1024)
        let fill = (10240 - afterEOF % 10240) % 10240
        return TarEditPlan(prefix: segments, membersEnd: position, unitOffsets: offsets, changed: changed,
                           boundaries: boundaries, terminal: isChanged ? Data(count: Int(1024 + fill)) : Data(),
                           isChanged: isChanged)
    }
}
