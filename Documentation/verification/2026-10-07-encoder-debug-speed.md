# DEBUG encoder 試験の検証（2026-10-07）

Apple M4 Max（16 cores、128 GB）、macOS 27.2、Apple Swift 6.4。Sources/・Package.swift・固定fixtureは変更しない。

## 既定のcoverageと元サイズ

`GYOSHUKU_LARGE_ENCODER_TESTS=1` で8 classの14件の `…FullSize` を開く。元の入力と分割幅を保持する。
Copy / file I/O対照の `EncoderWriterOverheadProbeTests` は別の `GYOSHUKU_ENCODER_TIMING=1` で開く。
7z / ZIPは7zz、raw / XZはxz、ZstdはzstdとKaitoKitの全byte復号を使う。

| 試験 | 既定の入力・検査 | `…FullSize` の元サイズ |
|---|---|---|
| PPMd text / random | 128 KiB text・256 KiB random、H / I、全256値 | 1 / 8 MiB |
| PPMd restoration | 256 KiB + 17 byte textと256 KiBの全256値乱数（各byteを二度置く）、heap 1 MiB。各入力でH / I restart・I cut-offのcount > 0、7z / ZIP oracleとKaitoKit | 20 MiB text |
| LZMA corpora / independent oracles | random / text各65,537 byte・mixed 2.625 MiB + 17 byte、level 0 / 1 / 3 / 5 / 6 / 9、raw EOS / 既知サイズ / LZMA2、copy → LZMA chunk遷移、圧縮結果共有 | 1 / 4 / 20 MiB |
| LZMA odd pieces | 65,537 byte、width 1 / 7 / 65,537、byte一致。別試験で2 MiB直前の1 / 7 byte分割とcopy chunk長 `[2 MiB, 17]` を検査 | 2 MiB + 777 byte・全分割幅 |
| 7z PPMd small memory | 256 KiB + 17 byte text、heap 1 MiB、solid 1 folder・tail substream・CRC・metadata、thread 1 / 4のbyte一致 | 20 MiB |
| ZIP PPMd restarts | 同じtext・heap、単一stream・pending input 0、thread 1 / 4のbyte一致 | 20 MiB |
| 7z PPMd filters / encryption | 4,097 / 8,197 byte、正負のbranch、none / BCJ / ARM64 / Delta × solid × AES / header暗号化、coder / bind / properties / CRC / metadata | 32,769 / 262,149 byte |
| Zstd odd pieces | text 128 KiB + 17 byte・random 256 KiB + 17 byte、level 1 / 3 / 9 / 19、raw fallback・compressed / ratio・pending input上界 | 1 / 8 MiB |
| Zstd window / transitions | random + zeros + random + text + zeros + text。乱数の距離はwindow + 4096、textの距離はwindow - 128 KiB + 4096。2 × window + blockSizeを越えるcompact、raw / RLE / compressed・未知content size | 20 MiB mixed |
| Zstd tree tail | text 256 KiB + 17 byte、level 13 / 19、128 KiB block末尾と17 byte tail | 4 MiB |
| Single stream | 9形式 × 空 / 1 byte / text 128 KiB / random 1 MiB + 17 byte。bzip2 level 9の二つのblock、複数I/O・非整列finish・進捗・原子的公開・取消しcleanup | text 1 MiB / random 9 MiB |
| LZW widths / CLEAR | text 128 KiB → random 256 KiB → text 128 KiB、maxbits 12 / 16のCLEAR count > 0・再学習・header・実compressサイズ比 | mixed 7 MiB / random 9 MiB / text 12 MiB |
| tar.xz level-9 cap | 4 MiB + 512 byte、packing越え・512 byte整列、thread 64要求 → 1、1200 MiB予算・pending bound・chunkMap | 128 MiB |

PPMd English-like 1 MiBの両variant < xz-6サイズ検査は既定のまま。
一様独立の乱数はIの復旧時のmodel使用量がheap半分未満で、cut-off指定でもrestartに戻る。
隣接byteを相関させた乱数は全256値をassertし、cut-offも必須にする。
7z共通oracleの全byte / metadata照合は `ReaderOptions(password:)` で開き、編集layout readerとは別に既定のconsumer設定も検査する。
writerのthread 1 / 4は両方を圧縮して書庫全byteを比較し、一致した2本目の同じoracle処理を共有する。

## round 1のDEBUG実測

baseline `f273d346fc8e0743d56604e8c59adb61cedc1828` → round-1 `b46d496`。DEBUG `-Onone`、SwiftPM `--disable-sandbox`。
工程timerと一時file分離をbaselineにも追加し、5 workersでbefore / afterを各5回。表は各classのbest-of-5。
他workstreamも同時実行しており、機械負荷の変動を含む。全suiteの壁時計やencoder throughputとは異なる。

元の137 default testsのclass時間合計5,421.581 s → 140件の974.804 s（82.0%短縮、5.56倍）。
14件のFullSizeはskip。独立CRC / PRNGとLZMA2境界の3件を追加した。下表はround 2修正前の記録。

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

## round 2のDEBUG実測

HEAD `b46d496` と修正版を同じ `swift build --build-tests --disable-sandbox -debug-info-format none` で作り、
保存した各DEBUG XCTest bundleの対象classだけを `xcrun xctest -XCTest GyoshukuKitTests.<class>` で実行する。
FullSizeと工程timerの鍵は外す。全suiteは実行しない。LZMAの圧縮cache初期化もclass時間に含む。

| Class | HEAD s | 修正版 s | 成功 / skip（両版） |
|---|---:|---:|---:|
| `EncoderWriterOverheadProbeTests` | 7.550 | 8.284 | 1 / 0 |
| `LZMAEncoderTests` | 110.408 | 111.292 | 8 / 3 |
| `PPMdEncoderTests` | 59.207 | 90.723 | 6 / 2 |
| `SevenZipCompressionMethodTests` | 45.611 | 49.264 | 4 / 0 |
| `SevenZipCompressionRewriterTests` | 16.512 | 18.120 | 2 / 0 |
| `SevenZipCompressionUpdaterTests` | 112.184 | 113.272 | 4 / 0 |
| `SevenZipFilterWriterTests` | 25.612 | 32.497 | 7 / 0 |
| `SevenZipPPMdWriterTests` | 59.317 | 63.294 | 5 / 2 |
| `SevenZipSolidFilterUpdaterTests` | 16.446 | 19.558 | 2 / 0 |
| `SevenZipSolidWriterTests` | 18.367 | 21.372 | 6 / 0 |
| `SingleStreamCompressorTests` | 10.601 | 13.455 | 6 / 1 |
| `ZstdEncoderTests` | 18.710 | 19.537 | 11 / 3 |

各版1回、1 processで逐次実行。HEADの11 classは一括、修正版は10 classの結果とcorpus修正後に単独再実行したPPMdを採る。
既定11 classの時間合計は492.975 s → 552.384 s（+12.1%）。両版61成功・FullSize 11 skip・失敗0。
PPMdの乱数はH restart=4、I restart=4、I cut-off=3。7zz / KaitoKit全byte復号も成功した。
一様乱数を使った修正前PPMdのcut-off count assertionは1 failure（class 112.569 s）で、表から除く。他10 classは成功。

probeの比較は両版ともLARGE / TIMINGを1にし、probeだけを選択した。修正版のTIMINGのみも1成功（7.703 s）。
既定とLARGEのみでは各1 skip（各0.001 s）。bzip2の `-tvv` はHEADの乱数を1 block、修正版を2 blocksと確認した。

機械負荷は他作業を含む。HEAD開始近くのload averageは1 / 5 / 15分で5.28 / 4.13 / 3.64。
16:55以降の30秒sampleは1分 3.95–8.47、5分 4.95–6.54、15分 4.62–5.58。単回測定の差には負荷の変動を含む。
[クラス別TSV](2026-10-07-encoder-debug-speed.r2.tsv) に成功・skip数とgateを保存する。FullSize・release throughputは今回は再計測しない。
Sources/・Package.swift・固定fixtureは `f273d34` とbyte同一で、製品の出力・thread determinism・memory契約を変更しない。

再計測用の [runner](2026-10-07-encoder-debug-speed.run.py)、[集計器](2026-10-07-encoder-debug-speed.summarize.py)、
独立したDEBUG corpus / CRC [probe](2026-10-07-encoder-debug-speed.corpus.swift) を同じdirectoryに置く。
FullSizeで保持するLZMA結果cacheは試験の滞在メモリを増やす。製品のmemoryLimit契約は変更しない。
