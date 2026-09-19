# ZIP 編集のリリースレビュー（2026-09-19）

開始時点: GyoshukuKit `e1f16ac`、作業ツリーは clean。コミットは作成していない。
KaitoKit / KaitoFinder は参照のみで変更していない。
環境: macOS 27.2（26B5086k）、arm64、Apple Swift 6.4、Swift language mode 6。
依存は `Package.swift` の path dependency `../KaitoKit`（0.6.1 + unreleased）。

## G1 — 移動しない ZIP record の読み書きを省く

対象ファイル:

- `Sources/GyoshukuKit/ZipRebuild.swift`
- `Sources/GyoshukuKit/ZipUpdateLayout.swift`（`ZipUpdateSource` の定義を含む）
- `Tests/GyoshukuKitTests/ZipDeleteRenameTests.swift`
- `Tests/GyoshukuKitTests/ZipReadCounter.swift`（G2 と共用の観測 helper）

修正前は `ArchiveUpdater.commit` が用意した byte-identical な clone に対し、
`ZipRebuild.write` が全残存 record をコピーしていた。同長改名も record 全体をコピーした後に
local header を patch していた。APFS の共有 extent を不要に分岐させる書込になる。

`position == raw.recordRange.lowerBound` の record はコピーせず位置だけ進める。
同長改名はその位置の replacement header だけを書き、移動する record は従来どおりコピーする。
各 emit は論理位置へ seek してから書き込むため、読み飛ばした record の後でも位置がずれない。
`offsets` / `descriptorMarkers` の判定、CD 再出力、終端、truncate は維持した。
コピーは 256 KiB の `Data` を一つだけ確保し、`readExactly(into:at:)` で再利用する。
短い read の継続・EOF 時の `sourceChanged`・範囲検査も維持する。

製品の最適化より先に6テストを書き、descriptor の `pread` が返した byte 数を観測する
内部 TaskLocal hook だけを追加して実行した。カウンタは Mutex を使い、並行テストの観測を混ぜない。
read 数は open / fixture 作成を除き、公開 `commit()` の呼出し中を測る。

修正前に観測した assertion 本文（6テスト、2 failures、unexpected 0）:

```text
XCTAssertLessThan failed: ("134218098") is not less than ("1048576") - same-length rename must not read unmoved payloads
XCTAssertLessThan failed: ("67109087") is not less than ("1048576") - tail deletion must not read unmoved payloads
```

入力は stored の64 MiB memberを2件、payloadは異なる固定byte。測定結果:

| 操作 | 修正前の source read bytes | 修正後の source read bytes |
|---|---:|---:|
| 先頭を同長改名 | 134,218,098 | 266 |
| 最後の entry を削除 | 67,109,087 | 171 |
| 最初の entry を削除 | 67,109,130 | 67,109,130 |
| 先頭を異長改名 | 134,218,046 | 134,218,046 |

追加テスト（いずれも `ZipDeleteRenameTests`）:

1. `testUnshiftedSameLengthRenameReadsLessThanOneMiB` — read < 1 MiB。
   元書庫の local / central 名だけを直接置換した独立 oracle と全 byte 一致。
2. `testUnshiftedTailDeletionReadsLessThanOneMiB` — read < 1 MiB、全出力 byte 一致。
3. `testShiftedFirstDeletionCopiesOnlySurvivor` — read は残存64 MiB以上、64 MiB + 1 MiB未満。
4. `testShiftedDifferentLengthRenameCopiesPayloadsByteExactly` — read は128 MiB以上、128 MiB + 1 MiB未満。
5. `testUnshiftedRenameAfterAddPreservesAppendedZIPByteExactly` — 各256 KiBの2件へ追加してから同長改名。
   `appended.zip` 経路の全出力 byte 一致。
6. `testUnshiftedSameLengthRenamePreservesAPFSCloneFreeSpace` — 以下の APFS 測定。

1〜5は既存の `Snapshot` / `assertCarried` でも payload / descriptor / 未改名 local record、
metadata を比較し、固定日時・権限の期待書庫とも全 byte を比較する。
G1単独の修正後実行は **6テスト、失敗0、skip 0**。

### APFS 空き容量

KaitoFinder の [2026-09-10 undo 測定](../../../KaitoFinder/Documentation/verification/2026-09-10-undo-model.md)
と同様、同一 volume に `clonefile` で undo を保持し、編集で分岐する extent の増加を測る。
OS の temp directory に128 MiBの stored ZIPを作成し、`statfs.f_fstypename == "apfs"` を確認。
非 APFS の場合は `XCTSkip`。本実行では APFS であり skip していない。
undo clone 作成後、commit 前後に `sync()`、`f_bavail * f_bsize` を比較した。
無関係な volume 活動の許容差は16 MiB。

```text
G1 APFS free bytes before=589824000000 after=589824000000 consumed=0
```

**測定上の限界:** 修正前の全 record コピーでも、この環境の同じ API は同じ値を返した。
したがって差分0 byteは観測値であり、物理割当の削減をこの容量計だけで実証したとは扱わない。
`URL.volumeAvailableCapacity` と `FileManager.attributesOfFileSystem` も589,824,000,000を返し、
important / opportunistic capacity は0だった。`diskutil info` / `diskutil apfs list` は sandbox 内で
`Unable to run because unable to use the DiskManagement framework.` と失敗し、より細かい値を得られなかった。
削減の決定的な回帰検査は、修正前に失敗した source read の2 assertion と書込範囲の実装確認。
10 GiB書庫での容量差、非 APFS 実 volume の skip は今回未検証。

ログ: `/private/tmp/gyoshuku-g1-before.log`、`/private/tmp/gyoshuku-g1-after.log`、
`/private/tmp/gyoshuku-capacity-apis.log`。

## G2 — reader を作らない編集可否 probe

対象ファイル: `Sources/GyoshukuKit/ArchiveUpdater.swift`、
`Tests/GyoshukuKitTests/ZipUpdateProbeTests.swift`。G1の descriptor 観測 hook / helper を共用する。

`public static ArchiveUpdater.probe(url:)` は `ZipUpdateSource` と `ZipUpdateLayout` を使い、
原本の同一性を再確認して、`Sendable` / `Equatable` の `Probe.entryCount: UInt64` を返す。
三門番と終端検証の error は既存 layout からそのまま返す。`open` の実装は変更していない。
成功時は SFX / trailing data がなく、CD offset と単一 volume / 空書庫の条件を通過している。
CD entry 自体は解析しない。利用前に自身の検証済み reader と entry 数を比較する必要を
公開 API doc と README に明記した。破損した CD entry の検出・読取制限は reader の責務。

10テストを先に作り、実行可能な失敗基準として新 API を一時的に
`Probe(entryCount: UInt64(try open(url: url).entryNames.count))` へ委譲した。
これはアプリが従来使っていた reader 付き gatekeeper 経路を再現するための仮実装で、最終差分には残していない。
この段階で **10テスト、3 failures（unexpected 1）** を観測した。

```text
XCTAssertEqual failed: threw error "Malformed archive: invalid ZIP central-header signature"
XCTAssertLessThan failed: ("4655636") is not less than ("2162687") - probe must not parse the multi-MiB central directory
XCTAssertTrue failed - probe must read only the bounded tail and the prefix/CD signatures
```

最後の2 assertion は4,000 entry、CD 3,474,890 byte、最大コメント65,535 byteの stored ZIP。
既存 scale テストと同じ writer / entry loop に長いパスを与えて生成した。
読取量は **4,655,636 → 1,114,161 byte**。予算は2 MiB + コメント = 2,162,687 byte未満。
固定長の EOCD 探索窓は CD 末尾に重なるが、その窓の外の read は先頭とCD先頭の各4 byteだけ、
という実 offset 範囲も検査する。全CDの走査がないことを公開 `probe(url:)` で確認した。

追加テスト（いずれも `ZipUpdateProbeTests`）:

1. `testProbeAcceptsNormalZIP`
2. `testProbeAcceptsCanonicalEmptyZIPWithMaximumComment`
3. `testProbeAcceptsZIP64AndCanonicalEmptyZIP64`
4. `testProbeRefusesSFXPrefixLikeOpen`
5. `testProbeRefusesTrailingDataLikeOpen`
6. `testProbeRefusesBadCentralDirectoryOffsetLikeOpen`
7. `testProbeRefusesSplitZIPAndZIP64LikeOpen`
8. `testProbeRefusesMalformedEndRecordsLikeOpen`
9. `testProbeReadsOnlyBoundedTailWithMultiMiBCentralDirectory`
10. `testProbeLeavesEntryValidationToCallersReader`

受理ケースは `open.entryNames.count` との一致、拒否ケースは gatekeeper と理由を含む
`UpdaterError` の完全一致、検査前後の原本 byte 不変を確認する。
10は2件目の CD signature を壊した書庫で probe が layout のみを検証すること、
reader を開く `open` は拒否することを別々に確認する。
修正後は **10テスト、失敗0、skip 0**。
G2は読取専用であり空き容量差の独立測定対象ではない。アプリへの接続・UI は対象外で未検証。

ログ: `/private/tmp/gyoshuku-g2-before.log`、`/private/tmp/gyoshuku-g2-after.log`。

## G3 — 文書

`CHANGELOG.md` の Unreleased に G1 / G2 と理由を追加した。
欠けていた tar / tar.gz / non-solid 7z / LHA writer、`ArchiveRewriter` / `ArchiveEditing`、
`EditPathReservations` の導入記録も補完した。
指定の2026-09-14の記録は GyoshukuKit 内には存在せず、KaitoFinder 内の
`2026-09-14-archive-rewriter.md` / `2026-09-14-rewrite-mode.md` を明示して参照する。
パス索引の差分更新は GyoshukuKit の2026-09-16の検証記録へ参照を分けた。
`README.md` は日英の依存表記を実際の path dependency に更新し、G1 / G2 の使い方も記載した。
本ファイルが今回の検証記録。文書のみの項目に実行可能な failing assertion / 新規テストはない。

## 最終検証

通常の最初の `swift test` は manifest 段階で
`error opening '/Users/nagash/.cache/clang/ModuleCache/Swift-7JL1KBZ3A6V3.swiftmodule' for output: /Users/nagash/.cache/clang/ModuleCache: Operation not permitted`
となり、テストは0件だった。以降は writable な module cache と SwiftPM の `--disable-sandbox` を使った。
ユーザーの SwiftPM cache が read-only という warning は残るが、ビルド・テストは実行できる。

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/gyoshuku-module-cache
swift build --disable-sandbox
swift test --disable-sandbox --filter 'ZipDeleteRenameTests|ZipRebuildBoundaryTests|ArchiveEditingScaleTests|ArchiveUpdaterTests|EmptyArchiveTests|ZipUpdate'
swift test --disable-sandbox --filter 'ArchiveUpdaterEntryNamesTests|ArchiveUpdaterOptionsTests|ZipModernMethodEditingTests|EncryptionTests/testUpdaterEncryptsAdditionsAndPreservesOriginalRecords|EncryptionTests/testXattrChangesDuringDiskReadAndBeforeUpdateCommitAreAllowed'
git diff --check
```

- `swift build`: 成功（`/private/tmp/gyoshuku-release-review-build.log`）。
- 指定 filter: **49テスト、失敗0、skip 0**、229.54秒。
  `ArchiveEditingScaleTests` 1、`EmptyArchiveTests` 2、`ZipDeleteRenameTests` 20、
  `ZipRebuildBoundaryTests` 5、`ZipUpdateProbeTests` 10、`ZipUpdaterTests` 11。
  4 GiBのoffset境界、65,536件の増減、既存byte一致・取消し・metadata・独立ツール検証を含む。
  指定文字列中の `ArchiveUpdaterTests` というクラスは存在しないため、関連する別名クラスも次の追加実行で検証する。
  ログ: `/private/tmp/gyoshuku-release-review-required.log`。
- 指定 filter 外の updater names / options、暗号化・modern method の既存 ZIP 回帰:
  **17テスト、失敗0、skip 0**、2.41秒。
  `ArchiveUpdaterEntryNamesTests` 7、`ArchiveUpdaterOptionsTests` 6、
  `ZipModernMethodEditingTests` 2、`EncryptionTests` の updater / xattr 2。
  ログ: `/private/tmp/gyoshuku-release-review-additional.log`。
- `CHANGELOG.md` / `README.md` / 本記録のローカル参照21件は全て存在する。
- 最終 `git diff --check`: 成功。

| 実行 | テスト数 | assertion failures | skip |
|---|---:|---:|---:|
| G1 修正前 | 6 | 2 | 0 |
| G1 修正後 | 6 | 0 | 0 |
| G2 reader付き仮実装 | 10 | 3（unexpected 1） | 0 |
| G2 修正後 | 10 | 0 | 0 |
| 最終・指定 filter | 49 | 0 | 0 |
| 最終・追加の ZIP 回帰 | 17 | 0 | 0 |

合計98テスト実行。最終検証は重複のない **66テスト** が成功し、その中に新規16テストを含む。
今回フルの `swift test` とアプリ側のビルド・UI検証は実施していない。

## G4–G7 — 第2回レビューの追補

G1–G3 と同じ未コミットのツリーを継続。依頼者から、その後のフルスイート **218件・失敗0** の
確認報告を受けて開始した（上記 G1–G3 の自分の実行件数とは区別する）。KaitoKit / KaitoFinder は
引き続き参照のみ。以下が今回追加した検証であり、G1–G3 の過去の測定値は変更していない。

### G4 — 曖昧な EOCD と旧 CD の拒否

変更ファイル:

- `Sources/GyoshukuKit/ZipUpdateLayout.swift`
- `Sources/GyoshukuKit/ZipCentralDirectory.swift`（追加）
- `Sources/GyoshukuKit/ArchiveUpdater.swift`
- `Sources/GyoshukuKit/ArchiveWriter.swift`
- `Tests/GyoshukuKitTests/ZipUpdaterIntegrityTests.swift`（追加）

stored の2-entry ZIP に34 byteの comment を付けた。内訳は8 byteの filler、22 byteの偽 EOCD、
4 byteの suffix。偽 EOCD は count 2、実 CD offset、実 CD size + 30、comment length 4を宣言する。
修正前は KaitoKit が実 EOCD へ fallback する一方、updater は偽 EOCD を採用していた。
テスト内で原本 reader の2件を確認し、その後、拒否されなかった場合だけ追加・commitまで実行した。

```text
XCTAssertThrowsError failed: did not throw an error - open must refuse an embedded coherent EOCD
XCTAssertThrowsError failed: did not throw an error - probe must refuse an embedded coherent EOCD
G4 RED append: before=2, after=2, added.txt visible=false
XCTAssertEqual failed: ("2") is not equal to ("3") - committed append must expose the added entry
```

`names.count == 2` の旧挙動も red 分岐内で assertion し、単なる不正 fixture の拒否ではなく
「commit は成功したが追加した entry が見えない」経路を再現した。ほかの修正前の assertion 本文:

```text
XCTAssertEqual failed: ("trailingData") is not equal to ("ambiguousEndRecord")
XCTAssertThrowsError failed: did not throw an error - CD walk must refuse a central signature planted inside a carried payload
XCTAssertThrowsError failed: did not throw an error - CD local offsets must agree with the reader's raw records
XCTAssertThrowsError failed: did not throw an error - CD walk must end exactly at the declared central-directory end
XCTAssertThrowsError failed: did not throw an error - finish must validate copied old-CD records (variant 0)
XCTAssertThrowsError failed: did not throw an error - finish must validate copied old-CD records (variant 1)
XCTAssertThrowsError failed: did not throw an error - finish must validate copied old-CD records (variant 2)
XCTAssertThrowsError failed: did not throw an error - finish must validate copied old-CD records (variant 3)
XCTAssertThrowsError failed: did not throw an error - finish must validate copied old-CD records (variant 4)
```

最初の G4 実行は **9テスト・13 failures・unexpected 0**。trailingData 比較は open / probe の2回。
CD walk 単体の3ケースは、テストを先に作り、新しい内部検査関数を no-op の仮実装にしてから失敗を確認した。
仮実装は最終差分に残していない。planted signature ケースは実 payload 内に central record の先頭を
置き、その偽 offset / size を検査関数へ直接渡す。曖昧 EOCD 門番が先に拒否しても、CD 層自体を検証できる。

実装後の動作:

- 既存の tail / trailing bound 内で comment length が収まる全 EOCD 候補を列挙する。
  複数が EOF に達する場合、または先行候補の comment 内に選択候補の header が入る場合は
  `editingRefused(.ambiguousEndRecord)`。
  理由は `複数の EOCD 候補、または comment 内の EOCD があるため終端構造が曖昧です`。
  収まらない comment length を持つ単なる `PK\x05\x06` byte列は候補にしない。
- `open` は reader の entry 数照合後、同じ件数の CD record を46 byte固定部 + 可変長の和で walk する。
  ZIP64 offset は size sentinel に対応する前置フィールドを飛ばして解決する。
  各 offset と `rawRecord.recordRange.lowerBound` の一致、全 record の上端が CD 開始以前であること、
  walk の終端が宣言された CD 末尾と一致することを検査する。不一致は説明付き `invalidArchive`。
- `finish(existingCount:comment:copyCentral:)` は旧 CD のコピー中に signature / 可変長 / 件数を検証する。
  保持するのは46 byteの固定 headerだけ。途中の chunk 境界を許し、切断・不足件数・余分な EOCD / byteを拒否する。

依頼者の追加指示に従い、**probe は tail-only のまま**。新しい曖昧 EOCD 門番は共有するが、CD 全件 walk は
`open` だけで行うことを API doc / README に明記した。既存 `ZipUpdateProbeTests` 10件は無変更で成功し、
3,474,890 byte CD + 65,535 byte comment の probe は引き続き **1,114,161 byte read**。

G4の9件 + 既存 probe 10件は **19テスト・失敗0・skip 0**。
さらに `open` の検査呼出しを一時的に外し、local payload が CD に重なる入力を追加して接続を検証した:

```text
XCTAssertThrowsError failed: did not throw an error - open must validate local ranges before an append can overwrite them
```

この入力は KaitoKit の metadata 読取と tail-only probe では2件として受理される。
**1テスト・1 failure → 検査呼出しを復元して1テスト・失敗0**。原本 byte の不変も確認した。
この追加を含む G4 の新規テストは10件:

1. `testEmbeddedCoherentEOCDIsRefusedBeforeAppendCanLoseEntries`
2. `testEnclosingEarlierCommentIsAmbiguousEvenWithTrailingData`
3. `testIncoherentEOCDBytesInLegitimateCommentRemainEditable`
4. `testCentralWalkRejectsPlantedPayloadSignature`
5. `testCentralWalkRequiresExactDeclaredEnd`
6. `testCentralWalkRejectsReaderLocalOffsetDisagreement`
7. `testOpenRejectsLocalPayloadOverlappingCentralDirectoryBeforeAdd`
8. `testFinishRejectsMalformedOrMiscountedCopiedCentralRecords`
9. `testFinishAcceptsCentralRecordsAcrossArbitraryChunkBoundaries`
10. `testCentralWalkResolvesZIP64OffsetAfterBothSizeFields`

コピーの拒否 variant は順に、先頭 signature 不正、可変長部分の切断、宣言件数不足、旧 EOCD 混入、
existingCount 0に対する非空 CD。正常コピーは chunk size 1 / 7 / 47 / 257で全 entry を展開して比較する。

最終の指定 filter 実行で、G4 新規10件は **失敗0**。拒否時の実際の出力（重複を省略）:

```text
G4 gate: ambiguousEndRecord: 複数の EOCD 候補、または comment 内の EOCD があるため終端構造が曖昧です
G4 invalidArchive: CD の開始位置が local record の終端より前です: first.bin
G4 invalidArchive: CD の local-header offset と KaitoKit が一致しません: other.bin
G4 invalidArchive: CD の walk 終端と宣言されたサイズが一致しません
G4 invalidArchive: CD record の signature がありません
G4 invalidArchive: 旧 CD の record 数または終端が一致しません
G4 invalidArchive: 旧 CD の entry 数を超える byte があります
G4 invalidArchive: ZIP local record を検証できません: first.bin: Malformed archive: ZIP entry data overlaps the central directory
```

ログ: `/private/tmp/gyoshuku-g4-before.log`、`...-g4-after.log`、
`...-g4-open-before.log`、`...-g4-open-after.log`（いずれも `gyoshuku` 接頭辞）。

### G5 — ZipCrypto spool の作成直後 unlink

変更ファイル: `Sources/GyoshukuKit/ZipCryptoEncryptor.swift`、`Sources/GyoshukuKit/ArchiveWriter.swift`、
`Tests/GyoshukuKitTests/EncryptionTests.swift`。

最初に実装を確認した。従来は `mkstemp` 後も path を保持し、明示的 `remove()` / deinit まで unlink しない。
既存テストも圧縮中の spool 件数1を期待していたため、「既に匿名化済み」ではなく G5 は修正対象だった。
新規2テストを実装前に追加し、両方で次の失敗を観測した:

```text
XCTAssertEqual failed: ("1") is not equal to ("0") - ZipCrypto add must not expose a named plaintext spool
XCTAssertEqual failed: ("1") is not equal to ("0") - ZipCrypto spool must be unlinked immediately after creation
```

`O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC`、mode 0600で作成して直後に unlink する。
内容を圧縮する前に匿名化を済ませ、保持するのは descriptor / size だけ。成功時は `close()`、失敗時は
deinit で閉じる。unlink の失敗は内容を書き込む前に返す。

追加テスト:

- `testZipCryptoSpoolIsAnonymousWhileAliveAndStillCopiesBytes` — spool が生きている間から directory は空。
  分割して書いた payload が同じ初期鍵の期待 ciphertext と byte一致し、全 byte が descriptor から読める。
- `testZipCryptoSpoolIsAbsentDuringAddAndBeforeFinish` — 入力 read callback 中と add 後・finish前に
  directory を検査する。入力と出力以外の sibling はない。KaitoKit / unzip で暗号 entry を検証する。

**2テスト・2 failures → 2テスト・失敗0**。新規 test の byte oracle は修正前も成功していた。
従来の取消し・入力変更テストと300 MiB streamingテストの「圧縮中は名前付き spool がある」という
期待値は、新しい匿名化の仕様に更新した。暗号 header の乱数生成・圧縮・暗号化処理は変更していない。
別々に生成した書庫全体の ciphertext は乱数を含むため直接同一とは比較せず、固定初期鍵の spool byte比較と
既存の header / payload / 暗号 oracleを使う。SIGKILL / power loss の実機注入は今回実施していない。
最終の指定 filter では、新規2件を含む `EncryptionTests` **18件・失敗0・skip 0**。
修正前に1だった名前付き spool 件数は、圧縮中・add後とも0の assertionを通過した。

### G6 — carried 名の衝突を open で拒否

変更ファイル: `Sources/GyoshukuKit/ArchiveRewriter.swift`、
`Tests/GyoshukuKitTests/ArchiveRewriterCollisionTests.swift`（追加）。

Python zipfile の独立 fixture で、重複、NFC/NFD、directory の末尾 `/`、file と子の衝突を作った。
修正前は全ケースで open が成功し、commit が最初の1 entry を書いてから失敗した。

```text
XCTAssertThrowsError failed: did not throw an error - carried-name collisions must be refused at open
G6 RED late collision after 1 carried entries: duplicatePath("a.txt")
G6 RED late collision after 1 carried entries: duplicatePath("café.txt")
G6 RED late collision after 1 carried entries: duplicatePath("folder/")
G6 RED late collision after 1 carried entries: invalidPath("parent/child")
G6 RED late collision after 1 carried entries: invalidPath("parent")
```

出力名を `ArchiveWriter.normalizedPath` で検証する既存 loop に `EditPathReservations.validate` / `insert` を追加。
省略する root directory の空名は予約しない。衝突した最初の entry に対し、open で
`RewriterError.unrepresentable(entry:reason:)`、理由 `正規化した出力名が他の entry と衝突しています: <name>` を返す。
正当な子→明示親directoryの順序は許す。原本 byte と sibling集合は不変で、部分出力を作らない。

追加テスト:

1. `testDuplicateCarriedNamesAreRefusedAtOpen`
2. `testCanonicallyEquivalentCarriedNamesAreRefusedAtOpen`
3. `testDirectorySlashNormalizationCollisionsAreRefusedAtOpen`
4. `testCarriedFileAndChildCollisionsAreRefusedInEitherOrder`
5. `testExplicitDirectoryAfterChildAndOmittedRootsRemainRepresentable`

**5テスト・5 failures → 5テスト・失敗0**（親子は1メソッド内で両順序、正常例は修正前から成功）。
G5 / G6 の合同ログは `/private/tmp/gyoshuku-g5-g6-before.log` と `...-g5-g6-after.log`。
合同では **7テスト・7 failures → 7テスト・失敗0・skip 0**。
最終実行も新規5件と既存 `ArchiveRewriterTests` 37件はすべて成功した。
修正後の拒否出力例:

```text
G6 unrepresentable: a.txt: 正規化した出力名が他の entry と衝突しています: a.txt
```

### G7 — 文書と最終検証

`CHANGELOG.md` Unreleased に G4 / G5 / G6 とそれぞれの理由を追加した。
本記録を追記し、`README.md` も probe / open の役割と匿名 ZipCrypto spool の説明を更新した。
文書項目に実行可能な failing assertion / 新規テストはない。

```sh
export CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/gyoshuku-module-cache
swift build --disable-sandbox
swift test --disable-sandbox --filter 'ZipUpdater|ZipUpdateProbe|ZipDeleteRename|ZipRebuild|Encryption|ArchiveRewriter|EmptyArchive'
swift test --disable-sandbox --filter 'ArchivePathValidationTests|EditPathReservationsTests|ArchiveEditingScaleTests|ArchiveUpdaterEntryNamesTests|ArchiveUpdaterOptionsTests|ZipModernMethodEditingTests'
git diff --check
```

- `swift build`: 成功。ログ `/private/tmp/gyoshuku-g4-g7-build.log`。
- 指定 filter: **122テスト・失敗0・unexpected 0・skip 0**、325.996秒。
  ログ `/private/tmp/gyoshuku-g4-g7-required.log`。
  新規 G4 10件 / G5 2件 / G6 5件の計17件、既存 probe 10件・updater 11件・
  delete/rename 20件・ZIP64境界5件、300 MiB暗号化も含む。
- 指定 filter から外れる関連箇所も検証した。パス検査2件、予約管理2件、編集規模1件、
  entryNames 7件、updater options 6件、modern ZIP method 2件の **20テスト・失敗0・skip 0**。
  ログ `/private/tmp/gyoshuku-g4-g7-adjacent.log`。指定 filter との重複1件を除き、最終2実行は
  **141種類のテスト**を通過した。今回フルスイートは再実行していない。
- G1 の APFS 測定も再実行され、`before=589824000000 after=589824000000 consumed=0`。
  冒頭の測定上の限界は引き続き適用し、これだけで物理割当削減を実証したとはしない。
- `git diff --check`: 成功。未追跡の6ファイルも `git diff --no-index --check /dev/null` で
  whitespaceエラーなし。README / CHANGELOG / 本記録の相対 Markdown リンク22件の存在を確認した。
- SwiftPM の通常 cache directory への権限警告は残るが、上記の /private/tmp module cache指定で成功した。
- アプリ側のビルド / UI は未実施。KaitoKit / KaitoFinder を変更せず、コミットも作成していない。
  最終 HEAD は開始時と同じ `e1f16ac`。

## オーケストレータによる全件検証（2026-09-19）

- G1–G3 適用後: `swift test` 218 件、1 skip、失敗 0。
- G4–G7 適用後（KaitoKit の K1–K13 を含む path 依存で）: `swift test` **235 件、1 skip、失敗 0**（6m38s）。
  skip は `GYOSHUKU_LARGE_TAR_TESTS` の 4 GiB tar 1 件。
- 修正前ベースライン: 202 件、1 skip、失敗 0。
- Release の bench harness での実測: 100,000 項目 ZIP の `ArchiveUpdater.probe` 0.2〜2.5 ms に対し `ArchiveUpdater.open` は
  G4 の CD walk（KaitoKit の raw record と照合、record ごとに pread）で 230 ms → 465 ms。
  128 MiB（64 MiB × 2、stored）の同長改名 + commit は 8.6 ms、`unzip -t` 成功。
- 受け入れたトレードオフ: コメント内に整合した EOCD 形状を含む正当な ZIP は `ambiguousEndRecord` で編集不可になる
  （読み取りは KaitoKit が従来どおり行う）。KaitoFinder は既存の文言「このアーカイブは変更できません。」に理由を添えて表示する。

### オーケストレータによる追加修正

`ZipCentralDirectory.validate` の entry ごとの `Task.checkCancellation()` を外した。KaitoFinder は保存確定後の
再オープンを取消し済み Task で行う（遅れた取消しで成功を隠さない設計）ため、open が取消しに依存すると plain ZIP でも
`ArchiveUpdater.open` が失敗し、アプリ側で「対応していないフォーマットです。」になっていた
（`ArchiveSaveAsTests.testCommittedOutputStillBecomesBackingFileAfterLateCancellation`）。walk は
`maxTotalMetadataSize` / `maxEntryCount` で有界。`ZipUpdaterIntegrityTests` / `ZipUpdateProbeTests` / `ZipUpdaterTests`
31 件成功。
取消し検査を外した後の全件: `swift test` **235 件、1 skip、失敗 0**（3 回目、13:1x）。

## B1（GyoshukuKit 側、オーケストレータ実装、2026-09-19 15:2x）

`ArchiveRewriter.open` の表現可能性の walk を `static validateRepresentability(entries:format:)` に切り出し、
`public static func probe(entries:format:)` を追加した。walk は `entries` と `format` だけに依存するため、
既存の受理・拒否と `unrepresentable` の文言は変わらない。
テスト `ArchiveRewriterProbeTests`（2 件）: G6 の衝突 fixture と受理される形を zip / tar / tar.gz / 7z / LHA の各形式で
`open` と `probe` にかけ、判定文字列（accepted / unrepresentable(entry): reason）が一致することを oracle にする。
合成 entry で LHA の symlink 拒否、`.other` 種別、参照先のない hard link も確認。
`ArchiveRewriterProbeTests` / `ArchiveRewriterCollisionTests` / `ArchiveRewriterTests` 44 件、失敗 0。
`ArchiveRewriter.probe` 追加後の全件: `swift test` **237 件、1 skip、失敗 0**（4 回目、15:5x）。
