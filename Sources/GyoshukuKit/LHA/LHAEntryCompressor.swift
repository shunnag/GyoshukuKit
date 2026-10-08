import Foundation

struct LHAEntryCompressionJob: Sendable {
    let name: String
    let mode: UInt16
    let date: Date
    let data: Data
    let output: OrderedEntrySpool
    let directory: URL
    let threads: Int
    let encoder: @Sendable (Data) throws -> Data
    // GCDはTaskLocalを継承しない。既存spoolの故障注入・descriptor観測を保つ。
    let scratchReserve = ScratchFile.testingFreeSpaceReserve
    let scratchCreated = ScratchFile.testingCreated
}

struct LHAEncodedMember: Sendable {
    let output: OrderedEntrySpool
    let length: UInt64
    let headerLength: Int
    let dataLength: UInt64
    let method: String
}

/// 中memberも既存の1 MiB区切りと端数bit連結を使い、完成recordだけを呼出側へ渡す。
enum LHAEntryCompressor {
    static func encode(_ job: LHAEntryCompressionJob, method: LHACompressionMethod, level: Int,
                       cancellation: CompressionCancellation) throws -> LHAEncodedMember {
        try ScratchFile.$testingFreeSpaceReserve.withValue(job.scratchReserve) {
            try ScratchFile.$testingCreated.withValue(job.scratchCreated) {
                try encodeOwned(job, method: method, level: level, cancellation: cancellation)
            }
        }
    }

    private static func encodeOwned(_ job: LHAEntryCompressionJob, method: LHACompressionMethod, level: Int,
                                    cancellation: CompressionCancellation) throws -> LHAEncodedMember {
        try cancellation.check()
        if job.data.count <= LHAWriter.compressionChunkSize {
            let entry = try LHARecords.Entry(name: job.name, mode: job.mode, size: UInt64(job.data.count), date: job.date)
            let crc = LHACRC16.update(0, job.data)
            let compressed = job.mode.isDirectoryMode ? Data() : try job.encoder(job.data)
            let shrinks = compressed.count < job.data.count
            let payload = shrinks ? compressed : job.data
            let headerMethod = job.mode.isDirectoryMode ? LHARecords.Method.lhd : shrinks ? method.headerMethod : LHARecords.Method.lh0
            let header = try entry.header(method: headerMethod, packedSize: UInt32(payload.count), crc: crc)
            try cancellation.check()
            try job.output.append(header)
            try job.output.append(payload)
            return LHAEncodedMember(output: job.output, length: job.output.length, headerLength: header.count,
                                    dataLength: UInt64(payload.count), method: headerMethod)
        }
        let scratch = job.output.scratch!
        // outputはunlink済み。作業名は補助spoolのdirectoryとabortのinode照合にだけ使う。
        let workURL = job.directory.appendingPathComponent(".gyoshuku-lha-record-\(UUID().uuidString).spool")
        let writer = LHAWriter(output: scratch.handle, url: workURL, threads: job.threads,
                               method: method, level: level, recordsMembers: true, allowsEntryParallelism: false, encoder: job.encoder)
        var offset = 0
        try writer.add(name: job.name, mode: job.mode, size: UInt64(job.data.count), date: job.date) { count in
            try cancellation.check()
            let end = min(job.data.count, offset + count)
            defer { offset = end }
            return job.data[offset..<end]
        }
        let length = try writer.endMembers()
        try cancellation.check()
        guard writer.memberRecords.count == 1, let record = writer.memberRecords.first else { throw WriterError.invalidState }
        // writerはhandleへ直接書くため、ScratchFile.lengthではなく確定したoffsetを使う。
        return LHAEncodedMember(output: job.output, length: length, headerLength: Int(record.headerLength),
                                dataLength: record.dataLength, method: record.method)
    }
}
