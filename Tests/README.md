# GyoshukuKit の試験

`swift test` が走らせる XCTest の target は `GyoshukuKitTests/`、試験が読む書庫は `Fixtures/`。
書き込み速度の計測は別 package の [Benchmarks](../Benchmarks/README.md) で行う。
説明はこの file に置く（target の directory の中の `.md` は SwiftPM が未処理の file として警告する）。

## 配置

- `Zip/`・`Tar/`・`CompressedTar/`・`SevenZip/`・`LHA/`・`Compression/`・`Editing/`・`Writer/` は、試験する型のある
  `Sources/GyoshukuKit/<Dir>/` に合わせる。全形式を公開 API で書く試験は `Writer/`、rewriter・名前の予約・
  spliced output など形式をまたぐ編集は `Editing/` に置く。
- `Probes/` は既定の `swift test` では skip する計測の class（`*ScaleProbeTests`・`EditPathReservationScaleProbeTests`・
  `WriterOutputBaselineTests`）。opt-in でも正しさを見る試験（`*LargeOffsetTests`・`TarUpdaterOracleTests`・`*InteropTests`）は
  形式の directory に置く。
- 一つの file に一つの XCTestCase を置き、file 名を class 名にする（`swift test --filter X` と `X.swift` が一対一）。
  例外は形式ごとの三つの class を束ねる `CompressedTar/CompressedTarSpliceDeterminismTests.swift`。
- `Support/` は一段のまま置く。`TestPaths` がこの位置から package の root を求める。

## Support/ の道具

| file | 役割 |
|---|---|
| `TestSupport` | 固定の日時、`directory(label)`・`work(in:)`、stderr への `report`、外部ツールの `run`、`assertKaitoKitRoundTrip` と `ExpectedEntry` |
| `TestPaths` | package の root・`Tests/Fixtures`・`.build/verification` の場所 |
| `ReferenceTool` | 外部ツールの path の一覧と、起動・終了値の検査・log の保存をまとめた `run` |
| `OptInGate`・`ScaleProbe` | opt-in の門（下の表）と、計測の負荷待ち・TSV の行・時間の閾値 |
| `ZipTestSupport`・`TarTestSupport`・`SevenZipTestSupport`・`LHATestSupport`・`EncryptionTestSupport` | 形式ごとの fixture と `verify`（外部ツールと KaitoKit の往復で照合） |
| `ZipEditTestSupport`・`TarEditTestSupport`・`CompressedTarTestSupport`・`SevenZipEditSupport`・`LHAUpdateSupport` | 編集の試験の fixture・操作の列・照合 |
| `ZipBytes`・`TarBytes`・`SevenZipBytes`・`EncryptedSevenZipHeader`・`LHABytes`・`LHAHeaderBuilder`・`TestBytes` | 製品の serializer を使わず、公開の format の表から読む byte 検査器と組み立て |
| `LegacyZipRebuild` | c0df9fb の ZIP 再構築を byte 比較の oracle として固定したもの。現行の実装に合わせて直さない |
| `IOEvents`（`ZipIOEvents`） | 製品の task-local の I/O 観測点に渡し、読み書きの範囲と量を記録する |
| `ArchiveTestDisk` | hdiutil で作る FAT32・ExFAT・HFS+ の disk image（作れなければ skip） |
| `ByteAssertions`・`TestCorpus`・`ArchiveFormat+Testing` | 大きな file の chunk ごとの比較、seed を固定した byte 列、形式ごとの拡張子 |
| その他 | `SevenZipExternalOracles`・`CompressedTarCompatibility`・`SevenZipProbePayload`・`BatchAdditionTestSupport`・`AdditionProgressTestSupport` |

## Fixtures

- `appledouble/` — ditto（Finder の圧縮）と macOS の tar が書いた AppleDouble sidecar 付きの ZIP / tar。`AppleDoubleSidecarEditingTests` が読む。
- `lha-updater/` — KaitoKit ef06e22 の LHA 書庫と manifest。`LHAUpdateSupport` が hash を照合してから使う。
- `sevenzip-edit/` — 7z の編集の 33 書庫と、期待する構造・復号の JSON。`SevenZipEditSupport`・`SevenZipHeaderSerializerTests` が読む。
- `zip-modern/` — KaitoKit 26b84ca の XZ / Zstandard（AES・ZipCrypto 付きを含む）ZIP。`ZipModernMethodEditingTests`・`ZipReencryptionInteropTests` が読む。
- 出自と license は `Fixtures/NOTICE` と各 set の README にある。

## opt-in の試験（`GYOSHUKU_*`）

鍵が無ければ `Set <KEY>=<値> to run <class>; see Tests/README.md` で skip する。計測（✱）は
`swift test -c release -Xswiftc -enable-testing --filter <class>` で走らせる（閾値は release build の値）。
計測の行は tag と列を tab で区切って stderr に出る。

| 鍵 | 開く試験 | 内容・条件 |
|---|---|---|
| `GYOSHUKU_LARGE_ZIP_TESTS=1` | `ZipReencryptionBoundaryTests` の `testLarge…` 3 件 | 300 MiB の payload と、ZIP32 の上限（4 GiB）をまたぐ再暗号化。10 GiB 以上の空き |
| `GYOSHUKU_LARGE_TAR_TESTS=1` | `CompressedTarWriterTests.testEntryLargerThanFourGiB…` | 4 GiB を越える entry。6 GiB 以上の空き |
| `GYOSHUKU_LARGE_TESTS=1` | `CompressedTarLargeOffsetTests` | 4 GiB を越える CRC の結合と image の offset |
| `GYOSHUKU_TAR_LARGE=1`・`GYOSHUKU_LHA_LARGE=1`・`GYOSHUKU_7Z_LARGE=1` | `TarUpdaterLargeMemberTests`・`LHAUpdaterLargeOffsetTests`・`SevenZipUpdaterLargeOffsetTests` | sparse file で 4 GiB（tar は 9 GiB の member）を越える offset の編集 |
| `GYOSHUKU_TAR_ORACLE_DIR=<dir>` | `TarUpdaterOracleTests` | `<dir>/arc/*.tar` の編集を `<dir>/out/*.intended.tar` と byte 比較 |
| `GYOSHUKU_TAR_GIT_REPO=<clone>` | `TarUpdaterInteropTests.testRealGitArchiveCommentIsPreserved` | 9fb6ee2 を含む GyoshukuKit の clone から `git archive` した tar |
| `GYOSHUKU_P2_COMPAT_OUTPUT=<dir>`（任意で `GYOSHUKU_P2_COMPAT_BASELINE=<dir>`） | `WriterOutputBaselineTests` | 全形式の出力を書き出し、別の build が書いた同名の file と byte 比較 |
| `GYOSHUKU_SCALE_PROBES=1` と `GYOSHUKU_SCALE_CORPUS=<dir>`（任意で `GYOSHUKU_SCALE_NEW_ARCHIVES=<dir>`） | ✱ `CompressedTarScaleProbeTests.testMixedNewAndOldLayouts` | `<dir>/arc/mixed.{tar,tgz,tbz,txz}` の新旧の配置の編集（TAR-SCALE） |
| `GYOSHUKU_SCALE_PROBES=1` | ✱ `EditPathReservationScaleProbeTests` | 1,000〜4,000 entry の一括改名（EDIT-RESERVATION-SCALE） |
| `GYOSHUKU_P14_ARCHIVES=<dir>`（任意で `GYOSHUKU_P14_ASSERT=1`） | ✱ `CompressedTarScaleProbeTests.testXZPackingArchives` | `<dir>/{mixed,payload,mid}.tar.xz`（あれば `old-*` も）の編集（TAR-XZ-PACKING） |
| `GYOSHUKU_ZIP_SCALE_ENTRIES=<n ≥ 2>`・`GYOSHUKU_TAR_SCALE_ENTRIES=<n ≥ 3>`・`GYOSHUKU_LHA_SCALE_ENTRIES=<n ≥ 3>` | ✱ `ZipUpdaterScaleProbeTests`・`TarUpdaterScaleProbeTests`・`LHAUpdaterScaleProbeTests` | n entry の書庫の編集（ZIP-/TAR-/LHA-SCALE）。LHA の閾値は n = 100000 のときだけ |
| `GYOSHUKU_7Z_SCALE_DIR=<dir>`（任意で `GYOSHUKU_7Z_SCALE_CASE=<fixture>/<操作>`） | ✱ `SevenZipUpdaterScaleProbeTests` | `<dir>/{g_real,g_k100,z_k100,z_real_default}.7z` の編集（7Z-SCALE） |
| `GYOSHUKU_LIVE_NAME_SCALE=1` | ✱ `LiveNameCheckTests.testShiftJISFirstScanWhenEnabled` | 500,000 個の Shift-JIS の名前の検査（LIVE-NAME-SCALE） |
| `GYOSHUKU_SCALE_ASSERT=1` | ✱ すべて | 時間の閾値の超過を失敗にする。無ければ行（と `*-MISS` の行）を出すだけ |
| `GYOSHUKU_{TAR,LHA,7Z}_DIFF_ITERATIONS=<n>` | `*UpdaterDifferentialTests`（skip しない） | 反復の回数。既定は 300・300・200 |
| `GYOSHUKU_P3_REPETITIVE_FIXTURE=1` | `CompressedTarTestSupport.fixture`（skip しない） | large-A / large-B の先頭 64 KiB を乱数にせず、同じ byte のままにする |

## 検証出力の保存

`TestSupport.directory(label)` は `.build/verification/<label>` を空にして作り、試験の後も残す。失敗したときに
書庫と外部ツールの log を調べるためで、同じ label の次の実行が消す。数十 MiB を超える出力はその試験が成功後に消す。
label は suite の中で重ねない（重なると別の試験の出力を消す）。

## 外部ツールが無いとき

- 方針は一つ: 参照ツールが無ければ失敗する（skip しない）。`ReferenceTool.run` と `ReferenceTool.require(候補)`、それを使う
  `TestSupport.run`・各 `*TestSupport` の `run` / `verify`・`SevenZipExternalOracles.check` は XCTFail して throw する。
- skip するのは名前に `WhenAvailable` を含む試験（`ReferenceTool.optional(候補)`。現状は `ArchiveRewriterTests.testLHAOutputPassesLhasaWhenAvailable`）と、
  ツールではなく環境の機能が無いとき（`ArchiveTestDisk` の hdiutil image、APFS clone、sparse file）だけ。
  `ReferenceToolPolicyTests` が両方の経路を固定する。
- 7zz や GNU tar があるときだけ照合を足す: `LHAUpdaterLargeOffsetTests`・`SevenZipUpdaterLargeOffsetTests`・
  `TarUpdaterInteropTests`・`SevenZipUpdaterDifferentialTests`。`XZPackingLayoutTests` は xz が無ければ失敗する。
- CI（`.github/workflows/ci.yml`）は `brew install sevenzip xz lhasa gnu-tar` で全てのツールを入れる。
