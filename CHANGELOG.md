# 変更履歴

注目すべき変更を記録する。バージョニングは Semantic Versioning に従う。

## [0.2.0] - 2026-09-10

### 追加

- `ArchiveUpdater.open(url:)`、`add(contentsOf:as:)`、`add(data:as:modificationDate:permissions:)`、
  `addDirectory`、`commit` による既存 ZIP / ZIP64 への追加。writer の出力処理を共有する。
- 旧 local record は移動せず、旧 CD は byte 単位で保持する。CP932 の名前や flag、
  data descriptor を再解釈・再符号化しない。新 entry は UTF-8 / NFC / bit 11。
- SFX prefix、EOCD 後の trailing data、不正な CD offset を、門番 ID と理由文字列で拒否する。
- 同一 volume の replacement directory で clone を更新し、atomic replace の直後に
  POSIX mode と quarantine を復元する。失敗・破棄時は clone を削除し、原本の変更を検出する。
- 合算した count / CD size / CD offset に従う ZIP64 終端、ZIP コメント保持、既存名との衝突検査。
- 実ツールと KaitoKit の回帰検証。65,530 + 10 件の ZIP64 移行と既存 ZIP64 への再追加、
  ditto の bit 3、Info-ZIP、Python 製 CP932、mode / quarantine / tags / xattrs / 作成日を検査する。

### 範囲と制限

- 削除・改名は段階 3。KaitoKit と KaitoFinder は変更しない。
- Apple unzip と macOS 版 7zz の旧文字コード表示には制限がある。内容検査、旧 name byte、
  KaitoKit と ditto の日本語名往復は成功。[検証記録](Documentation/verification/2026-09-10-zip-updater.md)。

> **Added — 0.2.0 (2026-09-10)**
>
> ArchiveUpdater adds entries to existing ZIP/ZIP64 archives through the writer's
> shared emitters. Existing local records remain in place and the old central
> directory is copied byte-for-byte, preserving CP932 names, flags and descriptors.
> Three named gatekeepers refuse SFX prefixes, trailing data and invalid declared
> CD offsets. Updates use a same-volume clone, atomic replacement, immediate mode
> restoration and quarantine restoration, with source-change detection and cleanup.
> Combined end records introduce ZIP64 as necessary; comments and path conflict
> checks are preserved. Real-tool tests include ditto, Info-ZIP, clean-room CP932,
> the 65,530 + 10 count transition and a subsequent ZIP64 update, plus metadata.
> Deletion/renaming remain stage three; neither reference repository is modified.
> Legacy-name display limitations are recorded separately from byte integrity and
> successful Japanese-name round trips through KaitoKit and ditto.

## [0.1.0] - 2026-09-10

### 追加

- `ArchiveWriter.create`、`add(contentsOf:as:)`、`addDirectory`、
  `add(data:as:modificationDate:permissions:)`、`finish` による ZIP / ZIP64 新規作成。
- system zlib の raw deflate と CRC-32。圧縮 level 0...9、既定 6、stored 選択と
  拡張子による圧縮方式の判断。通常ファイルは 256 KiB 単位のストリーム処理。
- UTF-8 / NFC / bit 11、UNIX host 3、POSIX mode、ディレクトリの DOS 0x10、
  `lstat` による symlink の保存。timestamp extra は local 9 byte / central 5 byte。
- local header を seek で確定し、descriptor を書かない。ZIP64 は central / EOCD の
  各欄を独立判定し、local の例外では両サイズと両 sentinel を使う。
- 所有者 ID の opt-in 保存。macOS metadata は既定で省略し、保存指定は未対応エラー。
- 新規出力限定、パスと名前衝突の検証、失敗後の writer 再利用拒否。
- XCTest による生バイト検査、unzip / 7zz / ditto / bsdtar との差分、KaitoKit の
  全 entry 往復。4 GiB 超と 65,536 entry を通常テストに含めた。

### 検証上の制限

- 空 ZIP に対する Apple unzip の警告と ditto の拒否、日本語の unzip 表示の崩れは
  独立した Python ZIP でも再現。Archive Utility / Windows Explorer は直接未検証。
- 既存書庫の更新は次段階。[検証記録](Documentation/verification/2026-09-10-zip-writer.md)。

> **Added — 0.1.0 (2026-09-10)**
>
> ZIP/ZIP64 creation through ArchiveWriter, with stored/system-zlib raw deflate,
> configurable levels (default 6), an extension heuristic and streaming file I/O.
> Supports UTF-8/NFC, UNIX modes, lstat-based symlinks, distinct local/central
> timestamp extras and seek-patched headers without descriptors. Central/EOCD
> ZIP64 sentinels are independent; the local exception uses both sizes and both
> sentinels. Owner IDs are opt-in; requesting macOS metadata returns an explicit
> unsupported error. Existing output files, unsafe paths and conflicting names
> are rejected, and writer failures are terminal.
>
> XCTest validates bytes and compares real unzip, 7zz, ditto, bsdtar and KaitoKit,
> including every byte above 4 GiB and all 65,536 entries. Apple tools have known
> empty-ZIP/Japanese-display limitations reproduced with independent Python ZIPs.
> Archive Utility and Windows Explorer remain directly unverified. Updating
> existing archives is deferred to the next milestone.
