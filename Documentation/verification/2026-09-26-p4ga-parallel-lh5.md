# P4-G-a（S18）: byte 不変の並列 LH5

## 対象と隔離

- 開始 commit: `bfb2980bee321194b57748dec0ffa10c3d8a01b7`（P1d-G 統合済み、親は G2 の `d5c51b3`）。開始時は差分なし。
- 対象は P4.md の P4-G-a、§0.1–0.2、§0.4 と ORDER-P6-P13 §1-3。
  `options.resolvedCompressionThreads` を LHAWriter へ渡し、rewriter も同じ create 経路を使う。
- 隔離 root は `/private/tmp/gyoshuku-p3g2.WYR2p1`。以前の隔離環境を再利用し、GyoshukuKit を現在の作業ツリーに同期した。
  隣の KaitoKit は `git archive d35f2da` の展開物。今回も archive を読み直し、tracked file 1,393 件の内容が一致することを検査した。
  live sibling は build していない。KaitoKit / KaitoFinder は編集していない。commit していない。
- macOS 27.2（26B5091g）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64、Swift 6 language mode。
- ログは `$P4GA_ROOT/s18-p4ga`。新規 public / SPI / unsafe concurrency annotation なし。

## 実装と試験

- 1 MiB 以下は member 単位の `OrderedChunkPipeline`。容量を待ってから読み、CRC と EOF の検査まで add の呼出側で済ませる。
  directory は符号化なしの tag として投入順を保つ。大きい member の前と finish / endMembers で drain する。
- 大きい member は従来どおり raw を先に出力する。1 MiB と直前 8 KiB の履歴ごとの符号列を並列に作り、
  完全な byte と端数 bit を padding なしで継いで spool に保存する。縮まないと分かった区切りで pipeline を abandon する。
  emit の最中に tag 列を消さないよう、内部の停止 error を pipeline に通し、呼出側だけで stored への切替として捕捉する。
- threads 1 は同期のまま。`LHARecords`、`LH5Encoder.encode/write`、`OrderedChunkPipeline`、既存の LHA 試験は不変。
- `endLHAMembers()` は終端・同期・close なしで offset を返す。`recordsMembers` が true のときだけ、
  実際に出力した header/data の長さ、絶対 offset、method、canonicalRawName 相当の byte を記録する。
- 新規 `LHAWriterParallelTests` 6 件: 300 member（0 B・1 B・1 KiB・1 MiB−1・1 MiB・directory・乱数）、
  threads 1/2/4/8/16 と直接 encode/header を組み立てる直列参照の byte 比較、KaitoKit の全 file 読取、
  同期 offset、後続 add / 大きい member 前 / finish / endMembers での注入失敗、worker の CancellationError、
  pending 状態の取消しと hardlink の無効化、入力前の容量待ち、add 後の入力削除、CP932 trail byte を含む memberRecords を検査。
- 新規 `LHAStreamSpliceTests` 2 件: threads 1/4/8/16、text / 乱数の 1 MiB+1・2 MiB・8 MiB+8191、
  前半 text / 後半乱数、小さな text prefix と乱数の stored fallback を、S15 の直列 addStreamed を写した参照と比較。
  参照は出力と spool の I/O を Data に置き換え、一本の Bits を維持する。最終片を読む前の打切りを assert する。
  継ぐ前と後の端数 0〜7 bit、完全 byte 数 0 / 1 / 257、3 片の連続した継ぎも一本の Bits と一致する。

## 実行コマンド

```sh
P4GA_ROOT=/private/tmp/gyoshuku-p3g2.WYR2p1
P4GA_REPO=/Users/nagash/Github/GyoshukuKit
P4GA_PACKAGE=$P4GA_ROOT/GyoshukuKit
export CLANG_MODULE_CACHE_PATH=$P4GA_ROOT/cache
P4GA_COMMON=(--build-system native --disable-sandbox --cache-path "$P4GA_ROOT/cache")

# KaitoKit の既存 export を git archive d35f2da と全 tracked file 比較（Python tarfile、1,393 件一致）。
# GyoshukuKit の同期（build cache はそのまま）。
rsync -a --delete --exclude .git --exclude .build --exclude .agents --exclude .codex \
  "$P4GA_REPO/" "$P4GA_PACKAGE/"

swift build --package-path "$P4GA_PACKAGE" "${P4GA_COMMON[@]}"
swift test --package-path "$P4GA_PACKAGE" "${P4GA_COMMON[@]}" \
  --filter 'LHAWriterParallelTests|LHAStreamSpliceTests'
swift test --package-path "$P4GA_PACKAGE" "${P4GA_COMMON[@]}"
swift build -c release --package-path "$P4GA_PACKAGE/Benchmarks" "${P4GA_COMMON[@]}"
GYOSHUKU_TAR_GIT_REPO="$P4GA_REPO" \
  swift test --package-path "$P4GA_PACKAGE" "${P4GA_COMMON[@]}" \
  --filter 'LHAWriterParallelTests|LHAStreamSpliceTests|LHA|ArchiveRewriterTests|ArchiveWriterTests|TarUpdaterInteropTests'

git diff --check
git diff -U0 -- Sources | rg -n '^\+.*\bpublic\b|^\+.*@_spi|^\+.*@unchecked Sendable|^\+.*nonisolated\(unsafe\)'
```

`--disable-sandbox` は SwiftPM の入れ子の sandbox を避ける設定。実行環境の権限を引き上げていない。
ソース監査は上記 grep が該当なし（exit 1）。既存 LHA 試験 6 file と LHARecords / OrderedChunkPipeline / LHACRC16 を
HEAD と byte 比較し、LH5Encoder の encode/write を d5c51b3 と関数単位で比較した。詳細は `source-audit.txt`。

| ログ | 実行 | 結果 |
|---|---|---|
| build-initial.log | debug build | 成功、1.55 s |
| test-new-initial.log | 新規 2 suite の初回 | 試験の `ArchiveEntry.path` を存在する `name` に直す前の compile error。試験未実行 |
| test-new.log | 新規 2 suite | 8 件、0 failure、51.303 s |
| test-full.log | 全件 debug | **447 件、18 skip、0 failure、730.794 s** |
| build-bench.log | release benchmark build | 成功、79.98 s |
| test-regression.log | LHA / ArchiveRewriterTests / ArchiveWriterTests / TarUpdaterInteropTests | **76 件、skip なし、0 failure、68.003 s** |

全件の skip は、hdiutil が image を作れない 5 件（FAT32 / exFAT / HFS+）、opt-in の大容量 6 件、
fixture / scale / 比較出力の未指定 7 件。既存の assert と skip 条件は変えていない。
このうち Git archive の fixture は後続の filter 実行で有効にし、成功した。
既存 LHA の Lhasa / 7zz / KaitoKit の読み取りを含む試験はすべて成功した。

## AC-Ga4

正式な release 計測（負荷平均 <4、2 回の中央値）は指示どおりオーケストレータが行う。
比較元は scratchpad の `p4bench/base/p4base-{small,headers,text256.txt,random256.bin}.lzh`（d5c51b3）。
閾値は変更していない。

全件試験が終わってから、release の `gyoshuku-bench` を **4 corpus × threads 1/2/4/8/16 = 20 回**実行し、
それぞれ `/usr/bin/cmp` で比較した。**20 組すべて一致、サイズ差 0 B**。
全行の時間・RSS・サイズ・負荷を [TSV](2026-09-26-p4ga-parallel-lh5.tsv) に保存した。
計測中にこちらの別の build / test は動かしていない。負荷平均（1 分）は 5.45〜8.23 で、各組 1 回の参考値。
初回 threads 1 と後続の cache 条件もそろえていないため、改善率の受入判定には使わない。

| corpus / threads 8 | writer 内 elapsed s | process wall s | peak RSS MiB | output B | サイズ差 B |
|---|---:|---:|---:|---:|---:|
| small | 2.677 | 2.686 | 31.06 | 63,200,923 | 0 |
| headers | 0.952 | 0.958 | 35.30 | 23,810,406 | 0 |
| text256.txt | 1.005 | 1.013 | 50.59 | 139,767,721 | 0 |
| random256.bin | 1.377 | 1.386 | 52.84 | 268,435,516 | 0 |

**headers は参考値でも 0.35 s の閾値を超えた。AC-Ga4 の時間条件を満たしたとは扱わない。**
sample 用の追加実行は elapsed 0.956 s、負荷 5.92、cmp 一致。`/usr/bin/sample` はプロセスを調べられず exit 255。
profile を取得できなかったので、host での計測・sample が必要。text256 は参考値で 1.6 s 未満のため LHACRC16 は変更しなかった。
全 20 行の最大 RSS は 72.88 MiB（random256 / threads 16）。

実際に起動した harness と引数は次のとおり。完全な 20 組の argv・exit は `benchmark-commands.jsonl` にある。

```sh
python3 "$P4GA_ROOT/s18-p4ga/compare-bench.py"
# Python が各 corpus / threads について順に起動した argv:
# $P4GA_PACKAGE/Benchmarks/.build/release/gyoshuku-bench lha \
#   $P4GA_ROOT/s18-p4ga/bytes-$corpus-$threads.lzh $SP/corpus/$corpus --threads $threads
# /usr/bin/cmp $SP/p4bench/base/p4base-$corpus.lzh $P4GA_ROOT/s18-p4ga/bytes-$corpus-$threads.lzh
# SP=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad
```

最初の `/usr/bin/time -l ... gyoshuku-bench lha ... small --threads 1` は、benchmark 自体は
elapsed 9.935 s・出力 63,200,923 B で終了したが、time が `sysctl kern.clockrate: Operation not permitted` で exit 1。
この初回 attempt を `time-l-unavailable/` に残し、上記 20 回は benchmark を直接起動した。
wall は Python の monotonic clock、RSS は各 child の `os.wait4` の rusage（Darwin は byte）を使った。
この失敗した time wrapper の値は TSV に入れていない。

追加 profile のコマンド（`profile-commands.json` に argv・負荷・exit を保存）:

```sh
# benchmark PID 2539 を起動直後に sample。benchmark exit 0、cmp exit 0。
/usr/bin/sample 2539 1 1 -file "$P4GA_ROOT/s18-p4ga/profile-headers-8.sample"
```

取得失敗のログ（`profile-headers-8.sample.log`）:

```text
sample[2540]: sample cannot examine process 2539 (gyoshuku-bench) for unknown reasons, even though it appears to exist; try running with `sudo`.
```

sudo や権限変更は行っていない。

## オーケストレータの検証（2026-09-26）

隔離した `$SCR/v4`（KaitoKit ef06e22 は `git archive`、この作業ツリーは rsync）。

| 実行 | 結果 |
|---|---|
| `swift test`（全件） | 447 件、失敗 0、skip 13（任意実行） |
| 公開 API | `git diff -U0 -- Sources` に `public` / `@_spi` の追加なし |

AC-Ga4（release の `gyoshuku-bench lha --threads 8` の時間と常駐メモリ、threads 1/2/4/8/16 の出力の byte 一致）は、負荷の平均が 4 未満のときに採り、この節の後に追記する。

### AC-Ga4 の計測（オーケストレータ、2026-09-26 08:15–08:19）

`gyoshuku-bench lha`（release）。新しい側は 5faab4b（KaitoKit ef06e22）を `git archive` して build、基準は d5c51b3 の直列（threads 1）。
corpus は `Benchmarks/make-corpora.sh` の出力（`SP/bcorp`。仕様の「今」の値と同じ corpus）。負荷の平均（1 分）は 4.3〜4.9。

| corpus | 基準（直列）s（3 回） | 8 threads s（3 回） | 条件 | 最大常駐メモリ（8 threads） |
|---|---|---|---|---|
| small | 9.21、5.93、6.05 | 2.64、2.66、2.52 | ≦ 3.0 | ≦ 66 MB |
| headers | 0.94、0.71、0.68 | 0.34、0.32、0.29 | ≦ 0.35 | ≦ 32 MB |
| text256 | 4.68、4.64、4.67 | 1.01、1.01、1.00 | ≦ 1.6 | ≦ 53 MB |

各回の出力は基準の直列の出力と `cmp` で一致した。加えて、別の大きな corpus（`SP/corpus`: small・headers・text256・random256）で、
threads 1 / 2 / 4 / 8 / 16 の全 20 通りの出力が d5c51b3 の直列の出力と byte 一致した（その corpus の headers は 9,485 件・63 MB で、
8 threads で 0.98 s。仕様の閾値の corpus ではないので判定には使わない）。最大常駐メモリは全て 120 MiB 以下。AC-Ga4 は合格。
