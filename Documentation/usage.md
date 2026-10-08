# 使い方と保証

[README](../README.md#クイックスタート)の短い例に加え、writer の寿命、編集・probe、単独圧縮を説明します。以下の例の URL・パスワードは呼び出し側で用意してください。

## 新規作成

```swift
import Foundation
import GyoshukuKit

let writer = try ArchiveWriter.create(
    url: destination,
    format: .zip,
    options: WriterOptions(deflateLevel: 6)
)
try writer.addDirectory("docs")
try writer.add(data: Data("こんにちは\n".utf8), as: "docs/readme.txt",
               modificationDate: Date(), permissions: 0o644)
try writer.add(contentsOf: sourceURL, as: "assets")
try writer.finish()
```

出力先は新規ファイルに限り、既存ファイルを上書きしません。ディスク上の
ディレクトリは再帰的に追加します。symlink は辿らず、target path を保存します（LHA は symlink を拒否します）。
同じ writer は呼出側が直列化してください。thread-safe / Sendable ではありません。
設定値の `WriterOptions` は `Sendable` です。

`finish()` の成功で初めて書庫が完成します。成功後の再呼出しは何もしません。
`add` / `finish` の失敗後は writer を再利用できません。呼出側が部分出力を削除し、
新しい writer でやり直してください。deinit はファイルを閉じるだけです。
追加中は入力を変更しないでください。通常ファイルの device / inode / size / mode / mtime を
比較します。Finder tag や LaunchServices の xattr 更新でも変わる ctime は比較しません。

### tar.zst を作る

```swift
let writer = try ArchiveWriter.create(url: archiveURL, format: .tarZstd,
    options: WriterOptions(zstdLevel: 3, compressionThreads: 4))
try writer.add(contentsOf: sourceURL, as: "input")
try writer.finish()
```

## 更新と再構築

ZIP は `ArchiveUpdater`、tar は `TarUpdater`、tar.gz / tar.bz2 / tar.xz は `CompressedTarUpdater`、LHA は `LHAUpdater`、7z は `SevenZipUpdater` で追加・削除・改名できます。未変更の member・圧縮区間を運び、圧縮 tar の変更区間と 7z solid folder の一部削除だけを再圧縮します。ZIP / 7z は再圧縮なしのパスワード設定・変更・解除にも対応します。

```swift
let updater = try ArchiveUpdater.open(url: archiveURL)
try updater.remove(entriesAt: [0, 2])
try updater.rename(entryAt: 1, to: "docs/新しい名前.txt")
try updater.add(data: Data("追加\n".utf8), as: "new.txt")
try updater.commit()
```

削除・改名の index は open 時の KaitoKit の一覧と同じゼロ始まりで、予約しても変化しません。
directory の子孫は呼出側で個別に指定します。追加済みの新 entry は index 操作の対象外です。
生き残る entry の圧縮 payload と descriptor はそのまま運び、再圧縮しません。
offset が変わらない record は clone 上で読み書きせず、条件を満たす同長改名では local header と CD だけを patch
します。末尾削除も残存 payload を書き直しません。移動が必要な範囲だけ 4 MiB の buffer で
コピーし、最後に central directory を再出力・truncate します。
未変更名は元の byte / flag を保持し、改名だけ UTF-8 / NFC / bit 11 を使います。
移動できない entry、危険な名前、予約済み名との衝突、範囲外 index は理由付きで拒否します。
ZIP32 descriptor の移動先が初めて ZIP64 offset を要する場合も、KaitoKit（0.4.0 以降）の
descriptor 幅の解釈により拒否します。詳細は[削除・改名の検証記録](verification/2026-09-10-zip-delete-rename.md)を参照してください。

ZIP の更新は同一 volume の clone で作業し、commit で atomic replace した直後に mode と quarantine を
復元します。未 commit の破棄、途中失敗、置換前の Task cancellation では原本を変更しません。
成功後の commit は no-op、失敗後は再利用できません。metadata 復元で失敗した場合は既に
内容の置換は完了しています。同じ書庫への操作は呼出側で直列化してください。

### ZIP の編集可否 probe

既に reader を持つ呼出側は `ArchiveUpdater.probe(url:)` で ZIP / ZIP64 の編集用終端と各門番を
検査できます。reader の生成や CD の entry 解析を行わず、成功時に `Probe.entryCount: UInt64` を
返します。SFX prefix・trailing data・不正な CD offset、分割 ZIP、矛盾した終端は `open` と同じ
理由で拒否し、複数の整合する EOCD 候補や comment 内の終端候補も `ambiguousEndRecord` で拒否します。
CD 全件の walk と local record の offset / 範囲の照合は `open` だけで行います。
probe だけでは entry の正当性は保証しないため、自身の検証済み reader と
`probe.entryCount == UInt64(reader.entries.count)` を必ず照合してから利用してください。

### パスワードと形式変換

`ArchiveUpdater.open(url:options:)` の `options.password` は新規追加する通常ファイルに適用します。
既存 entry の暗号化方式・パスワードは保持するため、平文と暗号文の混在も可能です。
既存 entry も変える場合は `reencryptExistingEntries(currentPassword:)` を予約します。
`SevenZipUpdater` も同じ `ArchiveReencrypting` に適合します。再圧縮や形式変換には `ArchiveRewriter` を使い、入力の `password` と出力の
`options.password` は独立しており、後者が nil なら平文を出力します。

```swift
let rewriter = try ArchiveRewriter.open(
    url: sourceArchive, password: sourcePassword,
    output: destination, format: .sevenZip,
    options: WriterOptions(password: outputPassword, encryptsSevenZipHeaders: true)
)
try rewriter.commit()
```

### 再構築の表現可能性 probe

KaitoFinder などが再圧縮による編集・変換の可否を判定するときは、
`appleDoublePolicy: .expose` の reader を渡して `ArchiveRewriter.probe(reader:format:)` を呼びます。
`open` も同じ検査を行い、未対応の LHA method / 7z coder と、envelope・resource fork を
保持できない MacBinary 入りの MacLHA member を `RewriterError.unrepresentable(entry:reason:)` で拒否します。
MacLHA の level 1/2 だけ stream の初期長を確認し、通常の本文を持つ `m` member は受理します。

`probe(entries:format:)` は投影済みの entry 一覧や追加予約の検査に使えます。
MacLHA の `m` 印だけでは MacBinary と通常の本文を区別できず、envelope は検出しません。
既存書庫の編集では、開いた reader に `probe(reader:format:)` を別途実行してください。
いずれも全本文の復号・CRC、パスワード、`WriterOptions`、原本の同一性を保証する検査ではありません。
詳細と ZIP 改名時の名前の扱いは [P0-G 検証記録](verification/2026-09-24-p0g-editability-and-zip-names.md)を参照してください。

### 新しい圧縮 tar の更新経路

`CompressedTarUpdater` の splice は tar.gz / tar.bz2 / tar.xz に限ります。
tar.zst を含む新しい6形式は `assess(reader:)` が nil、`open` が `UpdaterRouteError.requiresRewrite` を返します。
`ArchiveRewriter` は読み取れる書庫から各新形式へ変換でき、削除・改名・追加は全体を再符号化して反映します。

```swift
let editor = try ArchiveRewriter.open(url: archiveURL, format: .tarLzip)
try editor.rename(entryAt: 0, to: "新しい名前.txt")
try editor.add(data: Data("追加\n".utf8), as: "new.txt")
try editor.commit()
```

## 単独ファイル

```swift
let progress = Progress(totalUnitCount: 0)
try SingleStreamCompressor.compress(
    file: sourceURL, to: compressedURL, format: .gzip,
    options: WriterOptions(deflateLevel: 6), progress: progress
)
```

`SingleStreamFormat` は `.gzip` / `.bzip2` / `.xz` / `.zstd` / `.lzma` / `.lzip` / `.lz4` / `.brotli` / `.compress`。
通常ファイル一つを新規圧縮する create-only API で、directory と symlink は
`WriterError.unsupportedFileType` で拒否します。複数 source は呼出側で tar.X にまとめ、編集は扱いません。
宛先と同じ directory の一時 file に圧縮を完了し、排他的 rename で公開します。既存出力は上書きせず、
失敗・Task cancellation・`Progress.cancel()` では自分の一時 file を削除します。
`progress` の total は入力長、completed は読取 byte 数で、圧縮完了より先に total に達することがあります。

stream の分割・レベルと空 `.Z` の制限は[形式リファレンス](formats.md#単独ストリーム)を参照してください。

```swift
try SingleStreamCompressor.compress(file: sourceURL, to: compressedURL, format: .zstd)
```

## 一括追加と進捗

`ArchiveAddition` の配列を `add(_:events:)` に渡すと一括追加できます。ディスク読取の byte 進捗と追加イベントを受け取り、未出力の圧縮予約は `finishAdditions(progress:)` で待てます。updater / rewriter は commit の進捗も通知します。読取が完了しても圧縮・出力が残る場合があります。

詳しいイベントと進捗の意味は [ArchiveAddition](../Sources/GyoshukuKit/API/ArchiveEditing.swift)、[writer](../Sources/GyoshukuKit/Writer/ArchiveWriter.swift)、[進捗の検証記録](verification/2026-09-27-p6g-progress.md)、[一括追加の検証記録](verification/2026-09-27-p7g-batch.md)を参照してください。

待機中の入力上界とメモリ・一時ディスクは[設定リファレンス](options.md#pending-input-の意味)を参照してください。
