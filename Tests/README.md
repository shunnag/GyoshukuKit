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
| `IOEvents` | 製品の task-local の I/O 観測点に渡し、読み書きの範囲と量を記録する |
| `ArchiveTestDisk` | hdiutil で作る FAT32・ExFAT・HFS+ の disk image（作れなければ skip） |
| `ByteAssertions`・`TestCorpus`・`ArchiveFormat+Testing` | 大きな file の chunk ごとの比較、seed を固定した byte 列、形式ごとの拡張子 |
| `SingleStreamTestSupport` | 単独 stream の実ツール復号、decoder と bsdtar の pipe、lzip trailer の独立検査 |
| その他 | `SevenZipExternalOracles`・`CompressedTarCompatibility`・`SevenZipProbePayload`・`BatchAdditionTestSupport`・`AdditionProgressTestSupport` |
| `SevenZipSolidFilterSupport` | 小さい Mach-O 相当の入力、solid / filter の必須7zz t / l / x と KaitoKit 往復、folder 数・substream CRC の照合 |

## Fixtures

- `appledouble/` — ditto（Finder の圧縮）と macOS の tar が書いた AppleDouble sidecar 付きの ZIP / tar。`AppleDoubleSidecarEditingTests` が読む。
- `lha-updater/` — KaitoKit ef06e22 の LHA 書庫と manifest。`LHAUpdateSupport` が hash を照合してから使う。
- `lha-methods/` は method / level 追加前の既存 LH5 fixture 出力。`LHADefaultOutputTests` が byte 比較し、再生成しない。
- `sevenzip-edit/` — 7z の編集の 33 書庫と、期待する構造・復号の JSON。`SevenZipEditSupport`・`SevenZipHeaderSerializerTests` が読む。
- `lzma-writers/`: 自前 LZMA encoder の writer 接続前の Apple tar.xz / 7z LZMA2 / ZIP XZ 出力。`LZMAWriterDefaultOutputTests` が byte 比較し、再生成しない。
- `zip-modern/` — KaitoKit 26b84ca の XZ / Zstandard（AES・ZipCrypto 付きを含む）ZIP。`ZipModernMethodEditingTests`・`ZipReencryptionInteropTests` が読む。
- 出自と license は `Fixtures/NOTICE` と各 set の README にある。

## opt-in の試験（`GYOSHUKU_*`）

鍵が無ければ `Set <KEY>=<値> to run <class>; see Tests/README.md` で skip する。計測（✱）は
`swift test -c release -Xswiftc -enable-testing --filter <class>` で走らせる（閾値は release build の値）。
計測の行は tag と列を tab で区切って stderr に出る。

| 鍵 | 開く試験 | 内容・条件 |
|---|---|---|
| `GYOSHUKU_MULTICORE_BENCHMARK=1` | ✱ `MulticoreBenchmarkTests` / `ZipConcatenatedZstdProbeTests` | 256 MiB混合corpusのwriter wall / process CPU / サイズ / SHA-256。release必須。`Benchmarks/multicore.py`と同日検証記録を参照。corpusとJSONL出力は`GYOSHUKU_MULTICORE_CORPUS` / `GYOSHUKU_MULTICORE_RESULTS`。 |
| `GYOSHUKU_LZMA_BENCHMARK=1` | ✱ `LZMAEncoderBenchmarkTests` | 自前 LZMA2 / xz / Apple の level 1・6・9、4 MiB text と実在 Mach-O（最大 32 MiB）。`-c release` 必須。design.md の自前 LZMA encoder 節 |
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

`ZipPPMdWriterTests` / `SevenZipPPMdWriterTests` は level 1・既定6・9と order / memory の上書き、
ZIP AES / ZipCrypto、7z AES / header 暗号化・solid・BCJ / ARM64 / Delta、updater / rewriter を検査する。
必須の7zz `t / l -slt / x` と KaitoKit の全 byte 往復、7zz が書く PPMd の逆方向、
20 MiB text と1 MiBモデルの restart、thread 数による出力 byte 一致を扱う。
ZIP の7zz一覧は `PPMd` のみのため parameter word を直接検査し、7z は表示の order / memory と5 byte propertiesを照合する。

## 外部ツールが無いとき

- 方針は一つ: 参照ツールが無ければ失敗する（skip しない）。`ReferenceTool.run` と `ReferenceTool.require(候補)`、それを使う
  `TestSupport.run`・各 `*TestSupport` の `run` / `verify`・`SevenZipExternalOracles.check` は XCTFail して throw する。
- skip するのは名前に `WhenAvailable` を含む試験（`ReferenceTool.optional(候補)`。現状は `ArchiveRewriterTests.testLHAOutputPassesLhasaWhenAvailable`）と、
  ツールではなく環境の機能が無いとき（`ArchiveTestDisk` の hdiutil image、APFS clone、sparse file）だけ。
  `ReferenceToolPolicyTests` が両方の経路を固定する。
- 7zz や GNU tar があるときだけ照合を足す: `LHAUpdaterLargeOffsetTests`・`SevenZipUpdaterLargeOffsetTests`・
  `TarUpdaterInteropTests`・`SevenZipUpdaterDifferentialTests`。`XZPackingLayoutTests` は xz が無ければ失敗する。
- CI（`.github/workflows/ci.yml`）は `brew install sevenzip zstd xz lzip lz4 brotli lhasa gnu-tar autoconf automake` と
  固定commitの LHa for UNIX の一時ビルドで必須ツールを入れる。製品の依存には加えない。

`LHACompressionMethodTests` は Lhasa・7zz に加えて `~/.local/bin/lha-unix`（LHa for UNIX）を必須にする。
`--help` の `o[567]` を確認して `-ao62` / `-ao72` で逆方向の書庫も作る。未導入なら失敗する。
空 LHA の `[0]` を認識しないツールは同じ byte の基準書庫と終了値を比較する。
CP932 の日本語名は raw header と KaitoKit、文字コードを指定した LHa for UNIX の `-t` で検証する。
macOS の Lhasa / 7zz は日本語名での抽出を復元できないため、全 member の `t` と ASCII member の抽出を照合する。

`CompressedTarNewFormatTests` は tar.lzma / tar.lz / tar.lz4 / tar.br / tar.Z を実ツールで復号し、
bsdtar の stdin に pipe して一覧・抽出を検査する。20 MiB の混合入力、lzip level 0 / 6 / 9 と
trailer から数えた複数 member、KaitoKit の全 byte 往復も検査する。`ArchiveRewriterNewTarFormatTests` は
ZIP との相互変換と tar.lz4 / tar.lz の削除・改名・追加を扱う。
`SingleStreamCompressorTests` は9形式で空・1 byte・1 MiB text・9 MiB乱数の実ツールとKaitoKit往復、
読取 byte 進捗、directory / symlink / 既存出力の拒否、公開時の競合、途中取消しの一時file削除を検査する。
`LzipCompressorTests` はメモリ予算による並列数制限、辞書を保った拒否、DSの分数、
16 MiB境界を越える入力の逐次・並列byte一致とpending input上界を検査する。
`/opt/homebrew/bin/lzip`・`lz4`・`brotli`、xz、macOS の gzip / bzip2 / uncompress と bsdtar を必須にする。
`CompressedTarZstdTests` は level 1 / 3 / 19、20 MiB入力と4 threadの複数frame、
`zstd -t` と decoderからbsdtarへのpipe、KaitoKit往復、ArchiveRewriterの追加・削除・改名を検査する。
単独 .zstも `SingleStreamCompressorTests` の空・1 byte・1 MiB text・9 MiB乱数に含める。
`ZipZstdWriterTests` は必須7zzの `i / t / l -slt / x` とKaitoKitで非暗号・AES・ZipCryptoを照合し、
raw entry dataのzstd復号、単一frame・ZIP64・updater追加・rewriterも検査する。
7-Zip 26.03はmethod 93の実抽出に成功する。必須の `/opt/homebrew/bin/zstd` はCIでも導入する。
空 .Z を BSD uncompress が拒否する既知の制限は終了値・診断・空出力を照合し、KaitoKit と7zzで復号する。
制限付き環境が `uncompress -c` の `/dev/stdout` 再openだけを拒否した場合は同じ実ツールのfile出力を使う。
