# P5-G（S24）の検証記録

GyoshukuKit 基準 6e7cd9b、KaitoKit は `git archive 0cbd809592cad139ea430dd75cc15af37f8ca2c1` の隔離 export。
隔離 root: `/private/tmp/gyoshuku-p5g-gate.qxvrkzo7`。live sibling は build/test に使わない。commit は行わない。

最終結果: build 成功、full suite **523 tests / 28 skipped / 0 failures、1,604.864 s**。
属性追補後の focused run は 87 tests / 5 skipped / 0 failures。最終 tree の release 4 GiB probe は 1 test / skip・失敗 0。
実 disk image の試験と低負荷の正式な scale 合格は未確認（下記の環境制約）。

## S24-c1: scratch segment の修正

着手前の gate probe は、同一の generated prefix を beginAppend と commit に渡すと、sequential でも
`.relocatedAppend` になり、必要な 33 B に対して 73 B を書き、generator を二度呼んだ。
オーケストレータの S24-c1 指示により `.scratch(SplicedScratchFile, Range<UInt64>)` を追加した。
同じ append-only scratch object と同じ範囲を比較し、不変な prefix を再利用する。generated は従来どおり比較しない。
範囲外は outputVerificationFailed で後始末する。tar の exhaustive switch には scratch の拒否を足しただけで、
tar / LHA の source・literal の処理は変えていない。

復帰後の `scratch-resumed.log`: SplicedArchiveOutputTests 9 件、SevenZipSharedOutputGateTests 1 件、計 10 件、失敗・skip 0。
元の probe は `strategy=sequential units=33 commitWritten=33`。変更した範囲・別 object の再配置と範囲外の cleanup も通った。

## 基準 writer の凍結

SevenZipWriter の切り出し前（6e7cd9b の符号化、追加は IV 注入だけ）に、空・directory・symlink・16 MiB 超の file・日本語名を含む
出力を平文 / AES / AES header の三条件、thread 1 / 8 で SHA-256 凍結した。結果は SevenZipWriterByteIdentityTests 内に保存。
`scratch-and-freeze-2.log`: 10 件、失敗・skip 0。初回 scratch-and-freeze.log は TarImageSource の exhaustive switch の compile error。
修正後に再実行した。復帰時には既に終了していたログを確認した。

## 実行コマンド

各実行前に以下で作業 tree を隔離コピーへ同期（KaitoKit export は変更しない）:

```sh
TASK_ROOT=$(cat /private/tmp/gyoshuku-p5g-root)
rsync -a --exclude='.git' --exclude='.build' --exclude='.agents' --exclude='.codex' ./ "$TASK_ROOT/GyoshukuKit/"
CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" swift test --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$TASK_ROOT/cache" --filter '<FILTER>' > "$TASK_ROOT/<LOG>" 2>&1
```

以下に実行一覧と結果を記録する。

## AC-G13: StartPos の基準非互換（承認された追補）

2026-09-26、オーケストレータが `startpos.7z` に限る例外を承認した。
変更前の frozen fixture を 7-Zip 26.03 で直接検査した結果:

```text
/opt/homebrew/bin/7zz t Tests/Fixtures/sevenzip-edit/startpos.7z         exit 0
/opt/homebrew/bin/7zz x -y -o<isolated>/startpos-baseline/7zz <fixture>  exit 2
  ERROR: Unsupported Method : a.txt
/usr/bin/bsdtar -xf <fixture> -C <isolated>/startpos-baseline/bsdtar     exit 0
```

`SevenZipUpdaterInteropTests.testStartPosBaselineAndPreservation` でこの基準を固定し、改名後も StartPos の
生値と little-endian byte、KaitoKit の全 entry の内容・CRC を保つことを求める。
StartPos を持つ entry が残るときだけ `7zz x` の exit 2 / Unsupported Method を求め、それ以外は成功が必要。
7zz t と bsdtar の全件展開・SHA-256 はどちらの場合も成功が必要。他の fixture に例外を置かない。
変更前の実行ログは隔離 root の `startpos-baseline/{7zz-test,7zz-extract,bsdtar-extract}.log`。
この承認前の `differential-interop-1.log` の失敗は、同じ StartPos の改名出力に対する 7zz x の拒否と
それに続く展開先不在によるもの（独立した updater の破損ではない）。

## AC-G13: 属性無しの元に追加する場合の参照規則

2026-09-26 のオーケストレータによる 7-Zip 26.03 の実測を受け、bsdtar の例外は追加せず、
updater の header model の組立に次の規則を適用した。元の file が 1 件以上で、その全件の属性が未定義なら、
追加・置換の属性も未定義にする。元が空、または属性が 1 件でも定義されていれば、追加の属性を mode から作る。
削除・置換の後の件数ではなく、元の vector で判定する。運ぶ entry の属性（未定義を含む）は変えない。

オーケストレータの参照実行は以下。added.txt は disk 上で 0755:

- `solid_zero.7z`: `7zz d z.7z zero.txt; 7zz a z.7z added.txt` → added.txt の Attributes / Modified が両方無し、bsdtar が受理。
- `zero_lzma2.7z` + `7zz a` → 同様に Attributes / Modified が両方無し、bsdtar が受理。
- `empty_7zz.7z` + `7zz a` → Attributes（A -rwxr-xr-x）と Modified がある。

libarchive 3.7.4 は、一部だけ定義された 0x15 を "Damaged 7-Zip archive" として拒否する。
この規則は、bsdtar が読める属性無しの元から、その形を作ることを避ける。元が既に一部定義ならそのまま保持する。
追加の mtime は落とさない。部分定義の time vector は 7zz / bsdtar / KaitoKit が受理し、ここは 7zz と意図して異なる。
P5 前の全体の書き直しは `SevenZipRecords.swift` で mode から全件定義の属性を合成していた。
その既存の writer / rewriter は変更しない。属性無しの元への追加の Unix mode は、7zz と同様に保存されなくなる。

`SevenZipUpdaterHeaderTests` は solid_zero の一部削除と 0755 の file + directory の追加、zero_lzma2 への同じ追加を検査する。
0x15 不在、mtime 保持、emptyStream / emptyFile と KaitoKit / 7zz の directory 判定、4 oracle の内容 SHA-256 を検査する。
empty_fi0 / g_plain への追加は属性と mode を持つ。frozen empty_7zz の 32 B は KaitoKit 0cbd809 が open を拒否する
という元仕様の risk 11 を維持し、その正確な 32 B を照合した空 model に対する追加・直列化で属性を検査する。
この fixture を public updater が open できるとは報告しない。`SevenZipUpdatePlanTests` は一部定義の保持と、
全件削除・置換後にも元の vector が追加属性の判断に使われることを検査する。

## Fixture の取り込み確認（照合結果）

`SP/p5/fixtures` の 35 file（33 archives、2 expected JSON）を全 byte 比較し一致した。
`README.md` と `NOTICE-lines.txt` も元と一致し、`Tests/Fixtures/NOTICE` は NOTICE の全文を含む。
比較用 SHA-256 一覧は隔離 root の `fixture-sha256.tsv`。最初の監査 script は root NOTICE の先頭の
追加改行まで完全一致を求めたため assert になったが、fixture 本体・同梱 NOTICE の変更は無い。
その後 root NOTICE の「全文を含む」と fixture の「完全一致」をそれぞれ確認した。

## 実行一覧（途中の失敗も含む）

以下の filter は上記共通 command の `<FILTER>`、log は隔離 root のファイル名。
環境変数のない行は通常の debug test。最初の gate の失敗は S24-c1 の発端であり、承認された変更で解決した。

| log | filter / command 差分 | 結果 |
|---|---|---|
| gate-tests.log | SevenZipSharedOutputGateTests / SplicedArchiveOutputTests の当初の gate | 7 tests、4 assertions failed（generated prefix の再配置） |
| scratch-and-freeze.log | writer freeze + shared output | compile error: TarImageSource の switch に scratch が無い |
| scratch-and-freeze-2.log | `GYOSHUKU_7Z_FREEZE=1`, `SevenZipWriterByteIdentityTests\|SevenZipSharedOutputGateTests\|SplicedArchiveOutputTests` | 10 tests、0 failures |
| scratch-resumed.log | `SevenZipSharedOutputGateTests\|SplicedArchiveOutputTests` | 10 tests、0 failures、0.022 s |
| serializer-1.log | `SevenZipHeaderSerializerTests\|SevenZipWriterByteIdentityTests` | 3 tests、1 failure（test の JSON key を訂正） |
| serializer-2.log | 同上 | 3 tests、0 failures、5.127 s |
| updater-build-1.log | `swift build`（同じ package-path / native / disable-sandbox / cache-path） | exit 0 |
| updater-tests-1.log | `SevenZipUpdaterTests` | 2 tests、0 failures、17.427 s |
| solid-crypto-1.log | `SevenZipUpdaterSolidTests\|SevenZipReencryptionTests\|SevenZipUpdaterHeaderTests` | compile error: test の Data(contentsOf:) に try が不足 |
| updater-focused-1.log | `SevenZipUpdater\|SevenZipReencryption\|SevenZipSelfCheck` | 同じ compile error |
| updater-focused-2.log | 同上 | 暗号化 4、fault 1、header 2 は成功後、test helper の UInt8(i) overflow で signal 5。truncatingIfNeeded に修正 |
| lifecycle-solid-1.log | `SevenZipUpdaterOutputModeTests\|SevenZipUpdaterRefusalTests\|SevenZipUpdaterSolidTests` | 9 tests、3 skipped、1 failure（非 7z の試験名 .zip が分割名の門に当たる。other.bin に訂正） |
| differential-interop-1.log | `SevenZipUpdatePlanTests\|SevenZipUpdaterRefusalTests\|SevenZipUpdaterDifferentialTests\|SevenZipUpdaterInteropTests` | 7 tests、3 assertions failed (1 unexpected)、513.575 s。200 differential は成功、StartPos の基準非互換は上記追補で対応 |
| probe-build.log | `SevenZipWriterByteIdentityTests\|SplicedArchiveOutputTests\|SevenZipUpdaterScaleProbeTests\|SevenZipUpdaterLargeOffsetTests` | 13 tests、2 opt-in skipped、0 failures、3.547 s |
| targeted-limits-cancel.log | `SevenZipUpdaterCancellationTests\|SevenZipReencryptionTests/testLargeAESCopyWrongPasswordLimitAndSolidCurrentPassword\|SevenZipUpdaterTests/testAllDeletedThenDiskTreeAddedAndLateReservations` | 3 tests、0 failures、5.201 s |
| coverage-completion-1.log | `GYOSHUKU_7Z_DIFF_ITERATIONS=12`, `SevenZipUpdaterInteropTests\|SevenZipUpdaterSolidTests\|SevenZipUpdaterOutputModeTests\|SevenZipUpdaterDifferentialTests` | compile error: throwing String read を XCTest の非 throwing message closure の外へ移した |
| coverage-completion-2.log | 同じ env、`SevenZipUpdaterInteropTests\|SevenZipUpdaterSolidTests\|SevenZipUpdaterOutputModeTests\|SevenZipUpdaterDifferentialTests\|SevenZipUpdaterCancellationTests\|SevenZipUpdaterHeaderTests\|SevenZipUpdaterRefusalTests\|SevenZipSelfCheckFaultTests` | 21 tests、3 skipped、6 assertions failed（2 unexpected）、146.904 s。differential の directory 名の model の正規化、合成 Copy fixture の既存の部分定義属性、solid_zero への追加の部分定義属性を特定 |
| large-release-1.log | `GYOSHUKU_7Z_LARGE=1`, `-c release -Xswiftc -enable-testing`, `SevenZipUpdaterLargeOffsetTests` | compile error: build 中に test 入力を同期したため。probe は未実行。その後は build 中の隔離 tree の同期を行わない |
| coverage-completion-3.log | `GYOSHUKU_7Z_DIFF_ITERATIONS=12`, `SevenZipUpdaterDifferentialTests\|SevenZipUpdaterSolidTests/testFollowingPackMovesUpAndDownWithRelocatedAppend\|SevenZipReencryptionTests\|SevenZipUpdaterCancellationTests` | 8 tests、0 failures、105.404 s |
| final-build.log | `swift build`（上記共通 flags） | exit 0、0.602 s（属性の追補前） |
| full-1.log | `swift test`（共通 flags、filter と追加 env 無し） | 519 tests、28 skipped、2 failures（1 unexpected）、1,600.253 s。200 differential は成功（490.610 s）。失敗は solid_zero の追加を bsdtar が拒否し、その展開先が無いことだけ。属性の追補前に開始した実行 |

Scale、完成後の focused / full suite、large-offset の結果は下に記録する。

属性の追補前の切分けでは、独立した `SP/p5/sz.py` による合成 Copy の header の再直列化も byte 一致した。
部分定義の 0x15 は bsdtar が拒否し、全件定義・全件未定義なら成功した。mtime の有無や kDummy の整列を変えても
部分定義 0x15 の拒否は変わらなかった。移動量を検査する合成 Copy fixture は baseline 自体を全 reader で読める
全件定義にし、solid_zero の追加については上のオーケストレータ規則で解決する。外部 oracle の assert は弱めていない。

## Release scale（AC-G15）

```sh
GYOSHUKU_7Z_SCALE_DIR=$SP/p45/scale CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" \
  swift test --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$TASK_ROOT/cache" -c release -Xswiftc -enable-testing \
  --filter SevenZipUpdaterScaleProbeTests > "$TASK_ROOT/scale-release-1.log" 2>&1
```

1 test、0 failures、1,083.835 s（release build 125.05 s は別）。各 engine / case を 5 回、計 140 measurements。
[全回の TSV](2026-09-26-p5g-scale.tsv) と [各欄の中央値 TSV](2026-09-26-p5g-scale-medians.tsv) を保存した。
stdout の一つの行の途中へ SwiftPM の native deprecation warning が混入したため、抽出時にその warning だけを除いて
前後の `rewri` / `ter` を再接続した（元 log の 197–198 行。数値は変更していない）。

負荷 1 分値は **4.68–18.05**。いずれも仕様の `< 4` を満たさないため、低負荷の正式な合格とはしない。
閾値を変えていない。この実行では全ての時刻の閾値内に収まり、`7Z-SCALE-MISS` は 0 行だった。
macOS 27.2 / Apple Swift 6.4 / arm64。CPU 名・メモリの `sysctl` は sandbox で拒否された。
`sample GyoshukuKitPackageTests 2 1` は process list の sysctl が拒否され、ログから得た実際の xctest PID に対する
`sample 28844 2 1` も権限不足で exit 255。profile を取得したとは報告しない。

| input / operation | updater open ms | updater commit ms | rewriter commit ms | load1（updater 中央値） |
|---|---:|---:|---:|---:|
| g_real / rename | 4.090 | 3.730 | 20288.893 | 4.68 |
| g_real / last | 3.902 | 3.602 | 20451.658 | 10.93 |
| g_real / add | 4.048 | 3.709 | 20407.369 | 12.12 |
| g_real / first | 3.999 | 5.633 | 77.562 | 12.95 |
| g_real / middle | 4.064 | 4.741 | 20295.642 | 12.71 |
| g_k100 / rename | 397.734 | 306.665 | 3780.388 | 13.46 |
| g_k100 / first | 390.731 | 392.479 | 3888.912 | 14.10 |
| z_k100 / rename | 351.127 | 384.423 | 4030.373 | 11.56 |
| z_k100 / first | 349.557 | 929.905 | 5458.500 | 9.67 |
| z_real_default / rename | 3.578 | 6.892 | 19160.082 | 8.12 |
| z_real_default / first | 4.240 | 22104.895 | 20416.675 | 9.01 |
| plain256 / set | 4.913 | 264.894 | 20966.112 | 17.12 |
| aes256 / change | 5.577 | 471.596 | 11123.486 | 15.05 |
| aes256 / remove | 5.560 | 266.417 | 11471.894 | 12.17 |

z_k100 の rename 出力は 228,446 B（元の 1.1 倍以下の assert を 5 回とも通過）。z_real_default の一部削除は
全 folder を作り直すので rewriter の 1.083 倍、出力は solid を維持する。
`plain256` / `aes256` の本文は P0b と同じ generator（64 × 4 MiB + 1,000 個の 1 B file）から試験内で作成した。
最後の各出力と生成した入力は隔離コピーの `.build/verification/7z-scale/` に残した。

この scale 実行は、その後の progress 上界の厳密化（再圧縮より前の動かない clone pack を上界から除く）と
plan 計時に最終 model の組立時間を加える変更の前。符号化・header・copy・自己照合は同じ実装である。
この TSV の plan_ms は初期の予約計画だけで、最終コードの planSeconds は上界計算と最終組立も含む。
`packs_ms` は共有部品の実行と fsync（照合時間を除く）、`scratch_copy_ms` は共有 copy engine の呼出時間
（最後の buffer flush は packs に入る）。V2 は共有検証全体から V1 / V3 / V3a を除いた時間。

属性の追補もこの計測より後。scale の元はいずれも属性を持つので、その追補による header の形の変更はない。
再圧縮サイズの別の測定は `s200` の 1 件削除が updater 215,959 B / `7zz d` 209,993 B（+2.841 %、+5 % 以内）。
z_k100 の改名は元 275,006 B → 228,446 B（−46,560 B、−16.931 %）。
z_real_default の一部削除は 81,364,701 B → 85,088,977 B（+3,724,276 B、+4.577 %。この case のサイズ閾値は無し）。

## 属性追補後の隔離 build / focused tests

最初の full suite / release large probe の隔離 tree が使用中だったため、入力 file を build 中に変えないように
別の隔離 root `/private/tmp/gyoshuku-p5g-attrs.ynVAS4OI` を作った。ここでも live sibling の working tree は使わない。

```sh
TASK_ROOT=$(mktemp -d /private/tmp/gyoshuku-p5g-attrs.XXXXXXXX)
mkdir "$TASK_ROOT/KaitoKit" "$TASK_ROOT/GyoshukuKit" "$TASK_ROOT/cache"
git -C ~/GitHub/KaitoKit archive 0cbd809 | tar -x -C "$TASK_ROOT/KaitoKit"
rsync -a --exclude='.git' --exclude='.build' --exclude='.agents' --exclude='.codex' ./ "$TASK_ROOT/GyoshukuKit/"
printf '%s\n' "$TASK_ROOT" > /private/tmp/gyoshuku-p5g-attrs-root
CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" swift build --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$TASK_ROOT/cache" > "$TASK_ROOT/attributes-build.log" 2>&1
```

`attributes-build.log`: exit 0、9.89 s。

各 focused 実行の前は同じ rsync で同期（build / test が終了してから）。次の command の log 名だけ変えて実行:

```sh
TASK_ROOT=$(cat /private/tmp/gyoshuku-p5g-attrs-root)
GYOSHUKU_7Z_DIFF_ITERATIONS=12 CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" swift test --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$TASK_ROOT/cache" --filter 'SevenZip|SplicedArchiveOutputTests' > "$TASK_ROOT/attributes-focused-1.log" 2>&1
```

`attributes-focused-1.log`: 87 tests、5 skipped、2 failures、359.246 s。新しい directory 判定の test が
`7zz l -slt` に `Folder = +` があると想定したことだけが失敗。7zz 26.03 はその field を出さず、通常の `7zz l` は
両出力とも `D.... ... added-dir/` と表示する。その実際の directory indicator を assert するよう訂正した。
7zz t / x、bsdtar -xf、KaitoKit の内容・CRC・属性・mtime の検査はこの実行でも通った。
skip は 7z の FAT32 / exFAT / HFS+ image 3 件と opt-in scale / large-offset 2 件。

`attributes-focused-2.log`: 同じ command / filter / env、87 tests、5 skipped、**0 failures**、364.533 s。
追加属性の全条件、通常表示の directory indicator、4 oracle、writer の凍結 hash、scratch gate が成功。
clone の先頭 / 中央の削除では、元 model の後続 pack の合計から独立に求めた移動量に対して、書込み・copy の
読み取りが ±0、V5 の読み取りがちょうど 2 倍であることも追加して通した。改名・末尾削除・追加の source copy は 0。

その後の build / full suite command（同じ隔離 root、テスト回数は明示的に 200）:

```sh
CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" swift build --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$TASK_ROOT/cache" > "$TASK_ROOT/attributes-final-build.log" 2>&1
GYOSHUKU_7Z_DIFF_ITERATIONS=200 CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" swift test --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$TASK_ROOT/cache" > "$TASK_ROOT/full-final.log" 2>&1
```

`attributes-final-build.log`: exit 0、0.67 s。
`full-final.log`: **523 tests、28 skipped、0 failures（0 unexpected）、1,604.864 s、exit 0**。
2026-09-26 15:37:40 JST 終了。KaitoKit は上記の 0cbd809 export。full-1 の既知の属性由来の失敗は解消した。
最終 full suite 内の 200-case differential は 486.746 s、失敗 0（seed 0x5A24BEEF）。

最終 full suite 内の regression（prefix で class を集計）:

| classes | tests | skipped | failures |
|---|---:|---:|---:|
| TarUpdater* | 18 | 4 | 0 |
| CompressedTar* | 31 | 5 | 0 |
| LHAUpdater* | 24 | 5 | 0 |
| SplicedArchiveOutputTests | 9 | 0 | 0 |
| SevenZip* | 61 | 5 | 0 |

TarUpdater / CompressedTar / LHAUpdater の元の test file に変更無し。SplicedArchiveOutputTests は元の assert を
変えずに scratch の受入 case を追加した。7z の内訳には既存 SevenZipWriterTests 18 件を含む。

full-final / full-1 ともに 28 skips、内訳も同じ:

- hdiutil image 不可 11: CompressedTarLifecycleTests の FAT32 / exFAT、FATVolumeTests・LHAUpdaterOutputModeTests・
  SevenZipUpdaterOutputModeTests の FAT32 / exFAT / HFS+。create が "装置が構成されていません"（Device not configured）で終了。
- opt-in / 外部 corpus 17: ArchiveWriterP2CompatibilityTests 1、compressed-tar の large / writer-large / scale 3、
  LHA の large / scale 2、LiveNameCheck の Shift-JIS scale 1、7z の large / scale 2、tar の git / large / oracle / scale 4、
  ZIP re-encryption の large 3、ZIP scale 1。7z の 2 probe は上記・下記の opt-in 実行で別途走らせた。

## Release 4 GiB 境界（AC-G17）

```sh
TASK_ROOT=$(cat /private/tmp/gyoshuku-p5g-root)
GYOSHUKU_7Z_LARGE=1 CLANG_MODULE_CACHE_PATH="$TASK_ROOT/cache" swift test --package-path "$TASK_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$TASK_ROOT/cache" -c release -Xswiftc -enable-testing --filter SevenZipUpdaterLargeOffsetTests > "$TASK_ROOT/large-release-2.log" 2>&1
```

full-1 の終了後に実行された `large-release-2.log` は build 44.22 s、1 test / 0 failures / 0 skips、28.189 s。
rename / first / add は 0.855 / 1.287 / 2.142 ms、書込みは 164 / 152 / 201 B。

終了後に同じ rsync で最終 tree（属性の追補を含む）を同期し、上記 command の log を
`large-release-final.log` に変えて再実行。build 63.28 s、**1 test / 0 failures / 0 skips、28.258 s**。
APFS の sparse Copy folder は 4 GiB + 1 MiB。残す場合は KaitoKit で全 byte を stream して 0 と CRC を照合し、
後続の LZMA2 folder と追加の内容を検査、3 出力すべて `7zz t` が exit 0。

| operation | 操作 + commit ms | 書込み B |
|---|---:|---:|
| 後続 folder の改名 | 1.030 | 164 |
| 先頭の Copy folder を削除、後続 pack を >4 GiB から 32 へ移動 | 1.433 | 152 |
| >4 GiB の位置への追加 | 1.743 | 201 |

timer は open 後、remove / rename / add の直前に開始するため、log の `commit_ms` は操作も含む。
書込み数は 32 B の placeholder と開始 header の finalPatch をともに含む。
最終出力は隔離 root の `GyoshukuKit/.build/verification/7z-large-offset/` にある。

## 静的な確認と変更ファイルの範囲

```sh
git diff --check
rg -n 'fclonefileat|ftruncate|\.gyoshuku-|memcmp|@unchecked Sendable|nonisolated\(unsafe\)' Sources/GyoshukuKit/SevenZip*.swift
rg -n 'public |@_spi' Sources/GyoshukuKit/SevenZip*.swift Sources/GyoshukuKit/ArchiveEditing.swift
git diff --numstat -- Sources/GyoshukuKit/SevenZipRecords.swift Sources/GyoshukuKit/ArchiveRewriter.swift Sources/GyoshukuKit/ZipUpdateLayout.swift Sources/GyoshukuKit/TarUpdater.swift Sources/GyoshukuKit/LHAUpdater.swift Documentation/releases
```

diff の空白エラー無し。禁止 pattern は一致無し（rg exit 1）。公開宣言は SevenZipUpdater / SevenZipAssessment /
ArchiveReencrypting と指定の Testing SPI だけ。ZipUpdateLayout / SevenZipRecords / ArchiveRewriter / TarUpdater /
LHAUpdater と published release notes の diff は空。SplicedArchiveOutput の diff は S24-c1 で承認された scratch の
分岐・範囲検査・同一 prefix 比較と、その写しの内部計時に限る（元の AC-G1 の diff 空条件への承認された例外）。
fixture の 35 file と同梱 README / NOTICE-lines の完全一致を再度確認した。commit / tag / release はしていない。

実装の追加は `SevenZipUpdater.swift`、`SevenZipEditModel.swift`、`SevenZipUpdatePlan.swift`、
`SevenZipUpdateCommit.swift`、`SevenZipHeaderSerializer.swift`、`SevenZipFolderEncoder.swift`、
`SevenZipReencryption.swift`、`SevenZipSelfCheck.swift`。既存の接続部分は ArchiveEditing / ArchiveUpdater の
protocol、ArchiveWriter / SevenZipWriter の追記 factory と共通 encoder、EncryptionPrimitives の test IV、
SplicedArchiveOutput の scratch、TarImageSource の exhaustive switch。テストは SevenZip の各受入 class と
2 つの support、SplicedArchiveOutputTests の scratch cases、凍結 fixture / notice。記録は design / CHANGELOG の
Unreleased / このファイルと 2 つの scale TSV。

## AC ごとの検査範囲

| AC | 検査と実行範囲 |
|---|---|
| G1 | 最終 build と full suite。P2 / P3 / P4 の regression、禁止 I/O pattern、共有部品の承認された差分は上記 |
| G2 | SevenZipWriterByteIdentityTests: 凍結 SHA-256、平文 / AES / header AES、thread 1 / 8 |
| G3 | SevenZipHeaderSerializerTests: frozen header の byte hash、最小長の数、digest、property order、空 header |
| G4 | SevenZipUpdaterTests: 両 mode の操作、元の pack / metadata、全削除、disk tree / symlink と追加後の予約 |
| G5 | SevenZipUpdaterOutputModeTests: 1,002 folder の改名 / 末尾 / 追加 / 先頭 / 中央、write・source read・V5 の正確な byte 数 |
| G6 | SevenZipUpdaterSolidTests: 対象 folder だけ再圧縮、thread byte 一致、BCJ / BCJ2 / PPMd / LZMA / AES、0 byte stream、pack の上下移動と再配置、s200 の +5 % |
| G7 | SevenZipUpdaterHeaderTests: header の方針、暗号化の解除の門、16 MiB 制限、属性追補。z_k100 の +10 % は release scale の size assert |
| G8 | SevenZipReencryptionTests: attach / detach / change、期待する圧縮済み平文の byte、固定 IV、混在 / 間違った / 無い鍵、AES + Copy の 64 KiB の限界 |
| G9 | SevenZipUpdaterRefusalTests: S0 / S1 / S3–S6、snapshot 無しの assess、非 7z と KaitoKit が open を拒む入力のエラー区分 |
| G10 | SevenZipUpdaterOutputModeTests: host の clone / sequential、元の同一性、0600・close、取消・失敗・破棄・別 inode の保護。FAT32 / exFAT / HFS+ は hdiutil 不可で skip、host で要実行 |
| G11 | SevenZipUpdaterCancellationTests と共用 pipeline の既存 ParallelLZMA2WriterTests: scratch / generated / V3 / spool 往復 / encoder 待ちの取消し。操作・solid・1 万 directory の各 test で固定 total と単調な進捗 |
| G12 | SevenZipSelfCheckFaultTests: 6 fault を V0 / V1 / V5 (= V2) / V3 / V3a で検出、原本保持と cleanup |
| G13 | SevenZipUpdaterInteropTests と操作 / solid / header / re-encryption の各出力の共用 4 oracle。StartPos の承認された基準非互換だけを上記の条件で扱う。bsdtar の追加例外無し |
| G14 | SevenZipUpdaterDifferentialTests: seed 0x5A24BEEF、GK / 7zz、200 組、独立 model / rewriter / carried pack の照合 |
| G15 | release 5 回・140 measurements の TSV。数値の閾値内だが load1 4.68–18.05 のため正式な低負荷合格は未確認。sample は sandbox で取得不可 |
| G16 | public / SPI と scope の静的確認、design / Unreleased / 検証記録、commit 無し |
| G17 | 最終 tree の release opt-in 1 test、失敗・skip 0。4 GiB 超の sparse Copy + LZMA2、全 byte / CRC と 7zz t |

32 B の empty_7zz の public open と既存 writer / rewriter の `01 00` の空出力は元仕様の risk 11 のまま。
前者に対する今回の追加属性の test は正確な fixture の空 model / header serializer の test であり、KaitoKit の拒否を隠さない。

## オーケストレータの検証（2026-09-26 15:40–17:29）

作業ツリーを rsync した GyoshukuKit と、KaitoKit 0cbd809 の `git archive` を並べた隔離の配置で実行した（sandbox 無し、hdiutil あり）。

| 実行 | 結果 |
|---|---|
| `swift build` | 成功 |
| `swift test`（全件） | 523 件、失敗 0、skip 17（すべて環境変数で有効にする大きな書庫・計測・oracle の試験）。Codex の実行で skip だった hdiutil の試験はここで走り、`SevenZipUpdaterOutputModeTests` の `testFAT32`・`testExFAT`・`testHFSPlus` を含めて成功 |
| `GYOSHUKU_7Z_DIFF_ITERATIONS=2000 swift test --filter SevenZipUpdaterDifferentialTests` | 2,000 組（seed 0x5A24BEEF）、失敗 0（4,848 s） |
| `GYOSHUKU_7Z_LARGE=1 swift test -c release -Xswiftc -enable-testing --filter SevenZipUpdaterLargeOffsetTests` | 成功。4 GiB を越える offset で rename 0.887 ms / 164 B、first 1.012 ms / 152 B、add 1.595 ms / 201 B |

静的な確認: 新しい public は仕様 §0.2 の `SevenZipUpdater`・`ArchiveReencrypting`・`SevenZipAssessment` と `@_spi(Testing)` の統計だけ。
`SevenZip*.swift` に `fclonefileat`・`ftruncate`・`.gyoshuku-`・`memcmp` は無い（出力の部品は `SplicedArchiveOutput` を共有）。
`SplicedArchiveOutput.swift` の差分はオーケストレータが承認した `.scratch` の区間（S24-c1）だけ。公開済みの release notes は変更していない。

属性の追補の根拠（オーケストレータの実測、7-Zip 26.03）: 属性も mtime も持たない `solid_zero.7z` に `7zz d` と `7zz a` を行うと、
追加した file は Attributes も Modified も持たず、bsdtar は開ける。`zero_lzma2.7z` も同じ。0 件の `empty_7zz.7z` への `7zz a` では
Attributes と Modified が付く。

AC-G15 の release の計測（Codex、負荷 4.68–18.05）は閾値内だが、負荷 < 4 の条件を満たしていない。オーケストレータも採り直していない。
