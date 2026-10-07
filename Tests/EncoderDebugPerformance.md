# DEBUG encoder 試験の計測（2026-10-07）

作業treeは `speed-testspeed`、baselineは `f273d346fc8e0743d56604e8c59adb61cedc1828`。編集はTests/だけ。
Sources/・Package.swift・frozen fixturesは編集しない。設計書に相当する試験の実測は、Tests-onlyの指定に従いこのfileに置く。

Apple M4 Max（16 cores、128 GB）、macOS 27.2（26B5101f）、Apple Swift 6.4（swiftlang-6.4.0.34.1）。SwiftPMのDEBUG `-Onone`。pristineのTestsに工程timerと一時file分離だけを足して `.build-base` にビルドし、変更版と対にして5回実行した。
5 workersで同じclass群を実行し、各worker内ではbaseline完了直後にnewを走らせた。最後にraw LZMAの境界assertionを追加したため、表のnew側はその最終版8 classを同じ5-worker条件でさらに5回測り直した。別の5-worker群で残りの新規classも計測した。
他workstream・release検証・benchmarkも同じMacで走るため数字には負荷の揺れがある。表は各class / testのbest-of-5。serial全suiteの壁時計ではなくXCTest所要時間の合計。
LZMAのcache初期化はclass順で先に走るoracle試験に入る。個別のround-trip試験だけを選ぶと、その試験が初期化も負担する。

参照ツール実測version: 7zz 26.04、xz/liblzma 5.8.4、zstd 1.5.7。CI提示値の7zz 26.03とは異なる。
Instrumentsはsandboxのキャッシュ権限で起動できず、DispatchTimeの工程timerを使用。releaseのdSYM作成も拒否され、SwiftPMの `-debug-info-format none` で検証した。

## 合計

元の137 default tests 5,421.581 s → 新しい140 default tests 974.804 s（5.56倍、82.0%短縮）。新規140件には独立CRC/PRNGの2件とLZMA2境界の1件を含む。14 FullSizeはdefaultでskipする。

CI推計: 提示の11件（合計5639 s）を各testのMac比率で縮め、残り1352 sを残り全testのMac合計比率 0.7485 で縮めると、新規分は約1,222 s（6,991 / 推計 = 5.72倍）。
旧CI全体9,924 sのうち新規以外2,933 sを据え置くと約4,155 s。CIは実行していない。新規以外の以前の2,776 sと、提示CIの残差2,933 sは同じ測定値として扱わない。

## 変更した各ケースとdefault coverage

| Test | Before s | After s | 変更 | defaultで保持する性質 |
|---|---:|---:|---|---|
| `PPMdEncoderTests.testLargeTextAndRandom` | 1298.850 | 44.184 | 128 KiB text / 256 KiB random。元の 1 / 8 MiB は FullSize。 | H / I、full alphabet、text の実ツール・KaitoKit全 byte 往復。復旧は別の count 検査。 |
| `PPMdEncoderTests.testSmallMemoryRestorationOnTwentyMiBText` | 511.768 | 6.233 | 256 KiB + 17 byte、heap 1 MiB。元の20 MiBはFullSize。 | H / I restart と I cut-off を count > 0 で必須化。実測は各2回。 |
| `LZMAEncoderTests.testLargeCorporaAndChunkBoundaries` | 862.556 | 12.070 | random / text 各65,537 byte、mixed 2.625 MiB + 17 byte。圧縮結果を oracle と共有。 | level 0/1/3/5/6/9、raw EOS / 既知サイズ / LZMA2全 byte。mixedは >1 MiB距離、raw→compressed resetもwireで検査。 |
| `LZMAEncoderTests.testIndependentXZAndAloneOracles` | 620.866 | 68.766 | 同じ3種類の圧縮結果を各入力・levelにつき一度作る。元の1/4/20 MiBはFullSize。 | xz t/dc、7zz t、product .alone の既知 / 未知サイズをxzで復号。 |
| `LZMAEncoderTests.testOddPiecesProduceIdenticalStreams` | 71.620 | 1.474 | 65,537 byteでwidth 1/7/65,537。元の2 MiB + 777 byteはFullSize。 | bytewiseの分割一致。2 MiB境界直前の1/7-byte分割を新しい専用試験でraw / LZMA2双方に検査。 |
| `SevenZipPPMdWriterTests.testTwentyMiBTextWithSmallMemoryKeepsOneStream` | 336.574 | 2.728 | 復旧を確認した256 KiB + 17 byteを共有。thread 1/4の全byte一致後はoracleを一度だけ実行。 | 複数I/O、heap1 MiB、solid1 folder、tail substream、CRC、全byte・metadata・7zz t/l/x。元20 MiBはFullSize。 |
| `ZipPPMdWriterTests.testTwentyMiBTextWithRestartsAndThreadIndependentStream` | 306.618 | 2.540 | 同じ復旧corpus、複数I/O。thread 1/4のbyte一致後はoracleを共有。 | 単一PPMd stream、pending input=0、全byte・metadata・7zz t/l/x。元20 MiBはFullSize。 |
| `SevenZipPPMdWriterTests.testSolidFiltersAndEncryption` | 105.738 | 12.902 | 4,097 / 8,197 byte。小入力でも正負のBL/CALL/ADRPを含める。元32,769 / 262,149 byteはFullSize。 | none/BCJ/ARM64/Delta×solid on/off×AES/header暗号化 on/offの16条件。末尾余りは元と同じ mod8=1/5。coder、bind、properties、CRC、metadata、7zz t/l/xとKaitoKit。 |
| `ZstdEncoderTests.testOptimalTreeBlockTailWithLongText` | 85.704 | 3.585 | 128 KiB blockを2つ＋17 byte、level13/19。元4 MiBはFullSize。 | optimal tree のfull block末尾と短いframe tail、compressed block、zstd t/dcとKaitoKit。 |
| `ZstdEncoderTests.testTextAndRandomWithOddPiecesAtAllRequestedLevels` | 25.016 | 2.203 | text128 KiB+17、random256 KiB+17。元1/8 MiBはFullSize。 | 4 levels、3 raw blocksへのfallback、compressed/ratio、pending input上界、非整列finish、全byte。 |
| `ZstdEncoderTests.testTwentyMiBMixedCrossesWindowAndRawRLECompressedTransitions` | 10.894 | 4.371 | random1 block＋bulk zero＋text。各levelの2×window+128 KiB+17 byte。元20 MiB mixedはFullSize。 | windowと2-window buffer compactを越える。raw/RLE/compressed各type、unknown size、全byte。level19でも16 MiBを越える。 |
| `SingleStreamCompressorTests.testEveryFormatOnEmptyOneByteTextAndRandomFiles` | 66.270 | 8.193 | text128 KiB、random512 KiB+17。元1/9 MiBはFullSize。 | 9 formats×空/1byte/text/random、3回のI/O read、非整列finish、進捗・公開前出力なし・CLI/KaitoKit全byte・一時fileなし。 |
| `LZWStreamEncoderTests.testVariableWidthsClearAndRealCompressCompatibility` | 86.955 | 6.844 | text128 KiB→random256 KiB→text128 KiB、small samples。元7 MiB mixed /9 MiB random /12 MiB textはFullSize。 | maxbits12/16双方でCLEAR count>0。辞書満杯は全widthを通る。再学習、header、実compressサイズ比、gzip/uncompress/7zz/KaitoKitの全byte。 |
| `TarXZLZMALevelTests.testLevelNineConcurrencyCapOn128MiBInput` | 64.482 | 1.946 | 4 MiB+512 byte。元128 MiBはFullSize。 | 4 MiB packingを越え、512-byte整列でbody単独chunkを保つ。192 MiB piece、thread64要求→1、1200 MiB予算・per-worker/pending bound、xz tとKaitoKit全byte・chunkMap。 |

全行の元サイズ・入力パターン・分割幅は同名の `…FullSize` に保持する。English-like 1 MiB のPPMd < xz-6サイズassertionは元のままdefault。
小さい入力だけで保証できない境界を独立に確認する。PPMdはheap復旧count、LZMA2はwire上のuncompressed chunk長 `[2 MiB, 17]`。2 MiB境界直前の1/7-byte分割はraw / LZMA2の両方で全levelにbyte一致・全復号を検査する。
writerのthread 1と4は両方をencodeしてarchive全byteを比較する。最初のarchiveをt/l/xとKaitoKitで検査した後、同じbyteの2本目は同じoracleを再実行しない。

## 工程の分解

`encode.*` はencoder呼出し、またはpublic writerのencode / serialize / file I/O。`decode.*` はKaitoKitとData比較。
`oracle.process+files` は外部起動・待機・log / decoded file読書き。`framing.crc` は独立containerのIEEE CRC。
`test.output-append` と `test.decode-append` は内側のData appendのみ。writer hookをSourcesに足さず、Copy対照からI/O・filter・暗号化を測る。writeからCopyを引いたencoder費用は近似であり、厳密なプロファイラ分解とは呼ばない。

| Test / fastest baseline run | Encode/write s | Kaito+compare s | Oracle+files s | Corpus s | CRC s | Output append s | その他 s |
|---|---:|---:|---:|---:|---:|---:|---:|
| `PPMdEncoderTests.testLargeTextAndRandom` | 477.950 | 792.548 | 8.913 | 1.214 | 18.198 | 0.002449 | 0.024 |
| `PPMdEncoderTests.testSmallMemoryRestorationOnTwentyMiBText` | 134.112 | 324.665 | 6.486 | 0.076 | 46.414 | 0.002501 | 0.012 |
| `LZMAEncoderTests.testLargeCorporaAndChunkBoundaries` | 759.851 | 102.385 | 0.000 | 0.278 | 0.000 | 0.000000 | 0.042 |
| `LZMAEncoderTests.testIndependentXZAndAloneOracles` | 608.305 | 0.000 | 10.552 | 1.914 | 0.000 | 0.000000 | 0.095 |
| `LZMAEncoderTests.testOddPiecesProduceIdenticalStreams` | 15.935 | 8.541 | 0.000 | 0.152 | 0.000 | 0.000000 | 46.992 |
| `SevenZipPPMdWriterTests.testTwentyMiBTextWithSmallMemoryKeepsOneStream` | 90.422 | 241.584 | 4.479 | 0.078 | 0.000 | 0.000000 | 0.013 |
| `ZipPPMdWriterTests.testTwentyMiBTextWithRestartsAndThreadIndependentStream` | 88.853 | 213.537 | 4.138 | 0.078 | 0.000 | 0.000000 | 0.012 |
| `SevenZipPPMdWriterTests.testSolidFiltersAndEncryption` | 38.315 | 59.495 | 4.341 | 0.000 | 0.000 | 0.000000 | 3.587 |
| `ZstdEncoderTests.testOptimalTreeBlockTailWithLongText` | 85.214 | 0.116 | 0.274 | 0.098 | 0.000 | 0.000000 | 0.003 |
| `ZstdEncoderTests.testTextAndRandomWithOddPiecesAtAllRequestedLevels` | 23.023 | 0.129 | 1.096 | 0.712 | 0.000 | 0.003234 | 0.053 |
| `ZstdEncoderTests.testTwentyMiBMixedCrossesWindowAndRawRLECompressedTransitions` | 9.847 | 0.390 | 0.550 | 0.078 | 0.000 | 0.001689 | 0.028 |
| `SingleStreamCompressorTests.testEveryFormatOnEmptyOneByteTextAndRandomFiles` | 32.075 | 27.292 | 6.089 | 0.773 | 0.000 | 0.000000 | 0.041 |
| `LZWStreamEncoderTests.testVariableWidthsClearAndRealCompressCompatibility` | 14.815 | 64.412 | 6.071 | 1.577 | 0.000 | 0.004290 | 0.075 |
| `TarXZLZMALevelTests.testLevelNineConcurrencyCapOn128MiBInput` | 64.056 | 0.000 | 0.215 | 0.000 | 0.000 | 0.000000 | 0.212 |

Data appendはencodeの内側から差し引く。Kaitoのappendはdecode内側であり別に加算しない。corpus.mixed内のrandom/textも二重に足さない。
OddPiecesのpushループ、tar readerの直接read、test-owned file読書き・assertionは「その他」に入る。encoderの正確な直接計測がないOddPiecesの「その他」をtest-side費用だと断定しない。tarはwriterの残差に直接reader費用が入る。

## @_optimize(speed) の -Onone 実測

独立した `Tests/Tools/CorpusOptimizationProbe.swift` を同じSwift compilerでplain / `-D OPTIMIZE` の2本にし各5回。両方のCRCは2,766,007,512で一致。

| 8 MiB、best-of-5 | Plain s | @_optimize(speed) s |
|---|---:|---:|
| 旧bytewise PRNG | 0.651068 | 0.665448 |
| 旧bitwise CRC | 5.095895 | 5.119170 |

このtoolchainの -Onone では改善を確認できなかった。hot helperにはこのattributeを採用しない。
randomは従来のseed / recurrence / byteを保持してDataを直接埋め、CRCは製品の関数を使わない独立tableにした。独立した旧実装との比較とIEEE標準vectorを新しい2 testsで確認する。

## 同じcorpusでのrelease throughput / size

既存の `LZMAEncoderBenchmarkTests` / `ZstdEncoderBenchmarkTests` をbefore / afterで各5回。text4,194,304 byte、binary20,688,592 byte（/usr/lib/dyldと実在frameworkのMach-O連結）。
LZMAはraw LZMA2（xz -T1 --format=raw）。Zstdはframe。xzの速度はprocess / file I/O込み、zstdはツールの内部timed loop。Reference MB/sはbefore / afterの全反復の最良値。
Source encoderは変更していない。速度差は同時負荷を含む計測の揺れ。全14条件でown output sizeはbefore / afterで一致（サイズ増加0%）。

| Codec | Corpus | Level | Before MB/s | After MB/s | Own bytes (both) | Tool MB/s | Tool bytes |
|---|---|---:|---:|---:|---:|---:|---:|
| LZMA | binary | 1 | 14.762 | 16.272 | 6,453,276 | xz 25.815 | 6,451,638 |
| LZMA | binary | 6 | 4.117 | 3.851 | 4,615,940 | xz 4.773 | 4,623,756 |
| LZMA | binary | 9 | 4.359 | 4.140 | 4,612,054 | xz 5.086 | 4,620,542 |
| LZMA | text | 1 | 22.356 | 21.615 | 1,024,529 | xz 31.507 | 1,024,519 |
| LZMA | text | 6 | 2.638 | 2.612 | 694,823 | xz 2.995 | 695,024 |
| LZMA | text | 9 | 2.628 | 2.612 | 694,823 | xz 2.859 | 695,024 |
| ZSTD | binary | 1 | 93.940 | 85.384 | 7,997,811 | zstd 718.900 | 9,037,641 |
| ZSTD | binary | 3 | 92.828 | 94.801 | 7,371,581 | zstd 448.200 | 7,570,180 |
| ZSTD | binary | 9 | 8.961 | 9.424 | 6,920,557 | zstd 101.600 | 6,898,131 |
| ZSTD | binary | 19 | 2.840 | 2.859 | 5,339,170 | zstd 5.220 | 5,204,544 |
| ZSTD | text | 1 | 153.026 | 152.522 | 1,008,821 | zstd 554.700 | 1,022,409 |
| ZSTD | text | 3 | 162.469 | 163.619 | 933,816 | zstd 508.400 | 970,449 |
| ZSTD | text | 9 | 14.868 | 15.236 | 916,309 | zstd 81.100 | 944,619 |
| ZSTD | text | 19 | 1.874 | 1.899 | 704,190 | zstd 3.440 | 692,480 |

## 全classのDEBUG時間

| Class | Before s | After s | Before / after回数 |
|---|---:|---:|---:|
| `ArchiveRewriterNewTarFormatTests` | 1.206 | 1.288 | 5 / 5 |
| `BrotliStreamEncoderTests` | 2.241 | 2.027 | 5 / 5 |
| `CompressedTarNewFormatTests` | 76.183 | 74.923 | 5 / 5 |
| `CompressedTarZstdTests` | 8.94 | 8.382 | 5 / 5 |
| `EncoderTestCorpusTests` | — | 0.073 | 0 / 5 |
| `LHACompressionMethodTests` | 164.809 | 158.272 | 5 / 5 |
| `LHADefaultOutputTests` | 0.414 | 0.41 | 5 / 5 |
| `LZ4FrameEncoderTests` | 9.556 | 9.986 | 5 / 5 |
| `LZ4XXH32Tests` | 0.392 | 0.401 | 5 / 5 |
| `LZMAEncoderTests` | 1568.786 | 117.53 | 5 / 5 |
| `LZMAWriterConfigurationTests` | 0.001 | 0.001 | 5 / 5 |
| `LZMAWriterDefaultOutputTests` | 1.227 | 1.095 | 5 / 5 |
| `LZWStreamEncoderTests` | 90.491 | 10.036 | 5 / 5 |
| `LzipCompressorTests` | 10.855 | 10.499 | 5 / 5 |
| `PPMdEncoderTests` | 1825.438 | 62.827 | 5 / 5 |
| `PPMdWriterOptionsTests` | 0.0 | 0.0 | 5 / 5 |
| `SevenZipCompressionMethodTests` | 60.813 | 50.738 | 5 / 5 |
| `SevenZipCompressionRewriterTests` | 26.096 | 16.904 | 5 / 5 |
| `SevenZipCompressionUpdaterTests` | 178.313 | 112.236 | 5 / 5 |
| `SevenZipFilterWriterTests` | 47.509 | 26.091 | 5 / 5 |
| `SevenZipLZMALevelTests` | 68.176 | 49.127 | 5 / 5 |
| `SevenZipPPMdWriterTests` | 497.554 | 69.729 | 5 / 5 |
| `SevenZipSolidFilterUpdaterTests` | 32.047 | 16.827 | 5 / 5 |
| `SevenZipSolidWriterTests` | 32.522 | 19.083 | 5 / 5 |
| `SingleStreamCompressorTests` | 69.456 | 11.094 | 5 / 5 |
| `TarXZLZMALevelTests` | 71.267 | 8.549 | 5 / 5 |
| `ZipAdditionalCompressionEditingTests` | 1.052 | 0.965 | 5 / 5 |
| `ZipAdditionalCompressionWriterTests` | 31.504 | 22.096 | 5 / 5 |
| `ZipLZMALevelTests` | 39.092 | 31.161 | 5 / 5 |
| `ZipPPMdWriterTests` | 351.586 | 45.422 | 5 / 5 |
| `ZipZstdWriterTests` | 21.692 | 16.566 | 5 / 5 |
| `ZstdEncoderTests` | 131.2 | 19.356 | 5 / 5 |
| `ZstdWriterConfigurationTests` | 1.051 | 1.0 | 5 / 5 |
| `ZstdXXH64Tests` | 0.112 | 0.11 | 5 / 5 |

全testごとのbefore/afterは `.build/speed/test-times.tsv`、JSONは `.build/speed/metrics.json`。元の新規137件の一覧は `.build/speed/new-test-list.json`（benchmark2件を除く）。
ログは `.build/speed/{paired,remaining,full-release,reference-release,writer-control}/`。raw境界追加前の成功したnew5回は `paired-pre-raw/`。baseline buildは `.build-base` で作成・測定後、Git差分から除くため `.build/speed/baseline-build/` に移した。比較前の試行は `baseline-1.log`（途中で停止）、`new-debug-validation.log`（tar入力を修正する前の1 failure）、`corrected-boundaries.log` に残す。最終比較には含めない。

## 再実行

```sh
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --disable-sandbox --filter "PPMdEncoderTests|LZMAEncoderTests|SevenZipPPMdWriterTests|ZipPPMdWriterTests|ZstdEncoderTests|SingleStreamCompressorTests|LZWStreamEncoderTests|TarXZLZMALevelTests|EncoderTestCorpusTests"
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" GYOSHUKU_LARGE_ENCODER_TESTS=1 swift test --disable-sandbox -c release -Xswiftc -enable-testing -debug-info-format none --filter FullSize
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" GYOSHUKU_LARGE_ENCODER_TESTS=1 GYOSHUKU_ENCODER_TIMING=1 swift test --disable-sandbox --filter EncoderWriterOverheadProbeTests
python3 Tests/Tools/run-encoder-speed.py --baseline <before-debug.xctest> --new <after-debug.xctest> --workers 5 --rounds 5
python3 Tests/Tools/summarize-encoder-speed.py
```

Baselineはpristine sourceとTestsで先にbuildする。git stash / commitは使用していない。consumer向けのcompiler settingsやunsafeFlagsも追加しない。

## 制限

CI時間は推計。M4の同時負荷とrunner世代、7zz版、process起動の固定費が違う。FullSizeは元の規模の正しさを残すがdefaultの反復回数は同じではない。
LZMA cacheは各class内で結果を保持する（immutable Result）。full-size opt-in時は元のcorporaの圧縮結果を全level分保持するため、そのclassのメモリ滞在量は増える。SourceのmemoryLimit契約は変更しない。

## 変更後の工程とI/O対照

各caseの最速runを分解する。LZMA cacheの初期化はoracle行に入る。encode内側のData appendは差し引き、decode内側のappendは再加算しない。

| After / test | Encode/write s | Kaito+compare s | Oracle+files s | Corpus s | CRC s | Output append s | その他 s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `PPMdEncoderTests.testLargeTextAndRandom` | 15.370 | 27.989 | 0.809 | 0.000 | 0.011 | 0.000082 | 0.005 |
| `PPMdEncoderTests.testSmallMemoryRestorationOnTwentyMiBText` | 1.614 | 4.001 | 0.607 | 0.000 | 0.008 | 0.000018 | 0.004 |
| `LZMAEncoderTests.testLargeCorporaAndChunkBoundaries` | 0.000 | 12.067 | 0.000 | 0.000 | 0.000 | 0.000000 | 0.003 |
| `LZMAEncoderTests.testIndependentXZAndAloneOracles` | 60.408 | 0.000 | 8.208 | 0.112 | 0.000 | 0.000000 | 0.037 |
| `SevenZipPPMdWriterTests.testTwentyMiBTextWithSmallMemoryKeepsOneStream` | 1.106 | 1.419 | 0.201 | 0.000 | 0.000 | 0.000000 | 0.003 |
| `ZipPPMdWriterTests.testTwentyMiBTextWithRestartsAndThreadIndependentStream` | 1.083 | 1.255 | 0.200 | 0.000 | 0.000 | 0.000000 | 0.002 |
| `SevenZipPPMdWriterTests.testSolidFiltersAndEncryption` | 3.966 | 1.582 | 3.387 | 0.000 | 0.000 | 0.000000 | 3.966 |
| `ZstdEncoderTests.testOptimalTreeBlockTailWithLongText` | 3.301 | 0.009 | 0.268 | 0.006 | 0.000 | 0.000000 | 0.001 |
| `SingleStreamCompressorTests.testEveryFormatOnEmptyOneByteTextAndRandomFiles` | 2.138 | 1.704 | 4.292 | 0.038 | 0.000 | 0.000000 | 0.021 |
| `LZWStreamEncoderTests.testVariableWidthsClearAndRealCompressCompatibility` | 0.409 | 1.640 | 4.752 | 0.022 | 0.000 | 0.000068 | 0.021 |
| `TarXZLZMALevelTests.testLevelNineConcurrencyCapOn128MiBInput` | 1.870 | 0.000 | 0.068 | 0.000 | 0.000 | 0.000000 | 0.008 |

Copy / 実read-writeのDEBUG対照を元のinputで5回実行した。KaitoKitの全byte照合はtimerの外。16 filter条件の欄は各runの合計からbestを採る。

| Original input / Copy control | Best-of-5 s |
|---|---:|
| `test.copy-control.zip-20m` | 0.005262 |
| `test.copy-control.sevenZip-20m` | 0.009657 |
| `test.copy-control.tar-128m` | 0.024389 |
| `test.file-copy.text-1m` | 0.000216 |
| `test.file-copy.random-9m` | 0.001701 |
| `16 filter / solid / encryption combinations` | 3.450792 |

20 MiB writerのCopy費用はencode+I/O timerより十分小さい。filter / encryptionの固定費は小fixtureにも残る。圧縮でfile sizeが変わるため、Copyとの差は近似。

## PPMd Englishのrelease throughput / size

元のEnglish-like 1 MiB、order6 / heap16 MiBをreleaseの対で各5回。参照は既存assertionと同じxz-6（process / file I/O込み）。両variantのown sizeは両versionの全反復で一致。

| Variant | Before MB/s | After MB/s | Own bytes (both) | xz-6 MB/s | xz-6 bytes |
|---|---:|---:|---:|---:|---:|
| H | 19.282 | 19.412 | 41,930 | 3.628 | 72,628 |
| I | 20.038 | 19.462 | 41,967 | 3.628 | 72,628 |

## 実行したテストと結果

全suiteは実行していない。DEBUGの対象は上のclass表の33 baseline class / 34 new classの全methodで、新規137件を全て含む。追加CRC / PRNGが2件、LZMA2境界が1件。release最終default検証は同じ34 classとopt-in probe class（skip）。
`LZMAWriterDefaultOutputTests` と `LHADefaultOutputTests` のfrozen出力検証も含む。

| Configuration / selection | Repetitions | Pass per run | Skip per run | Failures | XCTest seconds min–max |
|---|---:|---:|---:|---:|---:|
| DEBUG 8 slow classes / baseline | 5 | 46 | 0 | 0 | 4613.025–4618.593 |
| DEBUG 8 slow classes / new | 5 | 47 | 14 | 0 | 344.551–347.281 |
| DEBUG remaining new classes / baseline | 5 | 91 | 0 | 0 | 820.545–827.399 |
| DEBUG remaining new classes / new | 5 | 93 | 0 | 0 | 635.036–649.399 |
| release original14 / FullSize14 + English / baseline | 5 | 15 | 0 | 0 | 389.451–390.717 |
| release original14 / FullSize14 + English / new | 5 | 15 | 0 | 0 | 261.987–266.161 |
| release LZMAEncoderBenchmarkTests + ZstdEncoderBenchmarkTests / baseline | 5 | 2 | 0 | 0 | 101.767–103.108 |
| release LZMAEncoderBenchmarkTests + ZstdEncoderBenchmarkTests / new | 5 | 2 | 0 | 0 | 105.667–107.547 |
| release default / 35 classes / raw境界追加前 | 1 | 140 | 15 | 0 | 223.283 |
| release final FullSize14 + English + Copy probe | 1 | 16 | 0 | 0 | 208.220 |
| release raw境界追加後 LZMAEncoderTests | 1 | 8 | 3 | 0 | 17.118 |
| DEBUG LZMAEncoderTests / raw境界追加前 | 1 | 8 | 3 | 0 | 102.854 |
| DEBUG Copy probe | 5 | 1 | 0 | 0 | 8.468–8.724 |

FullSizeの14 methodsは上のcase表の各 `…FullSize`。Englishは `PPMdEncoderTests.testEnglishLikeTextIsSmallerThanXZSix`、Copy probeは `EncoderWriterOverheadProbeTests.testCopyControlsOnOriginalWriterCorpora`、benchmarkは各classの `testSingleThreadBenchmark`。
工程測定のDEBUG / release比較は同じtimerをbaselineにも追加した。release default全class検証はtimerを有効にしていない。その後追加したraw境界assertionはDEBUG最終5回とreleaseのLZMAEncoderTests全methodで検証した。SwiftPM release buildは `-c release -Xswiftc -enable-testing -debug-info-format none`、DEBUGは標準 `-Onone`。両方 `--disable-sandbox`。
途中の修正前検証を最終比較と区別する。tarを256 KiBにした試行はchunkMap assertionで1 failure。snapshotへの修正だけで再実行した試行にも同じ1 failureがあり、実treeを4 MiB+512に直した `tar-corrected.log` は1 pass / 0 failure（3.015 s）。

| DEBUG preliminary run (excluded from comparison) | Pass | Skip | Fail | Seconds |
|---|---:|---:|---:|---:|
| `new-debug-validation.log` | 48 | 14 | 1 | 342.859 |
| `new-property-probes.log` | 6 | 0 | 0 | 30.337 |
| `corrected-boundaries.log` | 4 | 0 | 1 | 19.490 |
| `tar-corrected.log` | 1 | 0 | 0 | 3.015 |
| `filter-corrected.log` | 1 | 0 | 0 | 14.098 |
| `writer-control-debug.log` | 1 | 0 | 0 | 7.534 |

new-debug-validationはslow8 class＋EncoderTestCorpusTests。new-property-probesはPPMd復旧、7z/ZIP復旧、tar128m cap、Zstd window、LZMA2の2 MiB境界。corrected-boundariesはそこからLZMA2を除いた5件。filter / tar / Copyは各1 methodのみ。
最初のbaseline-1.logはLZMA oracle1件 pass（556.521 s）の後、large-corpora実行中に停止した。完走baseline5回には含めない。

## 変更fileと目的

| File under Tests/ | Purpose |
|---|---|
| [GyoshukuKitTests/Compression/PPMd/PPMdEncoderTests.swift](GyoshukuKitTests/Compression/PPMd/PPMdEncoderTests.swift) | 復旧countを残すdefaultと元サイズ2 FullSize、計測。 |
| [GyoshukuKitTests/Compression/PPMd/PPMdTestArchives.swift](GyoshukuKitTests/Compression/PPMd/PPMdTestArchives.swift) | 独立CRC tableでbit loopを削減。 |
| [GyoshukuKitTests/Compression/LZMAEncoderTests.swift](GyoshukuKitTests/Compression/LZMAEncoderTests.swift) | 圧縮結果共有、3 FullSize、2 MiB wire境界とreset検査、bulk append。 |
| [GyoshukuKitTests/Compression/LZWStreamEncoderTests.swift](GyoshukuKitTests/Compression/LZWStreamEncoderTests.swift) | CLEARを必須化したdefaultと元サイズFullSize。 |
| [GyoshukuKitTests/Compression/StreamEncoderTestSupport.swift](GyoshukuKitTests/Compression/StreamEncoderTestSupport.swift) | encoder / append / native decodeの工程計測。 |
| [GyoshukuKitTests/Compression/Zstd/ZstdEncoderTests.swift](GyoshukuKitTests/Compression/Zstd/ZstdEncoderTests.swift) | block / 2-window境界を保持したdefaultと3 FullSize。 |
| [GyoshukuKitTests/SevenZip/SevenZipPPMdWriterTests.swift](GyoshukuKitTests/SevenZip/SevenZipPPMdWriterTests.swift) | signed branch fixture、復旧corpus、同一archiveの検証共有、2 FullSize。 |
| [GyoshukuKitTests/Zip/ZipPPMdWriterTests.swift](GyoshukuKitTests/Zip/ZipPPMdWriterTests.swift) | 復旧corpus、threadのbyte一致と検証共有、FullSize。 |
| [GyoshukuKitTests/Writer/SingleStreamCompressorTests.swift](GyoshukuKitTests/Writer/SingleStreamCompressorTests.swift) | 9 formatsの3-read / odd-tail defaultと元サイズFullSize。 |
| [GyoshukuKitTests/CompressedTar/TarXZLZMALevelTests.swift](GyoshukuKitTests/CompressedTar/TarXZLZMALevelTests.swift) | packingを越えるaligned defaultと128 MiB FullSize。 |
| [GyoshukuKitTests/Support/TestCorpus.swift](GyoshukuKitTests/Support/TestCorpus.swift) | 同じPRNG byteをDataに直接埋める。corpus計測。 |
| [GyoshukuKitTests/Support/LZMAEncoderCorpus.swift](GyoshukuKitTests/Support/LZMAEncoderCorpus.swift) | text / mixed生成の工程計測。 |
| [GyoshukuKitTests/Support/EncoderTestCorpus.swift](GyoshukuKitTests/Support/EncoderTestCorpus.swift) | immutable lazyなdefault / full共通corpus。 |
| [GyoshukuKitTests/Support/EncoderTestCorpusTests.swift](GyoshukuKitTests/Support/EncoderTestCorpusTests.swift) | 独立した旧PRNG / CRCとのbyte一致。 |
| [GyoshukuKitTests/Support/EncoderTestTiming.swift](GyoshukuKitTests/Support/EncoderTestTiming.swift) | opt-inのDispatchTime TSV計測。 |
| [GyoshukuKitTests/Support/LZMAWriterTestSupport.swift](GyoshukuKitTests/Support/LZMAWriterTestSupport.swift) | writer + file I/Oの工程計測。 |
| [GyoshukuKitTests/Support/PPMdWriterTestSupport.swift](GyoshukuKitTests/Support/PPMdWriterTestSupport.swift) | writer + file I/Oの工程計測。 |
| [GyoshukuKitTests/Support/ReferenceTool.swift](GyoshukuKitTests/Support/ReferenceTool.swift) | process + temp fileの工程計測。 |
| [GyoshukuKitTests/Support/TestSupport.swift](GyoshukuKitTests/Support/TestSupport.swift) | 全assertionを保ち既存readerを再利用。native decode計測。 |
| [GyoshukuKitTests/Support/SevenZipMethodTestSupport.swift](GyoshukuKitTests/Support/SevenZipMethodTestSupport.swift) | readerと7zz listingを後続検証へ渡す。 |
| [GyoshukuKitTests/Support/SevenZipSolidFilterSupport.swift](GyoshukuKitTests/Support/SevenZipSolidFilterSupport.swift) | 同じlistingの再起動除去。小fixtureでsigned branchを保持。 |
| [GyoshukuKitTests/Support/TestPaths.swift](GyoshukuKitTests/Support/TestPaths.swift) | 反復processごとにtemp fileを分離。 |
| [GyoshukuKitTests/Probes/EncoderWriterOverheadProbeTests.swift](GyoshukuKitTests/Probes/EncoderWriterOverheadProbeTests.swift) | Copy / file I/Oの元corpus対照。 |
| [Tools/CorpusOptimizationProbe.swift](Tools/CorpusOptimizationProbe.swift) | -Ononeでattributeの効果を測る独立probe。 |
| [Tools/run-encoder-speed.py](Tools/run-encoder-speed.py) | before / after bundleを対にして反復実行。 |
| [Tools/summarize-encoder-speed.py](Tools/summarize-encoder-speed.py) | class / case時間と工程TSVの集計。 |
| [README.md](README.md) | opt-in flagsとdefault coverageの案内。 |
| [EncoderDebugPerformance.md](EncoderDebugPerformance.md) | 実測、coverage対応、結果と制限。 |
