# encoder の性能・安定性検証（2026-11-05）

基点は GyoshukuKit 0.17.0。KaitoKit 依存を 0.22.x に上げ、LH5・LZW・bzip2 の CPU 経路を改善する。出力は従来の encoder と byte 一致を確認し、公開 API・方式・level の意味は変えない。GPU / NPU の研究は KaitoAccelLab に保存し、本番 Package には Metal / Core ML を追加しない。

## 測定と再現

M4 Max と Mac mini M4、macOS 27.2、Xcode 27.2 / Swift 6.4.2。release の XCTest bundle を保存し、固定入力を変更前後で交互に測定した。性能測定と全テストを同じ Mac で同時には実行していない。

測定 class と環境変数は [Tests/README](../../Tests/README.md) を参照する。すべて通常の `swift test` では skip され、`-c release` が必要。

```console
GYOSHUKU_LH5_BENCHMARK=1 swift test -c release --filter LH5EncoderBenchmarkTests
GYOSHUKU_LZW_BENCHMARK=1 swift test -c release --filter LZWStreamEncoderBenchmarkTests
GYOSHUKU_BZIP2_BENCHMARK=1 swift test -c release --filter Bzip2
```

A/B には `KaitoAccelLab/Scripts/benchmark_gyoshuku_probe.py` を使う。候補ごとの全 round、失敗した候補、研究用 LZMA Metal は KaitoAccelLab の `Documentation/speed-report.md` §9 と `Results/` に記録する。

## LH5

`heads` / `previous` を `write` 全体で有効な raw pointer にし、長さ 8 以上の一致が 2 回見つかった後だけ、未整列 UInt64 の XOR と trailing-zero count で一致を延長する。短い一致や random では scalar を使い、hash・chain・lazy matching・候補の採用順は変えない。

pointer 化だけの Mac mini の測定（4 MiB、MB/s）:

| corpus | level 1 | level 6 | level 9 |
|---|---:|---:|---:|
| text | 132.942 → 150.081 | 79.996 → 93.016 | 44.512 → 50.983 |
| binary | 113.785 → 119.763 | 90.459 → 99.369 | 36.289 → 43.236 |
| random | 83.634 → 84.617 | 83.749 → 85.732 | 84.776 → 85.296 |

適応型の 8 byte 比較は、text / binary をさらに 5〜15% 改善した。無条件の 8 byte 比較は random を後退させたため採用しない。3 corpus・3 level、45＋81＋9 組の出力一致、独立 decoder 3 種類、最大距離・block 跨ぎ、ASan、LHA method / splice / parallel writer の関連 23 tests を確認した。

## LZW

線形探索 dictionary は `code << 48 | key` とし、probe を下位 32 bit の直接比較にする。hash・probe・code 割当の順は同じで、独立した参照 encoder と出力が一致する。Mac mini の 3 corpus・maxbits 12 / 16 は約 0.4〜4.5% 改善した。M4 Max は ±1% 前後の混在で、全条件での改善を主張しない。無条件の強制 inline は約 6.9% 後退したため採用しない。

差分・実 `compress` 互換を含む 10 tests（1 skip）と ASan を確認した。

## bzip2

`Bzip2BlockScanner` は、各 scan の先頭最大 64 byte に 16 byte 以上の run があるときだけ専用ループを選ぶ。通常入力は元の scalar 経路を使う。専用ループは未整列 UInt64 の比較と trailing-zero count で run を進めるが、255 byte 制限・block 境界・pending run・途中で返す位置は変えない。

4 MiB の圧縮全体（ms）:

| input / level | Mac mini 変更前 → 最終 | M4 Max 変更前 → 最終 |
|---|---:|---:|
| repeated / 1 | 25.288 → 24.272 | 25.572 → 24.807 |
| repeated / 9 | 25.344 → 24.089 | 25.492 → 24.784 |
| runs127 / 1 | 30.987 → 29.796 | 31.416 → 30.541 |
| runs127 / 9 | 33.466 → 32.008 | 33.812 → 32.884 |

text は両機で誤差範囲。無条件の 8 byte 比較は run 長 8 / 9 を後退させたため採用しない。出力は逐次 `Bzip2StreamEncoder`（system libbz2）と全 byte 一致し、大規模境界を含む 15 tests と M4 Max の ASan 15 tests が成功した。

## 全テスト

最終 production source の `/tmp/gyoshuku-bzip-verified-mini-20261105` で、Mac mini の `swift test -j 4` を実行した。

- GyoshukuKit: **948 tests、55 skipped、0 failures**（3,285.640 秒）
- LH5・LZW・bzip2 の個別試験、外部 decoder / 実 `compress`、大規模境界、ASan も成功

生の全出力は KaitoAccelLab の次の log に保存する。

- `Results/gyoshuku-bzip-final-full-mini-20261105.txt`
- `Results/gyoshuku-bzip-asan-max-20261105.txt`
- `Results/gyoshuku-lh5-pointer-full-mini-20261104.txt`
- `Results/gyoshuku-lzw-key32-full-mini-20261105.txt`
