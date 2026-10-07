# writerのmulti-core実測（2026-10-07）

## round 3: treeの窓停止・内部thread予約・単独ZIP spoolの修正

実施日は2026-10-08。HEAD `fb40b62`（round 2）への未commitの変更。
基準は`f273d34`、round 1は`f9d5178`。下のround 1/2本文とrawは保存し、今回の結果を`.r3.*`へ追加した。

### 実装と検証範囲

ZIPの空file・directory・symlink・1 MiB以下のStoredは同じ項目窓へinline投入し、spoolを作らない。
小さいStoredの前では全窓をdrainしない。16 MiB超の圧縮項目、1 MiB超のStored、ZipCryptoは従来のstream経路。
項目別APIでは空の窓の64 KiB〜16 MiBの圧縮項目を一つ保留し、後続が来ればworkerへ渡す。
単独のfinish/finishAdditions/drainではcallerが既存encoderで直接書き、出力spoolと再読取を省く。
保留もpendingInputBytesと一枠の予約に含める。
batchのdirectory URLは再帰探索のfallbackを保つが、その中の項目も同じ窓を使う。
空・directory・Stored・symlinkの混在、batchのdirectory URLと1 MiB超Stored、暗号化、進捗・出力順を試験した。

LHA/7z folderの内部threadsは実際の片数、未割当threads、`max(1, t / (pendingCount + 1))`の最小値。
割当はcallerだけで管理し、未出力jobの合計をt以下に保ち、emitで返す。
LHAは1 MiB片、7z LZMA2/Deflateは既存の片幅、他の7z codecは単一streamの1枠。
予算が一杯なら先頭だけをemitする。codec状態の予約は従来の保守的な上界を保つ。
今回のsingle/lha-mixed/corpusを含む全54比較でbase比1.05以下のため、この上限を採用した。
ZIP/LHA/7zのabortは片workerもjoinする。取消しとspool解放、workerの注入失敗を確認した。
既存LHA取消し試験は、cancel後もworkerをsemaphoreで止めたままtask.valueを待っていたため、join追加後の再確認を1回中断した。
試験をcancel→worker解放→task.valueの順へ直し、戻った時点の両worker完了も検査した。修正後18件は成功。

小予算試験は入力上限を1 MiB+4,096 byte、各方式の予約2枠分の予算へTaskLocalで注入する。
要求t=12でもentryThreads=2を確認し、ZIP、LHAの保留member、7z solid（blockSizeも同じ小上限）へ
上限近くの5項目を追加する。各add後は2枠分以下、観測最大は上界との差8 byte以内。
finishAdditionsの進捗とpending=0も確認する。通常値は16 MiB・既存予算のまま。

### 計測条件

既存記録と同じMac、macOS 27.2 (26B5101f)、Apple Swift 6.4、arm64。
base/round1のSourcesはgit archiveの129/132 fileとbyte単位で一致を確認した。
三版は同じharnessとKaitoKit checkoutを使い、下の同一release flagsでbuildした。
Release build planの27構成すべてでtestabilityはNO、`-enable-testing`無しを確認した。
[binary/flags記録](2026-10-07-writer-multicore.r3.builds.json)へfingerprintを保存した。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path Benchmarks --scratch-path .build/r3-builds/new/build --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path .build/r3-builds/base/source/Benchmarks --scratch-path .build/r3-builds/base/build --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path .build/r3-builds/round1/source/Benchmarks --scratch-path .build/r3-builds/round1/build --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
python3 Benchmarks/multicore.py corpus --profile round3
python3 Benchmarks/multicore.py measure --profile round3 --base .build/r3-builds/base/build/out/Products/Release/gyoshuku-multicore --round1 .build/r3-builds/round1/build/out/Products/Release/gyoshuku-multicore --new .build/r3-builds/new/build/out/Products/Release/gyoshuku-multicore --results .build/multicore/round3.r3.jsonl
python3 Benchmarks/multicore.py report --profile round3 --round1 .build/r3-builds/round1/build/out/Products/Release/gyoshuku-multicore --results .build/multicore/round3.r3.jsonl
```

測定期間: 2026-10-08 03:06:51 JST〜2026-10-08 03:29:16 JST。三版の先行順も回転・反転し、各群best-of-5を採用。
create/compress/finishのwall、process user+system、開始時load averageの1/5/15分を保存する。
こちらのbuild/testは計測と重ねていない。列挙・sort（tree内部の再帰探索は計時内）、入力byte集計、出力SHA-256は計時外。
固定日時1700000000、file0644 / directory0755、heuristic=false、既定codec levelを三版で揃えた。

| workload | 入力・設定 |
|---|---|
| tree | 100 folder × (64〜256 KiBのSwift text 6 file＋空file＋空subdirectory)、seed20261008。計96,446,400 byte、700 file＋200 directory。ZIP Zstd/BZip2/Deflate/Stored、7z LZMA/LZMA2 |
| single | 既存10 MiB。LHA LH5/LH7、7z Deflate/LZMA2 solid（既定blockSize）、ZIP XZ/Zstd |
| single16r | 16 MiBのseed20261008乱数1 file。treeと同じ6方式 |
| small | 既存5,000 × 1〜4 KiB、計12,819,316 byte。ZIP Zstd/BZip2/Deflate、7z LZMA/LZMA2 |
| lha-mixed | 10 MiB先頭member＋128小file、LH5/LH7 |
| corpus | 既存256 MiB（96×2 MiB＋64 MiB）。ZIP Zstd/BZip2、7z LZMA2 solid16 MiB、LHA LH7、t=12のみ |

入力digest・構成は[corpus記録](2026-10-07-writer-multicore.r3.corpus.json)。
[全810 sample](2026-10-07-writer-multicore.r3.samples.jsonl)、[best値TSV](2026-10-07-writer-multicore.r3.tsv)。
全47条件の940-sample matrixは繰り返さず、指定の29条件・三版だけに絞った。

### 回帰表

秒、各群best-of-5。各欄の順はbase / round1 / new。
loadはそれぞれの最短wall sampleの1分値、corpusのt=1は今回測定しないため「—」。

| workload / method | t=1 base / round1 / new 秒 | t=12 base / round1 / new 秒 | new/base 最大 | new/round1 最大 | load(1分) base / round1 / new: t=1; t=12 |
|---|---:|---:|---:|---:|---|
| tree / zip-zstd | 0.7515 / 0.7517 / 0.7481 | 0.7539 / 0.1675 / 0.1303 | 0.995 | 0.995 | 2.30/2.33/2.33; 2.33/2.33/2.60 |
| tree / zip-bzip2 | 3.3995 / 3.4029 / 3.3989 | 3.4063 / 0.5689 / 0.5466 | 1.000 | 0.999 | 2.47/2.35/2.24; 2.24/2.11/2.60 |
| tree / zip-deflate | 1.3601 / 1.3708 / 1.3668 | 0.3910 / 0.3901 / 0.3907 | 1.005 | 1.001 | 2.88/2.55/2.67; 2.81/2.69/2.55 |
| tree / zip-stored | 0.0468 / 0.0466 / 0.0470 | 0.0467 / 0.0469 / 0.0473 | 1.013 | 1.010 | 2.81/2.81/2.81; 2.81/2.81/2.81 |
| tree / 7z-lzma | 13.8200 / 13.8041 / 13.7275 | 13.8127 / 2.2671 / 2.2399 | 0.993 | 0.994 | 1.89/2.11/2.47; 1.86/2.10/1.93 |
| tree / 7z-lzma2 | 11.6166 / 11.5653 / 11.5497 | 1.9602 / 1.9665 / 1.9632 | 1.002 | 0.999 | 1.99/1.90/1.92; 2.02/3.58/3.22 |
| single / lha-lh5 | 0.1166 / 0.1157 / 0.1156 | 0.0359 / 0.1178 / 0.0366 | 1.017 | 0.999 | 3.27/3.27/3.27; 3.27/3.27/3.27 |
| single / lha-lh7 | 0.2452 / 0.2450 / 0.2435 | 0.0588 / 0.2462 / 0.0599 | 1.018 | 0.994 | 3.09/3.27/3.09; 3.09/3.09/3.09 |
| single / 7z-deflate-solid | 0.1215 / 0.1222 / 0.1220 | 0.0211 / 0.1230 / 0.0212 | 1.006 | 0.998 | 2.92/2.92/2.92; 2.92/3.09/3.09 |
| single / 7z-lzma2-solid | 0.7737 / 0.7698 / 0.7701 | 0.7748 / 0.7711 / 0.7753 | 1.001 | 1.006 | 2.89/3.06/2.89; 3.06/2.77/2.89 |
| single / zip-xz | 0.7665 / 0.7684 / 0.7688 | 0.7683 / 0.7678 / 0.7687 | 1.003 | 1.001 | 2.69/2.43/2.43; 2.56/2.69/2.56 |
| single / zip-zstd | 0.0439 / 0.0436 / 0.0440 | 0.0444 / 0.0453 / 0.0442 | 1.004 | 1.010 | 2.32/2.43/2.43; 2.32/2.32/2.43 |
| single16r / zip-zstd | 0.1406 / 0.1398 / 0.1398 | 0.1405 / 0.1435 / 0.1409 | 1.003 | 1.000 | 2.32/2.32/2.32; 2.32/2.32/2.29 |
| single16r / zip-bzip2 | 1.0161 / 1.0157 / 1.0174 | 1.0145 / 1.0198 / 1.0167 | 1.002 | 1.002 | 2.32/2.53/2.53; 2.53/2.44/2.53 |
| single16r / zip-deflate | 0.2280 / 0.2288 / 0.2289 | 0.0316 / 0.0316 / 0.0316 | 1.004 | 1.000 | 2.65/2.65/2.65; 2.60/2.65/2.60 |
| single16r / zip-stored | 0.0033 / 0.0034 / 0.0034 | 0.0034 / 0.0035 / 0.0034 | 1.030 | 1.020 | 2.60/2.60/2.60; 2.60/2.60/2.60 |
| single16r / 7z-lzma | 2.2202 / 2.2553 / 2.2428 | 2.2280 / 2.2542 / 2.2361 | 1.010 | 0.994 | 2.60/2.53/2.53; 2.38/2.41/2.67 |
| single16r / 7z-lzma2 | 2.2051 / 2.2071 / 2.1966 | 2.2127 / 2.2024 / 2.2108 | 0.999 | 1.004 | 2.81/2.79/2.81; 2.74/2.71/2.53 |
| small / zip-zstd | 0.3495 / 0.3465 / 0.3458 | 0.3493 / 0.6173 / 0.3481 | 0.997 | 0.998 | 2.49/2.49/3.17; 3.17/3.22/3.17 |
| small / zip-bzip2 | 1.5000 / 1.4978 / 1.5012 | 1.4981 / 0.6373 / 0.2159 | 1.001 | 1.002 | 3.43/3.13/3.65; 3.13/3.23/3.55 |
| small / zip-deflate | 0.2310 / 0.2307 / 0.2300 | 0.1737 / 0.1748 / 0.1740 | 1.002 | 0.997 | 3.52/3.52/3.04; 3.04/3.52/3.52 |
| small / 7z-lzma | 1.1354 / 1.1321 / 1.1271 | 1.1297 / 0.6170 / 0.1918 | 0.993 | 0.996 | 3.69/4.00/3.64; 3.69/3.69/4.00 |
| small / 7z-lzma2 | 1.1019 / 1.1054 / 1.1085 | 0.2272 / 0.2279 / 0.2292 | 1.009 | 1.006 | 3.74/3.68/4.02; 3.86/3.68/4.02 |
| lha-mixed / lha-lh5 | 0.1302 / 0.1300 / 0.1300 | 0.0407 / 0.1244 / 0.0425 | 1.046 | 1.000 | 3.86/3.86/3.86; 3.63/3.86/3.86 |
| lha-mixed / lha-lh7 | 0.2610 / 0.2593 / 0.2588 | 0.0649 / 0.2540 / 0.0661 | 1.019 | 0.998 | 3.63/3.42/3.63; 3.42/3.42/3.63 |
| corpus / zip-zstd | — | 1.4984 / 0.3851 / 0.3751 | 0.250 | 0.974 | —; 4.15/3.38/3.42 |
| corpus / zip-bzip2 | — | 20.3910 / 7.0937 / 7.0754 | 0.347 | 0.997 | —; 3.51/5.03/3.75 |
| corpus / 7z-lzma2-solid | — | 16.4838 / 3.3141 / 3.3170 | 0.201 | 1.001 | —; 2.65/4.04/4.15 |
| corpus / lha-lh7 | — | 3.9569 / 0.7092 / 0.9385 | 0.237 | 1.323 | —; 4.95/4.95/5.19 |

SHA-256/size: all builds/thread counts identical. No-regression: True.

明示的判定: **PASS**。new/baseの54比較すべて1.05以下（最大1.0461）、
tree/smallのnew/round1も22比較すべて1.05以下（最大1.0099）。
各条件の全版・全測定threadsでSHA-256と出力sizeが一致した。全sampleの1分load範囲は1.73〜6.12。

### 対象試験

全suiteと巨大gate試験は実行していない。共通flagsは`--disable-sandbox -debug-info-format none`、
`CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"`。release XCTestだけ`-Xswiftc -enable-testing`。
最終cleanup再確認はjoin変更とLHA試験修正を含む最終sourceで実行した。

| 実行 | 構成 | pass/fail/skip | XCTest秒 / build込みwall秒 | 開始/終了load(1分) |
|---|---|---:|---:|---:|
| debug-small | debug | 4/0/0 | 1.411 / 2.759 | 5.60/5.39 |
| release-targeted | release、enable-testing | 94/0/0 | 167.655 / 306.413 | 5.39/2.42 |
| release-cleanup-verified | release、enable-testing | 18/0/0 | 2.489 / 55.667 | 2.36/3.38 |


主試験はmulticore、spool、順序窓、ZIP各codec/暗号化、7z各codec/solid/filter/AES・凍結byte、
LHA片連結・parallel・凍結fixture、batch等価・安全性、finishAdditions。
command・case別時間・中断の理由・全load値は[test raw](2026-10-07-writer-multicore.r3.tests.jsonl)に保存した。

### 変更fileと目的

| file | 目的 |
|---|---|
| Sources/GyoshukuKit/Zip/ZipWriter.swift | 小Stored/空/dir/symlinkの窓保持、単独圧縮項目の保留と直接出力、abort join |
| Sources/GyoshukuKit/LHA/LHAWriter.swift | 未出力jobの内部thread合計をt以内、emitで解放、片worker join |
| Sources/GyoshukuKit/SevenZip/SevenZipBlockWriter.swift | folderの実片数と合計thread予約、emitで解放 |
| Sources/GyoshukuKit/SevenZip/SevenZipWriter.swift | abort時の片worker join |
| Sources/GyoshukuKit/Compression/OrderedChunkPipeline.swift | 予約待ちで先頭だけをemitする内部操作 |
| Sources/GyoshukuKit/Compression/EntryCompressionConfiguration.swift | 小入力上限・小予算のTaskLocal試験注入 |
| Tests/GyoshukuKitTests/Writer/MulticoreWriterTests.swift | tight bound、ZIP窓混在、batch tree、単独disk spool無し |
| Tests/GyoshukuKitTests/LHA/LHAWriterParallelTests.swift | joinする取消し経路でworkerを解放し、完了を検査 |
| Benchmarks/multicore.py / Sources/GyoshukuMulticore/main.swift / README.md | tree/single16r、三版交互比較、thread指定、回帰判定と手順 |
| Documentation/design.md / 本記録と.r3.* | 窓・thread予約・計測・試験の記録 |

### 残る制約

未解決の試験失敗・計測閾値超過は無い。最も閾値に近いのはLHA mixed LH5/t=12のnew/base=1.0461。
LHA corpus LH7/t=12はthread上限を採用した結果、round 1の0.7092秒から0.9385秒へ32.3%遅くなった。
baseの3.9569秒に対しては4.22倍速く、今回の基準を満たす。thread上限とmember並列度のトレードオフとして残す。
性能確認は指定の29条件で、全方式・全threadsの速度を網羅するものではない。
loadは他jobで変動する。大Stored、ZipCrypto、項目窓の入力上限超過は引き続きstream経路を使う。
圧縮codecのSources/GyoshukuKit/Compression/{LZMA,PPMd,Zstd}、Tests/Fixturesは変更しない。
変更は未commit。日本語commit messageは`.build/speed-commit-message-r3.txt`。


## round 2: 単独member・最終folder・小項目の退行修正

基準は`f273d346fc8e0743d56604e8c59adb61cedc1828`、変更版はround 1の`f9d5178`へ加えた未commitの修正。
下のround 1記録は当時の結果として保存する。round 2の判定には今回の最終binaryのsampleだけを使い、
修正前の試作binaryや中断した計測のsampleは混ぜない。

### 実装

LHAは窓の先頭の中memberを一つ保留し、単独でfinish/endMembers/finishAdditionsを迎える場合と
16 MiB超のmemberの前には、従来の1 MiB片の`addStreamedParallel`を全threadsで使う。
後続memberがあれば項目窓へ投入し、小memberも非空の同じ窓へ投入する。
workerの内部並列数は`max(1, 要求threads / 投入後の未出力数)`。小memberとdirectoryの完成recordは
メモリで保持し、中memberのseek用recordだけdisk spoolへ置く。注入encoderと進捗の契約を保つ。

7z solid/filterは最終folderのflush時に他のpending folderが無ければ同期の全threads経路を使う。
folder workerの内部並列数も未出力folder数から求める。solid blockSizeが256 MiB超なら従来の同期経路へ戻す。
Copyかつfilter無しも同期経路へ戻し、圧縮結果の二重spoolを避ける。
並列folderの入力diskは`窓数 × blockSize`以下（最大16 × 256 MiB = 4 GiB）。
非solid filterは最大16 × 16 MiB = 256 MiB。総disk量はこの入力と実際の未出力圧縮長の合計で、
codecによる膨張率を固定の数値で仮定しない。file自体を分割しないので、組立中の単一fileが入力上限Lを
超える場合の入力disk上界は`窓数 × L + max(0, fileSize - L)`。256 MiB超の同期folderは従来の単一入力spoolを使う。

ZIP/7zの圧縮出力は1 MiBまでメモリで保持し、それを超えた場合だけunlink済みScratchFileへ移す。
空・directory・stored項目の圧縮spoolを作らず、64 KiB未満のZIP Zstdは呼出threadで符号化する。
ZIP batchの方式は確定済み`entry.zip!.method`から取得する。Storedのbatch先読みは
従来の1 MiB上限へ戻し、これを超える項目はstreamで出力して完成recordのコピーを有界にする。
worker内部の1-thread OrderedChunkPipelineは同じthreadで符号化する。外側の1-thread窓は
入力読み取りとの重なりを維持する。項目窓は最大16枠で、LHA/7z folderは要求threads分の内部codec予約を
保守的に各枠へ数え、spoolメモリ1 MiBも予約へ数える。終了・失敗・取消しで内部workerもjoinする。
詳細と式は[design.md](../design.md)のsolidおよびwriter並列化節に記す。

### 計測条件

Apple M4 Max、16 cores、128 GB（既存round 1記録の環境）、macOS 27.2 (26B5101f)、Apple Swift 6.4、arm64。
公開APIだけを呼ぶ`Benchmarks/Sources/GyoshukuMulticore/main.swift`を両版に同じ内容で追加した。
基準版の`Sources`配下129ファイルは`git archive f273d34`とbyte単位で一致を確認した。
両版とも以下のrelease buildで、timing binaryには`-enable-testing`を付けていない。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path Benchmarks --scratch-path .build/multicore-release --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift build --package-path .build-base/source/Benchmarks --scratch-path .build-base/multicore-release --disable-sandbox -debug-info-format none -c release --product gyoshuku-multicore
python3 Benchmarks/multicore.py corpus
python3 Benchmarks/multicore.py measure --results .build/multicore/round2.jsonl
python3 Benchmarks/multicore.py report --results .build/multicore/round2.jsonl
```

最終測定期間は2026-10-07 23:32〜2026-10-08 01:58 JST。
threads=1/12、base/newを交互に各5回、pair内の先行版も回ごとに反転する。
wallはcreate/compressからfinishまで。入力列の列挙・sort、SHA-256、出力サイズは計測外。
CPUはprocessのuser+system。他のCodex jobが同じMacで動いているため、各sample開始時に
load averageの1/5/15分値を保存し、表には最短wallのsampleに対応する1分値を示す。
最終Stored batchの修正後に全940 sampleを再測定した。こちらのbuild/testとtimingは重ねていない。時刻1700000000、mode0644、入力順を両版で固定した。

| workload | 入力と設定 |
|---|---|
| single | 1 × 10 MiB。7z solidは`.on()`の既定64 MiB block（16 MiBへ上書きしない） |
| small | 5,000 × 1〜4 KiB、計12,819,316 byte、seed20261007、非solid |
| lha-mixed | singleと同じ10 MiBの先頭member＋smallの先頭128 file |
| corpus | round 1と同じ256 MiB、96 × 2 MiB＋64 MiB、solid16 MiB、filterはDelta距離4 |

全入力はf273d34由来のSwift本文・反復byte・seeded乱数の同じコーパスから作る。
corpus SHA-256は`473b4f17c3c378e80a0a4be156cb0e80480258ba787e7f6b3ca97c2d2e2f9f51`。
ZIP heuristic=false、Deflate6/BZip2 9/Zstd3/PPMd6/LHA6、raw LZMA1は6、XZ/LZMA2はApple nil-level経路。
50,000小ファイルは任意の追加条件として今回は実行していない。

### 回帰表

単位は秒、各群のbest-of-5。new/base最大はt=1とt=12の大きい方。
load欄は`基準/変更`をt=1、t=12の順に並べる。

| workload / method | t=1 base → new 秒 | t=12 base → new 秒 | new/base 最大 | load(1分) base/new: t=1; t=12 |
|---|---:|---:|---:|---|
| single / lha-lh5 | 0.1108 → 0.1112 | 0.0357 → 0.0364 | 1.018 | 2.88/3.29; 2.88/3.29 |
| single / lha-lh7 | 0.2347 → 0.2339 | 0.0586 → 0.0594 | 1.013 | 3.29/3.29; 3.29/3.29 |
| single / 7z-deflate-solid | 0.1166 → 0.1174 | 0.0213 → 0.0212 | 1.007 | 3.10/3.29; 3.10/3.10 |
| single / 7z-lzma2-solid | 0.7520 → 0.7485 | 0.7510 → 0.7487 | 0.997 | 3.10/3.10; 3.34/3.55 |
| single / zip-xz | 0.7514 → 0.7489 | 0.7551 → 0.7507 | 0.997 | 3.42/3.42; 3.23/3.42 |
| single / zip-zstd | 0.0436 → 0.0434 | 0.0433 → 0.0452 | 1.044 | 3.13/3.13; 3.13/3.13 |
| small / zip-zstd | 0.3439 → 0.3459 | 0.3449 → 0.3460 | 1.006 | 3.18/3.13; 3.20/3.20 |
| small / zip-bzip2 | 1.4818 → 1.4810 | 1.4811 → 0.2178 | 0.999 | 3.88/3.78; 3.81/4.23 |
| small / zip-deflate | 0.2337 → 0.2308 | 0.1721 → 0.1739 | 1.011 | 4.00/4.17; 4.45/4.17 |
| small / 7z-lzma | 1.1313 → 1.1281 | 1.1258 → 0.1944 | 0.997 | 3.55/3.34; 3.58/3.34 |
| small / 7z-lzma2 | 1.1006 → 1.1077 | 0.2292 → 0.2280 | 1.006 | 3.18/3.00; 3.08/3.00 |
| lha-mixed / lha-lh5 | 0.1300 → 0.1290 | 0.0415 → 0.0421 | 1.015 | 3.63/3.63; 3.63/3.63 |
| lha-mixed / lha-lh7 | 0.2588 → 0.2583 | 0.0646 → 0.0644 | 0.998 | 3.50/3.50; 3.50/3.50 |
| corpus / zip-stored | 0.0422 → 0.0421 | 0.0422 → 0.0421 | 0.999 | 3.54/3.54; 3.54/3.54 |
| corpus / zip-deflate | 3.0936 → 3.0921 | 0.3840 → 0.3847 | 1.002 | 3.93/4.02; 4.02/3.58 |
| corpus / zip-bzip2 | 20.2377 → 20.2371 | 20.2317 → 7.0517 | 1.000 | 3.62/3.99; 4.16/3.79 |
| corpus / zip-lzma | 26.4920 → 26.6086 | 26.7108 → 8.2701 | 1.004 | 3.17/3.52; 3.46/2.57 |
| corpus / zip-xz | 22.6743 → 22.6705 | 19.2299 → 3.4059 | 1.000 | 3.16/2.66; 2.77/2.95 |
| corpus / zip-zstd | 1.4913 → 1.4927 | 1.4891 → 0.3748 | 1.001 | 3.47/3.43; 3.50/3.43 |
| corpus / zip-ppmd | 29.2440 → 29.1271 | 29.1801 → 9.5754 | 0.996 | 3.63/2.89; 3.04/3.34 |
| corpus / 7z-lzma2 | 22.8078 → 22.7205 | 3.3808 → 3.3872 | 1.002 | 3.92/4.42; 3.74/4.81 |
| corpus / 7z-lzma2-filter | 21.0596 → 21.0908 | 18.7130 → 3.8212 | 1.001 | 3.53/3.11; 3.18/3.12 |
| corpus / 7z-lzma2-solid | 20.4204 → 20.3879 | 16.8027 → 3.3309 | 0.998 | 4.07/5.57; 2.89/2.83 |
| corpus / 7z-lzma2-solid-filter | 18.3532 → 18.3121 | 16.0256 → 3.6871 | 0.998 | 3.21/3.75; 3.42/3.22 |
| corpus / 7z-lzma | 27.0983 → 26.7192 | 26.7980 → 8.3468 | 0.986 | 4.03/3.69; 2.95/3.05 |
| corpus / 7z-lzma-filter | 24.7137 → 24.8530 | 24.6941 → 8.0337 | 1.006 | 3.41/3.75; 3.66/4.04 |
| corpus / 7z-lzma-solid | 24.6795 → 24.6951 | 24.6530 → 8.3017 | 1.001 | 4.59/5.43; 4.73/5.02 |
| corpus / 7z-lzma-solid-filter | 23.1423 → 23.4845 | 23.3115 → 8.1382 | 1.015 | 4.00/3.87; 3.90/3.68 |
| corpus / 7z-deflate | 3.0347 → 3.0391 | 0.3835 → 0.3831 | 1.001 | 3.33/3.15; 3.15/4.01 |
| corpus / 7z-deflate-filter | 4.1488 → 4.1525 | 3.7606 → 1.1460 | 1.001 | 3.45/3.33; 2.76/2.89 |
| corpus / 7z-deflate-solid | 3.1220 → 3.1266 | 0.5795 → 0.3667 | 1.001 | 2.51/2.70; 2.59/2.59 |
| corpus / 7z-deflate-solid-filter | 3.5148 → 3.5087 | 3.0937 → 1.1914 | 0.998 | 2.73/2.73; 2.74/2.74 |
| corpus / 7z-bzip2 | 20.2751 → 20.2629 | 20.2343 → 7.0580 | 0.999 | 2.73/2.07; 2.36/2.30 |
| corpus / 7z-bzip2-filter | 19.9893 → 19.9804 | 19.9270 → 7.1026 | 1.000 | 3.40/2.71; 2.96/1.88 |
| corpus / 7z-bzip2-solid | 22.5689 → 22.4319 | 22.5487 → 7.2785 | 0.994 | 2.35/2.15; 1.89/2.13 |
| corpus / 7z-bzip2-solid-filter | 22.6637 → 22.6820 | 22.6344 → 7.3664 | 1.001 | 3.73/4.90; 1.77/1.51 |
| corpus / 7z-ppmd | 27.2601 → 27.4605 | 27.1956 → 8.8900 | 1.007 | 5.00/3.65; 3.05/4.76 |
| corpus / 7z-ppmd-filter | 36.0619 → 36.2442 | 35.8980 → 12.2370 | 1.005 | 2.56/2.47; 3.90/1.97 |
| corpus / 7z-ppmd-solid | 26.0357 → 26.0433 | 26.1167 → 8.7868 | 1.000 | 2.12/3.64; 2.39/2.42 |
| corpus / 7z-ppmd-solid-filter | 35.9894 → 36.0449 | 35.9495 → 12.1149 | 1.002 | 2.65/2.20; 3.30/2.43 |
| corpus / 7z-copy | 0.0445 → 0.0442 | 0.0439 → 0.0438 | 0.997 | 2.48/2.48; 2.61/2.48 |
| corpus / 7z-copy-filter | 2.9817 → 2.9433 | 2.9563 → 0.9596 | 0.987 | 3.04/2.26; 2.72/2.23 |
| corpus / 7z-copy-solid | 0.0962 → 0.0958 | 0.0963 → 0.0954 | 0.996 | 2.67/2.72; 2.67/2.67 |
| corpus / 7z-copy-solid-filter | 2.9642 → 2.9476 | 2.9445 → 0.9790 | 0.994 | 2.75/2.85; 2.47/2.75 |
| corpus / lha-lh5 | 2.8833 → 2.9065 | 1.7116 → 0.4322 | 1.008 | 2.15/2.15; 2.63/3.58 |
| corpus / lha-lh6 | 4.4549 → 4.4442 | 2.6308 → 0.5451 | 0.998 | 2.49/2.76; 2.62/2.45 |
| corpus / lha-lh7 | 6.1797 → 6.1706 | 3.7744 → 0.6979 | 0.999 | 2.54/2.74; 2.62/2.65 |

SHA-256: all base/new/t=1/t=12 identical. No-regression (new/base <= 1.05): True.

明示的なno-regression check: **PASS**。47条件 × threads1/12の94比較すべてで`new/base <= 1.05`。最大はsingle/zip-zstd/t=12の1.0435（+4.35%）。940 sampleすべてで、各条件の20 sampleの出力サイズとSHA-256が一致した。全sampleの1分load範囲は1.51〜8.48。`report`はexit 0。

### 機能試験

全suiteは実行していない。Stored batchの最終修正前のrelease受入は109件成功、失敗0、skip0、213.416秒。
最終修正後は関連release24件成功、失敗0、skip0、30.507秒とdebugの追加1件成功、0.772秒を確認した。
debugの最終対象実行は9件成功、失敗0、skip0、11.338秒。どちらも`--disable-sandbox -debug-info-format none`と
`CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache"`を使った。release XCTestだけは`-Xswiftc -enable-testing`を使う。
timing executableにはこのflagを付けない。

| 最終実行 | 構成 | pass/fail/skip | 秒 | 範囲 |
|---|---|---:|---:|---|
| r2-final-acceptance-release | release、enable-testing、GYOSHUKU_MULTICORE_BENCHMARK=1 | 109/0/0 | 213.416 | 下の24クラス、凍結fixture、level、byte一致、pending上界、取消し、batch |
| r2-stored-release | release、enable-testing、既定gate | 24/0/0 | 30.507 | Stored batch、byte一致、AES、spool、batch等価・安全性、finishAdditions |
| r2-stored-debug | debug、既定gate | 1/0/0 | 0.772 | 1 MiB＋1 byteのStored batch/単項目・threads1/4・平文/AES、spool数0 |
| r2-mixed-debug-final | debug、既定gate | 9/0/0 | 11.338 | 小さい中項目、LHA混在、encoder注入失敗、spool、予約 |

release受入のfilter:

```text
MulticoreWriterTests|OrderedEntrySpoolTests|OrderedChunkPipelineWindowTests|LZMAWriterConfigurationTests|PPMdWriterOptionsTests|ZipZstdWriterTests|ZipAdditionalCompressionWriterTests|ZipPPMdWriterTests|ZipLZMALevelTests|SevenZipCompressionMethodTests|SevenZipSolidWriterTests|SevenZipFilterWriterTests|SevenZipWriterByteIdentityTests|SevenZipPPMdWriterTests|SevenZipLZMALevelTests|LHACompressionMethodTests|LHAWriterStreamedMemberIdentityTests|LHAWriterParallelTests|LHAStreamSpliceTests|LHADefaultOutputTests|LZMAWriterDefaultOutputTests|BatchAdditionEquivalenceTests|BatchAdditionSafetyTests|FinishAdditionsTests
```

debugではt=2の窓へ3個の約1.1〜1.3 MiB入力を追加する。release gate内ではt=12へ13個の
16,777,215 / 16,776,959 byte入力を追加し、ZIP/7z/LHAそれぞれで毎addの直後に
`pendingInputBytes <= maximumPendingInputBytes`を検査し、finishAdditionsで0、readerで全byteを確認した。
注入した物理メモリ・memoryLimit・thread数の固定条件はliteral期待値を使う。
spool試験は1 MiB境界のspill、descriptor解放、空/dir/storedのfile作成数、worker内のfault注入を扱う。
inner1-threadの呼出threadと投入順、エラーの伝播も検査する。
LHAの中member＋100小member＋20directoryはScratchFile作成数2を検査し、encoder注入エラーも保持する。
releaseはLHA/LZMA既定の凍結fixture、ZIP/7zの全方式のthread間byte一致、7z filter/solid、AES、
ZIP batch heuristic・進捗・finishAdditions、取消し後のworker/spool解放を含む。

初期debug実行ではspool予約1 MiBを含めない旧期待値と、literalへの置換時の期待値計算に各1件の失敗があった。
期待値を修正後、上の最終対象実行で成功した。試作の実行も[test記録](2026-10-07-writer-multicore.r2.tests.jsonl)へ残す。

### 変更fileと目的

| file | 目的 |
|---|---|
| Sources/GyoshukuKit/Compression/EntryCompressionConfiguration.swift | 16枠上限、物理メモリ注入、内部codecと1 MiBの予約、memory/spill spool |
| Sources/GyoshukuKit/Compression/OrderedChunkPipeline.swift | pending数、指定したinner1-threadのinline符号化 |
| Sources/GyoshukuKit/Compression/LZMA2ChunkPipeline.swift | worker内部のinline指定を伝播 |
| Sources/GyoshukuKit/Compression/ParallelXZCompressor.swift | worker内部のinline指定を伝播 |
| Sources/GyoshukuKit/API/WriterOptions.swift | pending上界と固定物理メモリ用の内部計算、巨大solidの逐次判定 |
| Sources/GyoshukuKit/LHA/LHAWriter.swift | 単独中memberの旧片並列、小・中窓の共有、worker内部thread配分とjoin |
| Sources/GyoshukuKit/LHA/LHAEntryCompressor.swift | 小recordのmemory spool、内部writerの再帰防止、注入encoder保持 |
| Sources/GyoshukuKit/SevenZip/SevenZipBlockWriter.swift | 最終単独folderの全threads、内部thread配分、256 MiBとCopy判定、memory spool |
| Sources/GyoshukuKit/SevenZip/SevenZipWriter.swift | 項目出力のmemory/spill spool、空項目のspool回避 |
| Sources/GyoshukuKit/SevenZip/SevenZipChunkPipeline.swift | inner inline指定とabort/join |
| Sources/GyoshukuKit/SevenZip/SevenZipFolderEncoder.swift | inner inline指定を伝播、成功/失敗/取消しで内部窓をjoin |
| Sources/GyoshukuKit/Zip/ZipWriter.swift | memory/spill spool、empty/storedの直接出力、tiny Zstdのinline、batch確定method、Stored batchの1 MiB上限 |
| Sources/GyoshukuKit/Zip/ZipEntryCompressor.swift | worker内部のinline指定 |
| Sources/GyoshukuKit/Writer/ArchiveWriter.swift | batchの確定済みZipRecords.Entry.methodを渡す |
| Tests/GyoshukuKitTests/Compression/LZMAWriterConfigurationTests.swift | 固定予算のliteral pending上界 |
| Tests/GyoshukuKitTests/Compression/PPMd/PPMdWriterOptionsTests.swift | 固定予算のliteral pending上界 |
| Tests/GyoshukuKitTests/Compression/OrderedChunkPipelineWindowTests.swift | inner1-threadのthread同一性と順序・エラー |
| Tests/GyoshukuKitTests/Compression/OrderedEntrySpoolTests.swift（新規） | spill境界、空/dir/stored、descriptor、fault注入、Stored batch/単項目の平文/AES byte一致 |
| Tests/GyoshukuKitTests/LHA/LHACompressionMethodTests.swift | 固定物理メモリのliteral予約と上界 |
| Tests/GyoshukuKitTests/SevenZip/SevenZipCompressionMethodTests.swift | method/thread別のliteral上界 |
| Tests/GyoshukuKitTests/Zip/ZipZstdWriterTests.swift | level別のliteral上界 |
| Tests/GyoshukuKitTests/Zip/ZipAdditionalCompressionWriterTests.swift | BZip2/XZのliteral上界 |
| Tests/GyoshukuKitTests/Zip/ZipPPMdWriterTests.swift | literal上界 |
| Tests/GyoshukuKitTests/Writer/MulticoreWriterTests.swift | t+1中項目、near16 MiB gate、LHA混在spool数と注入失敗 |
| Tests/README.md | 大入力試験のgateと実行範囲 |
| Benchmarks/Package.swift | worktree名に依存しないpackage名と新timing executable |
| Benchmarks/Sources/GyoshukuMulticore/main.swift（新規） | 公開APIだけのrelease timing、CPU/load/hash記録 |
| Benchmarks/multicore.py | 単一・small・混在の入力、交互best-of-5、hashと5%の判定 |
| Benchmarks/README.md | 両版の同一flagsとround 2再実行手順 |
| Documentation/design.md | spool・予約・内部thread・一時diskの上界と退行対策 |
| Documentation/verification/2026-10-07-writer-multicore.md | 今回とround 1の計測・試験・残る範囲 |
| Documentation/verification/2026-10-07-writer-multicore.r2.{samples.jsonl,tests.jsonl,corpus.json,tsv}（新規） | 全生sample、test履歴、入力manifest、best値の集計 |

### 残る範囲と再実行

5%判定はこの47条件・既定level・threads1/12での実測。あらゆる入力・level・負荷での退行が無いことを
有限の計測から証明したものではない。並行する他jobのload差とfile cacheの影響は残るため、全sampleも保存した。
50,000小file、BCJ/ARM64各filterの速度、256 MiB超のsolidの速度は今回は測っていない。
allocatorの管理領域とOS file cacheはcodec予約の対象外。圧縮出力が1 MiBを超える場合とLHA中recordには
一時diskが必要で、出力膨張分も含めた空き容量は利用側が確保する。
codec内部`Compression/{LZMA,PPMd,Zstd}`、`Tests/Fixtures`、public APIは変更していない。
進捗・header・暗号化は投入順の呼出threadで保持し、失敗と取消しは着手workerをjoinしてspoolを閉じる。
変更は未commitでworktreeに残す。

[round 2全sample](2026-10-07-writer-multicore.r2.samples.jsonl)、
[test名・構成・結果](2026-10-07-writer-multicore.r2.tests.jsonl)、
[入力manifest](2026-10-07-writer-multicore.r2.corpus.json)、
[集計TSV](2026-10-07-writer-multicore.r2.tsv)。
再実行は[Benchmarks/README.md](../../Benchmarks/README.md)のround 2節を参照。

---

## round 1（f9d5178）の記録

以下はround 1時点の実測・制約。今回のmemory spool、単独member/folderの経路、thread配分と上界は上のround 2節が現行。


基準はf273d346fc8e0743d56604e8c59adb61cedc1828。コーデック内部と凍結fixtureは変更していない。
ZIP 12/14/95/93/98の中項目、7z LZMA/BZip2/PPMdの中folder、solid/filterのfolderを有界窓で並列化した。
LHA LH5/6/7も1 MiB超〜16 MiBのmemberを項目間で並列化し、既存の1 MiB符号化境界を保つ。

### 条件

ユーザー指定環境はApple M4 Max、16 cores、128 GB。実行環境はmacOS 27.2 (26B5101f)、Apple Swift 6.4。
release、native SwiftPM、`-Xswiftc -enable-testing`。比較対象のSwiftソースは別buildに固定し、baselineに追加したのは同じopt-in harnessだけ。
ZIP/7z/tar/単独streamはそのwriter変更を含む初回buildで計測。LHA中member窓は後から追加し、最終build後にLHAの60 sampleを基準版と交互に取り直した。
他経路の実装・codecはその間変更していない（共有予約関数は同じ計算をhelperへ抽出）。LHA追加後のbinaryで他50経路の速度は再計測していない。
同じcorpus、同じプロセス条件でbase/newを続けて実行し、threads 1/12を各5回。最短wallのsampleに対応するCPU秒を表示する。
他workstreamも同じMacで動くため数値はノイズを含む。CPU秒はuser+system、実効コア数はCPU/wall。MB/sは10^6 byte/s。
wall/CPUはcreate/compress〜finish、SHA-256とサイズ確認は計測外。参照CLIのwall/CPUはプロセス全体。

入力は268,435,456 byte。96×2 MiBの中file＋64 MiBの大file、Swift本文50%・反復binary25%・seeded乱数25%。
corpus SHA-256: `473b4f17c3c378e80a0a4be156cb0e80480258ba787e7f6b3ca97c2d2e2f9f51`。時刻は各sample前に1700000000へ固定。
ZIP heuristicはfalse。levelはDeflate6/BZip2 9/Zstd3/PPMd6/LHA6、raw LZMA1は6、XZ/LZMA2はApple nil-level経路。
7zのsolidは16 MiB block、`filter`はDelta距離4。BCJ/ARM64/autoはコード上同じfolder経路、BCJ/ARM64も機能テストで照合したが速度を個別には測っていない。
単独streamは同じ順で連結した256 MiB本文。tarのcodec参照もこの本文を使う（tar headerは参照入力に含まない）。

参照: 7zz 26.04（26.03はこのMacに無かった）、xz 5.8.4、zstd 1.5.7、lzip1.26、LZ4 1.10.0、Brotli1.2.0、OS gzip/bzip2/compress、LHa for UNIX1.14i-ac20260723。
CLI commandと全sampleは末尾のJSONLに保存した。参照presetはlibraryの自前presetと同一アルゴリズムではない。
参照43条件は各5回成功。OS compress -cの初回1件は/dev/stdoutのsandbox拒否で失敗し、速度集計から除外した。
.Z参照は計時外で作った同一本文のコピーへ通常file出力し、元corpusを保った。失敗行も参照JSONLに残す。

### コードの経路表

| 経路 | f273d34でthreads>1が行う仕事 | 変更後 |
|---|---|---|
| zip-stored | 逐次I/O（batchは並列先読み/CRC） | 同左 |
| zip-deflate | 1 MiB block / 項目間（ZipCryptoは逐次） | 同左 |
| zip-bzip2 | 一項目の単一stream/frame/model、逐次 | 16 MiB以下の項目間、大項目は逐次 |
| zip-lzma | 一項目の単一stream/frame/model、逐次 | 16 MiB以下の項目間、大項目は逐次 |
| zip-xz | 項目内XZ block（nil levelは16 MiB） | 加えて16 MiB以下の項目間 |
| zip-zstd | 一項目の単一stream/frame/model、逐次 | 16 MiB以下の項目間、大項目は逐次 |
| zip-ppmd | 一項目の単一stream/frame/model、逐次 | 16 MiB以下の項目間、大項目は逐次 |
| tar | 逐次I/O | 同左 |
| tar.gz | 単一gzipの1 MiB Deflate block | 同左 |
| tar.bz2 | 独立bzip2 stream（level9は最大4.5 MB） | 同左 |
| tar.xz | 単一XZのblock（nilは16 MiB、tarは小memberを4 MiB packing） | 同左 |
| tar.zst | 独立Zstd frame（既定4 MiB） | 同左 |
| tar.lz | 独立lzip member（既定24 MiB） | 同左 |
| tar.lzma | LZMA_Alone単一stream、逐次 | 同左 |
| tar.lz4 | 単一frameの独立4 MiB block | 同左 |
| tar.br | Brotli単一stream、逐次 | 同左 |
| tar.Z | LZW単一stream、逐次 | 同左 |
| 7z-lzma2 | block / 項目間 | 同左 |
| 7z-lzma2-filter | folder内blockのみ | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-lzma2-solid | folder内blockのみ | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-lzma2-solid-filter | folder内blockのみ | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-lzma | 単一folderを逐次 | 16 MiB以下のfolder間、大項目は逐次 |
| 7z-lzma-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-lzma-solid | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-lzma-solid-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-deflate | block / 項目間 | 同左 |
| 7z-deflate-filter | folder内blockのみ | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-deflate-solid | folder内blockのみ | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-deflate-solid-filter | folder内blockのみ | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-bzip2 | 単一folderを逐次 | 16 MiB以下のfolder間、大項目は逐次 |
| 7z-bzip2-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-bzip2-solid | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-bzip2-solid-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-ppmd | 単一folderを逐次 | 16 MiB以下のfolder間、大項目は逐次 |
| 7z-ppmd-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-ppmd-solid | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-ppmd-solid-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-copy | 単一folderを逐次 | 同左 |
| 7z-copy-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-copy-solid | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| 7z-copy-solid-filter | 単一folderを逐次 | folder間（solid上限/非solid16 MiB以下）、大folderは従来経路 |
| lha-lh5 | 1 MiB以下のmember間 / 大member内1 MiB片 | 加えて1 MiB超〜16 MiBのmember間 |
| lha-lh6 | 1 MiB以下のmember間 / 大member内1 MiB片 | 加えて1 MiB超〜16 MiBのmember間 |
| lha-lh7 | 1 MiB以下のmember間 / 大member内1 MiB片 | 加えて1 MiB超〜16 MiBのmember間 |
| stream-gz | 単一gzipの1 MiB Deflate block | 同左 |
| stream-bz2 | 独立bzip2 stream（level9は最大4.5 MB） | 同左 |
| stream-xz | 単一XZのblock（nilは16 MiB、tarは小memberを4 MiB packing） | 同左 |
| stream-zst | 独立Zstd frame（既定4 MiB） | 同左 |
| stream-lz | 独立lzip member（既定24 MiB） | 同左 |
| stream-lzma | LZMA_Alone単一stream、逐次 | 同左 |
| stream-lz4 | 単一frameの独立4 MiB block | 同左 |
| stream-br | Brotli単一stream、逐次 | 同左 |
| stream-Z | LZW単一stream、逐次 | 同左 |

ZIP stored・tar・7z Copyの主処理はI/O。Brotli/LZW/Alone LZMA1は独立substreamへ分割しない。
ZIP BZip2のstream連結は使わない。ZIP XZは一streamのmulti-blockを維持する。
ZIP Zstd連結frameのprobeは7zz 26.04 status=0、KaitoKitも全内容一致。26.03は未確認。
level 3の64 MiB memberは単一frame 16,990,650 byte、4 MiB連結frame 20,122,354 byte。
全ZIPのbody差し替えによる計算上のサイズ差は+3.5829%（候補全ZIPの速度は未測定、全levelの比率も未確認）。
このframe分割は+0.3%の上限を超えるため採用せず、ZIPは大memberの単一frameと中memberの項目間並列化を維持する。

### wall/CPU（秒）と出力

各時間欄はwall / CPU。サイズは基準 / 変更byte。全53経路について、全20sampleのSHA-256が一つであることを確認した。

| 経路 | 基準1t | 基準12t | 変更1t | 変更12t | 基準/変更byte |
|---|---:|---:|---:|---:|---:|
| zip-stored | 0.048 / 0.047 | 0.046 / 0.045 | 0.048 / 0.048 | 0.048 / 0.047 | 268,447,694 / 268,447,694 |
| zip-deflate | 4.626 / 4.331 | 0.692 / 4.117 | 4.613 / 4.335 | 0.650 / 4.138 | 99,421,510 / 99,421,510 |
| zip-bzip2 | 27.229 / 23.914 | 26.988 / 23.639 | 29.245 / 24.286 | 10.702 / 24.577 | 90,438,540 / 90,438,540 |
| zip-lzma | 30.029 / 29.988 | 29.823 / 29.782 | 29.989 / 29.949 | 10.468 / 34.702 | 83,874,740 / 83,874,740 |
| zip-xz | 26.651 / 26.597 | 21.801 / 26.511 | 26.800 / 26.745 | 4.300 / 32.087 | 83,512,254 / 83,512,254 |
| zip-zstd | 1.615 / 1.610 | 1.593 / 1.590 | 1.600 / 1.596 | 0.510 / 2.115 | 87,406,271 / 87,406,271 |
| zip-ppmd | 44.879 / 44.760 | 44.518 / 44.396 | 43.798 / 43.666 | 15.198 / 51.101 | 88,201,198 / 88,201,198 |
| tar | 0.039 / 0.039 | 0.039 / 0.038 | 0.039 / 0.038 | 0.041 / 0.040 | 268,492,800 / 268,492,800 |
| tar.gz | 3.363 / 3.369 | 0.569 / 3.602 | 3.348 / 3.356 | 0.568 / 3.567 | 99,416,588 / 99,416,588 |
| tar.bz2 | 21.427 / 21.396 | 2.782 / 24.101 | 21.422 / 21.392 | 2.808 / 24.069 | 91,752,388 / 91,752,388 |
| tar.xz | 26.185 / 26.187 | 4.345 / 32.045 | 26.499 / 26.493 | 4.320 / 31.868 | 83,501,568 / 83,501,568 |
| tar.zst | 1.687 / 1.681 | 0.265 / 2.061 | 1.671 / 1.668 | 0.262 / 2.101 | 90,533,921 / 90,533,921 |
| tar.lz | 30.517 / 30.472 | 5.907 / 38.649 | 28.792 / 28.757 | 5.709 / 38.252 | 70,008,505 / 70,008,505 |
| tar.lzma | 29.612 / 29.569 | 29.933 / 29.897 | 29.657 / 29.592 | 30.563 / 30.452 | 68,215,836 / 68,215,836 |
| tar.lz4 | 0.251 / 0.250 | 0.061 / 0.253 | 0.250 / 0.248 | 0.061 / 0.255 | 120,637,746 / 120,637,746 |
| tar.br | 0.330 / 0.329 | 0.327 / 0.326 | 0.331 / 0.330 | 0.330 / 0.329 | 67,481,873 / 67,481,873 |
| tar.Z | 7.582 / 7.563 | 7.653 / 7.631 | 7.619 / 7.598 | 7.564 / 7.547 | 150,653,281 / 150,653,281 |
| 7z-lzma2 | 24.920 / 24.905 | 3.594 / 29.769 | 24.500 / 24.480 | 3.541 / 29.475 | 83,499,628 / 83,499,628 |
| 7z-lzma2-filter | 24.203 / 24.686 | 21.255 / 25.234 | 24.144 / 24.648 | 4.125 / 29.197 | 96,682,991 / 96,682,991 |
| 7z-lzma2-solid | 21.760 / 21.738 | 17.952 / 22.638 | 22.414 / 22.374 | 3.502 / 28.457 | 69,861,174 / 69,861,174 |
| 7z-lzma2-solid-filter | 20.834 / 21.370 | 19.060 / 23.064 | 21.848 / 22.363 | 4.066 / 28.416 | 71,970,417 / 71,970,417 |
| 7z-lzma | 28.328 / 28.310 | 27.967 / 27.929 | 28.318 / 28.305 | 8.877 / 32.726 | 83,867,141 / 83,867,141 |
| 7z-lzma-filter | 26.190 / 26.116 | 25.880 / 25.813 | 24.893 / 24.820 | 8.434 / 31.083 | 96,670,252 / 96,670,252 |
| 7z-lzma-solid | 27.131 / 26.989 | 25.876 / 25.850 | 26.800 / 26.758 | 8.561 / 31.940 | 70,176,846 / 70,176,846 |
| 7z-lzma-solid-filter | 27.103 / 27.076 | 25.130 / 25.109 | 26.228 / 26.184 | 8.543 / 32.071 | 71,892,595 / 71,892,595 |
| 7z-deflate | 3.116 / 3.145 | 0.389 / 3.359 | 3.111 / 3.143 | 0.385 / 3.330 | 99,414,961 / 99,414,961 |
| 7z-deflate-filter | 4.186 / 5.877 | 3.774 / 5.856 | 4.191 / 5.898 | 1.131 / 6.351 | 125,148,530 / 125,148,530 |
| 7z-deflate-solid | 3.187 / 3.196 | 0.584 / 3.369 | 3.222 / 3.232 | 0.352 / 3.398 | 99,414,671 / 99,414,671 |
| 7z-deflate-solid-filter | 3.557 / 5.956 | 3.165 / 5.970 | 3.540 / 5.934 | 1.135 / 6.537 | 125,147,392 / 125,147,392 |
| 7z-bzip2 | 20.714 / 20.707 | 20.682 / 20.675 | 20.778 / 20.767 | 7.191 / 21.623 | 90,431,991 / 90,431,991 |
| 7z-bzip2-filter | 20.353 / 20.299 | 20.315 / 20.261 | 20.321 / 20.266 | 7.204 / 21.270 | 114,583,369 / 114,583,369 |
| 7z-bzip2-solid | 23.024 / 23.007 | 23.171 / 23.150 | 23.108 / 23.091 | 7.438 / 24.081 | 92,204,716 / 92,204,716 |
| 7z-bzip2-solid-filter | 23.659 / 23.625 | 23.446 / 23.424 | 23.508 / 23.483 | 7.659 / 24.903 | 116,813,652 / 116,813,652 |
| 7z-ppmd | 40.232 / 40.218 | 41.556 / 41.499 | 40.277 / 40.266 | 12.830 / 43.813 | 89,246,644 / 89,246,644 |
| 7z-ppmd-filter | 50.796 / 50.734 | 50.813 / 50.751 | 50.027 / 49.970 | 17.188 / 58.328 | 104,785,676 / 104,785,676 |
| 7z-ppmd-solid | 38.852 / 38.833 | 39.043 / 39.024 | 38.725 / 38.706 | 12.919 / 43.020 | 86,084,378 / 86,084,378 |
| 7z-ppmd-solid-filter | 54.487 / 54.461 | 53.007 / 52.984 | 52.570 / 52.548 | 17.662 / 62.128 | 101,595,176 / 101,595,176 |
| 7z-copy | 0.049 / 0.049 | 0.048 / 0.047 | 0.048 / 0.048 | 0.048 / 0.048 | 268,441,047 / 268,441,047 |
| 7z-copy-filter | 3.211 / 3.175 | 3.178 / 3.137 | 3.198 / 3.162 | 1.008 / 3.293 | 268,442,017 / 268,442,017 |
| 7z-copy-solid | 0.104 / 0.088 | 0.104 / 0.088 | 0.104 / 0.088 | 0.108 / 0.124 | 268,440,474 / 268,440,474 |
| 7z-copy-solid-filter | 3.097 / 3.072 | 3.087 / 3.070 | 3.087 / 3.071 | 1.008 / 3.144 | 268,440,604 / 268,440,604 |
| lha-lh5 | 3.035 / 3.020 | 1.787 / 3.283 | 3.024 / 3.010 | 0.443 / 3.338 | 104,994,156 / 104,994,156 |
| lha-lh6 | 4.679 / 4.652 | 2.766 / 4.948 | 4.685 / 4.665 | 0.566 / 5.049 | 100,104,097 / 100,104,097 |
| lha-lh7 | 6.631 / 6.615 | 4.029 / 6.914 | 6.621 / 6.604 | 0.719 / 7.086 | 98,518,999 / 98,518,999 |
| stream-gz | 3.283 / 3.276 | 0.389 / 3.349 | 3.273 / 3.270 | 0.388 / 3.346 | 99,409,698 / 99,409,698 |
| stream-bz2 | 23.581 / 23.582 | 2.249 / 24.323 | 23.504 / 23.504 | 2.282 / 24.584 | 92,245,152 / 92,245,152 |
| stream-xz | 23.400 / 23.389 | 3.626 / 28.367 | 23.539 / 23.535 | 3.579 / 28.462 | 69,856,700 / 69,856,700 |
| stream-zst | 1.361 / 1.360 | 0.154 / 1.583 | 1.372 / 1.372 | 0.151 / 1.577 | 80,511,646 / 80,511,646 |
| stream-lz | 29.269 / 29.221 | 3.382 / 35.588 | 28.443 / 28.402 | 3.383 / 35.575 | 69,845,387 / 69,845,387 |
| stream-lzma | 27.869 / 27.845 | 27.640 / 27.615 | 27.867 / 27.842 | 27.306 / 27.286 | 68,215,111 / 68,215,111 |
| stream-lz4 | 0.233 / 0.234 | 0.056 / 0.238 | 0.234 / 0.234 | 0.056 / 0.238 | 120,629,637 / 120,629,637 |
| stream-br | 0.310 / 0.310 | 0.312 / 0.311 | 0.312 / 0.311 | 0.312 / 0.311 | 67,437,525 / 67,437,525 |
| stream-Z | 7.362 / 7.356 | 7.370 / 7.367 | 7.432 / 7.426 | 7.369 / 7.364 | 150,734,473 / 150,734,473 |

### throughput / speedup

thread倍率=変更1t / 変更12tのwall。変更倍率=基準12t / 変更12t。未変更経路の差は測定ノイズとして扱う。

| 経路 | 基準1t MB/s | 基準12t MB/s | 変更1t MB/s | 変更12t MB/s | thread倍率 | 変更倍率 | 実効core | 参照MB/s / byte |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| zip-stored | 5593.6 | 5822.3 | 5553.9 | 5583.2 | 1.01× | 0.96× | 0.99 | 3306.0 / 268,449,052 |
| zip-deflate | 58.0 | 388.1 | 58.2 | 412.9 | 7.10× | 1.06× | 6.37 | 70.3 / 98,028,118 |
| zip-bzip2 | 9.9 | 9.9 | 9.2 | 25.1 | 2.73× | 2.52× | 2.30 | 7.9 / 89,474,982 |
| zip-lzma | 8.9 | 9.0 | 9.0 | 25.6 | 2.86× | 2.85× | 3.32 | 51.2 / 84,151,898 |
| zip-xz | 10.1 | 12.3 | 10.0 | 62.4 | 6.23× | 5.07× | 7.46 | 50.8 / 83,300,072 |
| zip-zstd | 166.2 | 168.5 | 167.8 | 526.6 | 3.14× | 3.12× | 4.15 | 7139.3 / 85,782,502 |
| zip-ppmd | 6.0 | 6.0 | 6.1 | 17.7 | 2.88× | 2.93× | 3.36 | 52.3 / 86,517,008 |
| tar | 6826.0 | 6872.2 | 6911.5 | 6610.4 | 0.96× | 0.96× | 0.98 | 1966.3 / 268,486,144 |
| tar.gz | 79.8 | 472.1 | 80.2 | 472.5 | 5.89× | 1.00× | 6.28 | 82.4 / 99,628,284 |
| tar.bz2 | 12.5 | 96.5 | 12.5 | 95.6 | 7.63× | 0.99× | 8.57 | 11.1 / 92,261,346 |
| tar.xz | 10.3 | 61.8 | 10.1 | 62.1 | 6.13× | 1.01× | 7.38 | 106.3 / 69,044,900 |
| tar.zst | 159.1 | 1011.4 | 160.7 | 1024.5 | 6.38× | 1.01× | 8.02 | 7139.3 / 85,782,502 |
| tar.lz | 8.8 | 45.4 | 9.3 | 47.0 | 5.04× | 1.03× | 6.70 | 11.0 / 68,228,440 |
| tar.lzma | 9.1 | 9.0 | 9.1 | 8.8 | 0.97× | 0.98× | 1.00 | 13.8 / 68,229,426 |
| tar.lz4 | 1071.0 | 4400.9 | 1075.1 | 4396.7 | 4.09× | 1.00× | 4.18 | 4005.2 / 118,767,036 |
| tar.br | 812.4 | 820.6 | 809.9 | 813.8 | 1.00× | 0.99× | 1.00 | 881.9 / 67,437,223 |
| tar.Z | 35.4 | 35.1 | 35.2 | 35.5 | 1.01× | 1.01× | 1.00 | 80.1 / 143,587,381 |
| 7z-lzma2 | 10.8 | 74.7 | 11.0 | 75.8 | 6.92× | 1.01× | 8.32 | 21.0 / 83,281,800 |
| 7z-lzma2-filter | 11.1 | 12.6 | 11.1 | 65.1 | 5.85× | 5.15× | 7.08 | 32.0 / 96,061,515 |
| 7z-lzma2-solid | 12.3 | 15.0 | 12.0 | 76.7 | 6.40× | 5.13× | 8.13 | 20.2 / 69,382,383 |
| 7z-lzma2-solid-filter | 12.9 | 14.1 | 12.3 | 66.0 | 5.37× | 4.69× | 6.99 | 30.7 / 71,094,509 |
| 7z-lzma | 9.5 | 9.6 | 9.5 | 30.2 | 3.19× | 3.15× | 3.69 | 21.5 / 84,137,597 |
| 7z-lzma-filter | 10.2 | 10.4 | 10.8 | 31.8 | 2.95× | 3.07× | 3.69 | 31.9 / 96,889,664 |
| 7z-lzma-solid | 9.9 | 10.4 | 10.0 | 31.4 | 3.13× | 3.02× | 3.73 | 20.3 / 70,209,526 |
| 7z-lzma-solid-filter | 9.9 | 10.7 | 10.2 | 31.4 | 3.07× | 2.94× | 3.75 | 30.8 / 71,918,913 |
| 7z-deflate | 86.1 | 690.0 | 86.3 | 697.0 | 8.08× | 1.01× | 8.65 | 22.4 / 98,015,462 |
| 7z-deflate-filter | 64.1 | 71.1 | 64.0 | 237.3 | 3.71× | 3.34× | 5.61 | 33.4 / 124,228,960 |
| 7z-deflate-solid | 84.2 | 459.8 | 83.3 | 761.9 | 9.15× | 1.66× | 9.64 | 22.6 / 98,074,762 |
| 7z-deflate-solid-filter | 75.5 | 84.8 | 75.8 | 236.6 | 3.12× | 2.79× | 5.76 | 33.6 / 124,242,713 |
| 7z-bzip2 | 13.0 | 13.0 | 12.9 | 37.3 | 2.89× | 2.88× | 3.01 | 3.8 / 89,462,330 |
| 7z-bzip2-filter | 13.2 | 13.2 | 13.2 | 37.3 | 2.82× | 2.82× | 2.95 | 4.5 / 113,352,654 |
| 7z-bzip2-solid | 11.7 | 11.6 | 11.6 | 36.1 | 3.11× | 3.12× | 3.24 | 13.1 / 91,000,914 |
| 7z-bzip2-solid-filter | 11.3 | 11.4 | 11.4 | 35.0 | 3.07× | 3.06× | 3.25 | 15.2 / 115,444,041 |
| 7z-ppmd | 6.7 | 6.5 | 6.7 | 20.9 | 3.14× | 3.24× | 3.41 | 17.0 / 86,819,603 |
| 7z-ppmd-filter | 5.3 | 5.3 | 5.4 | 15.6 | 2.91× | 2.96× | 3.39 | 14.2 / 102,001,284 |
| 7z-ppmd-solid | 6.9 | 6.9 | 6.9 | 20.8 | 3.00× | 3.02× | 3.33 | 17.9 / 80,505,134 |
| 7z-ppmd-solid-filter | 4.9 | 5.1 | 5.1 | 15.2 | 2.98× | 3.00× | 3.52 | 14.6 / 91,533,619 |
| 7z-copy | 5455.3 | 5594.8 | 5567.6 | 5551.6 | 1.00× | 0.99× | 0.99 | 4137.5 / 268,436,182 |
| 7z-copy-filter | 83.6 | 84.5 | 83.9 | 266.3 | 3.17× | 3.15× | 3.27 | 2201.9 / 268,436,199 |
| 7z-copy-solid | 2574.3 | 2570.5 | 2578.8 | 2495.5 | 0.97× | 0.97× | 1.16 | 4124.1 / 268,436,180 |
| 7z-copy-solid-filter | 86.7 | 87.0 | 86.9 | 266.3 | 3.06× | 3.06× | 3.12 | 2239.7 / 268,436,189 |
| lha-lh5 | 88.4 | 150.2 | 88.8 | 605.7 | 6.82× | 4.03× | 7.53 | 47.3 / 104,360,225 |
| lha-lh6 | 57.4 | 97.1 | 57.3 | 474.3 | 8.28× | 4.89× | 8.92 | 34.8 / 99,433,880 |
| lha-lh7 | 40.5 | 66.6 | 40.5 | 373.2 | 9.20× | 5.60× | 9.85 | 25.3 / 97,760,456 |
| stream-gz | 81.8 | 690.0 | 82.0 | 691.2 | 8.43× | 1.00× | 8.62 | 82.4 / 99,628,284 |
| stream-bz2 | 11.4 | 119.4 | 11.4 | 117.6 | 10.30× | 0.99× | 10.77 | 11.1 / 92,261,346 |
| stream-xz | 11.5 | 74.0 | 11.4 | 75.0 | 6.58× | 1.01× | 7.95 | 106.3 / 69,044,900 |
| stream-zst | 197.2 | 1743.6 | 195.6 | 1777.4 | 9.09× | 1.02× | 10.44 | 7139.3 / 85,782,502 |
| stream-lz | 9.2 | 79.4 | 9.4 | 79.3 | 8.41× | 1.00× | 10.52 | 11.0 / 68,228,440 |
| stream-lzma | 9.6 | 9.7 | 9.6 | 9.8 | 1.02× | 1.01× | 1.00 | 13.8 / 68,229,426 |
| stream-lz4 | 1150.4 | 4836.6 | 1149.6 | 4818.9 | 4.19× | 1.00× | 4.28 | 4005.2 / 118,767,036 |
| stream-br | 864.8 | 859.2 | 859.8 | 860.9 | 1.00× | 1.00× | 1.00 | 881.9 / 67,437,223 |
| stream-Z | 36.5 | 36.4 | 36.1 | 36.4 | 1.01× | 1.00× | 1.00 | 80.1 / 143,587,381 |

実効6core以上は21/53測定条件: zip-deflate, zip-xz, tar.gz, tar.bz2, tar.xz, tar.zst, tar.lz, 7z-lzma2, 7z-lzma2-filter, 7z-lzma2-solid, 7z-lzma2-solid-filter, 7z-deflate, 7z-deflate-solid, lha-lh5, lha-lh6, lha-lh7, stream-gz, stream-bz2, stream-xz, stream-zst, stream-lz。並列化可能な圧縮経路のすべてで6core以上という目標は未達。
単一の大きいLZMA1/PPMd/ZIP BZip2/Zstd frameは逐次、Copy/stored/tarはI/Oに制限される。
実効コア数は平均CPU使用量であり、同時worker数や瞬間peakではない。小folder数・直列読取/CRC/書出し・他workstreamのCPU競合でも低下する。

### 変更ファイル

| ファイル | 目的 |
|---|---|
| .gitignore | 隔離した基準版buildを除外 |
| Sources/GyoshukuKit/API/WriterOptions.swift | 並列化の対象と待ち入力上界を更新 |
| Sources/GyoshukuKit/Compression/EntryCompressionConfiguration.swift | 項目workerの予約・並列数・取消しlatch・spool所有権 |
| Sources/GyoshukuKit/Zip/ZipEntryCompressor.swift | 既存の項目codec状態をcaller/workerごとに分離 |
| Sources/GyoshukuKit/Zip/ZipWriter.swift | ZIP中項目とbatchを順序付き並列圧縮 |
| Sources/GyoshukuKit/SevenZip/SevenZipWriter.swift | 非solid LZMA/BZip2/PPMdの中folderを並列圧縮 |
| Sources/GyoshukuKit/SevenZip/SevenZipBlockWriter.swift | solid/filter folderのspoolを順序付き並列圧縮 |
| Sources/GyoshukuKit/LHA/LHAWriter.swift | 中member窓と大member内の既存片並列を切替 |
| Sources/GyoshukuKit/LHA/LHAEntryCompressor.swift | 既存writerで中memberの完成recordをworker内で作成 |
| Sources/GyoshukuKit/Writer/ArchiveWriter.swift | ZIP batchの圧縮spoolを受け取って出力 |
| Sources/GyoshukuKit/Writer/SourcePrefetchLimiter.swift | 内部prefetch結果に圧縮spoolを保持 |
| Tests/GyoshukuKitTests/Writer/MulticoreWriterTests.swift | 暗号化・filter・順序・メモリ・取消し・LHA fallbackの照合 |
| Tests/GyoshukuKitTests/Probes/MulticoreBenchmarkTests.swift | opt-inで53経路のwall/CPU/size/SHAを計測 |
| Tests/GyoshukuKitTests/Probes/ZipConcatenatedZstdProbeTests.swift | ZIP93連結frameのreader受理と大memberのサイズ差を調査 |
| Tests/GyoshukuKitTests/Compression/LZMAWriterConfigurationTests.swift | 項目窓に合わせた待ち入力上界 |
| Tests/GyoshukuKitTests/Compression/PPMd/PPMdWriterOptionsTests.swift | PPMdモデルを保った並列項目窓の上界 |
| Tests/GyoshukuKitTests/SevenZip/SevenZipCompressionMethodTests.swift | 新規7z folder窓の上界 |
| Tests/GyoshukuKitTests/Zip/ZipAdditionalCompressionWriterTests.swift | ZIP BZip2/XZの入力待ち上界 |
| Tests/GyoshukuKitTests/Zip/ZipPPMdWriterTests.swift | PPMdの中項目待ち入力上界 |
| Tests/GyoshukuKitTests/Zip/ZipZstdWriterTests.swift | Zstdの中項目待ち入力上界 |
| Tests/GyoshukuKitTests/LHA/LHACompressionMethodTests.swift | LHA中member窓を含む入力上界 |
| Tests/GyoshukuKitTests/LHA/LHAStreamSpliceTests.swift | 中memberの順序待ちと既存逐次bit列の照合 |
| Tests/README.md | 計測gateの登録 |
| Benchmarks/multicore.py | 固定corpus生成・交互5回計測・参照CLI計測 |
| Benchmarks/multicore-report.py | sample検査と経路表・速度表・試験記録の生成 |
| Benchmarks/README.md | 基準版buildと計測の再実行手順 |
| Documentation/design.md | 予約・入力上界・spool/進捗/取消し契約と実測 |
| Documentation/verification/2026-10-07-writer-multicore.md | 全経路の実測と検証結果 |
| Documentation/verification/2026-10-07-writer-multicore.samples.jsonl | 全library sampleの生データ |
| Documentation/verification/2026-10-07-writer-multicore.references.jsonl | 参照commandと全sampleの生データ |
| Documentation/verification/2026-10-07-writer-multicore.zstd-frame-ratio.jsonl | ZIP Zstd大memberのframe resetサイズとreader照合 |
| Documentation/verification/2026-10-07-writer-multicore.tsv | throughput・size・coreの集計 |
| Documentation/verification/2026-10-07-writer-multicore.tests.jsonl | 実行したtest名・構成・結果・case時間の記録 |

### 機能試験

全test suiteは実行していない。release受入は26クラス131件、220.720秒、130成功/1失敗（旧PPMd pending=0期待値）。
その期待値を項目窓へ更新した後、MulticoreWriterTests/SevenZipPPMdWriterTests/ZipPPMdWriterTestsを再実行し15/15成功、76.168秒。
初回release対象実行は13件、11成功/1skip/1caseで5assertion失敗、20.383秒。
この新規AES比較はsalt固定漏れを固定saltへ修正して成功。対象はMulticoreWriterTests/LZMAWriterConfigurationTests/PPMdWriterOptionsTests/ZipZstdWriterTests/ZipConcatenatedZstdProbeTests。
LHA最終実装を含むrelease再検証: 136成功/0失敗/0skip、106.317秒。

| クラス | 最終成功case | case時間合計(秒) |
|---|---:|---:|
| AdditionProgressTests | 6 | 1.891 |
| BatchAdditionEquivalenceTests | 4 | 21.030 |
| BatchAdditionEventsTests | 5 | 0.252 |
| BatchAdditionSafetyTests | 6 | 0.083 |
| BatchOutputTests | 4 | 1.280 |
| EmptyBatchTests | 10 | 0.129 |
| FinishAdditionsTests | 8 | 10.879 |
| LHABoundedWriterTests | 4 | 0.770 |
| LHACompressionMethodTests | 8 | 23.998 |
| LHADefaultOutputTests | 1 | 0.015 |
| LHAHeaderReemitTests | 1 | 0.052 |
| LHALifecycleTests | 8 | 0.691 |
| LHAStreamSpliceTests | 2 | 2.130 |
| LHAUpdaterTests | 5 | 0.495 |
| LHAUpdaterVerificationFaultTests | 1 | 0.006 |
| LHAWriterParallelTests | 6 | 0.542 |
| LHAWriterStreamedMemberIdentityTests | 1 | 0.167 |
| LHAWriterTests | 10 | 4.163 |
| LZMAWriterConfigurationTests | 2 | 0.001 |
| LZMAWriterDefaultOutputTests | 1 | 1.082 |
| MulticoreWriterTests | 6 | 17.858 |
| PPMdWriterOptionsTests | 1 | 0.001 |
| ParallelDeflateBzip2WriterTests | 11 | 11.228 |
| SevenZipCompressionMethodTests | 4 | 23.181 |
| SevenZipFilterWriterTests | 7 | 14.116 |
| SevenZipHeaderSerializerTests | 2 | 0.044 |
| SevenZipLZMALevelTests | 5 | 9.442 |
| SevenZipPPMdWriterTests | 5 | 35.425 |
| SevenZipSolidWriterTests | 6 | 13.130 |
| SevenZipWriterByteIdentityTests | 2 | 2.915 |
| SevenZipWriterTests | 18 | 2.447 |
| ZipAdditionalCompressionEditingTests | 4 | 1.066 |
| ZipAdditionalCompressionWriterTests | 9 | 14.824 |
| ZipLZMALevelTests | 5 | 13.135 |
| ZipModernMethodEditingTests | 2 | 0.099 |
| ZipPPMdWriterTests | 5 | 24.189 |
| ZipWriterTests | 11 | 6.195 |
| ZipZstdWriterTests | 4 | 5.470 |

最終状態で上表のunique 200件がすべて成功。
debug初回はMulticoreWriterTestsのtestEntryMemoryReservationsKeepSequentialFallback、testQueuedEntriesCancelAndReleaseSpools、testZIPBatchHeuristicAndProgressOrderの3/3成功、3.402秒。
debug最終再検証は上記3件とtestLHAMediumMembersKeepIdentityProgressAndStoredFallback: 4成功/0失敗/0skip、14.430秒。
独立release実行: LZMAWriterDefaultOutputTests 1/1成功1.132秒、ZipConcatenatedZstdProbeTests/testIndependentReaders 1/1成功0.079秒。
ZipConcatenatedZstdProbeTests/testLargeMemberFrameResetSize: 1成功/0失敗/0skip、0.699秒。
既定gate確認: baseline harness1件skip。初回のZipAdditionalCompressionWriterTests/SevenZipCompressionMethodTests/SevenZipSolidWriterTestsは19成功/benchmark1skip、47.309秒。
計測用MulticoreBenchmarkTests/testWriterMatrixは最終集計1060 sample（53経路×2版×2threads×5回）。LHA再build前の60 sampleは置き換え、実行数は計1120回。
lzma-writers、lha-methods、sevenzip-edit、zip-modernの凍結fixture照合を対象クラスで実施。fixtureは書き換えていない。

### メモリ・進捗・残る制約

予約とmaximumPendingInputBytesは[design.md](../design.md)のwriter並列化節を参照。一項目入力は16 MiB、圧縮出力はdisk spool。
solid/filterの入力spoolもpendingへ計上し、内部pipelineを1 threadにして入れ子の予約を抑える。大folderの従来経路では内部block並列を保つ。
spoolによる追加disk I/Oと空き容量が必要。file cacheとallocator管理領域はcodecの予約に含まない。codecモデル/辞書を縮小しない。
進捗と暗号化乱数の順序は呼出側に置き、取消しをworkerのread/writeへ伝え、abortでworker/spoolを解放する。
計測は上記corpus/既定level/solid16 MiB/Delta4のみ。全level、他corpus、26.03そのもの、BCJ/ARM64別の速度は未測定。
PPMd/Zstd/LZMAのSources配下は無変更。public API追加なし。コミットせずworktreeに残した。

### 生データと再実行

[全sample JSONL](2026-10-07-writer-multicore.samples.jsonl)、[参照JSONL](2026-10-07-writer-multicore.references.jsonl)、[集計TSV](2026-10-07-writer-multicore.tsv)、[test名・構成・結果](2026-10-07-writer-multicore.tests.jsonl)。
`Benchmarks/multicore.py measure` / `references`と`Benchmarks/multicore-report.py`で再実行・集計できる。
