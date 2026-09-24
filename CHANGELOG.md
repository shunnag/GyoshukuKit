# 変更履歴

注目すべき変更を記録する。バージョニングは Semantic Versioning に従う。

## [Unreleased]

## [0.5.0] - 2026-09-24

### 修正

- ZIP の EOCD disk 欄・巻内 entry 数の検査を、終端の曖昧性検査の直後、SFX prefix と trailing data の検査より前に移す。
  native 分割 ZIP の最終巻に local header がなくても、`ArchiveUpdater.probe` / `open` は
  `UpdaterError.invalidArchive("分割 ZIP は編集できません")` で拒否する。既存の `UpdateGatekeeper` は変更しない。

### 変更

- KaitoKit の最低依存バージョンを 0.10.0 に更新する（`ArchiveRewriter.volumeSet` が使用する
  `ArchiveReader.volumeSet` / `ArchiveVolumeSet` を含む版）。
  隣接 checkout の path 依存自動選択は維持する。

### 追加

- `ArchiveRewriter.volumeSet`。open 時に内部の KaitoKit reader が組み立てた巻と同一性を返し、単一ファイルでは nil になる。
  `checkUnchanged` は URL 自身のファイルだけを検査するため、分割セットの編集を再生する前に呼出側が記録した同一性と照合する。
- 分割 ZIP の最終巻と trailing data がある分割 ZIP の拒否理由、7z / tar の 3 巻バイト分割の inode、
  単一ファイル（兄弟巻のない `.001` を含む）の `volumeSet` を検証する回帰テストを追加する。
- 分割 ZIP の拒否順と `ArchiveRewriter.volumeSet` の検証結果を
  [検証記録](Documentation/verification/2026-09-23-split-zip-gatekeeper.md)に記載する。

## [0.4.2] - 2026-09-22

### 修正

- KaitoKit 0.8.0 で AppleDouble sidecar の既定方針が `.merge` になったことに対応し、
  updater の入力・追加後の reader と rewriter の入力 reader に `appleDoublePolicy: .expose` を明示する。
  書庫に格納された entry 一覧と index を保ち、Finder 製 ZIP の entry 数・offset 不一致による編集拒否、
  再構築時の sidecar 消失や resource fork の擬似 entry の書き出しを防ぐ。
- `ArchiveRewriter` の表現可能性検査と `probe(entries:format:)` は、
  `formatSpecific["fork"] == "resource"` の擬似 entry を `RewriterError.unrepresentable` で拒否し、
  reader を `.expose` で開くよう案内する。

### 変更

- KaitoKit の最低依存バージョンを 0.8.1 に更新する（0.8.0 の `appleDoublePolicy` 対応に加え、0.8.1 のリリースレビュー修正 R1〜R14 を含む版）。
  隣接 checkout の path 依存自動選択は維持する。

### 追加

- Finder 製 ZIP の削除・追加と同時 commit、macOS tar の sidecar 名・本文の SHA-256 保持、
  merge 済み一覧の擬似 entry 拒否を検証する4件の回帰テストを追加する。
  KaitoKit 由来の fixture をリポジトリ内に複製し、隣接 checkout がなくても参照できるようにする。
- `.expose` を一時的に外した ZIP の失敗再現と、修正後のビルド・全件テストを
  [検証記録](Documentation/verification/2026-09-22-appledouble-expose.md)に記載する。

## [0.4.1] - 2026-09-20

### 修正

- 0.4.0 の `Package.swift` は、利用側が SwiftPM で取得したときも `checkouts/` に並ぶ KaitoKit を隣の
  開発用 checkout と見なして path 依存を選び、`swift package resolve` が
  `exhausted attempts to resolve the dependencies graph` で失敗した。親ディレクトリが `checkouts` の場合は
  常に tag 参照にする。root として使う場合の挙動（隣があれば path）は変えない。
- 切り替え手順の記述を修正: `.build` の削除では manifest cache が残るため、`swift package purge-cache`
  （Xcode は Reset Package Caches）を使う。

## [0.4.0] - 2026-09-19

最初の tag 付きリリース。0.1.0〜0.3.0 は CHANGELOG 上の区切りで、tag は打っていない。
`Package.swift` の KaitoKit 依存は、隣に `../KaitoKit` の checkout があればその path（開発用）、なければ
KaitoKit 0.7.0 の tag 参照を選ぶ（design.md §2）。tag 参照を root と隣の path 依存の両方から解決すると
SwiftPM が identity `kaitokit` の衝突を警告し将来はエラーになるため、KaitoFinder の開発配置では path を使う。

### 追加

- `ArchiveRewriter.probe(entries:format:)`。`open` と同じ表現可能性の検査（出力名の正規化と衝突、entry 種別、
  hard link の参照先、更新日時の表現範囲、LHA の名前・サイズ）を、書庫を開き直さずに一覧に対して行う。
  `open` の検査を `validateRepresentability(entries:format:)` に切り出して共有し、受理・拒否と文言は同一。
  復号可否・`WriterOptions`・原本の同一性は検査しない。KaitoFinder が編集可否の判定で圧縮 tar を再展開しないためのもの。
- `ArchiveUpdater.probe(url:)`。reader を開かず ZIP / ZIP64 の編集用門番と終端を検査し、
  `entryCount` を返す。既存 reader を持つアプリが編集可否のために CD を再解析する処理を省く。
  利用前に呼出側の reader の entry 数との一致を確認する。
  読取量と受理・拒否の一致は[リリースレビュー](Documentation/verification/2026-09-19-release-review.md)に記録。
- 既存実装の導入記録を補完: tar / tar.gz / non-solid 7z / LHA の新規 writer と、
  `ArchiveEditing` / `ArchiveRewriter` による全体再構築・形式変換。
  KaitoFinder 側の [2026-09-14 ArchiveRewriter 検証](../KaitoFinder/Documentation/verification/2026-09-14-archive-rewriter.md)と
  [再圧縮モード編集の検証](../KaitoFinder/Documentation/verification/2026-09-14-rewrite-mode.md)を参照。
- `EditPathReservations` による削除・改名・追加のパス予約管理。
  同名・親子の衝突を差分更新し、大量改名の全件走査を省く。
  [2026-09-16 の大規模編集・パス境界検証](Documentation/verification/2026-09-16-edit-review.md)を参照。

- `ArchiveFormat.tarBzip2` / `.tarXZ` のストリーム出力と書き換え。
  bzip2 の block size は `WriterOptions.bzip2Level`（1〜9、既定9）で選択し、XZは固定設定。
  4 GiB超・独立ツール・取消し・容量不足の[検証記録](Documentation/verification/2026-09-18-compressed-tar.md)。

- `WriterOptions.password`、`zipEncryption`（既定 `.aes256`）、`encryptsSevenZipHeaders`。
  ZIP のパスワードは UTF-8、7z は UTF-16LE。空パスワード、tar / tar.gz / LHA の暗号化、
  パスワードなしの header 暗号化は出力作成前に拒否する。
- ZIP WinZip AES-256 の stream 出力。20 byte 未満は AE-1 と実 CRC、以上は AE-2 と CRC 0。
  local / central の method 99、bit 0、0x9901、version 51 を揃え、空ファイルも暗号化する。
- ZIP ZipCrypto。圧縮結果を隣接する mode 0600 の一時ファイルへ spool し、確定 CRC の
  上位 byte を含む暗号 header と payload を書く。成功・失敗時に spool を削除する。
  ZIP の両暗号方式とも data descriptor を書かない。
- 7z non-solid LZMA2 + AES-256-CBC、任意の AES EncodedHeader。cycles=19、salt なし、
  folder ごとの 16 byte IV と zero padding。暗号 primitive は CommonCrypto / CryptoKit、乱数は Security。
- updater は追加 entry の暗号化を選択でき、既存の暗号化 payload はそのまま保持する。
  rewriter は入力パスワードと出力パスワードを独立に指定でき、復号・再暗号化・形式変換に対応する。
- KaitoKit / unzip / 7zz oracle、AE 境界・認証破損・誤パスワード・header 秘匿・旧 record 保存・
  spool cleanup・300 MiB stream 処理の XCTest。実行制限は[検証記録](Documentation/verification/2026-09-15-encryption.md)。

### 修正

- EOCD 候補が複数 EOF に達する書庫と、先行 EOCD の comment が後続候補を含む書庫を
  `UpdateGatekeeper.ambiguousEndRecord` で拒否する。comment 内の偽 EOCD により追加が見えなくなる
  経路を修正した。`probe` は tail だけでこの門番を検査し、`open` は CD 全件の長さ・終端・
  KaitoKit の local record との offset / 範囲一致も検査する。writer も旧 CD のコピー中に
  signature・record 数・終端を検査し、payload 上書きや曖昧な CD の公開を防ぐ。
- ZipCrypto spool は mode 0600、`O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC` で作成直後に
  unlink し、descriptor だけを保持する。圧縮中の crash / SIGKILL で名前付きの平文圧縮データを
  残さない。既存の符号化・暗号化と、取消し・失敗時の descriptor cleanup は維持する。
- `ArchiveRewriter.open` で全 carried 名を writer と同じ正規化・予約検査に通す。
  重複・NFC/NFD・directory の末尾 `/`・file と子の衝突は、部分出力を作る前に
  `RewriterError.unrepresentable` で理由を返す。省略する root directory と正当な親 directory は許可する。
  G4–G6 の失敗再現と修正後の結果は[リリースレビュー](Documentation/verification/2026-09-19-release-review.md)に記録。

- ZIP 再構築で、offset が変わらない local record の読み書きを省く。同長改名は local header
  だけを patch し、末尾削除では残存 payload に触れない。APFS clone の共有 extent を不要に
  複製する全書庫の書き直しを防ぐ。移動が必要な範囲は 256 KiB の buffer を再利用してコピーし、
  CD 再出力・truncate と追加後の再構築にも対応する。
  byte 一致・読取量・APFS 空き容量測定の限界は[検証記録](Documentation/verification/2026-09-19-release-review.md)を参照。
- 入力と更新元の変更検査から ctime を除外し、dev / ino / size / mode / mtime を比較する。
  tar hard link の内容 signature も同じ方針とし、Finder tag / LaunchServices の xattr 更新を許容する。
- 7z の LZMA2 圧縮単位を最大 16 MiB とし、読取・AES・書込の 256 KiB と分離した。
  初期の 256 KiB reset による圧縮率悪化を修正し、16 MiB 以下は従来の全体圧縮と同じ payload を保つ。
  40 MiB の固定 seed テキストの平文・暗号往復と全体圧縮比 ±5% の回帰テストを追加した。
- CommonCrypto の Int 定数と CCCryptorStatus（Int32）の三項演算子の型不一致を修正。
  SDK の宣言に従い、status 比較、algorithm / options、PBKDF2 rounds、size_t 境界を明示的に変換する。

> **Unreleased:** Password-protected ZIP AES-256 / ZipCrypto and 7z AES-256 output,
> optional encrypted 7z headers, encrypted updater additions and independent input/output
> passwords for rewriting. ZIP still writes no descriptors; ZipCrypto spools and cleans up.
> 7z now encodes 16 MiB chunks with 256 KiB I/O and a compression-ratio regression guard.
> CommonCrypto integer conversions match the SDK signatures. Source checks ignore ctime changes caused by tags/xattrs.
> Added interoperability and streaming tests could not run in the sandbox; see the verification record.
> ZIP rebuilds now skip unmoved records and reuse the copy buffer; same-length renames patch only local headers.
> The reader-free `ArchiveUpdater.probe(url:)` avoids parsing the central directory again; callers must compare
> its entry count with their validated reader. The 2026-09-19 record reports regression tests and measurement limits.

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
