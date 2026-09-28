import Foundation
@_spi(SevenZipEditLayout) internal import KaitoKit

final class SevenZipFolderConversion {
    let folderIndex: Int
    let conversion: SevenZipConversion
    let replacement: SevenZipEditPlan.Replacement
    let plaintextLength: UInt64
    private let aes: SevenZipAESEncryptor?
    private(set) var plaintextCRC: UInt32?
    var scratch: SplicedScratchFile?

    init(index: Int, conversion: SevenZipConversion, model: SevenZipEditModel, aes: SevenZipAESEncryptor?) throws {
        folderIndex = index; self.conversion = conversion; self.aes = aes
        let original = model.folders[index]
        var folder = original
        let pack = model.packs[original.packIndices.lowerBound]
        if conversion == .attach {
            plaintextLength = pack.length
            guard let aes else { throw WriterError.invalidState }
            folder.coders.insert(.init(methodID: [6, 0xF1, 7, 1], properties: Array(aes.properties)), at: 0)
            folder.bindPairs = original.bindPairs.map { .init(input: $0.input + 1, output: $0.output + 1) }
            folder.bindPairs.append(.init(input: original.packedInputs[0] + 1, output: 0))
            folder.packedInputs = [0]
            folder.unpackSizes.insert(pack.length, at: 0)
            folder.finalOutput += 1
        } else {
            guard let index = folder.coders.firstIndex(where: \.isAES) else { throw WriterError.invalidState }
            let input = folder.coders[..<index].reduce(0) { $0 + $1.inputCount }
            let output = folder.coders[..<index].reduce(0) { $0 + $1.outputCount }
            plaintextLength = folder.unpackSizes[output]
            if conversion == .change {
                guard let aes else { throw WriterError.invalidState }
                folder.coders[index].properties = Array(aes.properties)
            } else if folder.coders.count == 1 {
                folder.coders = [.init(methodID: [0])]
            } else {
                guard let consumer = folder.bindPairs.first(where: { $0.output == output }) else { throw WriterError.invalidState }
                folder.coders.remove(at: index)
                folder.bindPairs = folder.bindPairs.filter { $0.output != output }.map {
                    .init(input: $0.input - ($0.input > input ? 1 : 0), output: $0.output - ($0.output > output ? 1 : 0))
                }
                folder.packedInputs = [consumer.input - (consumer.input > input ? 1 : 0)]
                folder.unpackSizes.remove(at: output)
                folder.finalOutput -= folder.finalOutput > output ? 1 : 0
            }
        }
        let length = aes == nil ? plaintextLength : try checkedAdd(plaintextLength, 15) / 16 * 16
        replacement = .init(folder: folder, packs: [.init(range: 0..<length)],
                            streams: Array(model.substreams[original.substreamIndices]))
    }

    func write(reader: ArchiveReader, source: ArchiveFileSource, model: SevenZipEditModel,
               write: (Data) throws -> Void) throws {
        do {
            try Task.checkCancellation()
            let stream = conversion == .attach ? nil : try reader.sevenZipDecryptedPackedStream(folder: folderIndex, packedInput: 0)
            let originalRange = model.packs[model.folders[folderIndex].packIndices.lowerBound].range
            var position: UInt64 = 0, crc: UInt32 = 0
            while position < plaintextLength {
                try Task.checkCancellation()
                let count = Int(min(4 * 1024 * 1024, plaintextLength - position))
                let bytes: Data
                if let stream { bytes = try stream.readSome(upTo: count) }
                else { bytes = try source.bytes(at: originalRange.lowerBound + position, count: count) }
                guard !bytes.isEmpty else { throw KaitoError.truncated }
                crc = updateCRC(crc, bytes)
                position += UInt64(bytes.count)
                try write(aes.map { try $0.encrypt(bytes) } ?? bytes)
            }
            if let stream, !(try stream.readSome(upTo: 1)).isEmpty { throw KaitoError.malformed("7z AES length") }
            if let aes { try write(aes.finish()) }
            plaintextCRC = crc
        } catch {
            if error is CancellationError { throw error }
            if let kaito = error as? KaitoError, kaito == .wrongPassword || kaito == .passwordRequired { throw error }
            let file = model.files.firstIndex { file in
                file.substreamIndex.map { model.substreams[$0].folderIndex == folderIndex } ?? false
            } ?? 0
            throw UpdaterError.reencryptionFailed(index: file, name: reader.entries.indices.contains(file) ? reader.entries[file].name : "",
                                                  reason: "7z の圧縮済み stream の暗号化変換に失敗しました")
        }
    }

    static func verifyPassword(reader: ArchiveReader, files: [Int]) throws {
        guard reader.password != nil else { throw KaitoError.passwordRequired }
        do {
            var remaining = 64 * 1024
            for index in files {
                try Task.checkCancellation()
                let stream = try reader.stream(reader.entries[index])
                repeat {
                    let bytes = try stream.readSome(upTo: min(remaining, 64 * 1024))
                    remaining -= bytes.count
                    if bytes.isEmpty { break }
                } while remaining > 0
                if remaining == 0 { break }
            }
        } catch KaitoError.malformed { throw KaitoError.wrongPassword }
        catch KaitoError.truncated { throw KaitoError.wrongPassword }
    }
}
