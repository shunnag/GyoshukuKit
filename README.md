# GyoshukuKit (凝縮Kit)

GyoshukuKit は macOS 向けの純 Swift 書庫**書き込み**フレームワークです。
読み取り専用の [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)と対をなします。

- 対象: macOS 26 以上、Swift 6、Apple Silicon
- 対応: ZIP / ZIP64 の新規作成・追加・削除・改名、stored / raw deflate (system zlib)
- 作成・全体再構築: tar / tar.gz / tar.bz2 / tar.xz / non-solid 7z / LHA。暗号化出力: ZIP AES-256 / ZipCrypto、7z AES-256
- 更新: `TarUpdater` / `CompressedTarUpdater` / `LHAUpdater` / `SevenZipUpdater` で追加・削除・改名。未変更の member・圧縮区間を運び、圧縮 tar の変更区間と 7z solid の一部削除だけを再圧縮する。ZIP / 7z は再圧縮なしのパスワード設定・変更・解除にも対応
- 一括追加と進捗: `ArchiveAddition` と `add(_:events:)`、ディスク読取の byte 進捗、`finishAdditions(progress:)`、updater / rewriter の commit 進捗
- 依存: [KaitoKit](https://github.com/shunnag/KaitoKit) 0.11.x（0.11.0 以上、0.12.0 未満）。更新時の読取と往復検証に使用。`@_spi` は SemVer の保証外で、`public import KaitoKit` により公開 API にも KaitoKit の型を含むため、`.upToNextMinor(from: "0.11.0")` に限定する。`Package.swift` は隣に `../KaitoKit` の checkout があればその path 依存（開発用）、なければ tag 参照を選ぶ。SwiftPM / Xcode の `checkouts/` 配下（依存として取得された場合）では常に tag 参照。切り替わった後は `swift package purge-cache`（Xcode は File → Packages → Reset Package Caches）で manifest を再評価させる（`.build` の削除では manifest cache が残る）
- ライセンス: MIT

## インストール

GyoshukuKit 0.6.0 を Swift Package Manager で追加します。

```swift
.package(url: "https://github.com/shunnag/GyoshukuKit.git", .upToNextMinor(from: "0.6.0"))
```

利用側の target の dependencies に `.product(name: "GyoshukuKit", package: "GyoshukuKit")` を追加してください。
KaitoKit 0.11.0 → GyoshukuKit 0.6.0 → KaitoFinder 0.4.0 の順にリリースします。

## 使用例

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
ディレクトリは再帰的に追加します。symlink は辿らず、target path を保存します。
同じ writer は呼出側が直列化してください。thread-safe / Sendable ではありません。
設定値の `WriterOptions` は `Sendable` です。

`finish()` の成功で初めて書庫が完成します。成功後の再呼出しは何もしません。
`add` / `finish` の失敗後は writer を再利用できません。呼出側が部分出力を削除し、
新しい writer でやり直してください。deinit はファイルを閉じるだけです。
追加中は入力を変更しないでください。通常ファイルの device / inode / size / mode / mtime を
比較します。Finder tag や LaunchServices の xattr 更新でも変わる ctime は比較しません。

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
ZIP32 descriptor の移動先が初めて ZIP64 offset を要する場合も、KaitoKit 0.4.0 の
descriptor 幅の制限により拒否します。詳細は削除・改名の検証記録に記載しています。

更新は同一 volume の clone で作業し、commit で atomic replace した直後に mode と quarantine を
復元します。未 commit の破棄、途中失敗、置換前の Task cancellation では原本を変更しません。
成功後の commit は no-op、失敗後は再利用できません。metadata 復元で失敗した場合は既に
内容の置換は完了しています。同じ書庫への操作は呼出側で直列化してください。

既に reader を持つ呼出側は `ArchiveUpdater.probe(url:)` で ZIP / ZIP64 の編集用終端と各門番を
検査できます。reader の生成や CD の entry 解析を行わず、成功時に `Probe.entryCount: UInt64` を
返します。SFX prefix・trailing data・不正な CD offset、分割 ZIP、矛盾した終端は `open` と同じ
理由で拒否し、複数の整合する EOCD 候補や comment 内の終端候補も `ambiguousEndRecord` で拒否します。
CD 全件の walk と local record の offset / 範囲の照合は `open` だけで行います。
probe だけでは entry の正当性は保証しないため、自身の検証済み reader と
`probe.entryCount == UInt64(reader.entries.count)` を必ず照合してから利用してください。

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

KaitoFinder などが再圧縮による編集・変換の可否を判定するときは、
`appleDoublePolicy: .expose` の reader を渡して `ArchiveRewriter.probe(reader:format:)` を呼びます。
`open` も同じ検査を行い、未対応の LHA method / 7z coder と、envelope・resource fork を
保持できない MacBinary 入りの MacLHA member を `RewriterError.unrepresentable(entry:reason:)` で拒否します。
MacLHA の level 1/2 だけ stream の初期長を確認し、通常の本文を持つ `m` member は受理します。

`probe(entries:format:)` は投影済みの entry 一覧や追加予約の検査に使えます。
MacLHA の `m` 印だけでは MacBinary と通常の本文を区別できず、envelope は検出しません。
既存書庫の編集では、開いた reader に `probe(reader:format:)` を別途実行してください。
いずれも全本文の復号・CRC、パスワード、`WriterOptions`、原本の同一性を保証する検査ではありません。
詳細と ZIP 改名時の名前の扱いは [P0-G 検証記録](Documentation/verification/2026-09-24-p0g-editability-and-zip-names.md)を参照してください。

## 設定と形式

| `WriterOptions` | 既定値 | 意味 |
|---|---|---|
| `compressionMethod` | `.deflate` | `.stored` または `.deflate` |
| `deflateLevel` | `6` | ZIP / tar.gz の zlib level `0...9` |
| `bzip2Level` | `9` | tar.bz2 の block size level `1...9`（100,000〜900,000 byte） |
| `useCompressionHeuristic` | `true` | jpg/png/zip 等、既知の圧縮済み拡張子を stored にする |
| `preserveOwnerIDs` | `false` | true のときディスク由来の uid/gid を 0x7875 に保存 |
| `preserveMacOSMetadata` | `false` | true はこの段階では `unsupportedOption` |
| `password` | `nil` | ZIP / 7z の暗号化出力。空文字列は `invalidOption("password")` |
| `zipEncryption` | `.aes256` | WinZip AES-256。`.zipCrypto` は従来の PKWARE 暗号 |
| `encryptsSevenZipHeaders` | `false` | 7z のファイル名を含む header も暗号化。パスワードが必要 |
| `compressionThreads` | `nil` | ZIP deflate（ZipCrypto を除く）/ tar.gz / tar.bz2 / 7z / tar.xz / LHA の並列数 `1...64`。ZIP 再暗号化の鍵導出にも使用。自動は CPU 数・物理メモリ GiB・8 の最小値（最低1） |
| `additionPlacement` | `.end` | rewriter の追加位置。`.beginning` で従来の先頭追加 |
| `carriedTarOwnerIDs` | `.keep` | rewriter で運ぶ tar の uid/gid を維持。`.reset` で 0 にする。ディスクからの追加には `preserveOwnerIDs` を使用 |

ZIP の空ファイル・ディレクトリ・symlink は常に stored です。通常ファイルの payload は
256 KiB 単位で読み書きし、作業メモリをファイルサイズに比例させません。central directory 用の
メタデータは entry 数と名前長に比例します。

ZIP deflate（ZipCrypto を除く）/ tar.gz は最大 1 MiB ごとに raw deflate を圧縮し、直前の末尾 32 KiB を辞書に使います。
ZIP の小さい member は個別の `add(contentsOf:as:)` 呼出し間でも並列化し、出力は追加順です。
tar.gz は従来の header を持つ単一 gzip member、tar.bz2 は最大 `5 × bzip2Level × 100,000` byte の
完全な bzip2 stream の連結です。通常の tar member は途中で切らず、先頭で gzip の同期点・bzip2 stream を区切り、
上限を越える member は header 群と本文を分けて片にします。tar の終端は独立した区切りです。
thread 数を変えても圧縮 byte 列は変わりません。
tar.xz は header 群・本文・詰め物を合わせて4 MiB以下の member を最大4 MiBの block に詰めます。
4 MiBを越える member は header 群と本文を別の block にし、本文と大きな header 群は最大16 MiBの片に分けます。
tar の終端は独立した block です。既存書庫の編集では、変更した区間だけにこの規則を使います。
ZIP の暗号化では salt が毎回変わります。圧縮失敗は後続の `add` / `finish` で通知されることがあります。
deflate / bzip2 の未出力 chunk と組立中の入力は合計で最大 `compressionThreads` 個に抑えます。
tar.xz の未出力 block は、並列数が2以上のとき64 KiB以下を並列数に数えず、合計で最大
`2 × compressionThreads + 1` 個です。並列数1は同時に一つだけを符号化します。
deflate / bzip2 の主なメモリは thread ごとに入力と出力（約2 × chunk size）と codec state、
LZMA2 は16 MiBの片を使うと thread ごとに約130 MiBです。待機中の取消しは50 msごとに確認します。
tar.xz の待機中の入力と組立中の入力の上界は `(compressionThreads + 1) × (16 MiBの片 + 64 KiB)` です。
この入力の上界は codec state と出力を含みません。小さなファイルの多い tar.xz は従来より5–12%大きくなります。
bzip2 の chunk は内部 block size の5倍です。level 9 は4,500,000 byteごとの独立streamとなり、
thread ごとの入力・出力約9 MBとcodec state約7.6 MBで合計約16.6 MB（約15.8 MiB）を使います。

ZIP のパスワードは UTF-8、7z は UTF-16LE を使います。ZIP は空ファイルも暗号化し、
ディレクトリと symlink は暗号化しません。AES は 20 byte 未満を AE-1（CRC あり）、
20 byte 以上を AE-2（CRC 欄は 0）で書き、作業ファイルを使わず stream に暗号化します。
ZipCrypto は CRC の確定が必要なので、出力の隣で mode 0600 の一時ファイルを排他的に作成し、
書込前に unlink した descriptor へ圧縮結果を spool します。暗号化してコピーした後や失敗時に
descriptor を閉じます。圧縮中に名前付きの平文 spool を残しません。

7z は非空 stream ごとに LZMA2 → AES-256-CBC を使い、空ファイルは従来どおり
EmptyStream として保存します。header 暗号化は名前も隠します。LZMA2 の圧縮単位は最大 16 MiB、
読取・暗号化・書込は 256 KiB 単位です。Apple の 8 MiB 辞書を使い、16 MiB 以下のファイルは
従来の全体圧縮と同じ圧縮 payload になります。大きいファイルだけ 16 MiB 境界で辞書を reset します。
主な作業メモリは最大 16 MiB の入力とその圧縮出力です。
LHA は1 MiBまでのmemberをメモリで処理し、それより大きいmemberは1 MiB入力と8 KiB辞書履歴で
分割圧縮します。LH5 block間のbitを継続し、圧縮結果が大きければ従来どおりstoredにします。
圧縮候補は作成直後unlinkするmode0600のspoolへ書き、raw bytesは未完成出力に保持します。
作業用ディスクには一時的にraw bytesと圧縮候補の空きが必要です。取消し・途中失敗・容量不足時は
spoolを閉じ、未完成出力を無効化して削除します。256 MiB入力でのwriter単体peak RSSは約14 MiBでした。
再現できる測定条件と限界は[横断検証](Documentation/verification/2026-09-17-release-hardening.md)に記録します。
tar（tar.gz / tar.bz2 / tar.xz を含む）/ LHA のパスワード指定は `unsupportedOption("password")`、
パスワードなしの header 暗号化指定は `invalidOption("encryptsSevenZipHeaders")` です。

新規追加・改名・`ArchiveRewriter` の再出力名は、全形式で NFC へ正規化します。
空の名前・絶対パス・`.` / `..`・空の成分・NUL・
UTF-8 で 65,535 byte を超える出力名・NFC 正規化後の重複・file と子の衝突は拒否します。
`\` / `:` は Windows 向けの ZIP / 7z / LHA 出力で拒否します。
tar / tar.gz / tar.bz2 / tar.xz では両文字を名前の一部として許可します。
`ArchiveRewriter` の既存名の検査にも、出力形式の規則を適用します。

ZIP の名前は UTF-8 で書き、bit 11 を常に立てます。
ZIP の mtime / atime は秒単位で、extended timestamp の符号付き 32 bit Unix 秒の範囲外は
`invalidDate` です。DOS 日付にはローカル時刻を使い、表現範囲へ丸めます。

UNIX host、POSIX mode、symlink、local / central で長さの違う timestamp extra、
ZIP64 に対応します。local header を seek で patch し、data descriptor は書きません。
ZIP64 の central / EOCD はフィールドごとに sentinel を選びます。local の例外では
両サイズを 0x0001 に載せ、両サイズ欄を sentinel にします。

macOS metadata の保存は今後の段階です。[設計書](Documentation/design.md)と
[作成](Documentation/verification/2026-09-10-zip-writer.md)・
[追加](Documentation/verification/2026-09-10-zip-updater.md)・
[削除・改名](Documentation/verification/2026-09-10-zip-delete-rename.md)・
[暗号化](Documentation/verification/2026-09-15-encryption.md)・
[大規模編集とパス境界](Documentation/verification/2026-09-16-edit-review.md)・
[全形式の空書庫と横断検証](Documentation/verification/2026-09-17-release-hardening.md)・
[ZIP の読取量と編集可否 probe](Documentation/verification/2026-09-19-release-review.md)の検証記録を参照してください。

tar.xz は Apple Compression、tar.bz2 は macOS の libbz2 をプロセス内で使います。
TarWriter の 256 KiB の入力・出力をストリーム圧縮し、書庫全体をメモリへ保持しません。
XZ は固定設定、bzip2 は `WriterOptions(bzip2Level: 1...9)` でレベルを指定できます。
所有者・リンク・タイムスタンプ・取消し・失敗時の cleanup は通常の tar と共通です。

## ビルドと検証

書き込み速度の測定は独立した [Benchmarks package](Benchmarks/README.md) を使います。
`Benchmarks/make-corpora.sh /tmp/gyoshuku-corpora` で固定 seed の入力を作成し、
`Benchmarks/run.sh /tmp/gyoshuku-corpora` で全形式の release 実行時間・peak RSS・出力サイズを測定します。
2026-09-24 の [並列 LZMA2](Documentation/verification/2026-09-24-parallel-lzma2.md) と
[並列 deflate / bzip2](Documentation/verification/2026-09-24-parallel-deflate-bzip2.md) の検証記録も参照してください。

```sh
swift build
swift test
```

テストには `/usr/bin/unzip`、`/opt/homebrew/bin/7zz`、`/usr/bin/ditto`、
`/usr/bin/tar`、`/usr/bin/python3`、`/usr/bin/cmp` が必要です。共通の起動 helper は欠けていれば失敗し、
一部の相互運用テストだけが skip します（現状は [Tests/README.md](Tests/README.md) の「外部ツールが無いとき」）。
テストの配置、共有 helper、`GYOSHUKU_*` 環境変数（`GYOSHUKU_SCALE_ASSERT` を含む）の一覧も同じ README にある。通常の `swift test` に 4 GiB + 1 MiB の全バイト往復と
65,536 entry の全件検証と、改名で local offset が 4 GiB を越える再構築も含めます。
作業用 clone と展開物に約 12 GiB の空き領域を確保し、
巨大な展開物は成功後に削除します。小さい書庫と実ツールのログは
`.build/verification/` に残します。

暗号化の oracle は KaitoKit のパスワード付き全 entry 往復、ZIP AES / 7z AES の `7zz t`、
ZipCrypto の `unzip -P ... -t` と `7zz t` です。誤パスワード・AES 認証破損・header の秘匿、
更新時の旧 record の byte 一致も検査します。300 MiB の入力を ZIP AES / 7z AES / ZipCrypto
で stream 処理し、読取中と終了後の一時ファイルも検査します。40 MiB の固定 seed テキストでは
平文・暗号 7z の往復と、Apple の全体圧縮から packed size が ±5% に収まることを検査します。
7z の5 / 16 MiBの片の圧縮 payload の byte 一致も検査します。2026-09-15 はsandboxの
module cache制限で未確認でしたが、2026-09-16には標準のSwiftPM実行環境で全件成功を確認しました。
実行件数と大規模編集の測定は[追加の検証記録](Documentation/verification/2026-09-16-edit-review.md)にあります。

実機固有の制限も検査しています。空 ZIP は Python の出力とも一致する正当な
22 byte の書庫ですが、Apple unzip は警告、ditto は拒否します。Apple unzip の
日本語表示は崩れるため、独立した標準 ZIP の表示との比較に加え、7-Zip・ditto・
KaitoKit と生バイトで名前を検証します。Archive Utility / Windows Explorer の
直接検証は未完了です。

> **GyoshukuKit (凝縮Kit)** is a pure-Swift archive writer for macOS 26+,
> Swift 6 and Apple Silicon, paired with the read-only KaitoKit. It uses system
> zlib, Apple Compression, CommonCrypto, CryptoKit and Security, with no C shim
> or linked system libarchive.
> GyoshukuKit 0.6.0 depends on KaitoKit 0.11.x through `.upToNextMinor(from: "0.11.0")` for update reading and round-trip verification. Its SPI use falls outside SemVer guarantees, and `public import KaitoKit` exposes KaitoKit types in the public API. `Package.swift` uses the sibling `../KaitoKit` checkout by path when one exists (development) and the tag reference otherwise, always the tag inside a SwiftPM / Xcode `checkouts/` directory. Run `swift package purge-cache` (Xcode: Reset Package Caches) after the mode changes; deleting `.build` keeps the cached manifest.
> Creation and full rewriting also support tar, tar.gz, tar.bz2, tar.xz, non-solid 7z and LHA.
> `TarUpdater`, `CompressedTarUpdater`, `LHAUpdater` and `SevenZipUpdater` edit existing archives while carrying unchanged members or compressed regions. Changed compressed-tar regions and partially deleted solid 7z folders are recompressed. ZIP and 7z updaters also support password changes without recompression.
> `ArchiveAddition` batches use `add(_:events:)`; byte progress covers disk reads, `finishAdditions(progress:)` and updater/rewriter commits.
>
> Create an `ArchiveWriter`, add files, recursively add directories, add symlinks
> without following them, or supply `Data`, then call `finish()`. Existing output
> files are never overwritten. Serialize access to each writer; only options are
> Sendable. A failed add/finish makes the writer unusable and leaves partial output
> for the caller to remove. Deinitialization closes without finalizing.
>
> ArchiveUpdater supports additions, deletion and renaming in one atomic commit.
> Unmoved records remain on the clone without payload I/O; eligible same-length renames patch local headers and the CD.
> `ArchiveUpdater.probe(url:)` checks ZIP end records and editing gatekeepers without creating a reader.
> Ambiguous EOCD candidates are refused; only `open` walks the full CD and validates local record ranges.
> Before trusting it, compare `Probe.entryCount` with the entry count of your own validated reader.
> Removal/rename indices refer to the original list from open and remain stable;
> callers explicitly select descendants. Surviving stored payloads and descriptors
> are never recompressed. Unchanged names retain their bytes and flags, while
> renamed entries use UTF-8/NFC. Working copies are discarded on failure or
> cancellation before replacement. Mode and quarantine are restored after replacement;
> metadata-restoration failures occur after contents have already been replaced.
>
> Options select stored/raw deflate, level 0–9 (default 6), an extension-based
> storage heuristic, and opt-in disk owner IDs. macOS metadata preservation is
> reserved but explicitly rejected when enabled. Files stream in 256 KiB chunks;
> directory metadata grows with entry count and name length. Names use UTF-8/NFC
> and bit 11. Unsafe relative paths, normalized duplicates, and file/child
> conflicts are rejected. Timestamps use signed 32-bit Unix seconds, rejecting
> dates outside that range; DOS timestamps use local time. ZIP64 central/EOCD
> sentinels are per field, while the local exception carries both sizes and uses
> both size sentinels. No data descriptors are written.
>
> `password` enables ZIP AES-256 (default) or `zipEncryption: .zipCrypto`, and 7z
> AES-256. ZIP encrypts empty files but leaves directories and symlinks plain.
> It writes AE-1 below 20 bytes and AE-2 otherwise. ZipCrypto spools compressed
> bytes to a mode-0600 file unlinked immediately after creation to obtain the CRC before writing its encryption header;
> the anonymous spool is closed on success or failure. AES uses no spool. 7z optionally
> encrypts file names with `encryptsSevenZipHeaders`; empty streams stay empty.
> ZIP passwords use UTF-8, 7z passwords UTF-16LE. Empty passwords, unsupported
> formats and header encryption without a password are rejected. Updaters
> encrypt additions by default; `reencryptExistingEntries(currentPassword:)` also converts existing entries. The rewriter takes independent source and output
> passwords. Source checks exclude ctime so tag and xattr updates are allowed.
> LZMA2 encodes at most 16 MiB at a time using Apple's 8 MiB dictionary; reads,
> encryption and writes stay at 256 KiB. Files up to 16 MiB retain the previous
> whole-buffer compressed payload. Larger files reset the dictionary at 16 MiB
> boundaries. Working buffers hold at most 16 MiB of input plus its compressed output.
>
> `swift test` includes real unzip, 7-Zip, ditto and bsdtar checks plus KaitoKit
> round trips, including all bytes above 4 GiB and all 65,536 entries. Required
> tools are listed above; the shared launcher fails when a tool is missing, and a few
> interop tests skip (see Tests/README.md for the current list, the test layout and the
> `GYOSHUKU_*` environment variables).
> Tests retain small archives/logs under `.build/verification` and remove large
> extracted data after success. Allow about 12 GiB for working copies and extraction.
>
> Known tool limitations: Apple unzip warns on a valid empty archive and ditto
> rejects it; Python emits identical empty ZIP bytes. Apple unzip also mangles
> Japanese display, so its listing is compared with an independent standard ZIP,
> while actual names are checked through bytes, 7-Zip, ditto and KaitoKit.
> Archive Utility and Windows Explorer have not been directly verified.
> Encryption tests add password-aware KaitoKit, 7zz and unzip oracles, header
> inspection, failure cleanup, rewriting and 300 MiB streaming. A fixed-seed 40 MiB
> text corpus also checks plain/encrypted 7z round trips and a ±5% packed-size
> guard against whole-buffer Apple compression. The module-cache restriction
> that blocked the 2026-09-15 sandbox run was resolved by using the standard SwiftPM
> environment; the full suite passed on 2026-09-16. See the edit review linked above
> for counts, bulk-rename measurements and Unicode path regressions. macOS metadata
> preservation remains future work. MIT licensed.

### 圧縮 tar の大容量検証

`GYOSHUKU_LARGE_TAR_TESTS=1 swift test` は 4 GiB + 513 byte の実ファイルを両形式で作成し、
Python / bsdtar / 7zz と KaitoKit で内容を照合します。通常実行では、この大容量ケースだけを skip します。
6 GiB 以上の空き領域が必要です。読取側の既定 4 GiB 上限は変更せず、このテストでは明示的に上限を上げます。
KaitoFinder の `Tools/benchmark_tar_memory.py` は最適化した実 writer のピークRSSと内容を検査します。
