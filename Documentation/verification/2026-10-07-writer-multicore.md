# writerのmulti-core実測（2026-10-07）

基準はf273d346fc8e0743d56604e8c59adb61cedc1828。コーデック内部と凍結fixtureは変更していない。
ZIP 12/14/95/93/98の中項目、7z LZMA/BZip2/PPMdの中folder、solid/filterのfolderを有界窓で並列化した。
LHA LH5/6/7も1 MiB超〜16 MiBのmemberを項目間で並列化し、既存の1 MiB符号化境界を保つ。

## 条件

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

## コードの経路表

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

## wall/CPU（秒）と出力

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

## throughput / speedup

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

## 変更ファイル

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

## 機能試験

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

## メモリ・進捗・残る制約

予約とmaximumPendingInputBytesは[design.md](../design.md)のwriter並列化節を参照。一項目入力は16 MiB、圧縮出力はdisk spool。
solid/filterの入力spoolもpendingへ計上し、内部pipelineを1 threadにして入れ子の予約を抑える。大folderの従来経路では内部block並列を保つ。
spoolによる追加disk I/Oと空き容量が必要。file cacheとallocator管理領域はcodecの予約に含まない。codecモデル/辞書を縮小しない。
進捗と暗号化乱数の順序は呼出側に置き、取消しをworkerのread/writeへ伝え、abortでworker/spoolを解放する。
計測は上記corpus/既定level/solid16 MiB/Delta4のみ。全level、他corpus、26.03そのもの、BCJ/ARM64別の速度は未測定。
PPMd/Zstd/LZMAのSources配下は無変更。public API追加なし。コミットせずworktreeに残した。

## 生データと再実行

[全sample JSONL](2026-10-07-writer-multicore.samples.jsonl)、[参照JSONL](2026-10-07-writer-multicore.references.jsonl)、[集計TSV](2026-10-07-writer-multicore.tsv)、[test名・構成・結果](2026-10-07-writer-multicore.tests.jsonl)。
`Benchmarks/multicore.py measure` / `references`と`Benchmarks/multicore-report.py`で再実行・集計できる。
