# PPMd の encoder 比較

repository root で `python3 Benchmarks/PPMd/run.py` を実行する。Mac、Swift 6、Python 3、
PATH 上の `7zz` が必要。公開ドメイン C のビルドは行わず、`f273d34` と作業 tree の
PPMd Swift source をそれぞれ同じ `swiftc -O -wmo -swift-version 6` でコンパイルする。
XCTest、`@testable`、`-enable-testing` は使用しない。標準の出力先は無視対象の build directory。
`--directory` で変更でき、`--baseline` で比較 commit を指定できる。

```sh
python3 Benchmarks/PPMd/run.py --mode build
python3 Benchmarks/PPMd/run.py --mode bench --runs 7
python3 Benchmarks/PPMd/run.py --mode identity
python3 Benchmarks/PPMd/run.py --mode profile
```

build、bench、identity はこの順に実行する。bench 中は別の build / test を開始しない。
bench は固定 seed の英文風 text 8 MiB と、この Mac の `/usr/lib/dyld` を level 1 / 6 / 9 で
測る。旧→新→7zz の順に各反復で実行し、7 回の最良値を使う（`--runs` は5以上）。
入力読込みは計時外、model allocation、payload 生成、finish は計時内。
7zz は `-mmt=1` で起動・file I/O・書庫作成も計時内。全試行、load average、compiler / 7zz の版、
実際の参照 heap、source / build command を JSON に保存する。参照書庫は各反復の前に削除し、
最後の書庫を loop 後に一度だけ `7zz t` と全 byte 復号で確認する。
7zz が入力サイズに応じて heap を縮小した場合も記録する。

identity は dyld、`/bin/zsh`、8 MiB の混合 corpus、空、1 byte、64 KiB zeros を対象に、
H の order 2 / 4 / 8 / 16 / 32 と I の order 2 / 4 / 8 / 16、heap 1 / 3 / 64 MiB、
I の restart / cut-off を全組合せで比較する。I は製品の契約どおり order 32 を扱わない。
混合 corpus は 256 KiB の英文、dyld、zsh、固定 seed random を交互に置く。
さらに text / dyld の両 variant・全 level 1...9（I は両 restoration）と、chunk 1 / 7 / 65,536 byte の streaming、
dyld を chunk 7 / 65,536 byte に分けた両 restoration の streaming を比較する。
全 byte を比較し、結果と SHA-256 を JSON に保存する。失敗時は非ゼロで終了して比較 payload を残す。
独立 decoder、writer の並列数、復元回数、失敗後の状態は従来の対象 XCTest で確認する。

profile は作業 tree のコピーに 1024 回ごとの `mach_absolute_time` を挿入する診断用 build。
phase 0 は記号処理全体、1 は model update、2 は successor 作成、3 は rescale、4 は suffix escape。
20 回分の呼出数・sample 数・tick 合計を保存する。update は successor を含み、suffix は選択後の
update を含むため、phase の時間を足し合わせない。計測処理の overhead があり、bench の速度と区別する。
