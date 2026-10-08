@testable import GyoshukuKit

extension GyoshukuKit.ArchiveFormat {
    /// test が書く書庫の拡張子。LHA は製品（LHAUpdater の作業ファイル）と fixture（`*.lzh.b64`）に合わせて "lzh"。
    /// 拡張子と形式の対応そのものの試験（ArchiveFormatPathTests）は、この表を使わず自分の表を持つ。
    var testFileExtension: String {
        switch self {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarZstd: "tar.zst"
        case .tarXZ: "tar.xz"
        case .tarLZMA: "tar.lzma"
        case .tarLzip: "tar.lz"
        case .tarLZ4: "tar.lz4"
        case .tarBrotli: "tar.br"
        case .tarCompress: "tar.Z"
        case .sevenZip: "7z"
        case .lha: "lzh"
        }
    }
}
