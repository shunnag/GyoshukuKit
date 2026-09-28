# 変更履歴

注目すべき変更を記録する。バージョニングは Semantic Versioning に従う。

## [Unreleased]

### 変更

- 内部の整理のみ。公開 API・`@_spi`・出力 byte に変更はない。
  - Sources を役割ごとの階層(API / Writer / Editing / SplicedOutput / Zip / Zip/Update / Tar / CompressedTar / SevenZip / LHA /
    Compression / Support)に分けた。`Package.swift` は変えていない。設計書 §2.1 に配置の規則を書いた。
  - `ArchiveWriter` から ZIP の直列化を `ZipWriter` に分け、facade は形式ごとの writer への振り分けだけを持つ。
    updater の末尾追加は `ArchiveWriter.tarAppend` / `lhaAppend` / `sevenZipAppend` から作り、閉じ方は tar / LHA が `endAppendedMembers()`、7z が `endSevenZipEntries()`。
  - tar・圧縮 tar・7z・LHA の updater と `ArchiveRewriter` が別々に持っていた削除・改名の予約と名前の衝突検査を
    `EntryEditLedger` に一本化した。検査の順序と error は変わらない。表現可能性の門番は `ArchiveRepresentability` に置いた。
  - 形式ごとに Records / Layout / EditPlan / Updater / Writer / SelfCheck の形を揃えた: `TarSelfCheck`、`LHASelfCheck`(旧 `LHAAppendedMemberCheck`)、
    `ZipAppendedRecordSelfCheck`(旧 `ZipAppendedRecordCheck`)、`SevenZipEditPlan`(旧 `SevenZipUpdatePlan`)、`SevenZipFolderConversion`(旧 `SevenZipReencryption`)、
    `CompressedTarSpliceOutput`(旧 `CompressedTarSpliceWriter`)、`Bzip2StreamEncoder`(旧 `Bzip2Compressor`)、`ArchiveFileSource`(旧 `ZipUpdateSource`。typealias を残す)。
  - 出力 inode の所有を `OwnedOutputFile` に、ZIP の header 組立を `ZipHeaderRewrite` に、7z の AES encryptor の作成を `SevenZipAESEncryptor.Factory` に、
    LHA の大きな member の仮 header・spool・確定を `StreamedMember` に集めた。長い `commit` は段階ごとの private 関数に分けた。
  - 名前付き定数: `ZipRecords.Signature / ExtraID / FixedLength`、`TarRecords.TypeFlag`、`LHARecords.Method`、`SevenZipEditModel.Coder.aesMethodID / lzma2MethodID`、
    `DeflateBlock.windowSize`、`IOChunk.size`、`FileMode`、`Range<UInt64>.byteLength`。
  - 試験用の hook は置き換える対象の型へ移し(`EncryptionPrimitives.testingRandomBytes`、`ArchiveWriter.testingBeforeLstat`)、
    `testing*`(試験だけが設定)と `*Observer`(本番も使う観測点)で名前を分けた。試験だけの `TarCompressor` 適合と `XZCompressor` の別名を production から外した。
  - 自己照合の V/R/L 符号の凡例を code に書き、経緯の comment を現在の契約に書き換え、英語の comment を日本語に揃えた。
- 使われていなかった writer の `identity` 引数と、それだけのために呼んでいた `fstat` を削った。
- テストの整理: 共有 helper を `Tests/GyoshukuKitTests/Support/`（`TestSupport`・`ReferenceTool`・`TestPaths`・`TestCorpus`・
  `IOEvents`・`OptInGate`・`ScaleProbe` ほか）に集め、test class を一 file 一 class にして形式ごとの directory に分けた。
  milestone 名の class を機能名に改めた（`WriterOutputBaselineTests`・`CompressedTarSpecialMembersTests`・`ZipEditTestSupport`・
  `TarEditTestSupport` ほか）。環境変数で有効にする計測は `Probes/` に置き、閾値の検査は `GYOSHUKU_SCALE_ASSERT=1` のときだけ
  失敗する（`GYOSHUKU_P14_ASSERT` は別名として残る）。計測行は tab 区切りで stderr に出す。編集予約の時間計測は既定の
  suite から opt-in の probe に移した。`Tests/README.md` に helper・fixture・環境変数・外部ツールの一覧を書いた。
  `SevenZipExternalOracles.check` は 7zz / bsdtar が無いとき黙って通らず skip する。

## [0.6.0] - 2026-09-27

### 修正

- Swift 6.3（Xcode 26）でコンパイルできなかった 2 点を直す。`ZipCentralDirectory.CopyValidator` に明示の
  init を設け、`CompressedTarUpdater` の試験用の `Fault` と task-local を他の updater と同じく internal にする。
- `ArchiveRewriter.open` は、KaitoKit 0.11 の open が取消し済みの Task で投げる `CancellationError` を
  `RewriterError.invalidArchive` に包まずそのまま投げる。

- 書込み側の読取を共通の POSIX read にし、再帰追加と rewriter の項目ごとに autoreleasepool を設ける。
  ZIP の deflate stream も entry 間で再利用し、大量の小さなファイルや大きな入力でのメモリ増加を抑える。
  この最適化自体は出力 byte を変えない。

- ZIP updater の少数の追加・改名では、全件の名前表の構築を最初の 4 回まで生存名の走査に置き換える。
  5 回目から従来の表を使い、2,048 件未満は初回から表を使う。衝突の判定・例外・出力 byte・公開 API は保つ。
  [P1d-G 検証記録](Documentation/verification/2026-09-26-p1dg-live-name-check.md) に試験と計測を記載する。

- ZIP 出力を最大 256 KiB の buffer にまとめ、小さな entry の header・payload・CD の write 回数を減らす。
  seek・進捗/完了通知・API の復帰前に必要な flush を行い、出力 byte と通知順を保つ。
  7z では先読み済みの単一 chunk と CRC を encoder へ渡し、再読取・コピー・CRC 再計算を省く。
- ZIP XZ / Zstandard の編集・再暗号化の fixture をリポジトリ内へ複製し、テストの隣接 KaitoKit checkout への
  ファイル参照をなくす。出自と SHA-256 は `Tests/Fixtures/NOTICE` に記載する。

### 追加

- 公開の `WriterOptions.compressionThreads`（1...64、nil は自動）。自動値は CPU 数・物理メモリ GiB・8 の
  最小値（最低1）。ZIP deflate（ZipCrypto を除く）/ tar.gz / tar.bz2 / 7z / tar.xz / LHA の圧縮と、
  ZIP updater の再暗号化の鍵導出に使う。
- `ArchiveRewriter.probe(reader:format:)`。既存の reader で `open` と同じ検査を行い、
  一覧だけでは分からない MacLHA の MacBinary envelope も調べる。
  `probe(entries:format:)` は一覧の検査として残す。reader は `appleDoublePolicy: .expose` で開く。
- 独立した `Benchmarks` package。固定 seed の入力生成と、全形式の実行時間・peak RSS・出力サイズの
  TSV 記録、`--references` による zip / xz / 7zz との比較を提供する。

- `ArchiveAddition`・`ArchiveAdditionEvent`・`ArchiveAdditionError` と `add(_:events:)` による一括追加。
  小さな通常ファイルを有界に先読みし、出力 byte と項目ごとの API の動作を保つ。
  一括の名前の検査は open の前に行い、複数の失敗では最小の index に原因を帰属させる。
  events と取消しの例外は包まず返し、失敗時には source descriptor の close を待つ。
  ZIP の単一 block を一度の write で出力し、bench に `--mode batch` を追加する。
  [P7-G 検証記録](Documentation/verification/2026-09-27-p7g-batch.md) に試験と修正後の受入計測を記載する。

- ディスク追加の byte 進捗、`finishAdditions(progress:)`、`readsAdditionsDuringCommit`、
  `ArchiveRewriter.commit(progress:didCarry:)` と `WriterOptions.maximumPendingInputBytes(for:)`。
  追加の読取と圧縮待ちを分けて同期通知し、既存の出力 byte と updater の commit 進捗を保つ。
  bench に `--progress` と `--mode recursive|items` を追加する。
  [P6-G 検証記録](Documentation/verification/2026-09-27-p6g-progress.md) に上限値の導出・検証と受入計測の測り直しを記載する。

- `SevenZipUpdater.open(url:password:output:options:)` と `ArchiveReencrypting`。
  7z の運ぶ pack・coder・IV・CRC と file の生の名前・時刻・属性・anti・StartPos を保ち、
  改名は header、削除は移動範囲、追加は末尾だけを書く。solid の一部削除はその folder だけを
  一つの solid LZMA2 に作り直す。暗号化の設定・変更・解除は再圧縮せず、通常の編集では部分的な暗号化を保つ。
  header の圧縮の有無は元に合わせ、暗号化の予約なしに暗号化 header を平文にしない。
  属性が全件未定義の空でない元への追加は、7zz と同じく属性（Unix mode を含む）を保存せず、mtime は保つ。
  0 件の header は `01 05 00 00 00`。ZIP updater の protocol 適合による挙動変更はない。
  KaitoKit 0.11.0 の P5-K SPI が必要。
  currentPassword は AES folder ごとに先頭 64 KiB まで確認するため、64 KiB を越える AES + Copy の
  誤った鍵を検出できない場合がある。公開前の全件照合は呼出側の責務。
  [P5-G 検証記録](Documentation/verification/2026-09-26-p5g-sevenzip-updater.md) に試験・計測と既知の非互換を記載する。

- `LHAUpdater.open(url:output:options:)`。既存 member を再圧縮せずに追加・削除・改名し、
  clone 上で header と移動範囲だけを書く。追加は並列 LH5、照合・進捗・取消し・FAT/exFAT の cleanup は
  共通の出力部品を使う。構造上の fallback は `rewriteReason(reader:)` で照会できる。
  改名した member は level 2 / OS U となり、comment・所有者・code page・未知の拡張を落とし、
  時刻は秒へ切り捨てる。改名しない member の byte は保つ。
- `TarUpdaterError` を形式共通の `UpdaterRouteError` に改名する。同じ二つの case と
  `public typealias TarUpdaterError = UpdaterRouteError` により既存の生成・catch の source 互換性を保つ。
  [P4-G-b 検証記録](Documentation/verification/2026-09-26-p4gb-lha-updater.md) に試験・計測を記載する。

- `CompressedTarUpdater.open(reader:output:format:options:)`。session reader の tar image と
  地図を使い、gzip / bzip2 / xz の変更を含む区切りだけを再符号化する。
  P2 の編集規則・追加 factory・予約を共有し、従来の設定は open で `requiresRewrite` にする。
  `assess(reader:)` は初回の全体符号化を見積もり、`commit(progress:)` は戦略・出力 identity・
  segment 列・byte 統計を返す。公開前の KaitoKit K5 検証は呼出側が行う。
  FAT/exFAT の仮 inode を保存せず、失敗・取消しでは自分の出力だけを削除する。
  [G2 検証記録](Documentation/verification/2026-09-26-p3g2-compressed-tar-updater.md) に試験と計測を記載する。

- `TarUpdater.open(url:output:options:)`。非圧縮 tar の変更 header と位置の動く範囲だけを書き、
  運ぶ member の名前の byte・pax・sparse 表現・所有者を保つ。open での `requiresRewrite` と
  commit での `outputVerificationFailed` を `TarUpdaterError` で区別する。
- `ArchiveOwnerIDs` と `ArchiveEditing` の所有者指定 disk add・日付/所有者指定 directory add。
  従来の conformer 向けの既定実装は、指定値がある場合 `unsupportedOption` を返す。
- 後続形式でも共有する internal `SplicedArchiveOutput`、`TarLayout` / `TarEditPlan`、
  clone/sequential・検証 fault・differential・prototype oracle・100k/9 GiB probe の試験。

- `ArchiveUpdater.reencryptExistingEntries(currentPassword:)`。ZIP の暗号化を設定・変更・解除し、
  圧縮済み payload はそのまま保つ。通常ファイルは options に従い、directory と symlink は平文にする。
  同じ方式・同じ UTF-8 password の entry は検証せずに運ぶため、入力の全件検証は呼出側の責務。
- ZIP updater の `open(url:output:options:)`。原本の descriptor から clone snapshot を作り、
  指定した作業ファイルを mode 0600・flags 0・fsync・close 済みで返す。immutable / append の
  UF/SF flags は EPERM で拒否し、clone の ENOTSUP / EXDEV だけ直接読取へ戻す。
  snapshot helper は後続の tar updater と共有できる internal 実装にする。
- `ArchiveUpdater.CommitProgress` と `commit(progress:)`。計画した書込み byte の進捗を同期通知し、
  callback の throw・取消し・失敗では原本を保ち、自分の inode の作業ファイルだけを削除する。
- `@_spi(Testing)` の commit strategy、legacy byte oracle、境界・読取量・cleanup・進捗試験、
  `GYOSHUKU_ZIP_SCALE_ENTRIES` で有効にする ZIP-SCALE probe。
  結果は [P1-G検証記録](Documentation/verification/2026-09-25-p1g-zip-editing.md) に記載する。

### 変更

- KaitoKit の tag 依存を `.upToNextMinor(from: "0.11.0")`（0.11.0 以上、0.12.0 未満）にする。
  `@_spi` は SemVer の保証外であり、KaitoKit の型を公開 API に含むため、次の minor は再検証してから採用する。
  隣接 checkout の path 依存と SwiftPM / Xcode の `checkouts/` 判定は維持する。
  リリース順は KaitoKit 0.11.0 → GyoshukuKit 0.6.0 → KaitoFinder 0.4.0。
- KaitoKit の import を `public import KaitoKit` に変更し、`ArchiveReader` / `ArchiveEntry` /
  `ArchiveVolumeSet` などの型を公開 API に含むことを明示する。
- `UpdaterError.reencryptionFailed(index:name:reason:)` を追加し、出力検証の失敗を入力の password エラーから分ける。
  **source 互換性**: `UpdaterError` を網羅する switch には新しい case が必要。

- 7z / tar.xz の LZMA2 を順序付きの並列 pipeline で符号化する。7z は entry をまたいで並列化し、
  圧縮 payload は従来と byte 一致する。tar.xz は Apple の streaming encoder から独立した LZMA2 block を
  持つ単一 XZ stream（CRC32、両 size 付き block header）へ変わり、出力 byte が変わる。
  圧縮完了前に add が戻ることがあり、圧縮失敗・取消しは後続の add / finish で通知され得る。
  [並列 LZMA2 検証記録](Documentation/verification/2026-09-24-parallel-lzma2.md) を参照。
- ZIP deflate（ZipCrypto を除く）/ tar.gz を、直前の末尾 32 KiB を辞書にする最大 1 MiB の
  並列 deflate に変更する。ZIP は小さな member を add 間でも並列化する。
  tar.bz2 は最大 `5 × bzip2Level × 100,000` byte ごとの完全な bzip2 stream を連結する。
  **ZIP deflate / tar.gz / tar.bz2 の出力 byte が変わる**。同じ入力・設定での圧縮 byte は並列数に依存しない。
  圧縮失敗は後続の add / finish で通知されることがある。
  [並列 deflate / bzip2 検証記録](Documentation/verification/2026-09-24-parallel-deflate-bzip2.md) を参照。
- 圧縮 tar の通常 member を途中で切らず、member の先頭で gzip の同期点・bzip2 stream・XZ block を区切る。
  上限を越える member は header 群と本文を分け、それぞれを上限以下の片にする。
  tar の終端と record padding は独立した最後の区切りに置く。
  **すべての tar.gz / tar.bz2 / tar.xz 出力の byte が変わる**（新規作成・全体再構築）。
  [G1 検証記録](Documentation/verification/2026-09-25-p3-g1.md) を参照。

- tar.xz は4 MiB以下のmemberを最大4 MiBのblockに詰め、4 MiBを越えるmemberはheader群と本文を分ける。
  本文と大きなheader群の片は最大16 MiBのまま。G1 の配置に比べ、小さなファイルの多い書庫は5–12%、
  4 MiB前後のtextファイルが並ぶ書庫は約5%大きくなる。
  仕様の実測では小さな1件の削除・改名が16 MiBの再圧縮（約3.7–4.5秒）から4 MiB（約0.7–0.9秒）になる。
  大きなファイルだけの書庫は G1 の配置と同じbyte。既存書庫も編集でき、変更した区間だけを新しい規則で切る。
  並列数が2以上のとき64 KiB以下のblockは並列数に数えず、未出力の合計を `2 × threads + 1` に抑える。
  [P14-G 検証記録](Documentation/verification/2026-09-26-p14-xz-packing.md) に実行結果と受入計測を記載する。

- 名前の `\` と `:` を tar / tar.gz / tar.bz2 / tar.xz の出力で許可する。既存名の検査・改名・追加・
  ディスクの再帰追加・hard link の参照先に適用し、ZIP / 7z / LHA では引き続き拒否する。
  NUL・空の成分・`.` / `..`・長さの検査は全形式で保つ。
- `ArchiveRewriter.open` と probe は未対応の LHA method / 7z coder を早期に拒否する。
  reader 版と open は、envelope・resource fork を保持できない MacBinary 入りの MacLHA member も拒否する。
  一覧版の probe だけでは envelope を判別できず、通常の本文を持つ MacLHA member は受理する。
- ZIP の改名では Unicode Path extra（0x7075）を同長の padding にして旧名と CRC をゼロで消すため、
  **改名後の出力 byte が変わる**。名前を含み得る extra（0x0008 / 0x2605 / 0x334D / 0x4F4C / 0x554E）や
  解析できない非ゼロの末尾がある entry の改名は新たに拒否する。
  [P0-G 検証記録](Documentation/verification/2026-09-24-p0g-editability-and-zip-names.md) を参照。
- 空配列の `add(_:events:)` は全 writer / editor と `ArchiveEditing` の既定実装で no-op にする。
  finished / failed・追加終了後・取消し済みでも例外も通知もなく、writer の準備や未出力入力の flush を行わない。
  後続の `finishAdditions` / commit の動作・strategy・出力 byte を変えない。

- CompressedTarUpdater の追加/literal 保存領域に 1 GiB の空き容量を要求する制約を外す。
  出力 volume の空き容量が 1 GiB 未満でも小さな編集を行える。実際の書込み失敗時の後始末は保つ。
- FAT32 / exFAT で空 file の最初の書込みや truncate により inode が変わっても、
  TarUpdater の出力・再配置 spool を正しく検査し、失敗時に削除する。
  開いている出力は現在の descriptor とパスを照合し、空 file の仮 inode を保存済み ID として使わない。
  tar / 7z / LHA writer と ArchiveRewriter の破棄にも同じ規則を適用する。原本の同一性検査は変えない。

- LHA の LH5 符号化に `compressionThreads` を適用する。1 MiB 以下は member ごと、
  大きい file は 1 MiB の区切りと 8 KiB の履歴で並列に符号化し、bit 単位で継ぐ。
  直列時の出力 byte・header・圧縮方式の選択は保つ。並列数 1 は同期のまま、2 以上では
  add が出力前に戻る場合があり、符号化の失敗・取消しは後続の add / finish で通知する。
  [P4-G-a 検証記録](Documentation/verification/2026-09-26-p4ga-parallel-lh5.md) に試験を記載する。

- `ArchiveRewriter` の追加位置は既定で末尾（`additionPlacement: .end`）。追加は commit まで予約し、
  `.beginning` は従来の先頭追加を保つ。運ぶ tar の uid/gid は既定で維持（`carriedTarOwnerIDs: .keep`）、
  `.reset` で 0 にする。`preserveOwnerIDs` はディスクからの追加にだけ効く。
  既定の追加順と、運ぶ tar の所有者欄の出力 byte が変わる。
- `CommitProgress` の共通契約は計画後に固定した total、単調な completed、最後の一致（0 を含む）。
  TarUpdater は commit の書込みと V2/V5 の照合読取を合計し、一つの観測経路へ報告する。

- ZIP の password 操作を updater で行うと、元の圧縮方式・名前の byte・時刻・属性・extra・comment・
  directory の payload が保たれる。変換 entry だけ descriptor を除き、暗号欄・CRC・サイズ・ZIP64 を再構築する。
  AES 入力の AE-1/AE-2 は維持し、強度は AES-256 にそろえる。変換 0 件は従来の updater と同じ byte を返す。
- 再暗号化の鍵導出は `compressionThreads` の数で並列化する。`CommitProgress` はこの経路で書込みに加え
  pass A・V1–V3 の読取と鍵導出の仕事量を含む。公開前に KaitoKit と独立した header の検査、保存 byte・CRC・
  password からの鍵導出の照合を行う。変換で位置が変わる追加付き commit は `.stagedRebuild` になる。
  実行した試験とツールの制限は [P1b 検証記録](Documentation/verification/2026-09-25-p1b-reencryption.md) に記載する。
- ZIP の CD を一括検証し、KaitoKit の検証済み raw layout とともに保持する。
  再構築は計画と 4 MiB のコピーに分け、連続する必要範囲だけを読み、canonical CD の offset だけを patch する。
  条件を満たす同長改名は header と CD の patch だけで完成し、削除だけでは名前予約表を作らない。
- 削除・改名後の追加は詰めた位置へ直接書き、CD は一度だけ生成する。追加の後に位置が変わる場合だけ
  段階 snapshot を使う。追加 record の照合は GK と KaitoKit の両方で残す。
  この最適化自体は従来成功していた編集の出力 byte を保つ。混在時の N+M 件への段階 reader の上限はなくなり、
  CD 側の拒否は実行時 I/O より先、取消しは計画 4,096 件ごと・直後・実行前・chunk ごとになる。

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
