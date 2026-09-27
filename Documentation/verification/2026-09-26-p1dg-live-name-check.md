# P1d-G（S31）: ZIP の少数編集の名前検査

最終版: AG1–AG3 と GyoshukuKit の全件試験は成功。AG4 の KaitoFinder 全件と AG5 の正式な受入は未完了。

## 対象と隔離

- 作業ツリー: `~/Github/GyoshukuKit-p1d`、branch `feature/2026-09-26-p1d-names`。
- 開始 commit: `d5c51b3cd7a45347592cb20abe05519fbe2d6951`（S15 / P3-G G2）。開始時の差分なし。commit はしていない。
- 仕様: `final-p613/P12-P13-P1d.md` の P1d 共通前提・P1d-G、`ORDER-P6-P13.md` §2 の「ArchiveWriter の名前の検査」。
  指定された関数はすべて名前で確認できた。
- ビルド・試験の root: `/private/tmp/gyoshuku-p1dg.hi5u5g5f`。
  `after/GyoshukuKit` は専用 worktree のコピー、`baseline/GyoshukuKit` は `git archive d5c51b3`。
  両方の隣の `KaitoKit` は `git -C ~/Github/KaitoKit archive d35f2da` の展開先。
  KaitoKit の固定 commit は `d35f2da23ba2c213453aa36353eda7a0184b7fc1`。
  baseline への変更は `ZipUpdaterScaleProbeTests.swift` の操作追加だけ（全 tracked file を比較）。
  KaitoKit は両コピー各1,393ファイルを commit と照合し、差分0を確認した。
- canonical GyoshukuKit、KaitoKit、KaitoFinder を編集していない。live sibling をビルドしていない。
- macOS 27.2（26B5091g）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64、Swift 6 language mode。

## 実装と意味の保存

最初の走査で元の名前を平らな UTF-8 snapshot に写す。ASCII で空成分のない名前には個別の
String key を作らず、hash も使わない。それ以外だけ NFC の元の key と空成分を除いた key を持つ。
削除・改名した index は除外配列で管理し、改名後と追加済みの名前は走査時に含める。
構築元の entry 配列は一度だけ取得し、ローカル配列で組み立てた snapshot を `let` で保持する。
表への切替で削除がない場合は元の順の一覧に改名差分を当て、全件の改名辞書の検索を避ける。

改名は `EditPathReservations` と同じ空成分のある成分列で、祖先 file → 同名 → 子孫の順に検査する。
追加は実際の writer と同じく、同名 → 空成分を除いた必要 directory → 祖先 file の順になる。
例 `a//b/c` に対する file `a/b` は、改名の検査では受理、追加の検査では `invalidPath`。
正準等価も、例外の種類と名前の UTF-8 byte 列も照合した。

追加・改名で走査の budget 4 を共有する。5 回目から必要な側の従来の表を使い、2,048 件未満は
最初から表を使う。writer は走査中に元の名前の集合を作り直さず、切替時に生存名を補って hook を外す。
`reserveEntryName(_:directory:)` に正規化・hook・集合の検査と更新を集め、`addEntry` はこれを呼ぶ。
この関数は後続 S38 / S40 の共通呼出先になる。

`TarUpdater` / `CompressedTarUpdater` は仕様の対象外であり、形式ごとの後続判断に残す。
`EditPathReservations`、`ArchiveRewriter`、public API、SPI は変更していない。
新しい `@unchecked Sendable` / `nonisolated(unsafe)` はない。

## AG1–AG3

- 固定 seed `0x31_5041_5448`、生存名 50–200 件、100 trace × 100 候補を各 mode で照合。
  元の集合に ASCII、NFC/NFD、U+212A/K、U+037E/;、空成分、先頭・末尾 `/`、同名、file/directory、
  結合文字が `/` に続く名前、深い接頭辞を含め、削除・改名・追加の予約を混在させた。
  改名は実際の `EditPathReservations(live).validate`、追加は候補ごとに作り直した実際の ZIP writer が神託。
- 追加と改名の 4 → 5 回目、共通 budget、削除・再改名・追加後の古い名前の解放、2,047 / 2,048 件の境界を検査。
- 固定日時・非暗号化の 10 script を budget 0 / 4 / Int.max で commit し、30 出力の byte が対応ごとに一致。
  追加、改名、削除、置換、folder、切替を越える混在を含む。
  衝突拒否は各 script を別 transaction で再生して照合し、失敗後の commit 拒否と原本 byte の保持も確認。
  拒否した updater は再利用できないため、成功して commit する transaction と分けている。
- 初回 `LiveNameCheckTests`: 9 件、1 skip（opt-in の Shift-JIS 計測）、0 failure。

## 実行コマンドと結果

全コマンドは上記 root の `run.py` が cwd・環境変数・完全な引数・exit code を
`commands.log` に記録し、標準出力・標準エラーと前後の `uptime` を `logs/<label>.log` に保存した。
共通設定は次のとおり。SwiftPM の manifest sandbox の入れ子を避ける設定であり、ビルド先は常に隔離コピー。

```sh
P1DG_ROOT=/private/tmp/gyoshuku-p1dg.hi5u5g5f
export CLANG_MODULE_CACHE_PATH=$P1DG_ROOT/module-cache
P1DG_COMMON=(--build-system native --disable-sandbox --cache-path "$P1DG_ROOT/cache")
P1DG_RELEASE=(-c release -Xswiftc -enable-testing)
P1DG_AFTER=(--scratch-path "$P1DG_ROOT/after-release")
```

| label / cwd | 実行（共通引数は上記） | 結果 |
|---|---|---|
| build-after / after | `swift build` | 成功、build 10.12 s |
| test-live-initial / after | `swift test --filter LiveNameCheck` | 9 件、1 skip、0 failure、8.865 s |
| build-baseline-release / baseline | `swift build --build-tests "${P1DG_RELEASE[@]}"` | 成功、build 114.85 s |
| build-after-release / after | `swift build --build-tests "${P1DG_RELEASE[@]}" "${P1DG_AFTER[@]}"` | 成功、build 118.85 s |
| test-full / after | `GYOSHUKU_TAR_GIT_REPO=~/Github/GyoshukuKit-p1d swift test` | **439 件、17 skip、0 failure、636.049 s** |
| compat-baseline / baseline | `GYOSHUKU_P2_COMPAT_OUTPUT=$P1DG_ROOT/compat-baseline swift test "${P1DG_RELEASE[@]}" --skip-build --filter ArchiveWriterP2CompatibilityTests` | 1 件、0 failure、20 出力を生成 |
| compat-after / after | `GYOSHUKU_P2_COMPAT_OUTPUT=$P1DG_ROOT/compat-after GYOSHUKU_P2_COMPAT_BASELINE=$P1DG_ROOT/compat-baseline swift test "${P1DG_RELEASE[@]}" "${P1DG_AFTER[@]}" --skip-build --filter ArchiveWriterP2CompatibilityTests` | 1 件、0 failure、20 出力すべて S15 と byte 一致 |
| test-live-release / after | `swift test "${P1DG_RELEASE[@]}" "${P1DG_AFTER[@]}" --skip-build --filter 'LiveNameCheck\|ArchiveEditingScale\|EditPathReservations'` | 12 件、1 skip、0 failure、3.666 s |

cwd の after / baseline はそれぞれ `$P1DG_ROOT/after/GyoshukuKit` / `$P1DG_ROOT/baseline/GyoshukuKit`。
debug と release の試験を同時に同じ fixture に対して実行していない。性能計測は全件試験と build の終了後に直列で行った。
SwiftPM の user cache 書込み不可、native build-system の deprecation、既存の unused public import / 不要な `try` の警告は出た。
新規ソースに関するコンパイルエラー・警告はなかった。

既存 `ArchiveEditingScaleTests` の一括改名（変更なし）:

| 形式 / 設定 | 1,000 件 ms | 2,000 件 ms | 4,000 件 ms |
|---|---:|---:|---:|
| ZIP / debug | 11.343 | 22.165 | 45.884 |
| tar / debug | 6.457 | 13.612 | 27.578 |
| ZIP / release | 2.497 | 4.822 | 9.991 |
| tar / release | 1.442 | 3.018 | 5.786 |

全件実行の 17 skip は次の内訳。既存試験・assert・skip 条件を変更していない。

- `hdiutil` が `Device not configured` で image を作れず 5 件:
  CompressedTarLifecycleTests の FAT32 / exFAT、FATVolumeTests の FAT32 / exFAT / HFS+。
- opt-in の大容量試験 6 件: CompressedTarLargeOffsetTests、CompressedTarWriterTests の 4 GiB、
  TarUpdaterLargeMemberTests の 9 GiB、ZipReencryptionBoundaryTests の大容量 3 件。
- fixture / scale 設定なし 3 件: CompressedTarScaleProbeTests、TarUpdaterOracleTests、TarUpdaterScaleProbeTests。
- 後で有効にして別途実行した 3 件: ArchiveWriterP2CompatibilityTests、LiveNameCheckTests の Shift-JIS、ZIP-SCALE。

実装中の追加実行と最終版の全件（完全な引数は [command record](2026-09-26-p1dg-commands.txt)）:

| label | 実行 | 結果 |
|---|---|---|
| test-live-release-final | snapshot 調整版の release `LiveNameCheck\|ArchiveEditingScale\|EditPathReservations`（再 build あり） | 12 件、1 skip、0 failure、3.738 s |
| build-paths-release | release `swift build --build-tests` | 成功、74.38 s |
| test-full-final | debug `swift test`（元配列の一度の取得を加える前） | 439 件、17 skip、0 failure、641.708 s |
| build-final-release | 最終ソースの release `swift build --build-tests` | 成功、14.83 s |
| test-full-release-final | 最終ソースの release `swift test --skip-build` | **439 件、16 skip、0 failure、553.743 s** |

最後の全件は `GYOSHUKU_TAR_GIT_REPO` に専用 worktree を指定し、
`GYOSHUKU_P2_COMPAT_OUTPUT=$P1DG_ROOT/compat-final` と
`GYOSHUKU_P2_COMPAT_BASELINE=$P1DG_ROOT/compat-baseline` も指定した。
このため compatibility の skip が1件減り、**20出力すべてが S15 と byte 一致**した。
最終ソースでも AG1 の各1万候補、AG2、AG3 はすべて成功した。
最終 release の既存一括改名は ZIP 1k / 2k / 4k = 2.303 / 4.732 / 9.924 ms、
tar = 1.456 / 3.112 / 6.237 ms。

## AG4 の範囲

GyoshukuKit の全件は上記のとおり成功した。KaitoFinder の指定された三つ組（KK S14 / GK S31 / KF S16）は未実行。
全参照の直近履歴と worktree 一覧も確認した。KaitoFinder HEAD は `54c2b8d`（S28 / P13）で、S16 の commit がまだなかった。
live KaitoFinder や別段の snapshot を S16 の代用にはしていない。S16 が確定してからオーケストレータの全件検証が必要。

## AG5（正式な受入は未完了）

最終版は baseline / after を交互に各4回（初回を除外し、残り3回の中央値）実行した。
全8回の前後で1分 load average が4以上だったため、**正式な受入計測として数えられる回は0**。
下表は参考値であり、AG5 合格とは判定しない。閾値を緩めていない。

```sh
# baseline / after の各 cwd で交互に4回。after には P1DG_AFTER も付ける。
GYOSHUKU_ZIP_SCALE_ENTRIES=500000 swift test "${P1DG_COMMON[@]}" "${P1DG_RELEASE[@]}" \
  --skip-build --filter ZipUpdaterScaleProbeTests
# after で4回。初回を除外する。
GYOSHUKU_LIVE_NAME_SCALE=1 swift test "${P1DG_COMMON[@]}" "${P1DG_RELEASE[@]}" "${P1DG_AFTER[@]}" \
  --skip-build --filter LiveNameCheckTests/testShiftJISFirstScanWhenEnabled
```

fixture は固定日時の1 byte file × 500,000、stored ZIP。新しい `add_file` も1 byte、
`new_folder` は日時固定、`rename_1000` は先頭1,000件。probe は公開 API のみを使う。

| operation | mutate baseline ms | mutate final ms | open baseline ms | open final ms | commit baseline ms | commit final ms |
|---|---:|---:|---:|---:|---:|---:|
| delete_start | 0.014 | 0.030 | 505.088 | 489.178 | 126.905 | 128.578 |
| delete_end | 0.003 | 0.025 | 491.241 | 488.454 | 52.808 | 52.548 |
| rename_same_length | 263.327 | 10.092 | 493.500 | 486.708 | 33.779 | 32.375 |
| replace_file | 292.132 | 16.227 | 479.997 | 478.138 | 66.528 | 57.335 |
| add_file | 266.780 | 10.471 | 478.256 | 479.187 | 65.255 | 56.078 |
| new_folder | 280.506 | 10.840 | 485.038 | 482.553 | 64.531 | 54.571 |
| rename_1000 | 246.246 | 255.516 | 486.277 | 482.389 | 41.251 | 42.944 |

- 数値上は add_file / new_folder / rename_same_length の mutate ≤40 ms、replace_file ≤60 ms。
  rename_1000 は基準の **×1.038**（門は×1.15）。
- open は全7行とも基準±10%以内。
- commit は replace_file ×0.862、add_file ×0.859、
  new_folder ×0.846で、**短縮側に±10%を外れた**。他の4行は範囲内。
  これも AG5 の未充足として残す。検査・コピー・commit 本体のコードは変更していない。
  commit 内の writer 解放で全件集合の解放が減った可能性はあるが、sample は取得できず原因の断定はしない。

最終版の `uptime`（1 / 5 / 15分）:

| run | 開始 | 終了 |
|---|---|---|
| baseline 00（除外） | 13.48 / 9.84 / 7.71 | 12.86 / 9.83 / 7.73 |
| baseline 01 | 11.78 / 9.74 / 7.74 | 10.82 / 9.60 / 7.71 |
| baseline 02 | 9.92 / 9.45 / 7.68 | 9.30 / 9.33 / 7.66 |
| baseline 03 | 8.33 / 9.12 / 7.61 | 7.99 / 9.02 / 7.59 |
| after 00（除外） | 12.86 / 9.83 / 7.73 | 11.78 / 9.74 / 7.74 |
| after 01 | 10.82 / 9.60 / 7.71 | 9.92 / 9.45 / 7.68 |
| after 02 | 9.30 / 9.33 / 7.66 | 8.33 / 9.12 / 7.61 |
| after 03 | 7.99 / 9.02 / 7.59 | 7.98 / 8.98 / 7.60 |

### Shift-JIS の500k件

最終版の初回を除いた3回の中央値: snapshot **182.356 ms**、
構築を含む最初の走査 **184.161 ms**。
`String(data:encoding: .shiftJIS)` から名前を作り、名前の生成自体は timer の外に置いた。
全12回の値と負荷は [Shift-JIS TSV](2026-09-26-p1dg-shiftjis.tsv) にある。
最終版の3回目は snapshot 323.108 ms / first scan 325.077 ms であり、遅い回も除外していない。

### 全実行の生データと途中の計測

- [ビルド・試験・profile のコマンド・環境変数・exit code](2026-09-26-p1dg-commands.txt)
- [ZIP-SCALE 全175行](2026-09-26-p1dg-zip-scale.tsv): 初稿56行、snapshot調整版56行、最終版56行、profile試行7行。
- [Shift-JIS 全12行](2026-09-26-p1dg-shiftjis.tsv)
- [sample の結果](2026-09-26-p1dg-sample-status.txt)

TSV の stage は `initial` = 初稿、`snapshot` = ローカル配列で構築する中間版、`final` = 最終ソース、
`profile` = profile試行。log名の接頭辞はそれぞれ `zip-scale-` / `zip-scale-final-` / `zip-scale-paths-` / `profile-final`。
各段階で同じ S15 の baseline と交互に1+3回実行し、baseline に追加したのは同じ probe の操作だけ。

途中の参考中央値は rename_1000 が initial 251.788 →291.293 ms（×1.157）、
snapshot 222.043 →274.313 ms（×1.235）。いずれも負荷条件外。
最終版では snapshot の構築元配列を一度だけ取得し、表の切替時は改名差分を当てる形にした。
旧データを捨てず、TSV に残している。

profile は snapshot 調整版の最適化済み XCTest bundle を直接起動し、8秒後に
`sample 88899 2 1 -file .../sample-final.txt` を実行した。
xctest は1件成功・7行を出力したが、sample は対象 process を検査できず exit 255、sample file は生成されなかった。
権限昇格は試みていない。この7行は中央値に含めない。

## 最終の静的確認と残る受入

`git diff --check` は成功。追加した source の `public` / `@_spi` / `@unchecked Sendable` /
`nonisolated(unsafe)` は0件。既存テストの変更は scale probe の操作追加だけ。
`TarUpdater.swift` / `CompressedTarUpdater.swift` / `EditPathReservations.swift` /
`ArchiveRewriter.swift` の diff は0件。

```text
ArchiveWriter.swift:409  func reserveEntryName(_ path: String, directory: Bool) throws -> String
ArchiveWriter.swift:435  let name = try reserveEntryName(path, directory: directory)
ArchiveUpdater.swift:425 writer.existingPathCheck = { [unowned self] name, directory in
ArchiveUpdater.swift:430 self.writer!.existingPathCheck = nil
```

名前の正規化・hook・予約の guard と更新は上記1関数にあり、addEntry に写しを残していない。
完成した source / test の SHA-256 は検証 root の `source-sha256-final.json` に記録し、
専用 worktree と隔離コピーの一致を確認した。commit はしていない。

残る受入は **KF S16 の全件（AG4）** と、**静かな機械での再計測および commit の±10%下限の確認（AG5）**。
この記録は AG4・AG5 の全条件を達成したという主張ではない。

## オーケストレータの検証（2026-09-26）

隔離した `$SCR/v4`（KaitoKit d35f2da は `git archive`、この worktree は rsync）。hdiutil が使える host。

| 実行 | 結果 |
|---|---|
| `swift test`（全件） | 439 件、失敗 0、skip 13（任意実行の probe・大きな fixture）。FAT32 / exFAT / HFS+ の実 image の試験を含めて成功 |
| 公開 API | `git diff -U0 -- Sources` に `public` / `@_spi` の追加なし |

AG5 の判断: mutate は 500k 件で追加・新規フォルダ・同長改名が 263〜281 ms → 10〜11 ms、置換 292 → 16 ms、rename_1000 は基準の 1.04 倍
（門 1.15 倍）で、open は ±10 % 以内。commit が 14〜15 % 速くなった 3 行（置換・追加・新規フォルダ）は ±10 % の枠を短縮側に外れたが、
枠の目的は悪化の検出なので不合格とはしない（writer を解放する時に全件の名前の集合を解放しなくなった分と見られる。原因は断定しない）。
Codex の計測は負荷の平均 4 以上の中で採ったもので、オーケストレータは採り直していない（別の作業が機械を占有していたため）。
AG4（KaitoFinder の全件）は、S16 の commit の後に GyoshukuKit を本線へ merge してから行う。
