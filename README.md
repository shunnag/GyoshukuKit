# GyoshukuKit (凝縮Kit)

GyoshukuKit は macOS 向けの純 Swift 書庫**書き込み**フレームワークです。
読み取り専用の [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)と対をなします。

- 対象: macOS 26 以上、Swift 6、Apple Silicon
- 対応: ZIP / ZIP64 の新規作成・追加・削除・改名、stored / raw deflate (system zlib) / BZip2 (system libbz2) / LZMA (自前) / XZ (Apple Compression または自前) / PPMd var.I rev.1 (自前)
- 作成・全体再構築: tar / tar.gz / tar.bz2 / tar.xz / tar.lzma / tar.lz / tar.lz4 / tar.br / tar.Z / 7z（solid・BCJ / ARM64 / Delta を選択可能）/ LHA。暗号化出力: ZIP AES-256 / ZipCrypto、7z AES-256
- 更新: `TarUpdater` / `CompressedTarUpdater` / `LHAUpdater` / `SevenZipUpdater` で追加・削除・改名。未変更の member・圧縮区間を運び、圧縮 tar の変更区間と 7z solid の一部削除だけを再圧縮する。ZIP / 7z は再圧縮なしのパスワード設定・変更・解除にも対応
- 単独ファイルの圧縮: `SingleStreamCompressor` で .gz / .bz2 / .xz / .lzma / .lz / .lz4 / .br / .Z を新規作成
- 一括追加と進捗: `ArchiveAddition` と `add(_:events:)`、ディスク読取の byte 進捗、`finishAdditions(progress:)`、updater / rewriter の commit 進捗
- 依存: [KaitoKit](https://github.com/shunnag/KaitoKit) 0.12.x（0.12.0 以上、0.13.0 未満）。更新時の読取と往復検証に使用。`@_spi` は SemVer の保証外で、`public import KaitoKit` により公開 API にも KaitoKit の型を含むため、`.upToNextMinor(from: "0.11.0")` に限定する。`Package.swift` は隣に `../KaitoKit` の checkout があればその path 依存（開発用）、なければ tag 参照を選ぶ。SwiftPM / Xcode の `checkouts/` 配下（依存として取得された場合）では常に tag 参照。切り替わった後は `swift package purge-cache`（Xcode は File → Packages → Reset Package Caches）で manifest を再評価させる（`.build` の削除では manifest cache が残る）
- ライセンス: MIT

## インストール

GyoshukuKit 0.7.0 を Swift Package Manager で追加します。

```swift
.package(url: "https://github.com/shunnag/GyoshukuKit.git", .upToNextMinor(from: "0.7.0"))
```

利用側の target の dependencies に `.product(name: "GyoshukuKit", package: "GyoshukuKit")` を追加してください。
KaitoKit 0.12.0 → GyoshukuKit 0.7.0 → KaitoFinder 0.5.0 の順にリリースします。

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
| `compressionMethod` | `.deflate` | ZIP の `.stored` / `.deflate` / `.bzip2` / `.lzma` / `.xz` / `.ppmd` |
| `sevenZipMethod` | `.lzma2` | 7z の `.lzma2` / `.lzma` / `.deflate` / `.bzip2` / `.ppmd` / `.copy`。追加・再圧縮・7z への rewriter に適用 |
| `sevenZipSolid` | `.off` | `.on(blockSize:filesPerBlock:)` で入力順に非空ファイルを一つの folder にまとめる。nil は下記の既定上限 |
| `sevenZipFilter` | `.none` | `.auto` / `.bcjX86` / `.arm64` / `.delta(distance: 1...256)`。圧縮前の変換 |
| `lhaMethod` | `.lh5` | LHA の `.lh5` / `.lh6` / `.lh7` / `.stored`。新規追加・LHA への rewriter に適用。updater が運ぶ既存 member の byte は保持 |
| `lhaLevel` | `6` | LHA の探索量 `1...9`。既定の LH5 出力 byte は従来と同じ。stored は探索しない |
| `deflateLevel` | `6` | ZIP / 7z Deflate / tar.gz / 単独 gzip の zlib level `0...9` |
| `bzip2Level` | `9` | ZIP / 7z BZip2 / tar.bz2 / 単独 bzip2 の block size level `1...9`（100,000〜900,000 byte） |
| `ppmdLevel` | `6` | ZIP / 7z PPMd の order / model memory preset `1...9`。下表を参照 |
| `ppmdOrder` | `nil` | preset の order を上書き。ZIP は `2...16`、7z は `2...32` |
| `ppmdMemoryMiB` | `nil` | preset のモデルメモリを MiB 単位で上書き。ZIP は `1...256`、7z は encoder が対応する `1...1024` |
| `lzmaLevel` | `nil` | tar.xz / 7z LZMA2 / ZIP XZ は nil なら従来の Apple preset-6。`0...9` は自前 encoder。ZIP / 7z LZMA と tar.lzma / tar.lz は常に自前で nil は6。単独 XZ / LZMA / lzip も同じ解決 |
| `lzmaExtreme` | `false` | 自前 LZMA の探索量を増やす。tar.lzma / tar.lz / 単独 LZMA・lzip は nil でも使い、他はレベル指定時だけ |
| `memoryLimit` | `nil` | 自前 LZMA の作業メモリ上限（byte）。nil は物理メモリの50%。並列数を抑え、一つも入らなければ `invalidOption("memoryLimit")`。Apple 経路と他の codec には適用しない |
| `useCompressionHeuristic` | `true` | jpg/png/zip 等、既知の圧縮済み拡張子を stored にする |
| `preserveOwnerIDs` | `false` | true のときディスク由来の uid/gid を 0x7875 に保存 |
| `preserveMacOSMetadata` | `false` | true はこの段階では `unsupportedOption` |
| `password` | `nil` | ZIP / 7z の暗号化出力。空文字列は `invalidOption("password")` |
| `zipEncryption` | `.aes256` | WinZip AES-256。`.zipCrypto` は従来の PKWARE 暗号 |
| `encryptsSevenZipHeaders` | `false` | 7z のファイル名を含む header も暗号化。パスワードが必要 |
| `compressionThreads` | `nil` | ZIP deflate（ZipCrypto を除く）/ ZIP XZ / tar.gz / tar.bz2 / tar.lz / tar.lz4 / 7z LZMA2・Deflate / tar.xz / LHA の並列数 `1...64`。自前 LZMA2 と lzip はメモリ予算で実際の並列数を制限。単独 gzip / bzip2 / XZ / lzip / LZ4 も同じ設定。ZIP / 7z LZMA は同期。ZIP 再暗号化の鍵導出にも使用。自動は CPU 数・物理メモリ GiB・8 の最小値（最低1） |
| `additionPlacement` | `.end` | rewriter の追加位置。`.beginning` で従来の先頭追加 |
| `carriedTarOwnerIDs` | `.keep` | rewriter で運ぶ tar の uid/gid を維持。`.reset` で 0 にする。ディスクからの追加には `preserveOwnerIDs` を使用 |

ZIP の書き込み方式は次の六つです。updater の新規追加と ZIP への rewriter も同じ設定を使います。

| 方式 | method | encoder |
|---|---|---|
| `.stored` | 0 | 無圧縮 |
| `.deflate`（既定） | 8 | system zlib の raw deflate |
| `.bzip2` | 12 | system libbz2 の単一 bzip2 stream |
| `.lzma` | 14 | 自前の単一 raw LZMA1 stream、EOS 付き。展開要求 version 6.3 |
| `.xz` | 95 | Apple または自前 LZMA2 と XZFraming の完全な単一 XZ stream |
| `.ppmd` | 98 | 自前の単一 PPMd var.I rev.1 stream。2 byte parameter word、restoration は restart。展開要求 version 6.3 |

macOS Archive Utility / ditto と `/usr/bin/unzip` は method 12 / 14 / 95 / 98 を展開できません。
互換性のため Deflate を既定に保ち、BZip2 / LZMA / XZ / PPMd は KaitoKit や 7-Zip を使う場合の opt-in にします。
AES-256 では header の method は99、0x9901 に実際の12 / 14 / 95 / 98を記録します。ZipCrypto も圧縮後の byte を暗号化します。

7z の書き込み方式は `SevenZipCompressionMethod` で選びます。既定は非空ファイルごとに一つの non-solid folder です。

| 方式 | method ID | encoder |
|---|---|---|
| `.lzma2`（既定） | `21` | Apple または自前 LZMA2、dictionary property 1 byte |
| `.lzma` | `03 01 01` | 自前の単一 raw LZMA1 stream、EOS 無し。lc/lp/pb + 辞書 LE32 の5 byte properties |
| `.deflate` | `04 01 08` | system zlib の raw deflate、`deflateLevel` |
| `.bzip2` | `04 02 02` | system libbz2 の単一 bzip2 stream、`bzip2Level` |
| `.ppmd` | `03 04 01` | 自前の単一 PPMd var.H stream。order byte + model memory LE32 の5 byte properties |
| `.copy` | `00` | 無圧縮。入力 byte をそのまま保存 |

Copy / Deflate / BZip2 の coder に properties は置きません。7z は ZIP の拡張子 heuristic を使わず、
指定方式を全ての非空 stream に適用します。updater の追加と solid folder の再圧縮、7z への rewriter も
`sevenZipMethod` を使います。運ぶ既存 folder の coder と packed byte は保持し、AES の設定・変更・解除も再圧縮しません。
Deflate は最大1 MiBの block を直前の末尾32 KiBの辞書で圧縮し、一つの raw deflate stream に連結します。
LZMA / BZip2 / PPMd は folder ごとに一つの stream を同期で完結させ、Copy も同期出力します。
`maximumPendingInputBytes(for: .sevenZip)` は LZMA2 が `解決した並列数 × 片サイズ`、
Deflate が `compressionThreads × 1 MiB`、LZMA / BZip2 / PPMd / Copy が0です。BZip2 の codec state は最大約7.6 MBと I/O buffer です。

PPMd の preset は次の通りです。ZIP と7zで variant と order が異なります。

| `ppmdLevel` | ZIP var.I order | 7z var.H order | model memory（MiB） |
|---|---|---|---|
| 1 | 3 | 3 | 1 |
| 2 | 4 | 4 | 2 |
| 3 | 5 | 4 | 4 |
| 4 | 6 | 5 | 8 |
| 5 | 8 | 6 | 16 |
| 6（既定） | 8 | 6 | 16 |
| 7 | 10 | 8 | 32 |
| 8 | 12 | 12 | 64 |
| 9 | 16 | 16 | 192 |

`WriterOptions(compressionMethod: .ppmd, ppmdLevel: 9, ppmdOrder: 7, ppmdMemoryMiB: 3)` は
order 7・3 MiB の ZIP を書きます。7z は `sevenZipMethod: .ppmd` を使います。
モデルは ZIP の entry / 7z の folder ごとに一つ、solid では block 内の file 境界を越えて保持します。
指定した model memory と固定 I/O buffer を使い、入力長に比例してメモリを増やしません。
`compressionThreads` による片の並列化は行わず、`memoryLimit` は PPMd に適用しません。
モデルのメモリが尽きると restart します。AES・7z header 暗号化・全 filter を併用できます。
7zz の ZIP 一覧は `PPMd` のみを表示し、7z は `PPMD:o6:mem24` のように表示します。
`mem24` は2^24 byte、2の冪でない192 MiBは `mem192m` です。

`sevenZipSolid: .on()` は入力順を保ち、空ファイルと directory を件数・サイズに数えません。
サイズの既定上限は `min(4 GiB, max(64 MiB, 辞書 × 2))`、件数は1,000,000です。
Apple LZMA2 と他の方式の基準辞書は8 MiB、自前 LZMA / LZMA2 は選択 level の辞書、PPMd は model memory を使います。
ファイルは分割せず、上限を超えるものは単独の folder にします。全方式と AES・header 暗号化を併用できます。
一つの block の入力を出力の隣の unlink 済み一時ファイルへ流し、確定したサイズで圧縮します。
一時ディスク容量は最大 `max(blockSize, 最大ファイルサイズ)`、圧縮のメモリ上限は従来と同じです。
solid の `maximumPendingInputBytes` はメモリ使用量ではなく、disk 上に待つ一つの block のサイズ上限です。

`.auto` は先頭64 KiB内の magic / CPU を調べ、x86・x86_64 PE / 単一 Mach-O に BCJ、
arm64 PE / 単一 Mach-O / ELF64 に ARM64 を使います。universal Mach-O と未判定の入力は変換しません。
non-solid はファイル別、solid は filter の種別が変わるたびに block を区切ります。
filter の状態と命令位置は同じ folder のファイル境界を越えて続きます。Delta の距離は1〜256です。
updater の追加は設定に従う新しい folder を末尾へ置き、既存 folder の一部削除では元の filter と開始位置を保ちます。
既定の `.off` / `.none` の出力 byte は従来と同じです。

```swift
let options = WriterOptions(
    sevenZipSolid: .on(blockSize: 128 << 20, filesPerBlock: 10_000),
    sevenZipFilter: .auto
)
```

ZIP の空ファイル・ディレクトリ・symlink は常に stored です。通常ファイルの payload は
256 KiB 単位で読み書きし、作業メモリをファイルサイズに比例させません。central directory 用の
メタデータは entry 数と名前長に比例します。

ZIP deflate（ZipCrypto を除く）/ tar.gz は最大 1 MiB ごとに raw deflate を圧縮し、直前の末尾 32 KiB を辞書に使います。
ZIP Deflate の小さい member は個別の `add(contentsOf:as:)` 呼出し間でも並列化し、出力は追加順です。
ZIP BZip2 / PPMd は項目ごとに同期処理し、一つの stream を完結させます。ZIP XZ の既定は最大16 MiBの block を
`compressionThreads` で並列化し、一つの stream header・index・footer で包みます。一括 disk 追加も同じ経路です。
`maximumPendingInputBytes(for: .zip)` は LZMA / BZip2 / PPMd では0、XZでは `(解決した並列数 + 1) × 片サイズ` 以下です。
いずれの方式も項目の追加終了時には全て出力します。BZip2 の codec state は最大約7.6 MBと I/O buffer、
Apple XZ は thread ごとに約130 MiBと組立中16 MiBを使います。XZ の index は block 数に比例します。
tar.gz は従来の header を持つ単一 gzip member、tar.bz2 は最大 `5 × bzip2Level × 100,000` byte の
完全な bzip2 stream の連結です。通常の tar member は途中で切らず、先頭で gzip の同期点・bzip2 stream を区切り、
上限を越える member は header 群と本文を分けて片にします。tar の終端は独立した区切りです。
thread 数を変えても圧縮 byte 列は変わりません。
tar.xz は header 群・本文・詰め物を合わせて4 MiB以下の member を最大4 MiBの block に詰めます。
4 MiBを越える member は header 群と本文を別の block にし、本文と大きな header 群を片に分けます。
nil レベルは最大16 MiB、自前 encoder は下記の片サイズです。
tar の終端は独立した block です。既存書庫の編集では、変更した区間だけにこの規則を使います。
ZIP の暗号化では salt が毎回変わります。圧縮失敗は後続の `add` / `finish` で通知されることがあります。
ZIP deflate / tar.gz / tar.bz2 の未出力 chunk と組立中の入力は合計で最大 `compressionThreads` 個に抑えます。
Apple 経路の tar.xz の未出力 block は、並列数が2以上のとき64 KiB以下を並列数に数えず、合計で最大
`2 × compressionThreads + 1` 個です。並列数1は同時に一つだけを符号化します。
deflate / bzip2 の主なメモリは thread ごとに入力と出力（約2 × chunk size）と codec state、
Apple LZMA2 は16 MiBの片を使うと thread ごとに約130 MiBです。待機中の取消しは50 msごとに確認します。
Apple 経路の tar.xz の待機中の入力と組立中の入力の上界は `(compressionThreads + 1) × (16 MiBの片 + 64 KiB)` です。
この入力の上界は codec state と出力を含みません。小さなファイルの多い tar.xz は従来より5–12%大きくなります。
tar.bz2 の chunk は内部 block size の5倍です。level 9 は4,500,000 byteごとの独立streamとなり、
thread ごとの入力・出力約9 MBとcodec state約7.6 MBで合計約16.6 MB（約15.8 MiB）を使います。

ZIP のパスワードは UTF-8、7z は UTF-16LE を使います。ZIP は空ファイルも暗号化し、
ディレクトリと symlink は暗号化しません。AES は 20 byte 未満を AE-1（CRC あり）、
20 byte 以上を AE-2（CRC 欄は 0）で書き、作業ファイルを使わず stream に暗号化します。
ZipCrypto は CRC の確定が必要なので、出力の隣で mode 0600 の一時ファイルを排他的に作成し、
書込前に unlink した descriptor へ圧縮結果を spool します。暗号化してコピーした後や失敗時に
descriptor を閉じます。圧縮中に名前付きの平文 spool を残しません。

7z は非空 stream ごとに選択方式で圧縮してから AES-256-CBC を使い、Copy も暗号化できます。decoder 順は
packed → AES → 選択方式です。空ファイルは従来どおり
EmptyStream として保存します。header 暗号化は名前も隠します。既定の Apple LZMA2 の圧縮単位は最大 16 MiB、
読取・暗号化・書込は 256 KiB 単位です。Apple の 8 MiB 辞書を使い、16 MiB 以下のファイルは
従来の全体圧縮と同じ圧縮 payload になります。大きいファイルだけ 16 MiB 境界で辞書を reset します。
主な作業メモリは最大 16 MiB の入力とその圧縮出力です。

`WriterOptions(lzmaLevel: 9, lzmaExtreme: true)` は tar.xz / ZIP XZ / 7z LZMA2 の自前 encoder を選びます。
片ごとに辞書を reset し、辞書が16 MiBを超えるレベル8・9では xz の block size 規則に合わせて3倍の片を使います。
ZIP LZMA は entry ごと、7z LZMA は folder ごとに一つの stream を同期符号化し、片に分けません。
ZIP 14 は EOS と general purpose bit 1 を付けます。7z は folder の既知サイズを使い EOS を省略します。

自前 LZMA2 の実際の並列数 t は `t × (encoder memory + 2 × 片サイズ)` が
`min(memoryLimit（nil は物理メモリの50%）, 物理メモリの50%)` 以下になる最大数に制限します。
要求した並列数を上限とし、1個分も入らなければ書庫を作る前に `WriterError.invalidOption("memoryLimit")` を返します。
メモリ不足で宣言辞書を縮小しません。自前 tar.xz は小さい block も t 個の枠に数えます。
入力の上界は tar.xz が `t × 片 + 4 MiB`、7z が `t × 片`、ZIP XZ が `(t + 1) × 片` です。

| `lzmaLevel` | 辞書 MiB | LZMA2 encoder MiB | 片 MiB | LZMA2 1 thread の予算 MiB | raw LZMA1 の同期予算 MiB |
|---|---:|---:|---:|---:|---:|
| 0 | 0.25 | 5 | 16 | 37 | 20 |
| 1 | 1 | 10 | 16 | 42 | 25 |
| 2 | 2 | 17 | 16 | 49 | 32 |
| 3 | 4 | 31 | 16 | 63 | 46 |
| 4 | 4 | 47 | 16 | 79 | 62 |
| 5 / 6 | 8 | 91 | 16 | 123 | 106 |
| 7 | 16 | 179 | 16 | 211 | 194 |
| 8 | 32 | 355 | 96 | 547 | 370 |
| 9 | 64 | 643 | 192 | 1027 | 658 |

64-bit の通常 preset を MiB 単位で切り上げた値です。extreme のレベル0〜3は BT4 に替わり、
それぞれ1 / 4 / 8 / 16 MiB増えます。raw LZMA1 の予算は range buffer の最大16 MiBと I/O を含みます。
短い入力では encoder の実確保が減りますが、検証・並列数解決は表の完全な辞書で行います。
Apple の nil レベル経路は従来の byte と16 MiB境界を維持し、この予算で並列数を変えません。

LHA は `WriterOptions(lhaMethod: .lh7, lhaLevel: 9)` のように方式と探索量を選べます。
`.lh5` / `.lh6` / `.lh7` は8 / 32 / 64 KiB辞書を使い、縮まないファイルは `-lh0-` にします。
`.stored` は圧縮を試さず全ファイルを `-lh0-` で逐次保存します。ディレクトリは常に `-lhd-`、名前はCP932です。
圧縮する場合は1 MiBまでのmemberをメモリで処理し、それより大きいmemberは1 MiB入力と方式ごとの辞書履歴で
分割します。block間のbitを継続し、同じ設定なら逐次・並列の出力byteは一致します。

| `lhaLevel` | 一致探索の候補数（chain depth） | 探索 |
|---|---|---|
| 1 / 2 / 3 | 8 / 16 / 32 | 貪欲 |
| 4 / 5 / 6（既定） | 64 / 128 / 256 | 貪欲 |
| 7 | 512 | 貪欲 |
| 8 / 9 | 1024 / 2048 | 1 byte先に長い一致があればliteralを先に置くlazy matching |

最大一致長は全levelで256 byte、Huffman blockは32,768 commandです。level6は従来の探索を維持します。
64-bit環境でthreadごとの主なbufferは入力1 MiB + 履歴8 / 32 / 64 KiB、hash表512 KiB、
chain表64 / 256 / 512 KiB、command表512 KiBと圧縮出力約1.1 MiBで、合計の目安は約3.2 / 3.4 / 3.7 MiBです。
Foundationの一時コピー・Huffman木の作業領域は別に必要です。storedは通常のI/O bufferだけを使います。
`maximumPendingInputBytes(for: .lha)` は圧縮並列数 `t > 1` のとき `t × (1 MiB + 辞書履歴)`、
逐次またはstoredなら0です。出力・codec表はこの入力byte数に含みません。

圧縮候補は作成直後unlinkするmode0600のspoolへ書き、raw bytesは未完成出力に保持します。
作業用ディスクには一時的にraw bytesと圧縮候補の空きが必要です。取消し・途中失敗・容量不足時は
spoolを閉じ、未完成出力を無効化して削除します。256 MiB入力でのwriter単体peak RSSは約14 MiBでした。
再現できる測定条件と限界は[横断検証](Documentation/verification/2026-09-17-release-hardening.md)に記録します。
方式の辞書サイズと最大一致長は [LHa for UNIX header.doc](https://github.com/jca02266/lha/blob/master/header.doc.md)、
methodの対応と検査・抽出コマンドは [Lhasa 利用者文書](https://github.com/fragglet/lhasa/blob/master/doc/lha.1) を参照します。
tar（全8圧縮形式を含む）/ LHA のパスワード指定は `unsupportedOption("password")`、
パスワードなしの header 暗号化指定は `invalidOption("encryptsSevenZipHeaders")` です。

新規追加・改名・`ArchiveRewriter` の再出力名は、全形式で NFC へ正規化します。
空の名前・絶対パス・`.` / `..`・空の成分・NUL・
UTF-8 で 65,535 byte を超える出力名・NFC 正規化後の重複・file と子の衝突は拒否します。
`\` / `:` は Windows 向けの ZIP / 7z / LHA 出力で拒否します。
tar（全8圧縮形式を含む）では両文字を名前の一部として許可します。
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

tar.xz はレベル未指定時に Apple Compression、tar.bz2 は macOS の libbz2 をプロセス内で使います。
TarWriter の 256 KiB の入力をストリーム圧縮し、書庫全体をメモリへ保持しません。
XZ は `lzmaLevel: 0...9` の自前経路、bzip2 は `bzip2Level: 1...9` を選択できます。
所有者・リンク・タイムスタンプ・取消し・失敗時の cleanup は通常の tar と共通です。

## 新しい圧縮 tar と単独ファイル

`ArchiveFormat` の `.tarLZMA` / `.tarLzip` / `.tarLZ4` / `.tarBrotli` / `.tarCompress` は、
通常の `TarWriter` の出力を次の framing で包みます。拡張子はライブラリが決めず、呼出側が指定します。

| 形式 | framing と分割 | レベル |
|---|---|---|
| tar.lzma | 13 byte の LZMA_Alone header（未知サイズ）と EOS、逐次単一 LZMA1 stream | `lzmaLevel` 0...9、nil は6、extreme 対応 |
| tar.lz | lzip v1 の独立 member。tar member 境界を優先し、最大 `max(16 MiB, 3 × 辞書)`、終端は独立 member。CRC32・入力長・member 長を照合できる | `lzmaLevel` 0...9、nil は6、extreme 対応 |
| tar.lz4 | content checksum 付き単一 LZ4 frame、4 MiB の独立 block を並列化 | 単一レベル |
| tar.br | Apple Brotli の逐次単一 stream | Apple の固定 level 2、指定なし |
| tar.Z | block mode LZW、maxbits 16、逐次単一 stream | 指定なし |

lzip の並列数は `t × (raw LZMA1 encoder memory + 2 × member 上限)` が
`min(memoryLimit（nil は物理メモリの50%）, 物理メモリの50%)` 以下になるよう制限します。
既存の LZMA 経路と同じく、辞書を縮めず、一つも入らなければ `invalidOption("memoryLimit")` を返します。
level 0 / 6 / 9 の member 上限は16 / 24 / 192 MiBです。
`maximumPendingInputBytes(for:)` の入力上界は lzip が `t × member 上限`、LZ4 が `t × 4 MiB`、
LZMA_Alone / Brotli / compress は0です。codec 内部の辞書・bufferと出力はこの値に含みません。

`CompressedTarUpdater` の splice は tar.gz / tar.bz2 / tar.xz に限ります。
新しい5形式は `assess(reader:)` が nil、`open` が `UpdaterRouteError.requiresRewrite` を返します。
`ArchiveRewriter` は読み取れる書庫から各新形式へ変換でき、削除・改名・追加は全体を再符号化して反映します。

```swift
let editor = try ArchiveRewriter.open(url: archiveURL, format: .tarLzip)
try editor.rename(entryAt: 0, to: "新しい名前.txt")
try editor.add(data: Data("追加\n".utf8), as: "new.txt")
try editor.commit()

let progress = Progress(totalUnitCount: 0)
try SingleStreamCompressor.compress(
    file: sourceURL, to: compressedURL, format: .gzip,
    options: WriterOptions(deflateLevel: 6), progress: progress
)
```

`SingleStreamFormat` は `.gzip` / `.bzip2` / `.xz` / `.lzma` / `.lzip` / `.lz4` / `.brotli` / `.compress`。
通常ファイル一つを新規圧縮する create-only API で、directory と symlink は
`WriterError.unsupportedFileType` で拒否します。複数 source は呼出側で tar.X にまとめ、編集は扱いません。
宛先と同じ directory の一時 file に圧縮を完了し、排他的 rename で公開します。既存出力は上書きせず、
失敗・Task cancellation・`Progress.cancel()` では自分の一時 file を削除します。
`progress` の total は入力長、completed は読取 byte 数で、圧縮完了より先に total に達することがあります。

gzip は1 MiB block、bzip2 は `5 × level × 100,000` byte の独立 stream、XZ は通常16 MiBの block
（自前の大辞書では3 × 辞書）、lzip は上記の独立 member、LZ4 は4 MiB blockを並列化します。
レベルは tar の対応形式と同じ設定を使います。単独 gzip も tar.gz と同じく FNAME なし、MTIME 0、OS=3です。
ファイル名や日時を stream に保存しません。空 .Z は仕様上 header のみで、BSD uncompress / gzip が拒否する
既知の制限があります。KaitoKit と7zzは空を復元できます。

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

新形式の試験には `/opt/homebrew/bin/lzip`・`lz4`・`brotli`・`xz` と、macOS の
gzip / bzip2 / uncompress / bsdtar も使います。テストには `/usr/bin/unzip`、`/opt/homebrew/bin/7zz`、`/usr/bin/ditto`、
`/usr/bin/tar`、`/usr/bin/python3`、`/usr/bin/cmp` が必要です。参照ツールが欠けていれば試験は失敗し、skip しません
（名前に `WhenAvailable` を含む試験だけが例外。[Tests/README.md](Tests/README.md) の「外部ツールが無いとき」）。
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
> GyoshukuKit 0.7.0 depends on KaitoKit 0.12.x through `.upToNextMinor(from: "0.12.0")` for update reading and round-trip verification. Its SPI use falls outside SemVer guarantees, and `public import KaitoKit` exposes KaitoKit types in the public API. `Package.swift` uses the sibling `../KaitoKit` checkout by path when one exists (development) and the tag reference otherwise, always the tag inside a SwiftPM / Xcode `checkouts/` directory. Run `swift package purge-cache` (Xcode: Reset Package Caches) after the mode changes; deleting `.build` keeps the cached manifest.
> Creation and full rewriting also support tar, tar.gz, tar.bz2, tar.xz, 7z and LHA. 7z supports optional solid blocks and BCJ / ARM64 / Delta filters.
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
> tools are listed above; a missing tool fails the test instead of skipping it, except
> for tests named `...WhenAvailable` (see Tests/README.md for the policy, the test layout and
> the `GYOSHUKU_*` environment variables).
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
