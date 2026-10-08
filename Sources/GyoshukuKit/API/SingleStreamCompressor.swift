import Foundation

/// 通常ファイル一つを包む stream 形式。拡張子は呼出側が決める。
public enum SingleStreamFormat: Sendable, CaseIterable {
    /// 時刻0、OS=Unix、ファイル名なし。1 MiB の deflate block を並列化する。
    case gzip
    /// bzip2Level と入力サイズだけで片幅を決め、blockを並列圧縮して単一streamへ繋ぐ。
    case bzip2
    /// 単一 XZ stream。lzmaLevel の nil は Apple、指定時は自前 LZMA2。
    case xz
    /// content checksum 付き独立 frame を max(4 MiB, level の window) で並列化する。zstdLevel は1...19、既定3。
    case zstd
    /// 未知サイズ header と EOS を持つ逐次 LZMA_Alone。lzmaLevel の nil は6。
    case lzma
    /// lzip version 1。最大 max(16 MiB, 3 × 辞書) の独立 member を並列化する。nil は level 6。
    case lzip
    /// content checksum 付き単一 frame。4 MiB の独立 block を並列化する。レベルは一つ。
    case lz4
    /// Apple の固定 level 2 による逐次単一 stream。
    case brotli
    /// UNIX compress の block mode LZW、maxbits 16。逐次単一 stream。
    case compress

    var archiveFormat: ArchiveFormat {
        switch self {
        case .gzip: .tarGzip
        case .bzip2: .tarBzip2
        case .xz: .tarXZ
        case .zstd: .tarZstd
        case .lzma: .tarLZMA
        case .lzip: .tarLzip
        case .lz4: .tarLZ4
        case .brotli: .tarBrotli
        case .compress: .tarCompress
        }
    }
}

/// 単独 stream の新規作成。複数の source や編集は扱わず、必要なら ArchiveWriter の tar 圧縮を使う。
public enum SingleStreamCompressor {
    /// 通常ファイルだけを受け、directory / symlink は WriterError.unsupportedFileType で拒否する。
    /// 出力先の隣に一時 file を作り、成功時に排他的 rename で公開する。既存出力は上書きしない。
    /// 失敗・Task の取消し時は自分の一時 file を削除する。progress は読取 byte 数を報告する。
    public static func compress(file source: URL, to output: URL, format: SingleStreamFormat,
                                options: WriterOptions = .init(), progress: Progress? = nil) throws {
        try SingleStreamWriter.compress(file: source, to: output, format: format, options: options, progress: progress)
    }
}
