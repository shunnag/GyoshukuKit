# S38 / P6-G — byte progress (2026-09-27)

## Scope and start gate

This change implements only P6-G (AC-G1–G10), on `feature/2026-09-24-review`, starting at
`67a22e850ae100e35fe7d76edcd61e9f05f6764d`. No commit was made. S39, Step 0-P7, S40 and S41 were not started.
The canonical checkout is `~/Github/GyoshukuKit` (the supplied `~/GitHub/GyoshukuKit`
resolves to the same checkout on this volume).

Read the P6 sections of `../KaitoFinder/Documentation/pending/specs-2026-09-26/P6-P7.md`,
ORDER-P6-P13 §2 / §3.4 / §3.7 and the named functions before editing. No AGENTS.md was present at the
checkout or its parent paths. `git status --short` was empty. S24 `52655cb`, S31 `bfb2980` and P14 `b132551`
are ancestors of `67a22e8` (`git merge-base --is-ancestor` succeeded for each).

The S38 start gate passed; all required parts existed at the starting HEAD:

| Gate | Actual symbol / file |
|---|---|
| Existing fixed-total meter | `CommitProgressMeter.init(total:progress:)`, `start`, `advance`, `finish` in SplicedArchiveOutput.swift |
| Owner API | `ArchiveOwnerIDs`, protocol owner-ID overloads and defaults in ArchiveEditing.swift |
| Source signature | `DiskSignature.capture`, `matches`, `isDirectory` in DiskSignature.swift |
| Writer disk entry | internal `add(contentsOf:as:ownerIDs:expected:)` in ArchiveWriter.swift |
| Writer directory entry | internal `addDirectory(_:modificationDate:ownerIDs:)` in ArchiveWriter.swift |
| Single name check | `reserveEntryName(_:directory:)`, called by `addEntry`, and `existingPathCheck` in ArchiveWriter.swift |
| ZIP random injection | `ArchiveUpdater.testingRandomBytes` |
| Updater progress | `commit(progress:)` in ArchiveUpdater, TarUpdater, CompressedTarUpdater, LHAUpdater and SevenZipUpdater |
| S24 AES injection | `SevenZipAESEncryptor.testingIV` in EncryptionPrimitives.swift |

Also read the named writer, carry/buffer, compressor, layout and pipeline functions by name, not the old
spec line numbers. P14 already supplies `weight` in OrderedChunkPipeline / LZMA2ChunkPipeline; P6 extends
that weight with pending-byte accounting and caller-side emission observation, without changing the
heavy/light window. The existing name-check function, meter, shared spliced output and updater commit
implementations are preserved. The only new TaskLocal is `ArchiveWriter.testingAfterPreWalk`.
No public CommitProgress initializer, WriterError case, P7 batch API, defaults key or UI string was added.

## Isolation and bounds

KaitoKit `823ad460faab055b6b7051da10583480785e8f68` and GyoshukuKit HEAD were exported using `git archive`
into `.build/p6g-layout/{KaitoKit,GyoshukuKit}`. Modified Sources / Tests / Benchmarks were copied from the
canonical tree into that isolated GyoshukuKit. Debug builds / focused tests use that layout. A second independent export at
`.build/p6g-full-layout/{KaitoKit,GyoshukuKit}` uses the same committed heads with the final Sources / Tests
overlaid for the full Release test suite; its fixture directory is separate from the running Debug suite. Neither live
`../KaitoKit` nor live `../KaitoFinder` was built or edited; their initial status was clean.

For valid options let `t = resolvedCompressionThreads`:

| Format | Maximum pending input bytes |
|---|---|
| ZIP | `t × DeflateBlock.size`; stored / ZipCrypto = 0 |
| tar | 0 |
| tar.gz | `(t + 1) × DeflateBlock.size` |
| tar.bz2 | `(t + 1) × ParallelBzip2Compressor.chunkSize(level:)` |
| tar.xz | `t × defaultBlockSize + memberPackingSize + (t > 1 ? (t + 1) × lightChunkLimit : 0)` |
| 7z | `t × LZMA2ChunkPipeline.chunkSize` |
| LHA | `t == 1 ? 0 : t × LHAWriter.compressionChunkSize` |

P14 constants: `defaultBlockSize = 16 MiB`, `memberPackingSize = 4 MiB`, `lightChunkLimit = 64 KiB`.
At most t heavy blocks and 2t+1 total blocks are pending; the largest byte sum is t full pieces plus
(t+1) light blocks. At a completed add/member boundary, large-member header/body pieces have already
been submitted, so only a small-member packing buffer (at most 4 MiB) can remain assembled. With one
thread light blocks count in the normal window. Thus tar.xz is bounded by 20 MiB at t=1 and
132.5625 MiB (139,001,856 bytes) at t=8. A test exercises alternating light headers / 16 MiB bodies
plus a final buffered member and checks that emitted weights sum exactly to the starting pending bytes.

Read notifications retain the existing 4 MiB meter interval. Drain advances are per emitted item:
packed XZ blocks ≤4 MiB, large pieces ≤16 MiB, light blocks ≤64 KiB. A drain notification can therefore
include a 16 MiB piece plus the previously unreported amount (<4 MiB); a middle-notification jump is
therefore <20 MiB for XZ. Rewriter finish also credits any unused part of its conservative D budget.
All sessions remain within `ceil(total/4 MiB)+2` notifications. Tar pending weights
include framing/padding input; disk-add totals count regular-file content only.

## Implementation / release-note text

Added per-call byte progress for disk additions, fixed-total rewriter commit progress, explicit
`finishAdditions(progress:)`, `readsAdditionsDuringCommit`, and the options-based pending-input bound.
Closing additions rejects further adds without poisoning the writer/editor, while finish / remove /
rename / commit remain available. Rewriter closing does not drain between additions and carry.
Progress callback failures preserve their original error, including errors otherwise mapped by carry;
all callbacks complete before publication, and source identity is rechecked after the final callback.
ZIP's standalone partial-output cleanup remains the caller's responsibility.

Bench supports `--progress` and `--mode recursive|items`; items builds the sorted preorder lstat list
inside the timing interval and uses public `addDirectory(_:)`. Unknown mode values are rejected.
Published release notes under Documentation/releases were not changed. The preceding paragraphs are
release-note text for the orchestrator; CHANGELOG.md only updates Unreleased.

## Commands and results

All paths below are relative to `~/Github/GyoshukuKit`. Swift commands use
`CLANG_MODULE_CACHE_PATH="$PWD/.build/p6g-module-cache"`, `--disable-sandbox` and
`--cache-path .build/p6g-cache` to keep compiler/cache writes inside the repository. SwiftPM emits
warnings that the user-level configuration/security cache is not writable; those caches are disabled.

Setup:

```sh
mkdir -p .build/p6g-layout/{KaitoKit,GyoshukuKit} .build/p6g-module-cache .build/p6g-home
git -C ../KaitoKit archive 823ad46 | tar -xf - -C .build/p6g-layout/KaitoKit
git archive HEAD | tar -xf - -C .build/p6g-layout/GyoshukuKit
rsync -a Sources/ .build/p6g-layout/GyoshukuKit/Sources/
rsync -a Tests/ .build/p6g-layout/GyoshukuKit/Tests/
rsync -a Benchmarks/ .build/p6g-layout/GyoshukuKit/Benchmarks/ --exclude .build
```

Initial attempts (not hidden as passing runs):

- The first `swift build --package-path .build/p6g-layout/GyoshukuKit --disable-sandbox --cache-path .build/p6g-cache -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/p6g-module-cache"`
  failed compiling the manifest because the manifest compiler still attempted `~/.cache/clang/ModuleCache`.
  Setting CLANG_MODULE_CACHE_PATH fixed the manifest cache location.
- The first source compile then found a missing `additionsClosed` field in SevenZipUpdater (its state field
  has internal rather than private access). Added the field and rebuilt successfully. Failure log:
  `.build/p6g-build-compile-failure.log`; successful log: `.build/p6g-build.log`.
- The first three-new-class run executed 14 tests with 6 failures: 5 from the test helper opening compressed
  tar without an editing snapshot, and one from opening a gzip archive without a tar suffix. Corrected the
  fixture setup; rerun: **14 tests, 0 failures** (27.898 s). Logs:
  `.build/p6g-new-tests-initial.log`, `.build/p6g-new-tests.log`.
- A read-only `ps` check was rejected by the sandbox; no process inspection data was used.
- The full Release build with the default `swiftbuild` engine compiled the sources, then failed at
  `GenerateDSYMFile` / `dsymutil` with `Operation not permitted` before running any tests. Log:
  `.build/p6g-full-dsym-failure.log`. Retried with `--build-system native` (as used by the S24 verification).
  The test counts below refer to that retry, not to this failed build.

Static checks completed:

- `git diff --check`: clean.
- `git diff -U0 -- Sources | rg '^\+.*\bpublic\b|@_spi|^\+.*@TaskLocal'`:
  only the specified P6 public APIs / their conforming implementations and the one prewalk TaskLocal.
- Compared complete existing function bodies against `git show 67a22e8:...`: `reserveEntryName` and
  all five `commit(progress:)` implementations are identical. Entire SplicedArchiveOutput.swift,
  ZipCopyEngine.swift and EncryptionPrimitives.swift are byte-identical to the starting HEAD.
- `bash -n Benchmarks/run.sh`: passed. `Benchmarks/run.sh --mode bogus`: exit 1 with
  `--mode requires recursive or items`.
- Verified the benchmark preorder against the live, read-only `ArchiveImportPlan.build` function.

Focused command (output `.build/p6g-focused.log`):

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/p6g-module-cache" swift test \
  --package-path .build/p6g-layout/GyoshukuKit --disable-sandbox --cache-path .build/p6g-cache \
  --filter 'AdditionProgressTests|FinishAdditionsTests|RewriterCommitProgressTests|ParallelDeflateBzip2WriterTests|ParallelLZMA2WriterTests|ZipCommitProgressTests|ArchiveRewriterTests|ArchiveRewriterPlacementTests|TarUpdater|CompressedTarUpdater|LHAUpdater|SevenZipUpdater|ZipUpdaterTests|LiveNameCheckTests'
```

The independent final full run includes further assertions for the exact ParallelDeflateBzip2
fixture combined with 40 MiB + 200 small members, KaitoError callback identity, closed ZIP live-name budget,
and empty-writer drain identity.

Full command (all tests, Release with testability; output `.build/p6g-full.log`):

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/p6g-module-cache" swift test -c release -Xswiftc -enable-testing --build-system native \
  --package-path .build/p6g-full-layout/GyoshukuKit --disable-sandbox --cache-path .build/p6g-full-cache
```

Functional bench: **112 successful archive creations / 56 successful entry-order comparisons**, exit 0.
Both modes ran in all 7 formats × all 4 supplied corpora, with and without `--progress`.
The names were read through KaitoKit `ArchiveReader`, not a shell listing. Every comparison matched:
text256.txt / random256.bin = 1 entry each, headers = 10,907 entries, small = 50,551 entries.

- Exact driver run: `python3 .build/p6g-bench-modes.py > .build/p6g-bench-modes.tsv 2> .build/p6g-bench-modes-errors.log`.
  Its source is saved as [2026-09-27-p6g-bench-modes.py](2026-09-27-p6g-bench-modes.py).
  The published copy reads the scratchpad root from the `SP` environment variable in place of the local absolute path.
- Results: [2026-09-27-p6g-bench-modes.tsv](2026-09-27-p6g-bench-modes.tsv); error log empty.
- Corpus: `$SP/corpus`.
- Bench built in Debug with `swift build --package-path .build/p6g-layout/GyoshukuKit/Benchmarks --disable-sandbox --cache-path .build/p6g-cache`
  and the same CLANG_MODULE_CACHE_PATH. Log: `.build/p6g-bench-build.log`.
- The verification executable was built in `.build/p6g-layout/VerifyBench`, depending only on the committed
  sibling KaitoKit export, using the same build flags (`.build/p6g-bench-verifier-build.log`). Its entire body is:

```swift
import Foundation
import KaitoKit
let paths = Array(CommandLine.arguments.dropFirst())
guard paths.count == 2 else { fatalError("expected recursive and items archives") }
let a = try ArchiveReader.open(url: URL(fileURLWithPath: paths[0]))
let b = try ArchiveReader.open(url: URL(fileURLWithPath: paths[1]))
let left = a.entries.map(\.name), right = b.entries.map(\.name)
guard left == right else { fatalError("entry names/order differ: \(paths)") }
print("entries=\(left.count) equal=true")
```

`gyoshuku-bench zip /tmp/p6g-unused.zip /tmp --mode bogus` also rejected the mode with exit 1 before
creating output (`.build/p6g-bench-bad-mode.log`). This and `run.sh --mode bogus` cover both parsers.

Debug focused suite: **177 tests, 15 skipped, 0 failures (0 unexpected), 1,088.661 s, exit 0**.
The 200-sequence 7z differential test passed (534.430 s); the LHA differential used its unchanged default
300 sequences. Both iteration environment variables, as well as scale enable variables, were confirmed unset.
The skipped tests are volume-image cases and opt-in scale/large/Shift-JIS/oracle fixtures; details are in the log.

`swift package --package-path .build/p6g-layout/GyoshukuKit --disable-sandbox --cache-path .build/p6g-cache show-dependencies --format json`
(with the same CLANG_MODULE_CACHE_PATH) confirms the only dependency path is
`.build/p6g-layout/KaitoKit` (`.build/p6g-dependencies.json`). It waited for the Debug suite's SwiftPM lock,
then exited 0. A byte comparison of canonical Sources / Tests against the final full-layout copies found
no differences.

Final full Release suite: **553 tests, 29 skipped, 0 failures (0 unexpected), 727.747 s, exit 0**.
The run started at 2026-09-27 00:29:18.757 and finished at 00:41:26.503 (JST). All 18 new test methods
passed: AdditionProgressTests (6), FinishAdditionsTests (8), RewriterCommitProgressTests (4).
This run used the final source/test snapshot; the earlier Debug focused run preceded the last two
test methods and the additional assertions described above.

Full-suite skips (29 total):

| Reason | Count / cases |
|---|---|
| hdiutil unavailable in sandbox | 11: CompressedTarLifecycleTests FAT32/exFAT; FATVolumeTests, LHAUpdaterOutputModeTests and SevenZipUpdaterOutputModeTests HFS+/FAT32/exFAT |
| Compatibility export unset | 1: `GYOSHUKU_P2_COMPAT_OUTPUT` |
| Opt-in large-input tests unset | 8: `GYOSHUKU_LARGE_TESTS`, `GYOSHUKU_LARGE_TAR_TESTS`, `GYOSHUKU_LHA_LARGE`, `GYOSHUKU_7Z_LARGE`, `GYOSHUKU_TAR_LARGE`, and three `GYOSHUKU_LARGE_ZIP_TESTS` cases |
| Scale/probe fixtures unset | 7: `GYOSHUKU_SCALE_PROBES` / `GYOSHUKU_SCALE_CORPUS`, `GYOSHUKU_P14_ARCHIVES`, `GYOSHUKU_LHA_SCALE_ENTRIES`, `GYOSHUKU_LIVE_NAME_SCALE`, `GYOSHUKU_7Z_SCALE_DIR`, `GYOSHUKU_TAR_SCALE_ENTRIES`, `GYOSHUKU_ZIP_SCALE_ENTRIES` |
| External tar oracle inputs unset | 2: `GYOSHUKU_TAR_GIT_REPO`, `GYOSHUKU_TAR_ORACLE_DIR` |

Acceptance evidence:

| P6-G criterion | Result / evidence |
|---|---|
| AC-G1 | Passed: all writer/editor formats, protocol dispatch, session bounds/thread, zero/symlink behavior and byte identity in AdditionProgressTests |
| AC-G2 | Passed: recursive 17-file / three-level totals and growth after prewalk; nil callback avoids prewalk |
| AC-G3 | Passed: both placements, computed C+A+D / C+D budgets, didCarry/byte identity, hard links and unknown-size gzip in RewriterCommitProgressTests |
| AC-G4 | Passed: seven formats, threads 1/8, encryption variants, pending bounds, original parallel fixture plus 40 MiB / 200 small files, close/repeat behavior, name-check budget and updater strategy identity |
| AC-G5 | Passed: cancellation/custom-error propagation and existing cleanup at add, drain and rewriter carry/drain; KaitoError callback identity also covered |
| AC-G6 | Passed: fallback owner-ID dispatch counts, two zero notifications and false readsAdditionsDuringCommit |
| AC-G7 | Pending orchestrator measurements; no speed acceptance claimed |
| AC-G8 | Passed: public API / TaskLocal diff inspection, no untracked Sources files |
| AC-G9 | Full Release suite passed with the 29 documented skips; design.md and CHANGELOG Unreleased updated |
| AC-G10 | Passed: 112 functional creations and 56 entry-order comparisons; both mode parsers reject an unknown value |

Final working-tree checks: `git diff --check` passed; HEAD remained
`67a22e850ae100e35fe7d76edcd61e9f05f6764d`, with no commit. Changes are confined to Sources, Tests,
Benchmarks, Documentation/design.md, Documentation/verification and CHANGELOG.md. No published
Documentation/releases file changed. Both live sibling checkouts still report an empty `git status --short`.

## Orchestrator-only acceptance

AC-G7 speed thresholds have not been measured here. Run the stipulated B-P6G / final alternating
1+3 release measurements under load averages <4, including all 7 formats × 4 corpora, `--progress`,
and scale probes. Do not interpret the functional debug bench runs as speed acceptance.

Existing probe knobs confirmed by function/class name:

- `TarUpdaterScaleProbeTests`: GYOSHUKU_TAR_SCALE_ENTRIES
- `ZipUpdaterScaleProbeTests`: GYOSHUKU_ZIP_SCALE_ENTRIES
- `LHAUpdaterScaleProbeTests`: GYOSHUKU_LHA_SCALE_ENTRIES (large row: GYOSHUKU_LHA_LARGE)
- `SevenZipUpdaterScaleProbeTests`: GYOSHUKU_7Z_SCALE_DIR / optional GYOSHUKU_7Z_SCALE_CASE
- `CompressedTarScaleProbeTests`: GYOSHUKU_SCALE_PROBES=1 / GYOSHUKU_SCALE_CORPUS
  (P14-specific rows: GYOSHUKU_P14_ARCHIVES, optional GYOSHUKU_P14_ASSERT)

HFS+/FAT32/exFAT disk-image tests use the existing ArchiveTestDisk helper, which catches hdiutil failure
and throws XCTSkip. Real volume acceptance remains with the orchestrator. Step 0-P7 remains a separate
orchestrator gate after S39/S38 commit coordination; this run does not start P7.

## オーケストレータの検証（2026-09-27 01:00–01:30）

作業ツリーを rsync した GyoshukuKit と、KaitoKit 823ad46 の `git archive` を並べた隔離の配置（sandbox 無し、hdiutil あり）。

| 実行 | 結果 |
|---|---|
| `swift build` | 成功 |
| `swift test`（全件） | 553 件、失敗 0、skip 18（すべて環境変数で有効にする大きな書庫・計測・oracle の試験）。hdiutil の実 volume の試験はここで成功 |
| AC-G8 | `git diff -U0 -- Sources` の新しい `public` は §0.5 の宣言（進捗付きの `add(contentsOf:as:ownerIDs:…)`、`finishAdditions(progress:)`、`readsAdditionsDuringCommit`、`commit(progress:…)`、`maximumPendingInputBytes(for:)`）だけ |

AC-G7 の速度の計測は、仕様の「S24 の commit」ではなく S38 の親の 67a22e8（S24 と P14 を含む）を B-P6G にして、この節の後に追記する（P14 が tar.xz の区切りを変えたため）。

## AC-G7 の速度（オーケストレータ、2026-09-27 01:10–04:20）

B-P6G は、仕様の「S24 の commit」ではなく S38 の親 67a22e8（S24 と P14 を含む）。N = b9da4bc。KaitoKit 823ad46。
データは [2026-09-27-p6g-acceptance/](2026-09-27-p6g-acceptance/)。負荷の平均は 1 回目の計測で 4.4〜16.9、測り直しで 3.2〜34（S39・S40 の Codex と並走）。

### 1 回目（`run.sh`、7 形式 × 4 corpus、B と N を交互に 1 + 3 回）

中央値の比 N / B が 1.03 を越えた行: zip small 2.096、zip headers 1.670、tbz text 1.074、tbz random 1.058、lha random 1.059、lha text 1.040、
tar small 1.045、tgz headers 1.040、tgz small 1.032。zip small は B でも 2.49 / 5.01 / 2.45 s と二つの値に分かれ（N は 5.07–5.28 s）、
corpus の順に zip が小さなファイルを最初に読むので、キャッシュの状態の揺れと見た。各回とも B → N の順だった。

### 測り直し（キャッシュを温め、B と N の順を回ごとに入れ替える ABBA × 4、`gyoshuku-bench` を直接）

zip small 1.019、zip headers 1.006、tbz text 1.000、tbz random 1.002、tar small 1.002、tgz small 1.003、tgz headers 1.000。
lha だけは同じ向きに残った: random 1.36 → 1.42–1.44 s（1.048）、text 1.01 → 1.04 s（1.030）。user 時間はほぼ同じ（4.52–4.55 → 4.55–4.60 s）。
thread 数を変えると、1 thread 0.992・1.001、2 thread 1.008・1.027、8 thread 1.043・1.044 で、並列の受け渡しの差だった。
S40（244a9c2）では lha の 8 thread が random 1.36 s（B 1.37–1.38、S38 1.42）、text 1.01 s（B 1.01–1.09、S38 1.03–1.04）に戻った。
S38 の lha の +4.5 % は S38 だけの逸脱として記録し、S40 の commit で解消したので修正はしていない。

### `--progress`（S38 の同じ build で、付けない回と付けた回を ABBA × 4、キャッシュを温める）

text: 7z 1.002、txz 0.986（± 2 % の範囲）。small と headers（≤ 1.25、比を報告する）: lha headers 1.146、tar headers 1.116、tbz small 1.182、
tgz headers **1.252**、tgz small **1.381**、zip headers 1.160、zip small 1.208。tgz の二行が上限を越えた。事前の走査（5 万件の lstat）に加えて、
tgz は細かい読取ごとの進捗の通知の費用が大きい。KaitoFinder の小さなファイルの経路は S40 の一括の追加（`add(_:events:)`）に移るので、
この比は一件ずつの `add(contentsOf:progress:)` の経路の値として報告する。

### scale probe（× 1.05 以下）

1 回目は B の 4 つを流してから N の 4 つを流したので、rewriter の commit が N で 3–15 % 遅く出た。ABBA で採り直すと
tar の commit の 11 行の幾何平均 0.992（1.05 を越える行無し）、lha の 9 行 1.003（無し）、7z の `z_k100/first`・`g_k100/first`（× 2、各 5 回）は
0.989–1.015。zip の scale probe は 1 回目から 0.708–1.057（commit の 7 行のうち 1.05 を越えたのは new_folder 11.4 → 12.1 ms だけ）。
1 回目の rewriter の差は順番の偏りだった。
