import Foundation

/// frame の片と作業メモリを解決する。辞書は縮小せず、予算内の並列数に抑える。
struct ZstdWriterConfiguration: Sendable {
    let properties: ZstdEncoderProperties
    let chunkSize: Int
    let threads: Int
    let memoryPerThread: UInt64
    let memoryBudget: UInt64

    init(options: WriterOptions, streaming: Bool = false,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        guard (1...19).contains(options.zstdLevel) else { throw WriterError.invalidOption("zstdLevel") }
        properties = try .preset(options.zstdLevel)
        chunkSize = max(4 << 20, properties.windowSize)
        // ZIP は単一 frame を逐次出力する。独立 frame は入力と raw fallback の出力を予約する。
        let buffered = streaming ? ZstdFrameEncoder.blockSize : chunkSize
        let blocks = buffered / ZstdFrameEncoder.blockSize + 1
        memoryPerThread = UInt64(properties.estimatedMemoryBytes + 2 * buffered + 3 * blocks + 1024)
        memoryBudget = min(options.memoryLimit ?? physicalMemory / 2, physicalMemory / 2)
        guard memoryPerThread <= memoryBudget else { throw WriterError.invalidOption("memoryLimit") }
        threads = streaming ? 1 : min(options.resolvedCompressionThreads, Int(min(64, memoryBudget / memoryPerThread)))
    }
}
