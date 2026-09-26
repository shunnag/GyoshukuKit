# P4-G-b / S20 LHAUpdater 検証（2026-09-26）

## 基準・隔離・着手の門

- GyoshukuKit: `5faab4b9499fa75a6a51d23f976113692e1420d0` に対する作業差分。commit していない。
  作業中に外部の commit `a03833e`（S18 の受入計測の文書だけ）が加わった。
  その変更を保ち、Source / Tests / Package.swift が実際に試験した隔離 copy と同じことを再確認した。
- KaitoKit: **`ef06e226b409a92d41a9ca12e99d011a4dbceb71` の git archive**。
  P4-K `d171f27` の SPI と P5-K を含む。live sibling の source/build artifact は使わない。
- 隔離 root: `/private/tmp/gyoshuku-p4gb.3uv7t7y0`。その中の `GyoshukuKit` と `KaitoKit` を隣接させた。
  `rsync -a --delete --exclude .git --exclude .build --exclude .agents --exclude .codex` で GK を同期した。
  KaitoKit / KaitoFinder は編集していない。Package.swift と Benchmarks は変更していない。
- macOS 27.2 (26B5091g), arm64, Apple Swift 6.4 (swiftlang-6.4.0.34.1)。
- ORDER-P4-P5 §4 S20 の門を committed source で確認した:
  `SplicedArchiveOutput` / `SplicedSegment` / `SplicedSink` / `SplicedCommitPlan` / `SplicedScratchFile` /
  `CommitProgressMeter`、generated・finalPatch・makeScratch・units、internal の共有表現可能性検査、
  `EditPathReservations`、日付/所有者付き directory add、S19 の正確な SPI 名が存在する。
  `ZipUpdateSource(duplicating:)` も FAT/exFAT 修正ですでにあり、そのまま使う。
- `git diff --stat -- Sources/GyoshukuKit/SplicedArchiveOutput.swift` は空。
  TarUpdater は error 宣言の移動だけ。既存 Tar / compressed tar / 出力部品の試験は変更していない。
- export 後の KaitoKit 1,511 regular files を再度 git archive と byte 比較し、全件一致。
  archive SHA-256: `64f40cbe1271716ac6bfc0d2899d0056d885d54f7a0a2f684e04c9798e16747a`。
  `SplicedArchiveOutput` / `ZipUpdateSource` / `ArchiveWriter` / LHA writer・encoder・records / manifest と
  既存 tar 系の試験、計 22 files も `git show HEAD:path` との byte 一致を確認した。

## 実装と試験の範囲

独立した level 0/1/2 walk、SPI/公開 entry の一致、R0/R7/R8/R10/L1–L9、raw member の splice、
改名時の level 2 header、追加 writer の dup descriptor、予約と再配置、V1–V5、進捗と cleanup を実装した。
L6 は通常の open から到達しない安全網。既存の表現可能性検査と original identity は弱めていない。
`UpdaterRouteError` の二つの case と `TarUpdaterError` typealias を追加し、両方の catch を試験する。

固定 fixture は KaitoKit ef06e22 の P4-K fixture をコピーし、manifest の byte 数と SHA-256 を試験で確認する。
level 0/1/2/3 の独立 builder、大きい header、level 1 header CRC、実 lh4/lh6/lh7、MacLHA nm、
CP932/宣言付き名前、DOS/Unix/Windows 時刻、root、tail、4 GiB 超の packed-size 拒否も使う。
操作・byte・進捗・clone I/O・300 組 differential・worker fault・V1–V5 fault・取消し・再入・
foreign inode の保護・host/FAT32/exFAT/HFS+ lifecycle・外部 decoder・release scale・疎ファイルの試験を加えた。

仕様中の V2 全境界という記述は、§0.1-5 と AC-Gb4 の「追加だけでは既存 byte を読まない」に合わせ、
既存 member に変更があるときにだけ適用する。clone/sequential とも V2/V5 読取は共通 observer へ報告する。

## 実行コマンド

以下の共通 prefix を使った（作業 tree 内で直接 SwiftPM を走らせていない）。

```sh
ROOT=/private/tmp/gyoshuku-p4gb.3uv7t7y0
export CLANG_MODULE_CACHE_PATH="$ROOT/cache"
# 各 swift build/test に付ける共通引数:
# --package-path "$ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$ROOT/cache"
```

全件実行は `swift test`、個別実行は下表の filter / 環境変数を共通引数に加えた。
`focused-initial.log` / `focused-second.log` / `focused-third.log` の正確な filter は
`--filter 'LHAUpdater|LHALayout|LHAEditPlan|LHAHeaderReemit|UpdaterRouteError'`。
`refined-focused.log` / `refined-focused-final.log` は
`--filter 'LHAUpdaterInterop|LHAUpdaterRefusal|LHAUpdaterVerificationFault|LHALayout'`。

## 外部 decoder と仕様上の限界

- KaitoKit は全 tested member を復号し、運んだ内容と byte を照合する。
- 7zz 26.03 と bsdtar は、全削除の正しい出力 `[0]` を LHA と認識しない。
  updater 出力が新規 ArchiveWriter の空 LHA と byte 一致し、外部 tool の結果も一致することを試験する。
  したがって AC-Gb8 の「全出力を外部 tool が成功で読む」を空 LHA にまで適用することはできない。
- 原本 tl-S5b の 0 tail は 7zz の既知の warning。変更後の非空出力には warning が無いことを検査する。
- tool が原本を展開できない組合せは `LHA-INTEROP-EXCLUDED` に列挙する。KaitoKit の比較からは除かない。
- CP932 の非宣言 member を削除すると、残った宣言付きの非 ASCII 名だけでは nameEncoding が nil となり、
  次の updater open が R10(b) になる場合がある。完成書庫の名前・内容は reader で直接検証し、R10 は緩めない。

## 開発中に実行した検査

ログは隔離 root の `logs/` に保存する。途中の失敗も隠さず記録する。

| log | command / 結果 |
|---|---|
| build-initial.log | swift build: fault closure が非 Sendable な plan を capture して失敗。scalar capture へ修正 |
| layout-initial.log | swift test --filter 'LHALayout\|LHAEditPlan\|LHAHeaderReemit\|UpdaterRouteError': 5 tests、0 failures |
| focused-initial.log | 新しい試験の compile エラー（FormatDetector 戻り値と UInt8 tuple）を修正 |
| focused-second.log | LHA focused: 21 tests、3 skips、21 failures。test の fd 検査位置・非同期 worker fault の観測・symlink method・other-format 入力名・strategy 期待・R10 出力の比較を修正 |
| focused-third.log | LHA focused: 27 tests、5 skips、20 failures。300 differential は成功（120.093 s）。失敗は上記の空 LHA と原本 tl-S5b の外部 decoder 制約 |
| refined-focused.log | 新しい大 header builder 試験の UInt8 tuple compile エラーを修正 |
| build-final.log | swift build: 成功 |
| refined-focused-final.log | swift test --filter 'LHAUpdaterInterop\|LHAUpdaterRefusal\|LHAUpdaterVerificationFault\|LHALayout': 11 tests、0 failures、33.443 s |
| scale-release.log | GYOSHUKU_LHA_SCALE_ENTRIES=100000 swift test -c release -Xswiftc -enable-testing --filter LHAUpdaterScaleProbeTests: 1 test 成功 |
| full-final.log | swift test（filter なし）: **477 tests、23 skips、0 failures**、884.890 s、exit 0 |
| large-release.log | GYOSHUKU_LHA_LARGE=1 swift test -c release -Xswiftc -enable-testing --filter LHAUpdaterLargeOffsetTests: **1 test、0 failures**、0.996 s、exit 0 |
| scale-release-low-load.log | 180 s まで負荷を監視後、同じ 100k release scale command を再実行: **1 test、0 failures**、22.416 s、exit 0 |

`ps` による process 一覧は sandbox により `Operation not permitted`。

新規 Sources を `git ls-files --others --exclude-standard Sources` から列挙し、public / SPI を検査した。
新規 5 files の公開宣言は LHAUpdater と規定の操作、CommitStrategy / lastCommitStrategy /
testingDisablesClone の Testing SPI、UpdaterRouteError と TarUpdaterError alias だけ。
`LHARawLayout` SPI import は LHALayout / LHAAppendedMemberCheck の internal import だけ。
LHAUpdater は `public import KaitoKit`。新しい unchecked Sendable / nonisolated(unsafe) は無い。
`git diff --check` も成功。

全件 run の skip 内訳（計 23）:

| 件数 | 試験 | 理由 |
|---:|---|---|
| 8 | CompressedTarLifecycleTests の FAT32/exFAT、FATVolumeTests と LHAUpdaterOutputModeTests の FAT32/exFAT/HFS+ | hdiutil create が `Device not configured`（装置が構成されていません）、exit 1。host volume は成功 |
| 1 | ArchiveWriterP2CompatibilityTests | GYOSHUKU_P2_COMPAT_OUTPUT 未指定 |
| 3 | CompressedTarLargeOffset / CompressedTarScaleProbe / CompressedTarWriter の >4 GiB | 既存の large/scale opt-in 未指定 |
| 2 | LHAUpdaterLargeOffset / LHAUpdaterScaleProbe | 通常 run は opt-in なし。別途 release で実行 |
| 1 | LiveNameCheckTests の 500k Shift-JIS | GYOSHUKU_LIVE_NAME_SCALE 未指定 |
| 4 | TarUpdaterInterop の git archive、TarUpdaterLargeMember / Oracle / ScaleProbe | 外部 fixture または既存の opt-in 未指定 |
| 3 | ZipReencryptionBoundaryTests の large payload / AES boundary / descriptor boundary | 既存の large opt-in 未指定 |
| 1 | ZipUpdaterScaleProbeTests | 既存の scale opt-in 未指定 |

全件 run でも固定 seed 300 組の LHA differential、host volume の全 lifecycle、V1–V5 fault、
SplicedArchiveOutput、TarUpdater、CompressedTarUpdater、S18 の並列 writer / bit splice が成功した。

## AC-Gb11 初回 release probe（load 4.70、参考値）

[全 TSV](2026-09-26-p4gb-scale-initial.tsv)。100,000 × 1 KiB、各 file は ASCII `A` の反復。
負荷は配列生成後、計測の直前の 1 分平均。共通引数は上記のとおり。

| 操作 | updater open ms | rewriter open ms | updater commit ms | rewriter commit ms |
|---|---:|---:|---:|---:|
| 先頭削除 | 747.854 | 657.793 | 7.342 | 1874.372 |
| 末尾削除 | 745.187 | 655.328 | 4.708 | 1843.673 |
| 同長改名 | 734.477 | 652.979 | 5.082 | 3373.098 |
| 異長改名 | 736.899 | 656.761 | 5.373 | 2262.805 |
| 追加 | 738.119 | 659.188 | 3.183 | 1915.259 |
| 置換 | 734.358 | 654.639 | 5.779 | 1990.921 |

open 比は最大 1.137（上限 1.25）。先頭削除 7.342 ms（上限 150）、末尾削除・同長改名・追加は
各 4.708 / 5.082 / 3.183 ms（上限 20）。閾値の未達は無いが load 4 未満の条件を満たしていない。
256 MiB の text（ASCII `a` の反復）の追加は encode 574.004 ms、V3 30.454 ms、commit 30.726 ms。
V3 は walk / KaitoKit open / 全復号を含む。V2/V3/V5 の個別時間は TSV に含む。

## AC-Gb11 再計測（load 条件は未達）

[再計測の全 TSV](2026-09-26-p4gb-scale-retry.tsv)。
`/private/tmp/gyoshuku-p4gb.3uv7t7y0/wait-for-scale.py` を実行し、10 s ごとに load を記録した。
fixture 作成の余裕を取るため開始目標を 3.5 未満、待機上限を 180 s とした。
待機中の 1 分 load は 3.698–4.992。安定した低負荷の窓が得られず、180 s で再計測した。
再計測では各 engine の計測前に load1 / load5 / load15 を記録するようにした。
この変更は opt-in probe の記録だけで、通常 suite の実行対象と製品コードには影響しない。

| 操作 | updater open ms | rewriter open ms | updater commit ms | rewriter commit ms | load1 |
|---|---:|---:|---:|---:|---:|
| 先頭削除 | 718.222 | 639.268 | 7.860 | 1871.530 | 4.29 |
| 末尾削除 | 728.152 | 640.770 | 4.638 | 1854.679 | 4.35 |
| 同長改名 | 737.984 | 641.601 | 4.070 | 1825.574 | 4.35 |
| 異長改名 | 724.405 | 643.197 | 5.300 | 2244.990 | 4.32 |
| 追加 | 717.285 | 651.422 | 3.618 | 1927.351 | 4.85 |
| 置換 | 766.988 | 647.241 | 7.428 | 1886.377 | 4.85 |

open 比は最大 1.185、commit は 3.618–7.860 ms。time の上限はすべて満たし、閾値は変更していない。
commit は rewriter 比 99.58–99.81% 減。256 MiB text は encode 563.403 ms、V3 29.554 ms、
commit 29.828 ms。**load 4 未満での受入計測は完了していない**。この値を低負荷の測定として扱わない。
時間の上限未達は無かったため、未達時に指定された `sample` は実行していない。

## AC-Gb4 / AC-Gb8

500 × 64 KiB の疑似乱数 payload で、末尾削除は write 1 B / copy 0 B、
同長改名は header + 1 B / copy 0 B、追加だけの commit は write 1 B / copy 0 B / V2+V5 0 B。
中央削除は suffix + 1 B を書き、suffix だけを copy し、V2+V5 の上限も満たした。
追加の符号化・書込みは add / endMembers の仕事で、copy engine の writeObserver とは別。

外部比較は 14 fixture × 3 操作（削除・改名・追加）。原本と出力の展開 hash を比較した。
非空出力の比較数は bsdtar 31、Lhasa 33、7zz 36。空 LHA はそれぞれ 5 / 6 / 6 件の独立した
新規空 archive との比較。原本を読めないための除外は bsdtar の lh4-small / names-cp932-mixed、
Lhasa の names-cp932-mixed（各 3 操作）。7zz の原本除外は無い。

## AC-Gb12 release / 4 GiB 超の位置

2.5 GiB の lh0 member × 2、その後に 1 KiB × 2 の疎な LHA で実行した。
4 GiB 超の member 削除、異長改名、末尾追加、先頭 2.5 GiB の削除による copy がすべて成功。
出力は KaitoKit の一覧と `7zz l`（4 回、exit 0）で確認した。

```tsv
operation	output_bytes
delete_last	5368710265
rename_third_longer	5368711352
append	5368711381
delete_first_2.5GiB	2684356729
```

## オーケストレータの検証（2026-09-26）

隔離した `$SCR/v4`（KaitoKit 0cbd809 = ef06e22 + 記録だけ、を `git archive`、この作業ツリーは rsync）。hdiutil が使える host。

| 実行 | 結果 |
|---|---|
| `swift test`（全件） | 477 件、失敗 0、skip 15（任意実行の probe・大きな fixture） |
| LHAUpdaterOutputModeTests の実 image | FAT32 / exFAT / HFS+ / host の 4 件とも成功（Codex の sandbox では hdiutil が使えず skip だった） |

AC-Gb11 の 100k の時間は Codex の計測（全て上限以内、負荷の平均 4.3〜4.9）を採り、採り直していない。
