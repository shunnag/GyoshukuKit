import Foundation

// 拡張子だけを使う決定的な既定値。内容の sampling・並列数・CPU に依存しない。
enum CompressedContent {
    static let extensions: Set<String> = [
        "zip", "gz", "bz2", "xz", "7z", "rar", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp3", "mp4", "mov", "pdf",
        "avif", "jxl", "heif", "jp2", "cbz", "cbr", "cb7", "epub", "zst", "lz4", "lzma", "tgz", "txz",
        "m4a", "aac", "flac", "ogg", "opus", "webm", "mkv", "m4v", "docx", "xlsx", "pptx"
    ]

    static func contains(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }
}

extension WriterOptions {
    var usesDefaultLZMAHeuristic: Bool { useCompressionHeuristic && lzmaLevel == nil && !lzmaExtreme }

    func storesSevenZipContent(name: String, mode: UInt16, size: UInt64) -> Bool {
        usesDefaultLZMAHeuristic && !hasExplicitSevenZipMethod && sevenZipMethod == .lzma2
            && sevenZipFilter == .none && mode.isRegularFileMode && size > 0 && CompressedContent.contains(name)
    }
}
