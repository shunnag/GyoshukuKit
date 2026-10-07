# Write-throughput benchmark

macOS 26+、Swift 6、Python 3 が必要です。独立した SwiftPM package なので、root の
products / targets / `swift test` は変えません。repository root から実行します。
`../` の GyoshukuKit に依存する実行 package なので `Tests/` の外に置きます（KaitoKit の
`Tests/Measurement/` は package ではなく script の directory です）。試験の構成と、`swift test` の中の
opt-in の計測（`GYOSHUKU_*`）は [Tests/README.md](../Tests/README.md) にあります。

```sh
Benchmarks/make-corpora.sh /tmp/gyoshuku-corpora
Benchmarks/run.sh /tmp/gyoshuku-corpora
Benchmarks/run.sh /tmp/gyoshuku-corpora 'zip,tgz,tbz,txz,7z' 'text,small' --threads 4 --references
```

`make-corpora.sh` は新規または空の directory に以下を作ります。

| 選択名 | 入力 | 生成条件 |
|---|---|---|
| `text` | `text256.txt` | 256 MiB。`/usr/share/dict/words` から空白区切りで標本化、seed 20260924 |
| `random` | `random256.bin` | 256 MiB。Python MT19937、seed 20260925、1 MiB ごとの `getrandbits` を little endian に変換 |
| `headers` | `headers/` | `xcrun --sdk macosx --show-sdk-path` の `usr/include` をコピー。symlink は実体化 |
| `small` | `small/` | 50,000 files、各 1,024〜4,096 byte の単語列、seed 20260926 |

`WORDS_FILE` / `SDKROOT` で辞書 / SDK を指定できます。SDK の `usr/include` がなければ
理由を表示して headers を skip します。生成物の時刻と mode は固定し、`manifest.json` に
Python version、seed、辞書の SHA-256、SDK path、corpus ごとの件数・byte 数・digest を保存します。
corpus digest は名前順の各 file について、root 相対名の UTF-8 byte 長（UInt64 LE）、名前、
file size（UInt64 LE）、内容を順に SHA-256 へ渡した値です。同じ Python・辞書・SDK で再生成し、
digest を照合してください。SDK の版によって headers の件数とサイズは変わります。
過去の一時 harness と同じ種別の入力ですが、過去の corpus の byte 列を再現するものではありません。

`run.sh` は release build 後、指定した形式 × corpus をそれぞれ1回実行します。
形式と corpus は引用した空白区切り、または comma 区切りで指定できます。省略時は全形式・全 corpus。
`/usr/bin/time -l` の wall / user 秒、peak RSS（macOS の byte 値を MiB へ換算）、出力 byte 数、
thread 設定を TSV で表示します。コマンド、標準出力、生の time 出力、corpus manifest、
`results.tsv` は `Benchmarks/.build/results/run.XXXXXX/` に残し、成功した書庫は測定ごとに削除します。
失敗時は非ゼロで終了し、ログと残った出力を保持します。

`--mode recursive|items|batch` は GyoshukuKit の追加経路を選ぶ。既定の recursive は directory を
そのまま writer に渡す。items と batch は同じ名前順の前順走査（計時に含む）で項目列を作り、
items は項目別 API、batch は一回の `add(_:events:)` を使う。`--progress` は byte 進捗を観測し、
finish の前に `finishAdditions` を呼ぶ。directory の日時は現在時刻なので、この bench の mode 間の
比較では書庫 byte の一致を要求しない。`make-corpora.sh` の small は一つの directory に 50,000 file を平らに置きます。

`--references` は選択した `zip` / `txz` / `7z` に対して、PATH 上にある
`zip -r -6` / `tar | xz -6 -T0` / `7zz a -mx6` を追加します。欠けたツールは理由付きで skip。
`tar+xz` は tar 作成も計時し、RSS は `/usr/bin/time` の子プロセス群の最大値です
（同時使用メモリの合計ではありません）。reference の thread 数は zip が1、xz / 7zz が自動です。
7zz の solid 圧縮と writer の non-solid 圧縮など、既定設定の違いも結果に含まれます。
比較時は同じマシン・入力を使い、他の build / test と同時に実行せず、必要に応じて繰り返してください。

単独実行もできます。

```sh
swift build -c release --package-path Benchmarks
bin_dir=$(swift build -c release --package-path Benchmarks --show-bin-path)
"$bin_dir/gyoshuku-bench" zip /tmp/new-output.zip /tmp/gyoshuku-corpora/text256.txt --level 6 --threads 8
```

`gyoshuku-bench <zip|tar|tgz|tbz|txz|7z|lha> <output> <source>... [--level N] [--threads N]`
は source の basename で追加し、directory は名前順に再帰します。出力は入力の外にある新規 file に限ります。
`--level` は元の harness と同じ `deflateLevel`（0...9、既定6）で、ZIP / tar.gz に適用します。
bzip2 は library 既定の9、XZ / 7z / LHA は library 固有の設定です。
tar.xz は 4 MiB 以下の member を最大 4 MiB の block に詰め、4 MiB を越える member は header 群と
本文を分けて、本文と大きな header 群を最大 16 MiB の片にします。この配置は 0.6.0 からなので、
0.6.0 より前の tar.xz の結果とはサイズ・時間をそのまま比べないでください。
`--threads` は `compressionThreads`（1...64）へ渡し、省略時は nil のまま library に委ねます。
表示する `threads` は圧縮の並列数の設定です。tar.xzは2以上で64 KiB以下のblockを枠に数えず、
未出力blockを合計 `2 × threads + 1` まで許すため、同時に動くencoderの総数とは一致しません。
自動値の表示は library の現行規則（CPU 数・物理メモリ GiB・8 の最小値、最低1）と揃えています。
非圧縮 tar は常に1です。単独実行の `elapsed_s` は `ContinuousClock` で create から finish までを
測り、runner の wall 秒はプロセス起動・終了も含みます。`--level` / `--threads` は reference には適用しません。

検証記録:
[並列 LZMA2](../Documentation/verification/2026-09-24-parallel-lzma2.md)、
[並列 deflate / bzip2](../Documentation/verification/2026-09-24-parallel-deflate-bzip2.md)（2026-09-24）、
[tar.xz の block の詰め方](../Documentation/verification/2026-09-26-p14-xz-packing.md)（2026-09-26、
親 commit と交互に作った受入比較）、
[batch 追加](../Documentation/verification/2026-09-27-p7g-batch.md)（2026-09-27、三階層の固定 small corpus での
mode 間の受入計測）。


writer全経路の比較は`multicore.py`と`MulticoreBenchmarkTests`を使います。通常のswift testではskipされます。
`compressionThreads`は1/12、コーパスは256 MiB（96個の2 MiBと1個の64 MiB）、レベルはlibrary既定です。
7z solidは16 MiBのblock、filterの計測はDelta距離4。BCJ/ARM64/autoも同じfolder経路を使い、互換性は対象testで照合します。
CPU秒は`getrusage(RUSAGE_SELF)`のuser+system、wallはcreate/compressからfinishまで。SHA-256とサイズの確認は計測外。
各経路についてbase/newを連続して5回ずつ測り、最短wallのsampleに対応するCPU秒を報告します。

```sh
mkdir -p .build-base/source
git archive f273d34 | tar -x -C .build-base/source
ln -s /Users/nagash/Github/KaitoKit .build-base/KaitoKit
cp Tests/GyoshukuKitTests/Probes/MulticoreBenchmarkTests.swift .build-base/source/Tests/GyoshukuKitTests/Probes/
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --package-path .build-base/source --scratch-path .build-base/build --build-system native --disable-sandbox -c release -Xswiftc -enable-testing --filter MulticoreBenchmarkTests
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" swift test --build-system native --disable-sandbox -c release -Xswiftc -enable-testing --filter MulticoreBenchmarkTests
python3 Benchmarks/multicore.py corpus
python3 Benchmarks/multicore.py measure
python3 Benchmarks/multicore.py references --results .build/multicore/references.jsonl
GYOSHUKU_MULTICORE_BENCHMARK=1 GYOSHUKU_MULTICORE_CORPUS="$PWD/.build/multicore/corpus" xcrun xctest -XCTest GyoshukuKitTests.ZipConcatenatedZstdProbeTests/testLargeMemberFrameResetSize .build/arm64-apple-macosx/release/GyoshukuKitPackageTests.xctest > .build/multicore/zstd-frame-ratio.log 2>&1
python3 Benchmarks/multicore-report.py
```

`--cases zip-bzip2,7z-ppmd-solid-filter`で部分選択、`--repeats N`で5回以上にできます。
JSONLを残せば`measure`は中断後の続きから実行します。corpusのソース本文もf273d34から読み、source編集による入力の変化を避けます。
sourceの時刻は各sampleの前に固定します。tarの圧縮codecのCLI参照は同じ連結本文（tar headerを含まない）を使うため、
containerを含むlibrary出力とbyte比較しません。ZIP Zstdのencoderは7zzにないので単独Zstd CLIの参照を使います。
`multicore-report.py`はこの検証の対象testログ（`.build/multicore/release-acceptance.log`、`release-final.log`、
`release-lha-final.log`、`debug-final.log`、`zstd-frame-ratio.log`）も参照します。frame probeのstdoutも最後の名前で保存してください。
測定結果と予約の詳細は[2026-10-07 writer multicore](../Documentation/verification/2026-10-07-writer-multicore.md)を参照してください。
