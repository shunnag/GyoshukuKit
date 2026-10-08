import Foundation
internal import KaitoKit

/// 全 entry を出力形式で表現できるかを検査する門番。ArchiveRewriter の open / probe と、
/// tar・圧縮 tar・7z・LHA の updater の open が同じ検査順と拒否理由を共有する。
/// 未対応の LHA method・7z coder と、出力名・種別・日時・サイズの表現範囲を検査し、
/// 復号可否（password）、`WriterOptions`、原本の同一性は検査しない。
enum ArchiveRepresentability {
    /// reader を渡すと MacLHA の候補だけ stream の初期長を調べ、envelope を失う entry を拒否する。
    /// 返す names は正規化した出力名（root directory は空文字列）。hard link は参照先 index と、
    /// その内容を持つ通常ファイルの index を返す。
    static func validateRepresentability(entries: [ArchiveEntry], format: ArchiveFormat,
                                         reader: ArchiveReader? = nil) throws
        -> (names: [String], hardLinkTargets: [Int: Int], dataTargets: [Int: Int]) {
        var names: [String] = []
        let carriedPaths = EditPathReservations([])
        var hardLinkTargets: [Int: Int] = [:]
        var dataTargets: [Int: Int] = [:]
        for entry in entries {
            func refuse(_ reason: String) -> RewriterError {
                .unrepresentable(entry: entry.name, reason: reason)
            }
            guard entry.formatSpecific["fork"] != "resource" else {
                throw refuse("resource fork の擬似 entry は書き込めません。reader を appleDoublePolicy .expose で開いてください")
            }
            try validateSource(entry, reader: reader)
            let carried = entry.pathComponents.drop(while: { $0 == "." }).joined(separator: "/")
            let name: String
            // ./ や . の directory は書庫の root。改名された時だけ通常の directory として運ぶ。
            do {
                name = carried.isEmpty && entry.kind == .directory ? ""
                    : try ArchiveWriter.normalizedPath(carried, directory: entry.kind == .directory, format: format)
            } catch { throw refuse("出力名に空の要素・禁止文字・不正な相対パスが含まれています") }
            guard entry.kind != .other else { throw refuse("この entry 種別は書き込めません") }
            if entry.kind == .symlink, format == .lha { throw refuse("LHA は symlink を保存できません") }
            if entry.kind == .hardlink {
                guard let text = entry.formatSpecific["hardLinkTargetIndex"], let index = Int(text),
                      index >= 0, index < entry.index, entries.indices.contains(index),
                      entries[index].kind == .file || dataTargets[index] != nil else {
                    throw refuse("hard link の参照先が欠けているか、先行する通常ファイルではありません")
                }
                hardLinkTargets[entry.index] = index
                dataTargets[entry.index] = dataTargets[index] ?? index
            }
            let date = entry.modificationDate ?? Date()
            do {
                switch format {
                case .zip: _ = try ZipRecords.timestamp(date)
                case .sevenZip: _ = try SevenZipRecords.timestamp(date)
                case .lha: _ = try LHARecords.timestamp(date)
                case .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstd, .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress:
                    _ = try TarRecords.timestamp(date)
                }
            } catch { throw refuse("更新日時が出力形式の表現範囲外です") }
            if format == .lha {
                // writer と同じ CP932 往復・header 長・サイズの検査を、出力作成前に行う。
                let size = dataTargets[entry.index].map { entries[$0].uncompressedSize }
                    ?? entry.uncompressedSize
                do {
                    _ = try LHARecords.Entry(name: name, mode: mode(for: entry), size: size ?? 0, date: date)
                } catch { throw refuse("LHA の CP932 名・header 長・32 bit サイズで表現できません") }
            }
            if !name.isEmpty {
                let directory = entry.kind == .directory
                do { try carriedPaths.validate(name, directory: directory) }
                catch { throw refuse("正規化した出力名が他の entry と衝突しています: \(name)") }
                carriedPaths.insert(name, directory: directory)
            }
            names.append(name)
        }
        return (names, hardLinkTargets, dataTargets)
    }

    private static func validateSource(_ entry: ArchiveEntry, reader: ArchiveReader?) throws {
        func refuse(_ reason: String) -> RewriterError {
            .unrepresentable(entry: entry.name, reason: reason)
        }
        if entry.formatSpecific["headerLevel"] != nil {
            let method = entry.formatSpecific["method"] ?? entry.methodDescription
            switch method {
            case "-lh0-", "-lz4-", "-pm0-", "-lhd-", "-lh1-",
                 "-lh4-", "-lh5-", "-lh6-", "-lh7-", "-lhx-", "-lz5-", "-lzs-": break
            default: throw refuse("未対応の LHA 圧縮方式は再圧縮できません: \(method)")
            }
            if let reader, entry.kind != .directory, entry.formatSpecific["osID"] == "m",
               ["1", "2"].contains(entry.formatSpecific["headerLevel"]) {
                do {
                    let stream = try reader.stream(entry)
                    guard let size = entry.uncompressedSize, stream.remaining == size else {
                        throw refuse("MacBinary の envelope・resource fork を保持できないため再圧縮できません")
                    }
                } catch let error as KaitoError {
                    throw map(error, entry: entry.name)
                }
            }
        }
        // KaitoKit は未知の coder ID をこの表記で公開する。既知の coder の allowlist は持たない。
        if let method = entry.methodDescription.split(separator: "+").first(where: { $0.hasPrefix("7z method 0x") }) {
            throw refuse("未対応の 7z 圧縮方式は再圧縮できません: \(method)")
        }
    }

    /// 運ぶ entry の mode 欄。種別は kind から、許可 bit は posixPermissions（無ければ 755 / 644）から作る。
    static func mode(for entry: ArchiveEntry) -> UInt16 {
        let type: UInt16 = entry.kind == .directory ? FileMode.directory : entry.kind == .symlink ? FileMode.symlink : FileMode.regular
        return type | ((entry.posixPermissions ?? (entry.kind == .directory ? 0o755 : 0o644)) & 0o7777)
    }

    /// KaitoKit の読取 error を rewriter の error に写す。password 系だけを区別し、他は不正な書庫とする。
    static func map(_ error: KaitoError, entry: String?) -> RewriterError {
        switch error {
        case .passwordRequired, .wrongPassword: .password(entry: entry)
        default: .invalidArchive(String(describing: error))
        }
    }
}
