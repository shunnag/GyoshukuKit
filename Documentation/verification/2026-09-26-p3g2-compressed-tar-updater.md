# P3-G G2: CompressedTarUpdater 検証（2026-09-26）

対象は GyoshukuKit `da0af7b`（G1 `9fb6ee2`、P2-G `efdb651`、FAT/exFAT 修正を含む）上の未 commit の G2。
KaitoKit は指定された **`d35f2da23ba2c213453aa36353eda7a0184b7fc1`** の `git archive` だけを使った。
live の KaitoKit / KaitoFinder、Package.swift、Benchmarks、既存テストは変更していない。commit / tag は作っていない。

環境は macOS 27.2（26B5091g）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64、Swift 6 言語モード。
`sysctl` による機種照会と `ps` は sandbox で拒否された。低負荷の計測前には他の build/test を並行させていない。

## 実装と接点

- `CompressedTarUpdater.open(reader: sending ArchiveReader, output:format:options:)`、`assess(reader:)`、
  `commit(progress:) -> CompressedTarCommitResult` を D9 の名前で追加。結果は strategy、OutputIdentity、
  reused/encoded segment と 3 種の byte 統計。owner/date の ArchiveEditing 要件も実装した。
- P2 の TarLayout/TarEditPlan、表現可能性・予約、追加用 ArchiveWriter/TarWriter factory を共有する。
  K1 と member/header/global/EOF 境界を照合し、R0 と R1–R8・R10 の判断は open だけで行う。
  source URL を開く API や makeReader は追加していない。
- TarImageSource は旧 image と追加/literal の descriptor の区間表。保存領域は output の隣で作成直後に unlink。
  TarWriter には書込み量記録と容量故障注入用の internal `willWrite` だけを追加した。追加 factory へは fd を複製して渡す。
- D4 の区切り選択・32 KiB 窓・小さい区切りの吸収と、G1 の TarChunkLayout/XZFraming を使う。
  ByteSource 用の copy-engine overload で、読み取った運ぶ圧縮 byte の CRC32 を open 時の地図と比較する。
- V0–V3 は帳簿、橋だけの並列復号、framing、同一性を照合する。V4 は複写の読取り中に行う。
  検証の実読取 byte は `SplicedArchiveOutput.verificationReadObserver` に集約する。
  production のコードは K5 を呼ばず、呼出側が公開前に K5 を使う。全体 open への fallback は baseNotSpliceable だけ。
- output が空の間の inode は保存しない。fd がある間は ArchiveOwnedFile の fresh fstat/lstat 照合と remove を使い、
  descriptor を閉じる前に最終 identity を採る。source の同一性検査は変更しない。
- total を正確に固定するため出力作成前に圧縮長を求める。符号化結果の cache は
  `2 × threads × chunk上限` byte 以下。収まらない場合は書出し時に再符号化し、圧縮 spool は作らない。
  最初の progress 通知はこの事前符号化の後。Task 取消しはその間も確認する。
  `encodingSeconds` は worker ごとの経過時間の和（再符号化も含む）で、並列区間の wall ではない。
  commit wall、copy wall、self-check wall は別に記録する。

## 隔離と実行コマンド

作業用 root は `/private/tmp/gyoshuku-p3g2.WYR2p1`。KaitoKit の export 1,393 ファイルが指定 commit の archive と byte 一致することを確認した。
GyoshukuKit は次の形で同期した（.git/.build/.agents/.codex は持ち込まない）。

```sh
git -C ~/Github/KaitoKit archive d35f2da | tar -x -C /private/tmp/gyoshuku-p3g2.WYR2p1/KaitoKit
rsync -a --exclude .git --exclude .build --exclude .agents --exclude .codex ~/Github/GyoshukuKit/ /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit/
```

以下は実行したコマンドの共通引数をまとめた表記。debug と release の scratch を分離した。
全 log はこの root に保存した。SwiftPM の user cache 書込み不可と native build-system の deprecation 警告は出たが、build は成功した。

```sh
P3_ROOT=/private/tmp/gyoshuku-p3g2.WYR2p1
export CLANG_MODULE_CACHE_PATH=$P3_ROOT/cache
P3_ARGS=(--package-path "$P3_ROOT/GyoshukuKit" --build-system native --disable-sandbox --cache-path "$P3_ROOT/cache")
P3_RELEASE=(-c release -Xswiftc -enable-testing --scratch-path "$P3_ROOT/release-build")

swift build "${P3_ARGS[@]}"
swift build "${P3_ARGS[@]}" "${P3_RELEASE[@]}" --build-tests

GYOSHUKU_TAR_GIT_REPO=~/Github/GyoshukuKit \
GYOSHUKU_P2_COMPAT_OUTPUT=$P3_ROOT/compat-bytes \
GYOSHUKU_P2_COMPAT_BASELINE=/private/tmp/gyoshuku-p2g.HazIgb/baseline-bytes \
swift test "${P3_ARGS[@]}"

swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" \
  --filter 'CompressedTarUpdaterTests|CompressedTarSplice|CompressedTarRepeatEditTests'

swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" \
  --filter 'CompressedTarUpdaterTests|CompressedTarSplice|CompressedTarRepeatEditTests|CompressedTarLifecycleTests|CompressedTarSelfCheckFaultTests|CompressedTarP2OracleTests|CompressedTarThirdPartyTests|CompressedTarCompatibilityTests'
swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" --filter CompressedTarThirdPartyTests
swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" --filter CompressedTarUpdaterTests

GYOSHUKU_LARGE_TESTS=1 swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" --skip-build \
  --filter CompressedTarLargeOffsetTests
# VLI の期待値を独立した literal にしてから、--skip-build 無しで同じ large filter を再実行した。
GYOSHUKU_LARGE_TESTS=1 swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" \
  --filter CompressedTarLargeOffsetTests

GYOSHUKU_P3_REPETITIVE_FIXTURE=1 swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" --skip-build \
  --filter CompressedTarRepeatEditTests

GYOSHUKU_SCALE_PROBES=1 \
GYOSHUKU_SCALE_CORPUS=$SP/p3val \
GYOSHUKU_SCALE_NEW_ARCHIVES=/private/tmp/gyoshuku-g1.eHMEll/results/revised \
swift test "${P3_ARGS[@]}" "${P3_RELEASE[@]}" --skip-build --filter CompressedTarScaleProbeTests
```

## 結果と試験範囲

| 実行 / log | 結果 |
|---|---|
| debug build / `build-api.log` | 成功、2.42 s |
| release build-tests / `build-release.log` | 成功、110.53 s |
| G2 debug regression / `test-g2-regression.log` | 19 tests、0 failure、FAT/exFAT 2 skip、28.757 s |
| 全件 debug / `test-full.log` | **426 tests、0 failure、15 skip、615.682 s** |
| 最終の gate・決定性・サイズ・50 編集（release）/ `test-release-fixed.log` | **8 tests、0 failure、13.369 s** |
| whole-member の byte 統計も assert した updater（release）/ `test-whole-member-final.log` | **4 tests、0 failure、1.711 s** |
| 4.5 GiB / `test-large.log` | 1 test、0 failure、0.228 s |
| 独立した VLI 期待 byte も含む 4.5 GiB / `test-large-final.log` | **1 test、0 failure、0.221 s** |
| 極端な圧縮率の再現 / `test-repetitive.log` | **1 test、1 failure**（gzip の +1% 条件。下記） |

全件実行後に gate 1 test、size assert、他ツールの no-change / bsdtar branch を追加した。
初回 G2 検証中は production のソースは全件実行時から不変だった。後続の focused run は下記。
この後の S15 correction 1 による容量規則の修正と再検証は末尾に記す。

最後の G2 focused run は `test-release-all-g2.log`（20 tests、2 skip、1 failure、22.363 s）。
失敗は追加した bsdtar fixture を stdout へ書いたため圧縮 stream の後に padding が付いたもの。
指定どおり regular file に `bsdtar -czf` するように直し、当該 test を再実行した
`test-third-party-final.log` は **1 test、0 failure、4.204 s**。その中で 9 種の他ツール入力に対して
変更なしと追加を行い、期待 strategy、K5/P2、外部互換を確認した。他の focused test は先の run で通過済み。

最終の隔離照合では Sources/Tests の 135 ファイルと Package.swift が workspace と byte 一致した。
新規 14 ファイルの末尾改行・行末空白、追跡済みファイルの `git diff --check` も通過した。
TSV は 156 行すべての列が埋まり、waited の全 load1 と commit 時間が元の上限内であることを再集計した。

全件の skip 15 件は、実 disk image 5 件（既存 FAT32/exFAT/HFS+ と新規 FAT32/exFAT）、
opt-in large/scale/oracle 10 件。G2 の large と scale は上の別コマンドで有効化して実行した。
FAT32 と exFAT の lifecycle は hdiutil create が exit 1 /「装置が構成されていません」で XCTSkip。
この sandbox では実 volume 上の成功を確認できていない。ホストで再実行する対象は
`CompressedTarLifecycleTests.testFAT32` / `.testExFAT`。delete-first/last、同長/異長 rename、追加、
unchanged、取消し、最初の add 後の discard、強制故障を三 codec で行い、K5 と directory 残留物を検査する。

機能試験は次を含む。

- 新/旧配置の三 codec、P2 の独立した TarUpdater の結果と復号 image を byte 比較。
  K5 の結果と full open の entry/kind/本文/image を比較し、結果の inode/size/mtime を照合。
- hard-link chain、参照先削除時の実体化、comment global pax、sparse 1.0、NFD、ustar/pax をまたぐ改名。
  Python PAX/GNU と bsdtar の入力、uid=501/uname=alice、xattr pax、AppleDouble。
- 1/4/8 threads の決定性。同長改名の splice と fullEncode が三 codec で byte 一致。
  旧配置の EOF が二つの chunk をまたぐ 1,047,552 / 4,499,456 / 16,776,192 B の本文。
- GK の 7 故障は outputVerificationFailed。自己照合を飛ばした 5 故障は K5 の所定の理由で拒否。
  bzip2 stream / xz block の欠落は K5 の解析失敗か P2 image の違いで検出。
  GK が運んだ出力を読み直さないことも flipReusedByte で確かめた。
- V4 の同 inode・同 size・mtime 復元の改変。source の追記、path 差替えでは保持済み inode を使うこと。
  計画後/encode/copy/self-check の取消し、実 Task 取消し、progress callback の throw、foreign inode の保存。
  scratch fd の close、低容量 ENOSPC、add 後の discard、全件削除した空書庫への追加。
- progress の固定 total、単調性、終端 completed==total、検証 read observer と total の一致。
- gzip -6、bsdtar gzip、単一 bzip2、CRC64 xz は fullEncode、128 KiB zlib SYNC、900,000 B の Python bzip2 streams、
  CRC32/1 MiB xz blocks は splice。複数 gzip members / xz padding は framing fallback。
  bzip2 は level 9 と 1 が同じ出力で混在する。map が無い場合だけ K5 baseNotSpliceable を full open で代える。
- 外部互換は gzip/bzip2/xz `-t`、bsdtar `-tvf` / `-xOf` の復号 tar との一致、7zz `t` / `x -so` /
  `l -si -ttar`、Python tarfile の一覧/size/SHA-256、KaitoKit の K5/full open。外部道具欠落を skip にはしない。
- 非圧縮 tar / ZIP / 7z / LHA / hint 無し codec の既存テストも全件で通過。
  `TAR-COMPAT files=20` は P2 時点の baseline との出力 byte 一致を確認した。

4.5 GiB probe は len2=4,831,838,208 の crc32_combine が直接 CRC と一致（32,537,398）、
gzip ISIZE=512 MiB、2³² を越す xz VLI、TarImageSource offset=4,294,967,423 を確認した。

途中の失敗も記録する。初回 build では public な ArchiveReader 引数に対する internal import と既存の Range 拡張名衝突を修正した。
初回 test compile では ArchiveEditing 経由の permissions 引数と throwing reopen 呼出しを修正した。
初回 operation run は追加 factory の deinit が共有 fd を閉じる 2 件の失敗で、複製 fd に修正した。
core run の混合置換に対する「必ず splice」assert は、全区切りに変更が及ぶ正当な fullEncode を許すようにした。
後続 release の新規 gate は Swift sending の autoclosure 呼出しを reopen に修正し、
CP932 fixture を不正 UTF-8 の pax ではなく legacy ustar に直した。既存の assert は弱めていない。
途中 log は `build-initial.log`、`test-initial.log`、`test-operations.log`、`test-core.log`、
`test-g2.log`、`test-g2-expanded.log`、`test-release-final.log` に残した。

## サイズと再編集

| codec | append splice / full (B) | 差 (B) | delete splice / full (B) | 差 (B) |
|---|---:|---:|---:|---:|
| gzip | 136,438 / 136,413 | +25 | 69,623 / 69,623 | 0 |
| bzip2 | 124,722 / 124,658 | +64 | 62,651 / 62,651 | 0 |
| xz | 137,484 / 137,396 | +88 | 69,116 / 69,116 | 0 |

いずれも `4 KiB + full × 0.05%` の assert を通る。
seed=17 の 50 編集（delete/rename/add/replace）で K5 adopted snapshot と full-open snapshot を交互に使った。

| codec | splice / full (B) | 差 (B) | 相対差 | S/16 未満の chunk の最大数 |
|---|---:|---:|---:|---:|
| gzip | 135,171 / 135,121 | +50 | +0.0370% | 5 |
| bzip2 | 124,613 / 124,658 | −45 | −0.0361% | 5 |
| xz | 137,340 / 137,368 | −28 | −0.0204% | 5 |

**D11-5 の相対サイズ条件の例外は S15 correction 1 で orchestrator が受け入れた。** 同じ操作を、large-A/B の先頭 64 KiB の
疑似乱数を無くした極端に反復的な fixture に行うと、gzip は **3,886 / 3,836 B、+50 B、+1.3034%**。
bzip2 は 1,027 / 1,072 B、xz は 6,168 / 6,200 B、small chunk の最大数はいずれも 5。
元の +1% assert はそのままで、上の opt-in コマンドは失敗を再現する。
D4 の片側一個の小 chunk 吸収は区切り数を抑えるが、数十 byte の違いに対する相対率を常に保証しない。
orchestrator は「3.8 KB の書庫に対する固定 50 B の差で、4 KiB + 0.05% の上限を満たす」として受け入れた。
opt-in の再現と +1% assert は変更せず、閾値を広げたり、大域的な再圧縮を追加して D4 の意味を変えたりはしていない。

## AC9: mixed の計測

新配置は G1 検証時に保存された `/private/tmp/gyoshuku-g1.eHMEll/results/revised/mixed-8.{tgz,tbz,txz}`。
旧配置は指定の `p3val/arc/mixed.{tgz,tbz,txz}`。新配置を作る CPU 負荷を計測直前に加えないため既存出力を使った。
probe の先頭で各新配置の復号 image が `p3val/arc/mixed.tar` と byte 一致することを確認する。
raw image は 492,533,760 B。新/旧の入力サイズは gzip 217,752,708 / 217,756,137 B、
bzip2 174,055,237 / 174,128,427 B、xz 151,077,836 / 151,293,276 B。
8 threads。commit（fsync/自己照合を含む）と K5 の wall は別々に測り、full open の追加比較は両方の計測外。
load1/load5/load15 は各 commit の直前の getloadavg。計測開始直前の uptime は **3.71 / 5.76 / 6.25**。

[AC9 の全 TSV](2026-09-26-p3g2-ac9.tsv) は 3 回 × 26 操作 × 2 段 = **156 行**。
計画/worker encode/copy/self-check の時間、3 種の byte、chunk 数、scratch、出力サイズ、
load1/5/15、元の時間上限、測定前の待ち時間を含む。`run` で各回を区別できる。

| run / log | 結果 | 測定直前の load1 | 測定外の待ち |
|---|---|---:|---:|
| initial / `test-scale.log` | 全 assert 成功、119.509 s | 3.33–5.66 | 0 s |
| repeat / `test-scale-quiet.log` | 全 assert 成功、118.419 s | 4.80–6.75 | 0 s |
| waited / `test-scale-waited.log` | **全 assert 成功、154.421 s** | **2.71–3.95** | 計 35 s |

最初の 2 回は途中で負荷が上がったため、測定前に load1 ≤4 を待つ処理を probe に加えた。
待ちの予算は probe 全体で 180 s。予算を使い切っても閾値を緩めず、実 load を報告する。
最後の run は全 26 操作が 1-minute load ≤4 で始まった。5-minute は 3.87–4.09、15-minute は 4.95–5.17。
後二者まで ≤4 だったという主張ではない。最終 run は時間・scratch・byte の閾値をすべて満たし、
閾値超過の profile 採取（sample）は必要にならなかった。

以下は `waited` の実測（ms）。差は同じ run の新配置 commit / 旧配置 commit −1。
異なる framing からの編集の比較であり、旧版 GK に対する速度差や、open/publish を含む UI 全体の時間ではない。

| codec | 操作 | 新 commit | 旧 commit | commit 時間差 | 新 K5 | 旧 K5 |
|---|---|---:|---:|---:|---:|---:|
| tgz | append | 34.180 | 51.281 | −33.35% | 254.117 | 251.372 |
| tgz | delete-small | 60.303 | 59.467 | +1.41% | 248.921 | 251.426 |
| tgz | rename-same | 58.879 | 59.272 | −0.66% | 248.993 | 249.448 |
| tgz | rename-different | 59.673 | 59.994 | −0.54% | 251.956 | 250.277 |
| tbz | append | 32.793 | 149.730 | −78.10% | 204.476 | 242.196 |
| tbz | delete-small | 280.290 | 279.927 | +0.13% | 287.259 | 325.380 |
| tbz | rename-same | 279.294 | 291.432 | −4.16% | 285.246 | 315.286 |
| tbz | rename-different | 278.978 | 280.570 | −0.57% | 285.399 | 319.973 |
| txz | append | 29.423 | 1262.814 | −97.67% | 241.443 | 280.932 |
| txz | delete-small | 4613.318 | 4705.549 | −1.96% | 338.903 | 381.110 |
| txz | rename-same | 4821.796 | 4688.659 | +2.84% | 343.354 | 383.784 |
| txz | rename-different | 4620.126 | 4667.592 | −1.02% | 344.742 | 381.640 |
| txz | rename-text256 | 25.356 | 3289.372 | −99.23% | 238.267 | 361.964 |

新配置の append は三 codec とも旧 image の再符号化 **0 B**。xz の text256 header 改名も 0 B。
scratch は最大 14,336 B（追加 member と新終端）、改名 4,608 B、削除 6,144 B。
別の whole-member fixture の削除も old image 0 B と assert し、再符号化は新終端だけ
（bzip2 4,608 B / xz 5,120 B）だった（`test-whole-member-final.log`）。
新 xz の small 編集は encode worker 4,484.368–4,686.086 ms + 1,500 ms 以下、かつ 9,000 ms 以下。
他の新配置の上限（gzip 600 / bzip2 1,200 / xz append・text header 1,000 ms）、
旧 gzip 900 / bzip2 1,800 ms の上限も全操作で通過した。旧 xz の時間は報告だけ（TSV の limit は inf）。

## Public / SPI の監査（AC11）

追跡前の新規ファイルを含めて次を実行した。

```sh
git diff -U0 -- Sources | rg '^\+.*\bpublic\b|@_spi'
git ls-files --others --exclude-standard Sources
rg -n '\bpublic\b|@_spi' Sources/GyoshukuKit/CompressedTar*.swift Sources/GyoshukuKit/TarImageSource.swift
rg -n '@unchecked Sendable|nonisolated\(unsafe\)|openSplicedCompressedTar' Sources/GyoshukuKit/CompressedTar*.swift Sources/GyoshukuKit/TarImageSource.swift
git diff --check
```

追加 public は D9 の 6 型（Updater、Assessment、Strategy、FullEncodeReason、OutputSegment、CommitResult とその nested OutputIdentity）。
追加 Testing SPI は statistics 型/読取専用 property、Fault と三つの TaskLocal だけ。
internal な stage/free-space/fd lifetime の試験 hook は public/SPI ではない。エラー enum の case 追加は無い。
新規 unchecked Sendable / nonisolated(unsafe) は無い。K5 参照は production では API の doc comment だけ。

`CompressedTarUpdater.swift` だけは Swift 6.4 が public 引数の ArchiveReader に対する
`@_spi(TarEditLayout) internal import` を拒否したので、仕様で認めた fallback の
`@_spi(TarEditLayout) import KaitoKit` にした。他の SPI 使用 3 ファイルは internal import。

## S15 correction 1: 出力 volume の固定予備容量を撤廃

orchestrator の host 検証（KaitoKit d35f2da、427 tests）では G2 の FAT32/exFAT の 2 件が
`TarSpliceStorage.init` の `free space / ENOSPC` で失敗した。同じ 128 MiB image 上の
既存 TarUpdater は成功した、との報告を受けた。この差は D6-2 の 1 GiB reserve によるもので、
orchestrator がその仕様規則を撤回した。

修正後は side storage に固定 reserve も空き容量の事前検査も設けない。
保存量は追加と変更 header 等の literal だけで、場所は出力 volume なので、出力本体と同じ容量方針とする。
通常の `willWrite` は書込み量を記録するだけ。実際の pwrite / FileHandle の書込みと、その失敗を
`perform` から cleanup へ伝える経路は変更していない。
`testingFreeSpaceReserve` は残し、試験時だけ fstatfs と指定値を比較して
`WriterError.io(operation: "free space", code: ENOSPC)` を強制できる。
強制失敗の試験には、storage fd が EBADF、output が無い、原本の byte/inode が不変、
directory に追加物が無い、失敗した updater が再利用不可、という assert を追加した。

FAT32/exFAT の image は **128 MiB のまま**、操作列も変えていない。
各 codec の add の直前に利用可能容量が 0 より大きく 1 GiB 未満であることを assert し、
commit 後に K5/full open を照合した reader で追加した 1 B の本文を確認する。
repetitive-gzip の固定 +50 B / +1.303% は、この訂正で orchestrator が受け入れた例外として
上のサイズ節を更新した。opt-in の再現・assert と 128 MiB image helper は byte 単位で変更していない。

今回も `/private/tmp/gyoshuku-p3g2.WYR2p1` の隔離 layout を使い、export 済み KaitoKit の
1,393 ファイルが指定 commit の `git archive` と一致することを再確認してから workspace を同期した。
log は同 root の `correction-1/`。live の sibling は変更せず、commit もしていない。

今回実行した build/test コマンド（debug、上記の P3_ARGS と同じ引数）:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-p3g2.WYR2p1/cache \
swift test --package-path /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit \
  --build-system native --disable-sandbox --cache-path /private/tmp/gyoshuku-p3g2.WYR2p1/cache \
  --filter 'CompressedTarUpdaterTests|CompressedTarSplice|CompressedTarRepeatEditTests|CompressedTarLifecycleTests|CompressedTarSelfCheckFaultTests|CompressedTarP2OracleTests|CompressedTarThirdPartyTests|CompressedTarCompatibilityTests' \
  > /private/tmp/gyoshuku-p3g2.WYR2p1/correction-1/test-g2.log 2>&1

GYOSHUKU_P3_REPETITIVE_FIXTURE=1 CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-p3g2.WYR2p1/cache \
swift test --package-path /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit \
  --build-system native --disable-sandbox --cache-path /private/tmp/gyoshuku-p3g2.WYR2p1/cache \
  --skip-build --filter CompressedTarRepeatEditTests \
  > /private/tmp/gyoshuku-p3g2.WYR2p1/correction-1/test-repetitive.log 2>&1

git diff --check
```

| log / 検査 | 結果 |
|---|---|
| `test-g2.log` | build 成功 2.66 s。**20 tests、0 failure、2 skip、30.761 s** |
| `test-repetitive.log` | **1 test、1 failure、10.074 s**。既存の +1% assert が同じ gzip 3,886 / 3,836 B（+50 B / +1.303%）を再現。orchestrator 受入れ済みの例外として保持 |
| 隔離照合 / `source-audit.txt` | Sources/Tests 135 ファイルと Package.swift が検証対象の copy と byte 一致 |
| SHA-256 照合 | repeat test、fixture support、ArchiveTestDisk の訂正前後の digest が一致 |
| `git diff --check` | 成功 |

2 skip は `CompressedTarLifecycleTests.testFAT32` と `.testExFAT`。
今回も hdiutil create が「装置が構成されていません」（exit 1）で失敗したため、
新しい容量 assert を含む実 image 上の実行は host での再確認が必要。
通常 volume 上の ENOSPC hook と fd/output/original/directory の後始末は実行して通過した。
volume を使い切って実際の pwrite ENOSPC を起こす試験、全件、release、AC9 の再実行は今回は行っていない。

## S15 correction 2: 地図の無い変更なし commit の取消し試験

orchestrator の host 全件試験で、一度だけ FAT32 の `cancel` が throw せず output が残った。
報告には当該 codec と `chunkMapUnavailableReason` が無い。
確定した GK 側の欠陥は、`CompressedTarSpliceWriter.unchanged` の `.copying` 試験 hook が
`snapshot.chunkMap?.chunks ?? []` のループ内にあったこと。地図無しでは呼ばれず、
地図有りでも gzip/xz の先頭 framing を書いた後だった。
これを **ループの前、最初の copy より前に一回**呼ぶようにした。
通常の Task 取消しは元から copy engine / finish でも検査しており、今回確認したのは
試験 hook の欠落であって、通常の Task 取消し検査が無かったという意味ではない。

### KaitoKit d35f2da の nil / empty 経路の調査

以下の参照はすべて、指定 commit の `git archive` と照合した隔離 KaitoKit の
`Sources/KaitoKit/` 以下。live sibling の未 commit code は調査・build に用いない。
`ChunkMapUnavailableReason` は `Model/TarEditingSnapshot.swift:89` の全 9 case を調べた。

| 経路 / reason | code と条件 | 今回の fixture / run ごとの変動 |
|---|---|---|
| snapshot 自体が無い | `Reader/ArchiveReader.swift:147,348,837`。記録 off、volumeSet 有り、ConcatenatedByteSource、tar と認識できない suffix / magic、cpio 等 | 固定 options・suffix・単一 FileByteSource では変わらない。テストは magic に対応する tar suffix を渡す。GK open は snapshot 無しを拒否する |
| `.notCompressed` / `.unsupportedCodec` | `ArchiveReader.swift:764–767`。plain tar、gzip/bzip2/xz 以外の codec | この三 codec では該当しない。形式 / bytes が変わらなければ不変 |
| `.recoveryMode` | `ArchiveReader.swift:356,767`。recovery 有効時には recorder を作らない | options は各 open で新しく作り、recovery は false。true では tar layout も recovery reason で失われ、GK open に進めない |
| `.multipleGzipMembers` | `Formats/SingleFile/GzipDecompressor.swift:226` 付近。最初の stream end の後に次の gzip signature がある | bytes による固定条件。GK GzipCompressor は header/trailer 一組、worker は raw deflate。元 fixture は単一 member。空の gzip member を追加した今回の回帰試験では確実に nil にできる |
| `.multipleXZStreams` / `.xzStreamPadding` | `Formats/SingleFile/XZResourceValidator.swift:25,84` と `CompressedTarMapRecorder.swift:130`。二番目の stream / stream 間または末尾の padding | bytes による固定条件。GK は単一 stream、末尾 padding 無し。block 内の alignment padding はこの reason ではない。今回の回帰試験は末尾に 4 B のゼロを追加する |
| `.tooManyChunks` | `CompressedTarMapRecorder.swift:50,77–94,124,137`。chunk 上限 1,048,576、gzip stop 上限 1,048,576 + 復号 byte / 4096 | 期限・load・使用 memory による打切りではない。gzip のカウントは decoder の Z_BLOCK stop に従うが、fixture は約 1.6 MiB、地図は gzip 3 / bzip2 2 / xz 2 chunks。各 open で recorder / counter を新規作成するので試験間で蓄積しない |
| `.archiveChangedDuringOpen` | `ArchiveReader.swift:768–777`、`Core/ByteSource.swift:140`。復号前後の fresh fstat による dev/ino/size/mtime が違う（片方だけ取得失敗も含む） | **外部書込み・一時的 fstat 失敗なら run ごとに変わり得る**。その場合 archiveIdentity も nil になり GK open が拒否するため、報告された「open 成功 → cancel が commit 成功」とは一致しない。両方 nil の source は map を消さないが GK open が identity 無しを拒否する |
| `.inconsistent` | `CompressedTarMapRecorder.swift:66–107,113–118,167–216`。下記の記録整合性検査、または `ArchiveReader.swift:767` の recorder 不在 fallback | 同じ bytes と正しい decoder accounting なら固定。正常な記録 on / 三 codec / tar / 非 recovery の open には recorder 不在の分岐は無い。short read による decoder の返却区切りは変わり得るため実測したが、1 / 7 / 4,096 / 262,144 B の各上限で地図は完全一致した。元の一度限りの map 欠落の reason は不明で、この case だったとも断定できない |

`disable` は最初の reason を保持し、それ以降の記録を止める。gzip の `.inconsistent` は、
最初の Z_BLOCK stop の出力量 / header 長、final stop の存在、trailer の 8 B、
trailer offset と archive 長、checksum 数と point 数、復号長、最後の point と trailer の順序、
trailer CRC / ISIZE、point の正規化を検査する。bzip2 は stream header の 4 B と level / 始点、
xz は Index / footer の存在と隣接・末尾位置、全 block の圧縮 byte 消費量を検査する。
さらに三 codec とも chunk の圧縮範囲と image 範囲が連続し、圧縮範囲が非空で、
末尾が archive payload / image 全長を覆うことを確かめる。CRC・破損・上限等で decoder や
tar parser 自体が throw する経路は、地図無しの成功した snapshot にはならない。

**empty map は正常な GK tar では生成されない。** gzip は先頭 point が必須、bzip2 は
少なくとも一 stream が必要。xz の block ゼロは復号長ゼロの場合だけで、
非 recovery の TarReader は終端未発見を拒否する（`Formats/Tar/TarReader.swift:409`）。
member ゼロの GK tar でも終端 / record fill がある。今回三 codec の空 tar も非空 map を確認した。
内部境界が無い「一 chunk」は empty ではない。xz CRC64 等が GK の reuse 対象外でも、
それだけで K1 の地図が nil になるわけではない。

staging は `Reader/SingleFileMaterializer.swift:38–88` の同じ decoder を 256 KiB buffer で
最後まで読む同期処理。64 MiB まで memory、それ以上は system temp の unlinked fd を使うが、
recorder を捨てたり、期限 / load によって省略する分岐は無い。容量不足・取消し・I/O 失敗なら
open が throw する。今回の小 fixture は既定では memory に収まる。強制 disk staging
（inMemorySingleFileLimit = 0）でも全 codec の map / image は memory 時と一致した。

gzip と xz の recorder 呼出しは読取り thread 上で同期する。bzip2 は worker が並列でも
`Codecs/ParallelBzip2Decompressor.swift:167–208` で job ID 順に結果を取り、その同じ thread で
recorder に追加する。worker 数 1、候補境界の誤検出、圧縮 8 MiB / 復号 16 MiB の worker 上限、
worker の decode 失敗では同じ recorder を serial decoder に渡す。
worker 完了順・50 ms の condition wait・load は省略条件ではない。GK 側も
OrderedChunkPipeline が入力順に emit してから finish するので、worker の完了順で
gzip member や xz stream が増えることはない。

FAT32/exFAT の volume type による map 分岐は無い。read による atime と ctime は identity に
含めない。空 file の仮 inode は output / scratch の問題であり、閉じた非空の source archive の
この open には該当しない。仮に source の inode / mtime が変わっても前述の identity 拒否になる。
`reopen()` は immutable な tarEditingState を共有するだけ（`ArchiveReader.swift:688–697`）で、
map を再計算・無効化しない。今回の volume loop は操作ごとに元 source を新規 open し、
K5 の output reader を次の操作へ渡していない。options / recorder / updater も共有しない。
K5 自体が返す map は `Reader/CompressedTarSpliceVerifier.swift:355–384` と
`Reader/TarSpliceGzipDecoder.swift:116–141` が別に組み立て、gzip / bzip2 の記録上限到達では
`.tooManyChunks` を返し得るが、今回の入力 snapshot の取得経路ではない。

以上から、指定 fixture・固定 options・不変の原本について **run ごとに map を任意に落とす
code path は確認できなかった**。変動し得る source identity や read/decoder accounting と、
取消し hook の確実な欠陥は分けて報告する。元の FAT32 の一度限りの原因は未確定で、
load や staging のせい、あるいは KaitoKit の race と結論していない。KaitoKit は変更していない。
元の小 fixture の framing / options が報告どおりで、GK open も成功したという条件では、
追跡すべき残りの recorder 拒否は `.inconsistent` になる。ただし当時の reason は採れておらず、
これは code から候補を絞った推論であって、その reason や発生条件を再現したという報告ではない。

### 回帰試験と実行結果

`testUnchangedCopyStageWithoutChunkMap` は、複数 gzip member / xz padding で nil map の
reason を assert し、変更なし成功と取消しを両方実行する。成功は byte 同一、K5 の
baseNotSpliceable 後の full reader の tar image 同一。取消しは hook 一回、書込み **0 B**、
output 無し、原本不変、directory に原本だけ、を確かめる。
修正前の code で先に実行し、hook 0 回・取消し成功・実書込みを両 codec で再現してから直した。

FAT32 / exFAT は 128 MiB の image と従来の 9 操作・1 GiB 未満での add assert を保つ。
共有した同じ 9 操作 × 三 codec を `testHostVolume` でも実行するようにした。
cancel では CancellationError と hook 一回、通常の unchanged commit でも hook 一回を assert。
volume loop の assert / unexpected throw は volume・format・operation・
chunkMapUnavailableReason・chunk 数を含む。成功時にも同じ情報を log に残すので、
hook 修正後に map が失われても reason を追える。最終 filter と全件試験の host 実測は
それぞれ全 27 open で reason=nil、gzip 3 / bzip2 2 / xz 2 chunks だった。

`CompressedTarSnapshotTests.testMapsSurviveShortReadsStagingAndReopen` は、三 codec ×
memory/disk × 四つの read 上限（計 24 opens と各 reopen）を FileByteSource wrapper で実行。
map 全体（境界 / CRC を含む）・reason・tar image の同一性と、reopen の image 共有を検査した。
さらに member ゼロの public writer 出力三つの map が非空であることを検査した。

隔離 root は引き続き `/private/tmp/gyoshuku-p3g2.WYR2p1`。
KaitoKit 1,393 ファイルと d35f2da の git archive の byte 一致を再確認した（`correction-2/isolation.txt`）。
SwiftPM の workspace-state.json も KaitoKit の location がこの隔離 root の下であることを確認した
（`correction-2/dependency-path.json`）。
Sources/Tests 136 ファイルと Package.swift が検証対象の copy と一致した（`correction-2/source-audit.txt`）。
repeat test / fixture support / 128 MiB image helper の SHA-256 も correction 1 と同一。
workspace の同期は毎回次のコマンドで行い、以降の build/test はこの copy のみを指定した。

```sh
rsync -a --exclude .git --exclude .build --exclude .agents --exclude .codex \
  ~/Github/GyoshukuKit/ /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit/

# hook 移動前の意図した失敗（新規テストを追加した時点）
CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-p3g2.WYR2p1/cache \
swift test --package-path /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit \
  --build-system native --disable-sandbox --cache-path /private/tmp/gyoshuku-p3g2.WYR2p1/cache \
  --filter 'CompressedTarLifecycleTests.testUnchangedCopyStageWithoutChunkMap|CompressedTarSnapshotTests' \
  > /private/tmp/gyoshuku-p3g2.WYR2p1/correction-2/test-before-fix.log 2>&1

# hook 移動後
CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-p3g2.WYR2p1/cache \
swift test --package-path /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit \
  --build-system native --disable-sandbox --cache-path /private/tmp/gyoshuku-p3g2.WYR2p1/cache \
  --filter 'CompressedTarLifecycleTests|CompressedTarSnapshotTests|FATVolumeTests' \
  > /private/tmp/gyoshuku-p3g2.WYR2p1/correction-2/test-lifecycle.log 2>&1

# 成功時の volume 診断 log も追加した最終テスト
CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-p3g2.WYR2p1/cache \
swift test --package-path /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit \
  --build-system native --disable-sandbox --cache-path /private/tmp/gyoshuku-p3g2.WYR2p1/cache \
  --filter 'CompressedTar|FATVolumeTests' \
  > /private/tmp/gyoshuku-p3g2.WYR2p1/correction-2/test-g2-fat.log 2>&1

CLANG_MODULE_CACHE_PATH=/private/tmp/gyoshuku-p3g2.WYR2p1/cache \
swift test --package-path /private/tmp/gyoshuku-p3g2.WYR2p1/GyoshukuKit \
  --build-system native --disable-sandbox --cache-path /private/tmp/gyoshuku-p3g2.WYR2p1/cache \
  --skip-build > /private/tmp/gyoshuku-p3g2.WYR2p1/correction-2/test-full.log 2>&1

git diff --check
```

| log | 結果 |
|---|---|
| `test-before-fix.log` | build 1.79 s、2 tests、1 testcase が意図どおり失敗（8 assert failure）、0.511 s。snapshot の試験は成功 |
| `test-lifecycle.log` | 12 tests、0 failure、5 disk-image skip、6.560 s |
| `test-g2-fat.log` | build 1.41 s、36 tests、0 failure、8 skip、51.240 s |
| `test-full.log` | **430 tests、0 failure、17 skip、643.105 s**。exit 0 |

disk-image の skip は CompressedTarLifecycleTests の FAT32/exFAT と、FATVolumeTests の
FAT32/exFAT/HFS+。`ArchiveTestDisk` が呼ぶ hdiutil create は今回も
「装置が構成されていません」（exit 1）で失敗した。
広い filter の残りの三 skip は large-offset、4 GiB public writer、AC9 scale probe の opt-in。
全件の残りの十二 skip は、これら三つと、G1 byte-compatibility、実 git archive、9 GiB tar、
prototype oracle、tar scale、ZIP re-encryption の大型三件、ZIP scale の opt-in。
`git diff --check` と今回の新規 / 未追跡ファイルの末尾空白・改行検査も成功した。
今回 release / opt-in の大型・scale・repetitive-gzip は実行していない。
サイズ / throughput の測定値と correction 1 の +50 B 受入れ記録は変更していない。
commit / tag / release と live sibling の編集は行っていない。

## オーケストレータの検証（2026-09-26）

隔離した `$SCR/v4/{KaitoKit,GyoshukuKit}`（KaitoKit d35f2da は `git archive`、GyoshukuKit は作業ツリーの rsync）。hdiutil が使える host。

| 実行 | 結果 |
|---|---|
| G2 の最初の作業ツリー、`swift test` | 427 件、失敗 2: `CompressedTarLifecycleTests.testFAT32` / `testExFAT` が `free space`（ENOSPC）。仕様 D6-2 の「出力の volume に 1 GiB を残す」規則の欠陥（128 MiB の image が露出した）。オーケストレータが規則を改めた（correction 1） |
| correction 1 の後 | 427 件、失敗 2: `testFAT32` の `cancel` が一度だけ throw せず出力が残った。単独 3 回、`CompressedTar|FATVolumeTests` 3 回では再現せず。変更の無い commit の `.copying` の試験 hook が地図の区切りのループの中にあった欠陥を correction 2 で直した（元の一度の原因は未確定。地図が実行ごとに欠ける経路はコード上見つからない） |
| correction 2 の後 | **430 件、失敗 0**、skip 12（任意実行の probe・大きな fixture）。FAT32 / exFAT / HFS+ の実 image の lifecycle と FATVolumeTests は全て成功 |
| 公開 API の追加 | D9 の型（`CompressedTarUpdater`・`CompressedTarAssessment`・`CompressedTarCommitResult`・`CompressedTarOutputSegment`・`CompressedTarStrategy`・`CompressedTarFullEncodeReason`）と `@_spi(Testing)` の hook だけ |

受け入れた例外（利用者へ報告する）: 疑似乱数を除いた極端に反復的な 3.8 KB の fixture に 50 回の編集を行うと、gzip の出力が `fullEncode` より
50 B（+1.303 %）大きい。仕様どおりの 50 回編集の fixture では +0.037 % で、「4 KiB + 0.05 %」の条件も満たす。assert と opt-in の再現はそのまま残す。
AC9（大きな書庫の計測）は Codex の実行（負荷の平均 2.71〜3.95）を採り、オーケストレータは採り直していない。
