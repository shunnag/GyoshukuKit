import Foundation

/// 既知の入力を約16片へ分ける。環境値は使わず、未知・空入力は従来幅を保つ。
enum CompressionPieceSize {
    static func resolve(standard: Int, floor: Int = 2 << 20, size: UInt64?, prefersSpeed: Bool) -> Int {
        guard prefersSpeed, let size, size > 0 else { return standard }
        // ceil(S / (16 MiB)) × 1 MiB。先に従来幅で抑え、UInt64.maxでも溢れさせない。
        let units = (size - 1) / UInt64(16 << 20) + 1
        let rounded = Int(min(UInt64(standard), units * UInt64(1 << 20)))
        return max(floor, rounded)
    }
}
