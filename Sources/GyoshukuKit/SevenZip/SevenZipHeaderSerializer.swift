import Foundation
internal import KaitoKit

enum SevenZipHeaderSerializer {
    typealias Model = SevenZipEditModel
    static func header(_ model: Model) throws -> Data {
        if model.files.isEmpty { return Data([1, 5, 0, 0, 0]) }
        var result = Data([1])
        if !model.packs.isEmpty || !model.folders.isEmpty {
            result.append(4)
            streams(model, to: &result)
        }
        result.append(5)
        result.append(SevenZipRecords.number(UInt64(model.files.count)))
        if !model.files.isEmpty { try files(model, to: &result) }
        result.append(contentsOf: [0, 0])
        guard result.count <= ReadLimits().maxMetadataSize else {
            throw RewriterError.unrepresentable(entry: "", reason: "7z の header が 16 MiB を越えます")
        }
        return result
    }

    static func encodedHeader(folder: Model.Folder, packOffset: UInt64, length: UInt64) -> Data {
        var model = Model()
        model.packPosition = packOffset
        model.packs = [.init(range: 0..<length)]
        model.folders = [folder]
        var result = Data([0x17])
        streams(model, substreams: false, to: &result)
        return result
    }

    static func bits(_ values: [Bool]) -> Data {
        var data = Data(count: (values.count + 7) / 8)
        for (index, value) in values.enumerated() where value { data[index / 8] |= 0x80 >> (index % 8) }
        return data
    }
    static func digests(_ values: [UInt32?], to result: inout Data) {
        guard values.contains(where: { $0 != nil }) else { return }
        result.append(0x0A)
        defined(values.map { $0 != nil }, to: &result)
        for case let value? in values { result.le(value) }
    }
    static func defined(_ values: [Bool], to result: inout Data) {
        if values.allSatisfy({ $0 }) { result.append(1) }
        else { result.append(0); result.append(bits(values)) }
    }
    static func streams(_ model: Model, substreams: Bool = true, to result: inout Data) {
        if !model.packs.isEmpty {
            result.append(6)
            result.append(SevenZipRecords.number(model.packPosition))
            result.append(SevenZipRecords.number(UInt64(model.packs.count)))
            result.append(9)
            for pack in model.packs { result.append(SevenZipRecords.number(pack.length)) }
            digests(model.packs.map(\.crc32), to: &result)
            result.append(0)
        }
        if !model.folders.isEmpty {
            result.append(contentsOf: [7, 0x0B])
            result.append(SevenZipRecords.number(UInt64(model.folders.count)))
            result.append(0)
            for folder in model.folders {
                result.append(SevenZipRecords.number(UInt64(folder.coders.count)))
                for coder in folder.coders {
                    result.append(UInt8(coder.methodID.count) | (coder.isComplex ? 0x10 : 0) | (coder.properties != nil ? 0x20 : 0))
                    result.append(contentsOf: coder.methodID)
                    if coder.isComplex {
                        result.append(SevenZipRecords.number(UInt64(coder.inputCount)))
                        result.append(SevenZipRecords.number(UInt64(coder.outputCount)))
                    }
                    if let properties = coder.properties {
                        result.append(SevenZipRecords.number(UInt64(properties.count)))
                        result.append(contentsOf: properties)
                    }
                }
                for bind in folder.bindPairs {
                    result.append(SevenZipRecords.number(UInt64(bind.input)))
                    result.append(SevenZipRecords.number(UInt64(bind.output)))
                }
                if folder.packedInputs.count > 1 {
                    for index in folder.packedInputs { result.append(SevenZipRecords.number(UInt64(index))) }
                }
            }
            result.append(0x0C)
            for folder in model.folders {
                for size in folder.unpackSizes { result.append(SevenZipRecords.number(size)) }
            }
            digests(model.folders.map(\.crc32), to: &result)
            result.append(0)
            if substreams {
                result.append(8)
                if model.folders.contains(where: { $0.substreamIndices.count != 1 }) {
                    result.append(0x0D)
                    for folder in model.folders { result.append(SevenZipRecords.number(UInt64(folder.substreamIndices.count))) }
                }
                if model.folders.contains(where: { $0.substreamIndices.count > 1 }) {
                    result.append(9)
                    for folder in model.folders {
                        for index in folder.substreamIndices.dropLast() {
                            result.append(SevenZipRecords.number(model.substreams[index].size))
                        }
                    }
                }
                var crcs: [UInt32?] = []
                for folder in model.folders where folder.substreamIndices.count != 1 || folder.crc32 == nil {
                    for index in folder.substreamIndices { crcs.append(model.substreams[index].crc32) }
                }
                digests(crcs, to: &result)
                result.append(0)
            }
        }
        result.append(0)
    }

    static func propertyOrder(original: [UInt8], needed: Set<UInt8>) -> [UInt8] {
        let canonical: [UInt8] = [0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x18, 0x15]
        var order = original.filter { $0 != 0x19 && needed.contains($0) }
        for id in canonical where needed.contains(id) && !order.contains(id) {
            let rank = canonical.firstIndex(of: id)!
            let insertion = order.firstIndex { (canonical.firstIndex(of: $0) ?? 0) > rank } ?? order.endIndex
            order.insert(id, at: insertion)
        }
        return order
    }

    private static func files(_ model: Model, to result: inout Data) throws {
        let files = model.files
        let empty = files.filter { !$0.hasStream }
        var values: [UInt8: (Data, Int, Int)] = [:]
        if !empty.isEmpty {
            values[0x0E] = (bits(files.map { !$0.hasStream }), 1, 0)
            for (id, flags): (UInt8, [Bool]) in [(0x0F, empty.map(\.isEmptyFile)), (0x10, empty.map(\.isAnti))] {
                if model.filePropertyOrder.contains(id) || flags.contains(true) { values[id] = (bits(flags), 1, 0) }
            }
        }
        var names = Data([0])
        for file in files {
            try Task.checkCancellation()
            guard UInt64(names.count) + UInt64(file.rawName.count) + 2 <= ReadLimits().maxMetadataSize else {
                throw RewriterError.unrepresentable(entry: "", reason: "7z の header が 16 MiB を越えます")
            }
            names.append(contentsOf: file.rawName); names.append(contentsOf: [0, 0])
        }
        values[0x11] = (names, 16, 1)
        let times: [(UInt8, KeyPath<Model.File, UInt64?>)] = [
            (0x12, \.creationTime), (0x13, \.accessTime), (0x14, \.modificationTime), (0x18, \.startPosition)
        ]
        for (id, key) in times {
            let present = files.map { $0[keyPath: key] != nil }
            if present.contains(true) {
                var value = Data()
                defined(present, to: &value); value.append(0)
                let prelude = value.count
                for file in files { if let time = file[keyPath: key] { value.le(time) } }
                values[id] = (value, 8, prelude)
            }
        }
        let present = files.map { $0.attributes != nil }
        if present.contains(true) {
            var value = Data()
            defined(present, to: &value); value.append(0)
            let prelude = value.count
            for file in files { if let attributes = file.attributes { value.le(attributes) } }
            values[0x15] = (value, 4, prelude)
        }
        for id in propertyOrder(original: model.filePropertyOrder, needed: Set(values.keys)) {
            let (value, alignment, prelude) = values[id]!
            let size = SevenZipRecords.number(UInt64(value.count))
            if model.filePropertyOrder.contains(0x19), alignment > 1 {
                // 7-Zip の SkipToAligned。property の値の先頭を基準にする。
                let offset = (result.count + 1 + size.count + prelude) % alignment
                if offset != 0 {
                    var skip = alignment - offset
                    if skip < 2 { skip += alignment }
                    result.append(contentsOf: [0x19, UInt8(skip - 2)])
                    result.append(Data(count: skip - 2))
                }
            }
            result.append(id); result.append(size); result.append(value)
        }
    }
}
