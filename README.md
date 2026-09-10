# GyoshukuKit (凝縮Kit)

GyoshukuKit は macOS 向けの純 Swift 書庫**書き込み**フレームワークです。
読み取り専用の [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)と対をなします。

- 対象: macOS 26 以上、Swift 6、Apple Silicon
- 対応: ZIP / ZIP64 の新規作成・追加・削除・改名、stored / raw deflate (system zlib)
- 依存: 開発中は隣接する `../KaitoKit`（0.4.0）。更新時の読取と往復検証に使用
- ライセンス: MIT

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
追加中は入力を変更しないでください。通常ファイルのサイズ・変更時刻の変化は拒否します。

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
未変更名は元の byte / flag を保持し、改名だけ UTF-8 / NFC / bit 11 を使います。
移動できない entry、危険な名前、予約済み名との衝突、範囲外 index は理由付きで拒否します。
ZIP32 descriptor の移動先が初めて ZIP64 offset を要する場合も、KaitoKit 0.4.0 の
descriptor 幅の制限により拒否します。詳細は削除・改名の検証記録に記載しています。

更新は同一 volume の clone で作業し、commit で atomic replace した直後に mode と quarantine を
復元します。未 commit の破棄、途中失敗、置換前の Task cancellation では原本を変更しません。
成功後の commit は no-op、失敗後は再利用できません。metadata 復元で失敗した場合は既に
内容の置換は完了しています。同じ書庫への操作は呼出側で直列化してください。

## 設定と形式

| `WriterOptions` | 既定値 | 意味 |
|---|---|---|
| `compressionMethod` | `.deflate` | `.stored` または `.deflate` |
| `deflateLevel` | `6` | zlib の `0...9` |
| `useCompressionHeuristic` | `true` | jpg/png/zip 等、既知の圧縮済み拡張子を stored にする |
| `preserveOwnerIDs` | `false` | true のときディスク由来の uid/gid を 0x7875 に保存 |
| `preserveMacOSMetadata` | `false` | true はこの段階では `unsupportedOption` |

空ファイル・ディレクトリ・symlink は常に stored です。通常ファイルの payload は
256 KiB 単位で読み書きし、全体をメモリへ読み込みません。central directory 用の
メタデータは entry 数と名前長に比例します。

名前は UTF-8 / NFC、bit 11 を常に立てます。絶対パス・`..`・空の成分・NUL・
Windows の区切り文字 `\` / `:`・NFC 正規化後の重複・file と子の衝突は拒否します。
mtime / atime は秒単位で、extended timestamp の符号付き 32 bit Unix 秒の範囲外は
`invalidDate` です。DOS 日付にはローカル時刻を使い、表現範囲へ丸めます。

UNIX host、POSIX mode、symlink、local / central で長さの違う timestamp extra、
ZIP64 に対応します。local header を seek で patch し、data descriptor は書きません。
ZIP64 の central / EOCD はフィールドごとに sentinel を選びます。local の例外では
両サイズを 0x0001 に載せ、両サイズ欄を sentinel にします。

暗号化した新規 entry、macOS metadata の保存、他形式の作成は
今後の段階です。[設計書](Documentation/design.md)と
[作成](Documentation/verification/2026-09-10-zip-writer.md)・
[追加](Documentation/verification/2026-09-10-zip-updater.md)・
[削除・改名](Documentation/verification/2026-09-10-zip-delete-rename.md)の検証記録を参照してください。

## ビルドと検証

```sh
swift build
swift test
```

テストには `/usr/bin/unzip`、`/opt/homebrew/bin/7zz`、`/usr/bin/ditto`、
`/usr/bin/tar`、`/usr/bin/python3`、`/usr/bin/cmp` が必要です。欠けていれば失敗し、
黙って skip しません。通常の `swift test` に 4 GiB + 1 MiB の全バイト往復と
65,536 entry の全件検証と、改名で local offset が 4 GiB を越える再構築も含めます。
作業用 clone と展開物に約 12 GiB の空き領域を確保し、
巨大な展開物は成功後に削除します。小さい書庫と実ツールのログは
`build/verification/` に残します。

実機固有の制限も検査しています。空 ZIP は Python の出力とも一致する正当な
22 byte の書庫ですが、Apple unzip は警告、ditto は拒否します。Apple unzip の
日本語表示は崩れるため、独立した標準 ZIP の表示との比較に加え、7-Zip・ditto・
KaitoKit と生バイトで名前を検証します。Archive Utility / Windows Explorer の
直接検証は未完了です。

> **GyoshukuKit (凝縮Kit)** is a pure-Swift ZIP/ZIP64 writer for macOS 26+,
> Swift 6 and Apple Silicon, paired with the read-only KaitoKit. It uses system
> zlib, with no C shim, Compression framework or linked system libarchive.
> The local `../KaitoKit` dependency (0.4.0) provides update reading and round-trip verification.
>
> Create an `ArchiveWriter`, add files, recursively add directories, add symlinks
> without following them, or supply `Data`, then call `finish()`. Existing output
> files are never overwritten. Serialize access to each writer; only options are
> Sendable. A failed add/finish makes the writer unusable and leaves partial output
> for the caller to remove. Deinitialization closes without finalizing.
>
> ArchiveUpdater supports additions, deletion and renaming in one atomic commit.
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
> `swift test` includes real unzip, 7-Zip, ditto and bsdtar checks plus KaitoKit
> round trips, including all bytes above 4 GiB and all 65,536 entries. Required
> tools are listed above; missing tools fail instead of silently skipping.
> Tests retain small archives/logs under `build/verification` and remove large
> extracted data after success. Allow about 12 GiB for working copies and extraction.
>
> Known tool limitations: Apple unzip warns on a valid empty archive and ditto
> rejects it; Python emits identical empty ZIP bytes. Apple unzip also mangles
> Japanese display, so its listing is compared with an independent standard ZIP,
> while actual names are checked through bytes, 7-Zip, ditto and KaitoKit.
> Archive Utility and Windows Explorer have not been directly verified.
> Writing new encrypted entries, macOS metadata and other formats are
> future work. See the design and verification records linked above. MIT licensed.
