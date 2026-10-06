import Foundation

/// 作成できる書庫形式。ZIP / ZIP64 の追加・削除・改名は ArchiveUpdater が扱う。
public enum ArchiveFormat: Sendable {
    case zip
    /// 非圧縮の restricted pax tar。
    case tar
    /// restricted pax tar 全体を gzip で包む。
    /// gzip header は時刻 0、OS=Unix、ファイル名・comment なし。
    /// member 境界で最大 1 MiB に区切り、大きい member は header 群と本文を分ける。終端は独立させる。
    case tarGzip
    /// restricted pax tar を member 境界で最大 5 × level × 100,000 byte の bzip2 stream に区切る。
    /// 大きい member は header 群と本文を分け、tar 終端は独立した stream にする。
    case tarBzip2
    /// restricted pax tar の 4 MiB 以下の member を最大 4 MiB の LZMA2 block に詰め、単一 XZ stream で包む。
    /// 4 MiB を越える member は header 群と本文を分け、本文と大きな header 群は最大 16 MiB の片に区切る。
    /// tar 終端は独立した block にする。
    case tarXZ
    /// restricted pax tar を未知サイズの LZMA_Alone（13 byte header + EOS）で包む。
    /// 自前 LZMA1 の逐次単一 stream。lzmaLevel は0...9、nil は6。extreme も使える。
    case tarLZMA
    /// restricted pax tar を lzip version 1 の独立 member に区切り、メモリ上限内で並列化する。
    /// member 境界を優先し、上限を越える header 群・本文は max(16 MiB, 3 × 辞書) で分割する。
    /// 終端は独立 member。LZMA1 + EOS、CRC32・入力長・member 長を持ち、lzmaLevel の nil は6。
    case tarLzip
    /// restricted pax tar を content checksum 付きの単一 LZ4 frame で包む。
    /// 4 MiB の独立 block を並列化する。圧縮レベルは一つ。
    case tarLZ4
    /// restricted pax tar を Apple Brotli の固定 level 2 で包む。逐次単一 stream、レベル指定なし。
    case tarBrotli
    /// restricted pax tar を UNIX compress の block mode LZW（maxbits 16）で包む。逐次単一 stream。
    case tarCompress
    /// ファイルごとに Apple LZMA2 を使う non-solid 7z。AES-256 と header 暗号化を選択できる。
    case sevenZip
    /// CP932 名の level-2 LHA。既定は -lh5-。-lh6- / -lh7- / -lh0- を選択でき、縮まなければ -lh0-。
    /// 1 MiB 以下は member ごと、それ以上は 1 MiB と 8 KiB の履歴で並列に符号化する。出力は並列数によらず同一。
    case lha

    var isTar: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ, .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress: true
        default: false
        }
    }
}
