# BZip2 splice の Mac mini 交互比較（2026-10-08）

`speed/bzip2-splice` da08ba6（ZIP / 7z BZip2 の単一stream並列圧縮、filter付きsolidの予約分配、splice高速化）を
base 9d46fe2 と比べた。Mac mini M4（10 core、16 GB）、macOS 27.2、Xcode 27.0、他の作業なし。

## 方法

- harness は同じ `Benchmarks/Sources/GyoshukuMulticore` と `Benchmarks/Package.swift`。base は `git archive 9d46fe2` に同じ
  harness を置いた。両版とも `swift build -c release --disable-sandbox -debug-info-format none`。
- 三本を交互に best-of-5 で計測した。base、base の executable の複製（表の base2。測定の揺れの床）、新版。順序は
  `multicore.py measure --profile round3` と同じく回転・反転する。raw と harness report の `round1` は base2 を指す。
- armごとの同一性を検査する `multicore.py` の作業用複製を使った（repository の script は変更しない）。今回の全26入力 / 方式で
  base / base2 / 新版と t=1 / 12 の SHA-256・出力サイズが一致した（690 sample）。splice出力は逐次libbz2経路とbyte一致した。
- run1 は tree / single（10 MiB）/ single16r（16 MiB 乱数）/ small を t=1・12。
  方式は ZIP BZip2、7z BZip2、7z BZip2 filter、7z BZip2 solid、7z BZip2 solid-filter。
  filterはDelta distance 4。singleのsolidは既定blockSize、他のsolidは16 MiB。
- run2 は 256 MiB corpus を t=12で同じ5方式と tar.bz2（変更していない経路の対照）で測った。
- raw は [run1](2026-10-08-bzip2-splice-mini-ab.run1.jsonl)（600 sample）と
  [run2](2026-10-08-bzip2-splice-mini-ab.run2.jsonl)（90 sample）。表の秒数はharness report、比は各armの最短値から求めた。
  load は各最短 sample の 1 分値。

## 結果（秒、best-of-5、base / base2 / 新版）

| workload / 方式 | 出力サイズ 新/base | t=1 | t=12 | 新/base（t=1; t=12） |
|---|---:|---:|---:|---|
| tree / ZIP BZip2 | 1 | 3.5508 / 3.5489 / 3.5537 | 0.6241 / 0.6306 / 0.6298 | 1.001; 1.009 |
| tree / 7z BZip2 | 1 | 3.5553 / 3.5512 / 3.5545 | 0.6259 / 0.6244 / 0.6304 | 1.000; 1.007 |
| tree / 7z BZip2 filter | 1 | 5.1267 / 5.1009 / 5.1212 | 0.7759 / 0.7750 / 0.7805 | 0.999; 1.006 |
| tree / 7z BZip2 solid | 1 | 3.7934 / 3.7905 / 3.7902 | 0.7932 / 0.7929 / 0.6919 | 0.999; 0.872 |
| tree / 7z BZip2 solid-filter | 1 | 4.9620 / 4.9695 / 4.9670 | 1.0339 / 1.0315 / 0.9806 | 1.001; 0.948 |
| single / ZIP BZip2 | 1 | 0.9071 / 0.9079 / 0.9076 | 0.9078 / 0.9206 / 0.1814 | 1.001; 0.200 |
| single / 7z BZip2 | 1 | 0.9044 / 0.9085 / 0.9078 | 0.9075 / 0.9078 / 0.1779 | 1.004; 0.196 |
| single / 7z BZip2 filter | 1 | 0.9311 / 0.9312 / 0.9283 | 0.9337 / 0.9351 / 0.2762 | 0.997; 0.296 |
| single / 7z BZip2 solid | 1 | 0.9056 / 0.9012 / 0.9051 | 0.9046 / 0.9052 / 0.1797 | 0.999; 0.199 |
| single / 7z BZip2 solid-filter | 1 | 0.9281 / 0.9322 / 0.9312 | 0.9309 / 0.9320 / 0.2696 | 1.003; 0.290 |
| single16r / ZIP BZip2 | 1 | 1.0461 / 1.0634 / 1.0451 | 1.0489 / 1.0626 / 0.2231 | 0.999; 0.213 |
| single16r / 7z BZip2 | 1 | 1.0446 / 1.0439 / 1.0444 | 1.0519 / 1.0477 / 0.2216 | 1.000; 0.211 |
| single16r / 7z BZip2 filter | 1 | 1.2288 / 1.2301 / 1.2306 | 1.2349 / 1.2364 / 0.3016 | 1.001; 0.244 |
| single16r / 7z BZip2 solid | 1 | 1.0525 / 1.0501 / 1.0491 | 1.0561 / 1.0548 / 0.2141 | 0.997; 0.203 |
| single16r / 7z BZip2 solid-filter | 1 | 1.2312 / 1.2321 / 1.2295 | 1.2370 / 1.2354 / 0.2986 | 0.999; 0.241 |
| small / ZIP BZip2 | 1 | 1.5154 / 1.5167 / 1.5244 | 0.2804 / 0.2808 / 0.2835 | 1.006; 1.011 |
| small / 7z BZip2 | 1 | 1.5029 / 1.5023 / 1.5124 | 0.2833 / 0.2825 / 0.2823 | 1.006; 0.996 |
| small / 7z BZip2 filter | 1 | 2.1280 / 2.1738 / 2.1809 | 0.4936 / 0.4932 / 0.5044 | 1.025; 1.022 |
| small / 7z BZip2 solid | 1 | 0.8829 / 0.8808 / 0.8835 | 0.8810 / 0.8807 / 0.2658 | 1.001; 0.302 |
| small / 7z BZip2 solid-filter | 1 | 0.7385 / 0.7325 / 0.7386 | 0.7381 / 0.7375 / 0.3041 | 1.000; 0.412 |
| corpus / ZIP BZip2 | 1 | — | 8.1707 / 8.1822 / 3.5081 | —; 0.429 |
| corpus / 7z BZip2 | 1 | — | 8.1931 / 8.1748 / 3.5075 | —; 0.428 |
| corpus / 7z BZip2 filter | 1 | — | 8.0465 / 8.0382 / 4.4433 | —; 0.552 |
| corpus / 7z BZip2 solid | 1 | — | 9.4957 / 9.4390 / 4.4843 | —; 0.472 |
| corpus / 7z BZip2 solid-filter | 1 | — | 9.4943 / 9.4864 / 4.1094 | —; 0.433 |
| corpus / tar.bz2 | 1 | — | 3.4178 / 3.3981 / 3.3901 | —; 0.992 |

1 分 load は 2.16〜7.81。base2 / base は 0.992〜1.022 だった。

## 試験

同じda08ba6をMac miniで検査した。debug full suiteは804件、44件skip、失敗0（41.9分）。
releaseは `GYOSHUKU_LARGE_ENCODER_TESTS=1` のFullSize 16件、失敗0。

## 判断

- t=12の単一10 MiBはZIP BZip2 5.01倍、7z BZip2 5.10倍、7z BZip2 solid 5.03倍。
  filter付きは7z BZip2 3.38倍、solid-filter 3.45倍。
- 単一16 MiB乱数はZIP BZip2 4.70倍、7z BZip2 4.75倍、solid 4.93倍。
  filter付きは7z BZip2 4.09倍、solid-filter 4.14倍。
- 256 MiB corpusはZIP BZip2 2.33倍、7z BZip2 2.34倍、solid 2.12倍、solid-filter 2.31倍。
  非solidのfilter付きは1.81倍。smallのsolidは3.31倍、solid-filterは2.43倍。
- treeのsolidは0.7932→0.6919秒（12.77%短縮）、solid-filterは1.0339→0.9806秒（5.15%短縮）。
  先の151fbc1ではsolid-filterが1.03→1.48秒（約44%増）だったが、da08ba6のfolder予約分配でこの退行を解消した。
- t=1は下記のsmall / filterを除いて±2%以内。既に項目並列だったtreeの非solidとsmallのZIP / 7zも同程度で、
  対照のtar.bz2は新/base 0.992（0.81%短縮）と揺れの床（約±2%）内に留まった。
- +2%を超えたのはsmall / 7z BZip2 filterの2セル。t=1は新/base 1.02484（+2.48%、52.87 ms）、
  base2/baseも1.02154（+2.15%）、新/base2は1.00323なので、測定の揺れが混じっている可能性が高い。
  t=12は新/base 1.02186（+2.19%、10.79 ms）に対しbase2/base 0.99914、新/base2 1.02274。
  t=12の超過はbase2には出ておらず、揺れだけとは断定しない。この測定では約±2%の床を僅かに超える値が残る。
- 全26入力 / 方式で出力byteの同一性を保ち、単一大項目とsolidの並列化を確認した。
