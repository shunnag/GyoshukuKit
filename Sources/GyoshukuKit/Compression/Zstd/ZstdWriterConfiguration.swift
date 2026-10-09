import Foundation

/// frame の片と作業メモリを解決する。辞書は縮小せず、予算内の並列数に抑える。
struct ZstdWriterConfiguration: Sendable {
    let properties: ZstdEncoderProperties
    let chunkSize: Int
    let threads: Int
    let memoryPerThread: UInt64
    let memoryBudget: UInt64
    let streaming: Bool

    init(options: WriterOptions, streaming: Bool = false,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        self.streaming = streaming
        guard (1...19).contains(options.zstdLevel) else { throw WriterError.invalidOption("zstdLevel") }
        properties = try .preset(options.zstdLevel)
        chunkSize = max(4 << 20, properties.windowSize)
        // ZIP は単一 frame を逐次出力する。独立 frame は入力と raw fallback の出力を予約する。
        let buffered = streaming ? ZstdFrameEncoder.blockSize : chunkSize
        let blocks = buffered / ZstdFrameEncoder.blockSize + 1
        memoryPerThread = UInt64(properties.estimatedMemoryBytes + 2 * buffered + 3 * blocks + 1024)
        memoryBudget = min(options.memoryLimit ?? physicalMemory / 2, physicalMemory / 2)
        guard memoryPerThread <= memoryBudget else { throw WriterError.invalidOption("memoryLimit") }
        threads = streaming ? 1 : min(options.resolvedCompressionThreads, Int(min(UInt64(WriterOptions.compressionThreadsRange.upperBound), memoryBudget / memoryPerThread)))
    }

    // 独立frameのbufferが収まらなければ、検証済みの単一frameへ戻す。
    static func zip(options: WriterOptions, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> Self {
        let single = try Self(options: options, streaming: true, physicalMemory: physicalMemory)
        if options.prefersSpeed, let parallel = try? Self(options: options, physicalMemory: physicalMemory) { return parallel }
        return single
    }
}
