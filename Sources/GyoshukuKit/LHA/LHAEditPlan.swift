import Foundation

struct LHAEditPlan {
    struct Changed {
        let index: Int
        let outputOffset: UInt64
        let header: Data
    }
    struct Boundary {
        let source: UInt64
        let output: UInt64
        let length: UInt64
    }
    let prefix: [SplicedSegment]
    let membersEnd: UInt64
    let memberOffsets: [UInt64?]
    let changed: [Changed]
    let boundaries: [Boundary]
    let boundaryBytes: UInt64
    let terminal: Data
    let isChanged: Bool

    static func make(layout: LHALayout, removed: Set<Int>, renamed: [Int: Data], additionLength: UInt64 = 0) throws -> LHAEditPlan {
        var segments: [SplicedSegment] = []
        var offsets: [UInt64?] = []
        var changed: [Changed] = []
        var boundaries: [Boundary] = []
        var position: UInt64 = 0, boundaryBytes: UInt64 = 0
        let existingChanged = !removed.isEmpty || !renamed.isEmpty
        func append(_ segment: SplicedSegment, boundary: Boundary? = nil) throws {
            guard segment.length > 0 else { return }
            position = try checkedAdd(position, segment.length)
            if case .source(let next) = segment, let last = segments.last, case .source(let previous) = last,
               previous.upperBound == next.lowerBound {
                segments[segments.count - 1] = .source(previous.lowerBound..<next.upperBound)
            } else {
                segments.append(segment)
                // 追加だけでは元の prefix に継ぎ目がなく、既存 byte を読み戻さない（design.md §4「LHA の更新」）。
                if existingChanged, let boundary {
                    boundaries.append(boundary)
                    boundaryBytes = try checkedAdd(boundaryBytes, boundary.length)
                }
            }
        }
        for index in 0..<layout.count {
            if index & 1023 == 0 { try Task.checkCancellation() }
            if removed.contains(index) { offsets.append(nil); continue }
            let member = try layout.member(index)
            offsets.append(position)
            if let header = renamed[index] {
                changed.append(Changed(index: index, outputOffset: position, header: header))
                try append(.literal(length: UInt64(header.count), bytes: { header }))
                try append(.source(member.dataRange))
            } else {
                try append(.source(member.headerRange.lowerBound..<member.dataRange.upperBound),
                           boundary: Boundary(source: member.headerRange.lowerBound, output: position,
                                              length: member.headerRange.byteLength))
            }
        }
        let isChanged = existingChanged || additionLength > 0
        return LHAEditPlan(prefix: segments, membersEnd: position, memberOffsets: offsets, changed: changed,
                           boundaries: boundaries, boundaryBytes: boundaryBytes,
                           terminal: isChanged ? Data([0]) : Data(), isChanged: isChanged)
    }
}
