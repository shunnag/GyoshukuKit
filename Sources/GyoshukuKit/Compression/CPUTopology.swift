import Foundation
private import Darwin

/// perflevel は番号順（0 が最高性能）。名称や特定の製品のコア構成には依存しない。
struct CPUTopology: Sendable, Equatable {
    struct PerformanceLevel: Sendable, Equatable {
        let logicalCPUs: Int
        let physicalCPUs: Int
    }

    let activeLogicalCPUs: Int
    let performanceLevels: [PerformanceLevel]

    init(activeLogicalCPUs: Int, performanceLevels: [PerformanceLevel] = []) {
        let active = max(1, activeLogicalCPUs)
        self.activeLogicalCPUs = active
        self.performanceLevels = performanceLevels.isEmpty || performanceLevels.contains { $0.logicalCPUs <= 0 || $0.physicalCPUs <= 0 }
            ? [.init(logicalCPUs: active, physicalCPUs: active)] : performanceLevels
    }

    static var current: Self {
        read(integer: systemInteger, fallbackActiveCPUs: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// sysctl の欠落も純粋な入力で検証できる。途中の level が欠けた場合は単一 level に戻す。
    static func read(integer: (String) -> Int?, fallbackActiveCPUs: Int) -> Self {
        let active = integer("hw.activecpu").flatMap { $0 > 0 ? $0 : nil } ?? fallbackActiveCPUs
        guard let count = integer("hw.nperflevels"), count > 0 else { return .init(activeLogicalCPUs: active) }
        var levels: [PerformanceLevel] = []
        for index in 0..<count {
            guard let logical = integer("hw.perflevel\(index).logicalcpu"), logical > 0,
                  let physical = integer("hw.perflevel\(index).physicalcpu"), physical > 0 else {
                return .init(activeLogicalCPUs: active)
            }
            levels.append(.init(logicalCPUs: logical, physicalCPUs: physical))
        }
        return .init(activeLogicalCPUs: active, performanceLevels: levels)
    }

    static func systemInteger(_ name: String) -> Int? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            sysctlbyname(name, bytes.baseAddress, &size, nil, 0)
        }
        guard status == 0, size == 4 || size == 8, value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }
}

/// 外側で待つ worker と、内側で実行する worker のための余地を分ける。
enum CompressionWorkerPool {
    // kernel pool の安全上限はprocess内で共有し、項目ごとにtopologyを読み直さない。
    static let maximumEntryThreads: Int = {
        let active = CPUTopology.systemInteger("hw.activecpu").flatMap { $0 > 0 ? $0 : nil }
            ?? ProcessInfo.processInfo.activeProcessorCount
        return entryThreadLimit(activeCPUs: active,
                                constrainedThreads: CPUTopology.systemInteger("kern.wq_max_constrained_threads"))
    }()

    static func entryThreadLimit(activeCPUs: Int, constrainedThreads: Int?) -> Int {
        // xnu の constrained pool は既定 max(64, 5 × ncpu)。読める場合は実際の上限を優先する。
        let fallback = max(64, 5 * max(1, activeCPUs))
        let pool = constrainedThreads.flatMap { $0 > 0 ? $0 : nil } ?? fallback
        // ZIP 項目 / 7z folder / LHA member の外側だけが片の完了を待つ。
        // OrderedChunkPipeline → XZ / LZMA2 / BZip2 / LHA の片 worker は葉で、再度待たない。
        // 外側を pool / 4 に抑え、先読みと呼出側を含む待機、および葉の実行に残りを確保する。
        // 内側が逐次の 7z は inline 実行、LHA は項目並列の再帰を無効化する。
        return max(1, pool / 4)
    }
}
