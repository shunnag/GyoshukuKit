# GyoshukuKit 設計書(2026-09-10 初版)

## 1. 位置づけ

解凍(KaitoKit)と凝縮(GyoshukuKit)を対にする。KaitoKit が読み取り専用で
あることは意図的な設計であり、書き込みをそこへ足すと、読み取りしか必要としない
利用者(cooViewer など)にまで writer の byte が届いてしまう。別リポジトリに
することで、その影響を文言ではなく構造として断つ。

KaitoKit と同じ性格を引き継ぐ。

- 純 Swift。外部依存なし。zlib、libbz2、Apple Compression だけをサポートされた
  形で使う。システムの libarchive は使わない —— SDK に `archive.h` が無く
  (実測)、prototype を手書きして依存するのは性格に合わない。加えて libarchive
  には in-place update が無く、書庫内編集のためにどのみち自前の updater が要る。
- 攻撃者が制御する値は読んだ場所で検証する。書く側でも同じで、宣言サイズや
  entry 数を信用して確保しない。
- 実装の正しさは**参照実装との差分テスト**で担保する。書いたものを `unzip -t`、
  `7zz t`、`bsdtar` で読み、さらに **KaitoKit で読み直す往復**を必ず行う。
  解凍と凝縮が対である以上、この往復が最も素直な回帰テストになる。

## 2. 依存の向き

```
GyoshukuKit ──依存──> KaitoKit
```

一方向だけ。KaitoKit は GyoshukuKit を知らない。

書庫の**更新**(追加・削除・改名)は、生き残る entry を再圧縮せずに運ぶために
既存書庫を読む必要がある。その堅い parser は KaitoKit が既に持っているので、
二つ目の ZIP parser は書かない。開発中は `.package(path: "../KaitoKit")`、
release では tag 参照へ切り替える。

## 3. API の形

KaitoKit の `ArchiveReader` と対称にする。

```swift
// 新規作成
let writer = try ArchiveWriter.create(url: destination, format: .zip, options: WriterOptions())
try writer.add(contentsOf: sourceURL, as: "docs/readme.txt")
try writer.addDirectory("docs/")
try writer.finish()

// 既存 ZIP への追加(段階 1 後半)
let updater = try ArchiveUpdater.open(url: archive)   // 内部で KaitoKit の reader を使う
try updater.add(contentsOf: fileURL, as: "new.txt")
try updater.add(data: Data("追加".utf8), as: "memo.txt", modificationDate: nil, permissions: nil)
try updater.addDirectory("empty/")
try updater.commit()        // clone を完成させて atomic replace
// remove / rename は段階 3。KaitoKit の rawRecord accessor 追加後に実装する。
```

`ArchiveWriter` / `ArchiveUpdater` は thread-safe にしない。KaitoKit と同じく、
一つの instance の操作は呼出側が直列化する。値型の設定は `Sendable` にする。

`WriterOptions` は圧縮方式と level、暗号化、名前の encoding、timestamp の
粒度、macOS metadata を書くかどうかをまとめる。既定値は「相手が Windows でも
困らない」側に倒す(§5)。

## 4. 形式ごとの段階

| 段階 | 形式 | 作成 | 追加 | 削除・改名 |
|---|---|---|---|---|
| 1 | ZIP / ZIP64 | ○ | ○(旧 CD の byte をそのまま運ぶ) | 段階 3(新しい KaitoKit accessor が必要) |
| 2 | tar | ○ | ○(末尾の zero block の手前へ) | ○(作り直す) |
| 2 | tar.gz / .bz2 / .xz | ○ | × | × |
| 3 | 7z | ○(non-solid・非暗号) | 作り直し | 作り直し |
| 4 | LHA / LZH | ○(`-lh5-`) | ○ | ○ |
| — | RAR | × license が禁じる | × | × |
| — | CAB / RPM / ISO / xar | × | × | × |

圧縮 tar に増分更新が無いのは形式の性質で、毎回 展開 → 変更 → 再圧縮になる。
UI 側は進捗と取り消しを必ず出す。

## 5. 既定値の方針

- ZIP は general purpose **bit 11** を立てて UTF-8 名を書き、NFC へ正規化する。
  既存の CP932 書庫を更新するときは、既存 entry の名前バイトと flag を
  **そのまま**運ぶ(混在は正当)。
- ZIP の `version made by` は host 3 (UNIX)。でないと POSIX mode と symlink が
  尊重されない。
- data descriptor は**書かない**(seek して local header を patch する)。ただし
  **読む側は必須** —— `ditto` は deflate entry すべてに bit 3 を立てる。
- tar は macOS metadata(`._` AppleDouble、`SCHILY.xattr`)を**既定で書かない**。
  Apple の bsdtar は既定で書き、それが Mac 製書庫が Windows で嫌われる主因。
- uid/gid は既定 0、uname/gname は空。作者のアカウント名を書庫へ入れない。
- 圧縮は zlib の deflate、既定 level 6(Info-ZIP と同じ)。Apple の Compression
  framework は `COMPRESSION_ZLIB` が level 5 相当に固定で選べない(実測)。

## 6. 更新の安全性

### 段階 1 の追加

1. 同一ボリュームの `.itemReplacementDirectory` へ **APFS clone** する
   (`FileManager.copyItem`。実測 300 MB で 0.002 s)。最初の add まで遅延する。
2. clone の旧 CD offset から新しい local record を書く。既存の local record は
   元の位置のままであり、再圧縮も descriptor の探索も行わない。
3. 原本の開いた descriptor から **旧 CD の byte をそのまま**コピーし、新しい CD を
   続ける。旧 local offset が動かないので、旧 CD の再符号化や部分修正は不要。
   旧 entry 数・CD size・CD offset を合算した EOCD を作り、必要なら ZIP64 EOCD と
   locator を新たに書く。旧 ZIP コメントも保持し、末尾を truncate・同期する。
4. `FileManager.replaceItemAt` で差し替え、**直後に POSIX permission を復元**する
   (実測:replacement 側の mode が勝つ)。`replaceItemAt` は Finder tag と
   xattr と作成日は保つが `com.apple.quarantine` は落とすので、付いていれば戻す。

原本は一度も in-place 編集しない。commit 前の失敗・破棄では clone を削除する。
成功後の commit は no-op。失敗後の instance は再利用できない。原本の inode・size・
mtime・ctime・mode が open 時と変わった場合は置換を拒否する。ただし排他 lock は取らず、
同一書庫への他プロセスの操作も呼出側で直列化する。
置換後の metadata 復元が失敗した場合はエラーを返すが、内容の置換は既に完了している。

### 段階 3 の削除・改名(未実装)

生き残る local record 全体を新しい位置へ運ぶには、KaitoKit の rawRecord accessor が
必要になる。local と central の extra field 長は異なるので local を CD から再構成しない。
この場合は offset が動き、ZIP64 extra も増減するため CD を再構成する。
追加だけにこの再構成や descriptor 探索を持ち込まない。

### 編集を断る三つの門番

読み取りは従来どおり行い、**編集だけ**を断る。理由を呼出側へ返す。

- **SFX prefix 付き ZIP** —— prefix があると central directory の offset 基準がずれる。
- **EOCD の後ろに trailing data がある ZIP**。
- **`EOCD.cdOffset` が `PK\x01\x02` を指さない ZIP** —— 実測で見つけた実在の罠。
  `ditto`(Finder の「圧縮」)は 4 GiB 超の entry を ZIP64 なしで書き、
  uncompressed size / compressed size / EOCD の CD offset を mod 2^32 で切る。
  その状態で data descriptor を算術で探すと deflate stream の途中を指し、
  編集が静かに壊す。詳細は KaitoFinder の
  `Documentation/verification/2026-09-10-ditto-zip64.md`。

## 7. KaitoKit へ必要な追加

削除・改名で生き残る entry を再圧縮せずに運ぶには、生 record の範囲が要る。
`ZipReader` は `localHeaderOffset` / `dataOffset` / `compressedSize` を private に
持っているため、追加の公開 API が必要になる。

```swift
public struct RawEntryRecord: Sendable {
    public let recordRange: Range<UInt64>   // そのまま運ぶ範囲(data descriptor 含む)
    public let payloadRange: Range<UInt64>  // 検証用。圧縮データ本体だけ
    public let formatSpecific: [String: String]
}
public func rawRecord(of entry: ArchiveEntry) throws -> RawEntryRecord?
```

**終端の算出は KaitoKit にやらせる**のが要点。ZIP の data descriptor は
signature の有無と ZIP64 かどうかで 0 / 12 / 16 / 20 / 24 byte と変わる。
呼ぶ側にこの算術をやらせると writer と reader で解釈がずれる。

これは段階 1 の**追加**では不要で、**削除・改名**に入るときに必要になる。
それまで KaitoKit には触れない。

## 8. やらないこと

- **RAR の作成**。license が
  「cannot be used to develop RAR (WinRAR) compatible archiver」と明示している。
- **SFX の作成**。macOS では成立しない —— data を追記した Mach-O は正しく署名
  できず、ad-hoc 署名の実行ファイルは Gatekeeper に拒否され、quarantine が付けば
  Apple Silicon では SIGKILL される。作っても相手の Mac で動かない。
- **sparse file の検出**。bsdtar は自動で行うが、結果は改名された entry と
  GNU.sparse.* pax record で、規約を知らない reader を混乱させる。GUI 利用者が
  踏むことはまず無い割に writer の複雑さがほぼ倍になる。

> **GyoshukuKit design (2026-09-10, first edition)**
>
> GyoshukuKit is the compression half of a pair whose extraction half is KaitoKit.
> KaitoKit is read-only by design, and adding writing to it would push writer code
> into consumers that only ever read; a separate repository makes that separation
> structural rather than asserted. It inherits KaitoKit's character: pure Swift,
> no external dependencies, only OS-bundled zlib, libbz2 and Apple Compression
> through supported APIs — deliberately not the system libarchive, which ships no
> `archive.h` in the SDK and has no in-place update anyway.
>
> The dependency runs one way only, GyoshukuKit to KaitoKit, because updating an
> archive means reading the existing one to carry surviving entries across without
> recompressing them, and KaitoKit already has the hardened parser for that.
>
> The API mirrors `ArchiveReader`: an `ArchiveWriter` for creation and an
> `ArchiveUpdater` for add, remove and rename, committed through a temporary file
> and an atomic replace. Neither is thread-safe, matching KaitoKit's contract.
>
> Formats arrive in four stages — ZIP, then tar and the compressed tars, then 7z,
> then LHA. Compressed tars support no incremental update at all, which is a
> property of the format, so every change is a full decompress-modify-recompress.
>
> Defaults are chosen so a recipient on Windows is not inconvenienced: UTF-8 names
> with bit 11 and NFC normalization, UNIX host byte so POSIX modes and symlinks
> survive, no data descriptors written but always parsed because `ditto` emits
> them, no macOS metadata in tar by default, and no owner names leaked.
>
> Stage-one append clones the archive with APFS, leaves old local records at
> their original offsets, writes new local records at the old CD offset, then
> copies the old CD bytes verbatim and emits the new CD and combined end records.
> ZIP64 appears whenever the combined values require it. No descriptor scanning
> or existing-name re-encoding is needed. Commit uses `replaceItemAt`, immediately
> restores POSIX permissions and restores quarantine when originally present.
> Remove/rename and their CD reconstruction are deferred to stage three.
> Editing is refused — while reading still works — for SFX-prefixed ZIPs, ZIPs
> with trailing data after the EOCD, and ZIPs whose declared central-directory
> offset does not point at a `PK\x01\x02` signature, the last being a measured
> trap: `ditto` writes entries above 4 GiB with no ZIP64 at all and truncates
> three separate values mod 2^32.
>
> Remove and rename will need one additive KaitoKit accessor, `rawRecord(of:)`,
> exposing the byte range of an entry's stored record with the data-descriptor
> arithmetic done on KaitoKit's side so writer and reader cannot disagree. Stage
> one does not need it, so KaitoKit stays untouched until then.
>
> Three things are deliberately never done: writing RAR, whose licence forbids it;
> creating self-extracting archives, which cannot be validly signed on macOS and
> would be killed by Gatekeeper on the recipient's Mac; and sparse-file detection,
> which roughly doubles writer complexity for a case a GUI archiver's users
> essentially never hit.
