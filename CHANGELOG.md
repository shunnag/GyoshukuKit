# 変更履歴

注目すべき変更を記録する。バージョニングは Semantic Versioning に従う。

## [0.3.0] - 2026-09-10

### 追加

- `ArchiveUpdater.remove(entriesAt:)` と `rename(entryAt:to:)`。open 時の index で予約し、
  追加と同じ commit で atomic replace する。子孫の削除・改名は呼出側が明示する。
- KaitoKit 0.4.0 の `rawRecord(of:)` による ZIP / ZIP64 の再構築。生き残る local record と
  descriptor を再圧縮せず運び、改名時だけ local / central の名前を UTF-8 / NFC / bit 11 で更新。
  同長の local 名は同じ位置で patch し、異長なら header を再出力して payload をコピーする。
- 全 CD の再出力と、size / compressed size / offset / count ごとの ZIP64 増減。
  未変更 entry の名前 byte・flag・extra・comment・属性を保持し、旧 Unicode Path override は
  改名時に無効化する。削除で空になった ZIP は通常の EOCD だけになる（ZIP コメントは保持）。
- 範囲外 index、予約済み名との衝突、危険な改名を拒否する。移動できない entry は
  `nonRelocatableEntry` で理由を返し、途中失敗・Task cancellation・未 commit の破棄で原本を保つ。
- 既存の三門番、APFS clone、mode / quarantine 復元、原本変更検知を維持。
  追加と再構築の混在時は完成した clone の snapshot から読み、読取元の上書きを避ける。
- 実ツールによる削除・改名、CP932、ditto descriptor、symlink、metadata、空 ZIP の往復。
  65,536 → 65,533 → 65,536 件と、実際の local offset 4 GiB 境界越え・削除による縮小も検証。

### 範囲と制限

- KaitoKit / KaitoFinder は変更しない。依存は引き続きローカル `../KaitoKit`（0.4.0）。
- ZIP32 descriptor の entry に移動先の ZIP64 offset が新たに必要になる場合は拒否する。
  KaitoKit 0.4.0 が offset 用 extra でも descriptor を wide と解釈するため、原本を保って理由を返す。
- 空 ZIP・旧文字コード表示・特殊な descriptor に対する Apple ツールの制限と、
  実行環境の制約は[検証記録](Documentation/verification/2026-09-10-zip-delete-rename.md)に記載。

> **Added — 0.3.0 (2026-09-10)**
>
> ArchiveUpdater queues deletion and renaming by stable indices from open, and commits them
> together with additions. KaitoKit 0.4.0 raw records carry surviving payloads and descriptors
> without recompression. Renames update both headers to UTF-8/NFC with bit 11; unchanged names
> and flags retain their original bytes. The entire CD is rebuilt with independent ZIP64 fields.
> Invalid indices, unsafe names, conflicts and non-relocatable records are rejected. Existing
> gatekeepers, atomic replacement, metadata restoration and source-change detection remain.
> Cancellation and failures preserve the original. Real-tool tests cover CP932, ditto descriptors,
> symlinks, metadata, empty archives, count transitions in both directions and actual local offsets
> crossing 4 GiB. Neither reference repository is modified. Tool and environment limits are
> documented in the linked verification record. A ZIP32 descriptor gaining a ZIP64 offset is
> refused because KaitoKit 0.4.0 would reinterpret its descriptor width.

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
