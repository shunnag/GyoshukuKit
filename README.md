# GyoshukuKit (凝縮Kit)

GyoshukuKit は macOS 向けの純 Swift 書庫**書き込み**ライブラリです。ファイルや `Data` から書庫を作り、既存書庫の追加・削除・改名、再圧縮・形式変換を行えます。読み取りは [KaitoKit (解凍Kit)](https://github.com/shunnag/KaitoKit) で行い、書き込みが必要な場合に GyoshukuKit を追加します。GyoshukuKit は KaitoKit に依存します。

## 要件

| 用途 | 要件 |
|---|---|
| 実行 | macOS 26 以上 / Apple Silicon |
| ビルド | Xcode 27 / Swift 6.4 以上 |

Xcode 26 / Swift 6.3 はビルドできても release で誤動作するためサポートしません。この要件は manifest では強制されません。[詳細](Documentation/testing.md#toolchain-と-ci)

## インストール

Swift Package Manager で GyoshukuKit 0.9.0 を追加します。

```swift
// Package.swift の dependencies
.package(url: "https://github.com/shunnag/GyoshukuKit.git", .upToNextMinor(from: "0.9.0"))

// 利用側 target の dependencies
.product(name: "GyoshukuKit", package: "GyoshukuKit")
```

KaitoKit 0.12.x（0.12.0 以上、0.13.0 未満）が依存として自動で解決されます。
依存解決の仕組みと開発時の配置は[導入の詳細](Documentation/installation.md)を参照してください。

## クイックスタート

各例は `import Foundation` と `import GyoshukuKit` を使います。入力 URL と、まだ存在しない出力 URL を渡してください。

### ZIP・7z・tar.xz を作る

```swift
import Foundation
import GyoshukuKit

func createArchives(sourceURL: URL, directory: URL) throws {
    let outputs: [(ArchiveFormat, String)] = [
        (.zip, "example.zip"), (.sevenZip, "example.7z"), (.tarXZ, "example.tar.xz")
    ]
    for (format, name) in outputs {
        let writer = try ArchiveWriter.create(
            url: directory.appendingPathComponent(name), format: format)
        try writer.addDirectory("docs")
        try writer.add(data: Data("こんにちは\n".utf8), as: "docs/readme.txt",
                       modificationDate: Date(), permissions: 0o644)
        try writer.add(contentsOf: sourceURL, as: "assets")
        try writer.finish()
    }
}
```

ディレクトリは再帰追加し、symlink は辿らず保存します（LHA は symlink 非対応）。`finish()` の成功で書庫が完成します。
同じ writer への呼び出しは直列化してください。失敗後は再利用できず、部分出力の削除は呼び出し側で行います。[ライフサイクルと入力の扱い](Documentation/usage.md#新規作成)

### パスワード付き 7z を作る

```swift
func createEncryptedArchive(destination: URL, password: String) throws {
    let writer = try ArchiveWriter.create(
        url: destination, format: .sevenZip,
        options: WriterOptions(password: password, encryptsSevenZipHeaders: true))
    try writer.add(data: Data("秘密\n".utf8), as: "memo.txt")
    try writer.finish()
}
```

ZIP は `format: .zip` と `WriterOptions(password: password)` で AES-256 を使います。ZipCrypto は `zipEncryption: .zipCrypto` を指定します。空パスワードは拒否します。[暗号化の詳細](Documentation/formats.md#暗号化)

### ZIP を更新し、tar.xz に変換する

```swift
func updateAndConvert(zipURL: URL, output: URL) throws {
    let updater = try ArchiveUpdater.open(url: zipURL)
    try updater.add(data: Data("追加\n".utf8), as: "new.txt")
    try updater.commit()

    let rewriter = try ArchiveRewriter.open(
        url: zipURL, output: output, format: .tarXZ)
    try rewriter.commit()
}
```

削除は `remove(entriesAt:)`、改名は `rename(entryAt:to:)`。index は open 時の一覧を基準とし、予約後も変わりません。
updater は未変更の圧縮データを運び、rewriter は全体を再圧縮します。ZIP / 7z は再圧縮なしのパスワード変更も可能です。[編集・probe・原子的置換](Documentation/usage.md#更新と再構築)

### 通常ファイル一つを圧縮する

```swift
func compressFile(sourceURL: URL, compressedURL: URL) throws {
    try SingleStreamCompressor.compress(
        file: sourceURL, to: compressedURL, format: .gzip)
}
```

`.gz` / `.bz2` / `.xz` / `.zst` / `.lzma` / `.lz` / `.lz4` / `.br` / `.Z` に対応します。拡張子は呼び出し側で指定します。[単独ファイルと進捗](Documentation/usage.md#単独ファイル)
必要に応じて `options` で設定、`progress` で読取の進捗を指定できます。

## 対応機能

| 形式 | 作成・全体再構築 | 更新（追加・削除・改名） | 暗号化 | 書き込み方式 |
|---|---|---|---|---|
| ZIP / ZIP64 | ○ | `ArchiveUpdater` | AES-256 / ZipCrypto | Stored / Deflate / BZip2 / LZMA / Zstandard / XZ / PPMd |
| 7z | ○ | `SevenZipUpdater` | AES-256、任意の header 暗号化 | LZMA2 / LZMA / Deflate / BZip2 / PPMd / Copy、solid・BCJ / ARM64 / Delta |
| tar | ○ | `TarUpdater` | — | 無圧縮 |
| tar.gz / tar.bz2 / tar.xz | ○ | `CompressedTarUpdater`（変更区間を再圧縮） | — | gzip / BZip2 / XZ |
| tar.zst / tar.lzma / tar.lz / tar.lz4 / tar.br / tar.Z | ○ | `ArchiveRewriter`（全体再構築） | — | Zstandard / LZMA_Alone / lzip / LZ4 / Brotli / compress |
| LHA | ○ | `LHAUpdater` | — | LH5 / LH6 / LH7 / Stored |

ZIP の既定は互換性を重視した Deflate です。BZip2 / LZMA / Zstandard / XZ / PPMd は macOS Archive Utility / ditto / unzip では展開できません。KaitoKit や 7-Zip などの対応 reader が必要です。
方式 ID、レベル、名前・日時・メタデータの制限は[形式リファレンス](Documentation/formats.md)を参照してください。

## よく使う設定

| `WriterOptions` | 既定値 | 用途 |
|---|---|---|
| `compressionMethod` / `sevenZipMethod` / `lhaMethod` | `.deflate` / `.lzma2` / `.lh5` | 形式ごとの方式 |
| `deflateLevel` / `bzip2Level` | `6` / `9` | `0...9` / `1...9` |
| `lzmaLevel` / `lzmaExtreme` | `nil` / `false` | レベル `0...9`、extreme で探索量を増やす。[形式別の nil の動作](Documentation/options.md#全オプション) |
| `zstdLevel` / `ppmdLevel` / `lhaLevel` | `3` / `6` / `6` | `1...19` / `1...9` / `1...9` |
| `password` / `zipEncryption` | `nil` / `.aes256` | ZIP・7z の暗号化 |
| `sevenZipSolid` / `sevenZipFilter` | `.off` / `.none` | 7z のまとめ方と前処理 |
| `prefersSpeed` | `false` | 速さ優先。既知サイズの圧縮片・7z solid folderを増やす。[分割規則と比率のトレードオフ](Documentation/options.md#速さ優先) |
| `compressionThreads` / `memoryLimit` | `nil` / `nil` | 並列数 `1...1024` の自動解決、対応 codec のメモリ予算 |
| `powerPolicy` | `.reduceInLowPowerMode` | 自動並列数の省電力・温度方針 |

全26項目の既定値・範囲と圧縮待ちの入力量の上限は[設定リファレンス](Documentation/options.md)にまとめています。
一括追加には `ArchiveAddition` と `add(_:events:)`、読取・圧縮待ち・commit の進捗 API も使えます。[詳細](Documentation/usage.md#一括追加と進捗)

## 性能とスレッド

自動並列数は有効 logical CPU 数と物理メモリ GiB の最小値（最低1）。既定の `powerPolicy` は Low Power Mode で減らします。
`.reduceInLowPowerModeOrThermalPressure` は thermal state が serious / critical の場合も減らし、`.alwaysUseAllCores` は電力・温度による削減をしません。
writer / updater は開始時に一度解決し、codec・項目サイズ・メモリ予算と GCD pool の安全上限で実際の並列数を制限します。
アプリの自動値表示には `WriterOptions.automaticCompressionThreads(powerPolicy:)`、明示値の範囲には `WriterOptions.compressionThreadsRange` を使います。
同じ writer は thread-safe / Sendable ではありません。`WriterOptions` は `Sendable` です。
速度・サイズ・RSS の測定条件は [Benchmarks](Benchmarks/README.md) と[並列処理の検証記録](Documentation/verification/2026-10-07-writer-multicore.md)を参照してください。

## ドキュメント

| 読みたいこと | 資料 |
|---|---|
| 依存解決・キャッシュ・リリースの関係 | [導入](Documentation/installation.md) |
| writer / updater / rewriter、単独圧縮、進捗 | [使い方と保証](Documentation/usage.md) |
| 方式・レベル・互換性・制限 | [形式](Documentation/formats.md) |
| 全設定・並列数・メモリ | [WriterOptions](Documentation/options.md) |
| ビルド・CI・大容量検証 | [開発と検証](Documentation/testing.md)、[テストの配置・環境変数](Tests/README.md) |
| 設計の判断・変更履歴 | [設計書](Documentation/design.md)、[CHANGELOG](CHANGELOG.md) |

## 開発

貢献者向けのビルド・テスト手順、CI、大容量試験は[開発と検証](Documentation/testing.md)を参照してください。

## English

GyoshukuKit is a pure-Swift archive writer for ZIP, 7z, tar variants and LHA, with ZIP / 7z encryption and single-file compression. It depends on KaitoKit for reading: use KaitoKit alone to read, and add GyoshukuKit to write.

Requirements: macOS 26+ on Apple Silicon at runtime; Xcode 27 / Swift 6.4+ to build. Xcode 26 / Swift 6.3 release builds are unsupported; the manifest does not enforce this requirement.
KaitoKit 0.12.x (>= 0.12.0, < 0.13.0) is resolved automatically as a dependency.

```swift
// Package.swift dependencies
.package(url: "https://github.com/shunnag/GyoshukuKit.git", .upToNextMinor(from: "0.9.0"))
// Target dependencies
.product(name: "GyoshukuKit", package: "GyoshukuKit")
```

Create a ZIP at a destination that does not exist:

```swift
import Foundation
import GyoshukuKit

func createZIP(at destination: URL) throws {
    let writer = try ArchiveWriter.create(url: destination, format: .zip)
    try writer.add(data: Data("Hello\n".utf8), as: "hello.txt")
    try writer.finish()
}
```

Serialize calls to each writer. A failed add/finish makes it unusable and leaves partial output for you to delete.
Use `ArchiveUpdater`, `TarUpdater`, `CompressedTarUpdater`, `LHAUpdater` or `SevenZipUpdater` for edits, and `ArchiveRewriter` for recompression or format conversion.

Detailed docs are in Japanese: [Installation and dependencies](Documentation/installation.md), [Usage and guarantees](Documentation/usage.md), [Formats and compatibility](Documentation/formats.md), [WriterOptions and memory](Documentation/options.md), [Development and verification](Documentation/testing.md).
MIT licensed.

## ライセンス

[MIT](LICENSE)
