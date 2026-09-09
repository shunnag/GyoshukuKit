# 変更履歴

注目すべき変更を記録する。バージョニングは Semantic Versioning に従う。

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
