# CPU scaling の MacBook 交互比較（2026-10-09）

`speed2/integrate` の新版を `origin/main` 0de2cd6 と比べた。
MacBook・Apple M4 Max（16 logical CPU、perflevel0が12・perflevel1が4）、128 GiB、macOS 27.2。
新版binaryは `dcff0a0` からビルドした。後続の `0e92b43` はlzipの予算境界テストのみで、製品ソースの差分はない。

## 方法

- harnessは `Benchmarks` の `gyoshuku-multicore`。アプリが使う `ArchiveWriter.add(_:events:)` のbatch経路で計測した。
  codecのlevelは既定、圧縮済み拡張子のheuristicは無効。corpusのsolidは明示16 MiB、filter条件はDelta distance 4。
  singleのsolidは `.on()` の既定上限を使う。`prefersSpeed` はfalse。
- corpusは256 MiB（96 × 2 MiBと64 MiBの通常ファイル一つ）。Swift source text 50%・反復binary 25%・固定seed乱数25%。
  singleは10 MiBの通常ファイル一つ。ファイル名順ではcorpusの64 MiBファイルが最後に来る。
- armは `main-t8`（mainの旧自動値8 threads）、`main-t16`（mainを16 threadsへ増やす）、
  `new-t16`（新版の通常の自動値、全16 logical CPU）。harnessでは各armのthread数を明示する。
  新版の自動値は電力方針・物理メモリGiB・codec予約でも制限されるため、どの環境でも16になる意味ではない。
- 各条件を3回ずつ計測し、arm順を `main-t8 → main-t16 → new-t16`、
  `main-t16 → new-t16 → main-t8`、`new-t16 → main-t8 → main-t16` と回転した。表は各armの最小wall時間（best-of-3）。
- 列挙と入力時刻の固定は計時外。wallはwriter作成・読取・圧縮・書込・finishを含み、
  CPUは同じ区間のprocess user＋system時間。出力のSHA-256計算は計時外。
- rawは [2026-10-09-cpu-scaling-macbook-ab.jsonl](2026-10-09-cpu-scaling-macbook-ab.jsonl)。
  提供された `maxab-final.jsonl` をbyte単位でそのままコピーした。
  全180 sampleをworkload / path別に集計し、20条件それぞれで全3 arm × 3回のSHA-256が一種類だけであることを確認した。
  出力サイズも全9 sampleで一致する。各armのsample数・thread数・入力長・回転順も照合した。

## 結果（秒、best-of-3）

speedupは `main-t8の最小wall / new-t16の最小wall`。
CPU/wallは **new-t16の最小wallを記録した同じsample** の `cpu_s / wall_s` で、平均稼働core数の目安。
比率は丸める前の値から計算した。

| workload | path | main-t8 | main-t16 | new-t16 | speedup vs main-t8 | new-t16 CPU/wall |
|---|---|---:|---:|---:|---:|---:|
| corpus | zip-deflate | 1.6904 | 1.6071 | 0.2941 | 5.75× | 11.55 |
| corpus | zip-bzip2 | 2.9638 | 1.9081 | 1.7720 | 1.67× | 13.89 |
| corpus | zip-lzma | 7.4174 | 6.5344 | 5.1409 | 1.44× | 5.41 |
| corpus | zip-xz | 4.2568 | 3.2301 | 3.1975 | 1.33× | 9.80 |
| corpus | zip-zstd | 0.1184 | 0.0991 | 0.0608 | 1.95× | 11.65 |
| corpus | zip-ppmd | 5.6997 | 5.0490 | 4.2891 | 1.33× | 4.73 |
| corpus | 7z-lzma2-solid | 4.7465 | 3.3292 | 2.1344 | 2.22× | 14.73 |
| corpus | 7z-lzma-solid | 8.1247 | 6.8045 | 5.1815 | 1.57× | 5.15 |
| corpus | 7z-ppmd-solid | 6.0736 | 5.0987 | 4.1672 | 1.46× | 4.64 |
| corpus | 7z-bzip2 | 2.9780 | 1.9095 | 1.7126 | 1.74× | 14.22 |
| corpus | 7z-copy-filter | 1.0549 | 0.9299 | 0.1396 | 7.56× | 1.31 |
| corpus | tar.gz | 0.7004 | 0.3648 | 0.3643 | 1.92× | 9.22 |
| corpus | tar.bz2 | 2.8686 | 1.7350 | 1.7532 | 1.64× | 14.31 |
| corpus | tar.xz | 4.2396 | 3.1567 | 3.1740 | 1.34× | 9.92 |
| corpus | tar.zst | 0.0808 | 0.0574 | 0.0570 | 1.42× | 11.53 |
| corpus | lha-lh7 | 0.9934 | 0.6411 | 0.5553 | 1.79× | 12.67 |
| single | zip-bzip2 | 0.2202 | 0.1284 | 0.1290 | 1.71× | 7.49 |
| single | zip-xz | 0.8130 | 0.8094 | 0.8106 | 1.00× | 1.00 |
| single | 7z-lzma2-solid | 0.8080 | 0.8068 | 0.8142 | 0.99× | 1.00 |
| single | zip-deflate | 0.0350 | 0.0197 | 0.0198 | 1.77× | 6.58 |

全sampleの1分loadは2.95〜14.23。`main-t16` はthread数だけを増やした効果、`new-t16` との差は実装変更の効果を見る比較になる。

## 判断と限界

- 256 MiB corpusの旧既定8 threads比はZIP Deflate 5.75倍、7z Copy＋Delta 7.56倍、
  7z LZMA2 solid 2.22倍、ZIP Zstandard 1.95倍。新版のCPU/wallはZIP Deflate 11.55、7z LZMA2 solid 14.73。
  一括追加の大項目をdrainせず重ねる変更と、全logical CPUの利用が効く。
- mainを16 threadsへ増やすだけでも改善する方式がある。tar.bz2 / tar.xzとsingleのZIP BZip2は
  `main-t16` と新版がほぼ同等で、最短値では新版がわずかに遅い。全方式で実装変更自体が速くなるとはいえない。
- single 10 MiBのZIP XZ / 7z LZMA2 solidは、既定16 MiB片に収まりCPU/wallが約1のまま。
  このrawでは約0.81秒。別の **Codex batch-lpt計測** では `prefersSpeed: true` により両条件が約0.79→0.22秒になった。
  この0.22秒は上表のJSONLから集計した値ではなく、圧縮片を増やして圧縮率と引き換える別モードの記録。
- 既定モードでは64 MiBのLZMA1 / PPMdを独立streamに分割しないため、一つの長いstreamがcorpusのwall時間の下限になる。
  LZMA1は予算内でfinderを追加一coreへ分離できるが、stream全体を16 coreに配る経路ではない。
- 絶対時間・CPU/wallと倍率は機種、入力、I/O、同時負荷に依存する。best-of-3は最短値で、分散や全環境の性能保証を示さない。
- この20条件には単独 `.bz2` とBZip2の長いrunによる強制切断・末尾block境界の例外を含めていない。
  ここでの全hash一致は0.8.0との全入力でのbyte一致を意味しない。
  既定モードのbyte変更は[0.9.0の互換性](../../CHANGELOG.md#互換性)に記録する。
