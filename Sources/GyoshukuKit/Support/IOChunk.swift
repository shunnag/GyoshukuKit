// ディスクと pipeline の間で一度に運ぶ byte 数。読取 loop、出力 buffer、圧縮前の分割で共有する。
enum IOChunk {
    static let size = 256 * 1024
}
