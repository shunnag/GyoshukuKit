# P2-G verification — 2026-09-25–26 JST

Implemented the GyoshukuKit part of P2, including ORDER-P4-P5 §1.1. `TarUpdater`
uses the internal `SplicedArchiveOutput` for output ownership, clone/copy,
relocation, scratch files, synchronization, V5, and cleanup. Tar V2 and shared V5
report to `SplicedArchiveOutput.verificationReadObserver`. G2 and the other
repositories are outside this change. No commit, tag, or release was made.

## Environment and isolation

- GyoshukuKit base: `9fb6ee26f2ba65c63f7b9d40b639811eda14966e` (G1), branch
  `feature/2026-09-24-review`.
- KaitoKit dependency: committed `73c1b9f89978f51e6bdfaebec01b28755f39341b`.
  This was exported with `git archive`, not read from the changing sibling tree.
- Workspace: `/Users/nagash/Github/GyoshukuKit`.
- Isolated root: `/private/tmp/gyoshuku-p2g.HazIgb`. The candidate package is
  `GyoshukuKit/`, next to the exported `KaitoKit/`. All builds and tests below
  used this layout. Live KaitoKit and KaitoFinder were not edited or built.
- Compatibility baseline: a separate export of GyoshukuKit `9fb6ee2` at
  `baseline/GyoshukuKit/`, with the compatibility test harness added. Its
  `baseline/KaitoKit` symlink points to the same committed dependency export.
- Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`), swift-driver
  1.168.6, arm64, macOS 27.2 (26B5091g).
- Native SwiftPM build system, `--disable-sandbox`, explicit writable cache.
  SwiftPM warned that its user configuration/security directories were not
  writable and that `--build-system native` is deprecated. These did not prevent
  the builds. The default Xcode build system was not tested in this task.

The source copy was refreshed with:

```sh
rsync -a --exclude .git --exclude .build --exclude .agents --exclude .codex ./ /private/tmp/gyoshuku-p2g.HazIgb/GyoshukuKit/
```

The variables below abbreviate the exact paths in the commands that follow:

```sh
P2_RUN=/private/tmp/gyoshuku-p2g.HazIgb
P2_SPEC=/private/tmp/claude-501/-Users-nagash-Github-KaitoFinder/3d80b8d3-15ce-4c2d-bf52-2944c9d6e58c/scratchpad
```

## Final validation

| Run / log under `P2_RUN` | Result |
|---|---|
| `build-final.log` | Debug build passed, 0.22 s |
| `full-clean.log` | 399 tests, 0 failures, 8 opt-in skips, 589.056 s; exit 0 |
| `focused-corrected.log` | 30 tests, 0 failures, 0 skips, 1.823 s |
| `release-focused.log` | 8 tests, 0 failures, 0 skips, 13.141 s; includes 300 differential cases |
| `baseline-compat.log` | 1 test, 0 failures; generated 20 baseline files |
| `oracle-large-compat.log`, compatibility test | 1 test, 0 failures, 0.018 s; all 20 files byte-identical to baseline |
| `oracle-large-compat.log`, large-member test | 1 test, 0 failures, 0.282 s; 9 GiB sparse archive |
| `oracle-final.log` | 1 test, 0 failures, 13.647 s; all 18 frozen oracle cases |
| `scale-final.log` | 1 test, 0 failures, 12.601 s; all 100k performance targets met |

Commands (output redirection is included so each result can be located):

```sh
CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift build \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" > "$P2_RUN/build-final.log" 2>&1

GYOSHUKU_TAR_GIT_REPO=/Users/nagash/Github/GyoshukuKit \
GYOSHUKU_P2_COMPAT_OUTPUT="$P2_RUN/full-compat-clean" \
GYOSHUKU_P2_COMPAT_BASELINE="$P2_RUN/baseline-bytes" \
CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" > "$P2_RUN/full-clean.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" \
  --filter 'TarLayoutTests|TarHeaderRewriteTests|TarAppendWriterTests|TarUpdaterTests|TarUpdaterRefusalTests|TarUpdaterOutputModeTests|TarUpdaterVerificationFaultTests|TarUpdaterCancellationTests|SplicedArchiveOutputTests|ArchiveOwnerIDsTests|ArchiveRewriterPlacementTests' \
  > "$P2_RUN/focused-corrected.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" --scratch-path "$P2_RUN/release-build" \
  -c release -Xswiftc -enable-testing \
  --filter 'TarUpdaterDifferentialTests|TarUpdaterInteropTests|TarHeaderRewriteTests|TarUpdaterRefusalTests' \
  > "$P2_RUN/release-focused.log" 2>&1

GYOSHUKU_P2_COMPAT_OUTPUT="$P2_RUN/baseline-bytes" \
CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/baseline/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" -Xswiftc -DP2_G_BASELINE \
  --filter ArchiveWriterP2CompatibilityTests > "$P2_RUN/baseline-compat.log" 2>&1

GYOSHUKU_P2_COMPAT_OUTPUT="$P2_RUN/revised-bytes" \
GYOSHUKU_P2_COMPAT_BASELINE="$P2_RUN/baseline-bytes" \
GYOSHUKU_TAR_ORACLE_DIR="$P2_SPEC/p3val" GYOSHUKU_TAR_LARGE=1 \
CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" --scratch-path "$P2_RUN/release-build" \
  -c release -Xswiftc -enable-testing \
  --filter 'ArchiveWriterP2CompatibilityTests|TarUpdaterOracleTests|TarUpdaterLargeMemberTests' \
  > "$P2_RUN/oracle-large-compat.log" 2>&1

GYOSHUKU_TAR_ORACLE_DIR="$P2_SPEC/p3val" \
CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" --scratch-path "$P2_RUN/release-build" \
  -c release -Xswiftc -enable-testing --filter TarUpdaterOracleTests \
  > "$P2_RUN/oracle-final.log" 2>&1

GYOSHUKU_TAR_SCALE_ENTRIES=100000 \
CLANG_MODULE_CACHE_PATH="$P2_RUN/cache" swift test \
  --package-path "$P2_RUN/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_RUN/cache" --scratch-path "$P2_RUN/release-build" \
  -c release -Xswiftc -enable-testing --filter TarUpdaterScaleProbeTests \
  > "$P2_RUN/scale-final.log" 2>&1
```

The release-focused run preceded the final additions to the interop test (real
`git archive` and a long renamed GNU name). Those additions run in the final
debug suite. The final release scale run rebuilt the final source. No other
build or probe from this task ran alongside the final scale or final full run.

The eight opt-in tests omitted from the ordinary full run are:

| Test | Missing opt-in / separate coverage |
|---|---|
| `CompressedTarWriterTests.testEntryLargerThanFourGiBThroughPublicWriterAndIndependentReaders` | `GYOSHUKU_LARGE_TAR_TESTS`; not run in S11 |
| `TarUpdaterLargeMemberTests.testSparseNineGiBOffsetsAndHardLinkMaterialization` | `GYOSHUKU_TAR_LARGE`; run separately above |
| `TarUpdaterOracleTests.testPrototypeIntendedImages` | `GYOSHUKU_TAR_ORACLE_DIR`; run separately above |
| `TarUpdaterScaleProbeTests.testReleaseScaleTimingsAndIO` | `GYOSHUKU_TAR_SCALE_ENTRIES`; run separately above |
| `ZipReencryptionBoundaryTests.testLarge300MiBPayloadReadsAtMostOneMiB` | `GYOSHUKU_LARGE_ZIP_TESTS`; not run in S11 |
| `ZipReencryptionBoundaryTests.testLargeAESSizeCrossingAndRemoval` | `GYOSHUKU_LARGE_ZIP_TESTS`; not run in S11 |
| `ZipReencryptionBoundaryTests.testLargeConvertedDescriptorCrossesButCarriedDescriptorRefuses` | `GYOSHUKU_LARGE_ZIP_TESTS`; not run in S11 |
| `ZipUpdaterScaleProbeTests.testScale` | `GYOSHUKU_ZIP_SCALE_ENTRIES`; not run in S11 |

## Coverage and independent readers

- The 300 differential cases use fixed seed `0x70a8e122`, 10–300 members,
  GyoshukuKit and Python PAX/GNU producers, independent expected names/content/
  link holders, unchanged-group byte comparisons, and rewriter comparisons.
- Both clone and forced-sequential modes cover operations, reservations before
  and after additions, relocation, no-op, raw paths, root entries, hard links,
  canonical termination, cancellation, progress exceptions/reentrancy, source
  changes, flags, inode-safe cleanup, and output descriptor closure.
- Header tests cover ordered/repeated/empty pax records, GNU/v7, `X`, `L`/`K`,
  sparse 0.0/0.1/1.0, owner fields, signed checksum, octal/base-256, bounded reads,
  and byte equivalence with `TarRecords`. `TarLayout.Unit` is 48 bytes.
- All refusal gates R0–R8/R10 have tests. The isolated R6 walk test exercises a
  legacy-name fixture; public open rejects that fixture earlier through R10.
- The shared-output tests use synthetic plans, without tar headers. They cover
  skipped clone ranges, sequential prewrites, relocation in both modes,
  generated/literal length failures, generated copy, final-patch order relative
  to fsync, scratch cleanup/foreign inode preservation, and exact progress units.
- V1–V5 faults include changed header bytes, a shifted header, truncation, and
  changed copied-body bytes. The updater's total equals observed commit writes
  plus observed V2/V5 reads; additions already written during `add` are excluded.
- The 20-file baseline comparison covers fresh writer output in all seven
  formats, the old rewriter placement/owner options, and ZIP updater output.
  All 20 are byte-identical, including the formats for which AC-G3 permits a
  metadata/content comparison instead.
- `bsdtar` listing/extraction, `/opt/homebrew/bin/7zz t` and `l`, Python tarfile
  metadata/content checks, and KaitoKit were run on the interop fixtures. These
  include BSD xattrs/AppleDouble, Python PAX/GNU/USTAR, a pax header before a GNU
  member, and a real `git archive --format=tar` from `9fb6ee2` with its global
  comment preserved. Hard-link tests also verify extracted content/inodes.
- `/opt/homebrew/bin/gtar` and `gnutar` were absent; no GNU tar result is claimed.
  The standalone prototype `kaito list`/`kaito sha` command-line verification of
  every oracle image was not run; the tests use the committed KaitoKit library.
- The 9 GiB sparse-file probe covers pax/base-256 sizes, edits beyond 4 GiB,
  append, and hard-link materialization, then reads the listing with KaitoKit and
  `bsdtar -tvf`. Clone can retain the all-zero body at its original offset in
  this fixture; the 0.282 s result is not a measurement of copying 9 GiB.

The 18 frozen oracle cases comprise headers (5), small (4), text (3), and mixed
(6). Append and same-length rename match the entire intended file. Other edits
match all member bytes and finish with the required newly generated zero tail.
There is one historical fixture discrepancy: current `tools/splice.py.make_edit`
uses 60 `z` characters for `headers-rename-diff`, while its frozen intended tar
contains 20. The test explicitly asserts that historical name and replays it for
that one case. The initial comparison exposed this mismatch; the corrected run
passes all 18. No oracle file or prototype script was changed.

## Release 100k measurements

APFS clone mode, 100,000 members of 1 KiB each. Each row is one paired sample
against `ArchiveRewriter(.end, .keep)`, not a median or confidence interval.
Commit timings include verification. All corresponding output lengths match:
**0-byte size delta**. Raw timings for open/remove/rename/add/commit and I/O from
all three runs are in [the TSV](2026-09-25-p2g-scale.tsv).

| Operation | Updater open ms | Rewriter open ms | Open delta | Updater commit ms | Rewriter commit ms | Commit reduction | Verification ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| Delete first | 499.358 | 417.033 | +19.74% | 55.240 | 922.925 | 94.01% | 18.289 |
| Delete last | 490.287 | 412.891 | +18.74% | 6.575 | 916.562 | 99.28% | 0.472 |
| Rename, same length | 494.862 | 420.004 | +17.82% | 6.514 | 941.147 | 99.31% | 0.416 |
| Rename, different length | 493.468 | 415.800 | +18.68% | 52.513 | 917.330 | 94.28% | 9.743 |
| Append | 490.306 | 413.428 | +18.60% | 4.248 | 930.400 | 99.54% | 0.061 |
| Replace | 490.962 | 421.185 | +16.57% | 48.939 | 946.782 | 94.83% | 9.687 |

| Operation | Commit writes B | V2/V5 reads B | Final output B | Commit speedup |
|---|---:|---:|---:|---:|
| Delete first | 153600000 | 307197952 | 153600000 | 16.71× |
| Delete last | 1536 | 1024 | 153600000 | 139.40× |
| Rename, same length | 10752 | 1024 | 153610240 | 144.48× |
| Rename, different length | 76810240 | 153600000 | 153610240 | 17.47× |
| Append | 8704 | 1024 | 153610240 | 219.02× |
| Replace | 76808704 | 153598976 | 153610240 | 19.35× |

Append and replace also write 1536 B during `add`, before the commit observer is
installed. Rewriter's zero values in the TSV's copy-engine columns mean it does
not use that observer; it writes the entire output through its ordinary writer.
The speedups measure commit latency, not full-archive streaming throughput for
operations that skip unchanged clone ranges.

Every final open is within +25%. First-delete commit is below 150 ms; last-delete,
same-length rename, and append are each below 20 ms. The initial run exceeded the
open-time limit. Removing temporary field `Data` allocations and byte-iterator
overhead from TarLayout's checksum/number parsing fixed that miss without
removing checks or V5. `scale-100k.log` records the initial run;
`scale-optimized-preliminary.log` records the intervening run (it overlapped a
full suite and is not the final qualification). All three are retained in the TSV.

`/bin/ps -Ao pid=,args=` and `/usr/bin/sample xctest 1 1 -file
/private/tmp/gyoshuku-p2g.HazIgb/scale-sample.txt` were attempted after the initial
miss. Sandbox process-list access was denied, so no sample was captured.
Hardware-model sysctl access was also denied; no hardware model is inferred.

## Earlier runs and corrections

These runs are recorded separately from the final results:

| Log | Result and correction |
|---|---|
| `core-tests.log` | 10 tests, 8 assertions failed in a new hard-link test that incorrectly expected KaitoKit's direct hard-link read to return target content; the test now follows the target chain |
| `full-first.log` | Aborted in a new test using compressed archives without format filename suffixes; fixed the fixture names |
| `full-second.log` | Aborted in a new test passing an entry index where the ZIP extra parser needs a physical offset; fixed the test |
| `full-third.log` | 388 tests, 5 skips, 50 assertions failed in old default-placement/owner expectations; updated only the seven permitted tests listed below |
| `focused-first.log` | 21 tests, 0 failures |
| `focused-second.log` | 28 tests, 0 failures |
| `full-final.log` (earlier run despite its filename) | 397 tests, 8 skips, 1 failure, 587.511 s: existing APFS volume-free-space assertion measured 409600000 B rather than its allowed 16 MiB |
| `focused-final.log` | 161 tests, 4 skips, 18 assertions failed in the new descriptor-closure test because it opened its own result reader before checking descriptors; moved the check before that reader. The existing APFS test passed here (0 B consumed) |
| `focused-corrected.log` | The corrected tests and related checks passed: 30 tests, 0 failures |
| `oracle-large-compat.log` | 3 tests, 1 failure: only the historical oracle-name mismatch described above; compatibility and large-member tests passed |
| `oracle-final.log` | Corrected oracle test passed all 18 cases |

The APFS check observes volume-wide free space; the earlier delta may include
unrelated volume activity or accounting. Its cause was not proven. Neither that
test nor its threshold was changed. Two initial baseline setup attempts used a
wrong relative sibling symlink and attempted a remote package fetch, which
failed. Correcting the symlink and invalidating the cached baseline manifest
resolved this; the successful baseline run used the committed local export.
The final full run passed the APFS assertion with 0 B consumed and finished all
399 tests with no failures. Its 300 differential cases and all 20 compatibility
byte comparisons also passed.

The broad focused selection used for `focused-final.log`, with the same debug
flags above and `GYOSHUKU_TAR_GIT_REPO=/Users/nagash/Github/GyoshukuKit`, was:

```text
TarLayoutTests|TarEditPlanTests|TarHeaderRewriteTests|TarAppendWriterTests|TarUpdater|SplicedArchiveOutputTests|ArchiveRewriterPlacementTests|ArchiveOwnerIDsTests|ArchiveRewriterTests|TarWriterTests|CompressedTarWriterTests|TarChunkLayoutTests|AppleDoubleSidecarEditingTests|ArchiveRewriterCollisionTests|EmptyArchiveTests|ZipUpdaterTests|ZipDeleteRenameTests|ZipUpdaterOutputModeTests|ArchiveFormatPathTests|ZipRenamePrivacyTests
```

## Existing test changes and API audit

Only these seven existing tests changed. Each retains assertions for the old
explicit options and adds assertions for the new defaults:

1. `ArchiveFormatPathTests.testTarRewriterRenamesAndAddsColonAndBackslashNames`
2. `ArchiveRewriterTests.testRemoveRenameAndAddCarryOnlySurvivorsInIndexOrder`
3. `ArchiveRewriterTests.testEncryptedZIPWrongPasswordCleansUp`
4. `ArchiveRewriterTests.testDeinitWithoutCommitRemovesQueuedOutputAndWorkDirectory`
5. `ArchiveRewriterTests.testHardLinkExpandsRemovedTargetInsteadOfAnAddedReplacement`
6. `ArchiveRewriterTests.testOwnerIDsAreDroppedUnlessRequestedForTar`
7. `ZipRenamePrivacyTests.testOldNamesAbsentAfterRenameRemovalAndStagedAddThroughBothEditors`

The public additions are `ArchiveOwnerIDs`, the two ArchiveEditing requirements
and their defaults/implementations, `AdditionPlacement`, `CarriedOwnerIDs`, the
two WriterOptions properties and appended initializer arguments, `TarUpdater`,
and `TarUpdaterError`. The only new SPI is TarUpdater's Testing commit strategy,
last strategy, and `testingDisablesClone`. The shared output/planner, append
writer support, owner/signature writer overloads, and hooks remain internal.

The audit includes untracked source files; its output is in
`/private/tmp/gyoshuku-p2g.HazIgb/api-audit.txt`. The forbidden-output-internals
search in TarUpdater had no matches. No new `@unchecked Sendable` or
`nonisolated(unsafe)` was added. `git diff --check` passed. Status contains only
changes under Sources, Tests, Documentation, and CHANGELOG.md.
All 120 files under Sources/Tests in the isolated package were compared with the
workspace and are byte-identical. HEAD remains `9fb6ee2`.

```sh
git diff -U0 -- Sources | rg '^\+.*\bpublic\b|@_spi'
git ls-files --others --exclude-standard -z Sources | xargs -0 rg -n '\bpublic\b|@_spi'
rg -n 'fclonefileat|ftruncate|\.gyoshuku-append|memcmp' Sources/GyoshukuKit/TarUpdater.swift
git diff --check
git status --short
```

## S11 correction 1 — FAT32 / exFAT (2026-09-26 JST)

Base commit is `efdb651`; it was not amended. This correction changes ownership
checks for files created by GyoshukuKit. FAT32 and exFAT assign an empty file a
temporary high-range inode and assign its first-cluster inode when it receives data.
Truncation to zero can return it to a temporary inode. Retaining the creation-time
inode caused both the false `sourceChanged` error and the failed cleanup.

While an owned descriptor is open, path checks and removal now compare a fresh
`fstat(fd)` with `lstat(path)`. An unlinked descriptor is not an ownership match.
For temporary inode values, `F_GETPATH` and the canonical path must also agree;
temporary IDs alone do not establish ownership.
Closed-descriptor cleanup uses an identity captured after the last write and
rejects temporary identities. The first version recognized only `ino_t.max` and
`ino_t.max - 1`; correction 2 below covers the full fake range. The original
archive's `ZipFileIdentity` and `checkUnchanged` checks are unchanged.

The ownership audit covered every `ArchiveOwnedFile` initializer and exclusive
file creation in Sources:

| Site | Result |
|---|---|
| `SplicedArchiveOutput` sequential output | No creation-time identity is retained. Checks and cleanup use the live descriptor, including after relocation truncates it to zero. The final identity is captured immediately before close, allowing cleanup if the final progress callback throws. |
| `SplicedScratchFile`, including relocation spool | No empty-file identity is retained. Reads duplicate the owned descriptor. Cleanup compares the live descriptor/path before closing and is idempotent. |
| `ArchiveWriter` and tar / 7z / LHA writers | Output-versus-input checks use the current output descriptor. Abort checks/unlinks before truncating, preserving replacement files and invalidating the abandoned inode's other links. Existing internal initializer labels remain compatible; their initial inode arguments are not stored. |
| `ArchiveRewriter` | Holds its own duplicate output descriptor through cleanup, even when its writer has already closed. This also covers ZIP writer failure/discard. The duplicate is closed on success and failure. |
| ZIP updater output and staged snapshot | `ArchiveOwnedFile(url:)` is recorded after a non-empty ZIP has been copied/cloned. ZIP rebuilds terminate with non-empty end records. These sites did not have an empty-file capture and retain their existing checks. |
| Re-encryption / `ZipCryptoSpool` / `LHACompressionSpool` | Re-encryption uses the ZIP output above. The two codec spools are unlinked immediately while open and retain no pathname identity. |
| Rewriter entry buffers | Created in the private work directory, with no stored empty-file inode; cleanup remains owned by that work directory. |
| `ArchiveSourceSnapshot` | Non-empty source/clone identities and original-source checks remain unchanged. Sentinel values are not accepted by closed-file removal. |

The only production `ArchiveOwnedFile(url:descriptor:)` call left is the final
capture in `SplicedArchiveOutput`, after writing and verification.
Clone output descriptors are adopted for cleanup only after they match the
identity recorded for that clone. `ArchiveOwnedFileTests` replaces the clone
between creation and open with both an empty file and a non-empty file, and
checks that failure/discard preserves those replacements.

Added `FATVolumeTests` and the `ArchiveTestDisk` helper. The tests invoke real
`hdiutil create -size 128m -fs "MS-DOS FAT32"` / `-fs ExFAT`, followed by
`hdiutil attach -nobrowse -mountpoint ...`. They use `XCTSkip` if image creation
or attachment is unavailable. An HFS+ image run and a host-volume run use the
same cases. The image tests assert the empty → allocated → empty inode behavior
on FAT32/exFAT, so an incorrect filesystem cannot silently qualify the tests.

Coverage per volume:

- TarUpdater with clone disabled: delete first/last/all, same/different-length
  rename, append, append-then-delete relocation, and unchanged commit. Every
  committed archive is listed and read through KaitoKit; source bytes, inode,
  and mtime remain unchanged and directories contain only source plus output.
- Cancellation during a commit write, discard after the first add, V5 corruption,
  and an exception from the final progress callback. Each failure leaves only
  the source.
- Synthetic SplicedArchiveOutput commits, relocation, generated data from
  scratch, empty/non-empty discard, generated-length failure after relocation,
  scratch reads before/after allocation, and preservation of replaced empty and
  non-empty output/scratch paths.
- All seven public writer formats accept a separate empty disk file while their
  output is still empty. Non-ZIP writers remove abandoned output. Rewriter
  cancellation in both placements and discard cover all seven formats.
- ZIP update with staged additions, re-encryption success, and cancellation at
  verification preserve the source and clean their own output.

Existing tests, including `SplicedArchiveOutputTests` and AC-G10 output-mode tests,
were not edited.

### Commands and results for the correction

All builds/tests used `/private/tmp/gyoshuku-p2g-fat.wL5yRz/GyoshukuKit`, beside
a fresh `git archive 73c1b9f` export at
`/private/tmp/gyoshuku-p2g-fat.wL5yRz/KaitoKit`. Live sibling trees were not edited
or built. No commit was made. Swift/OS and native SwiftPM settings are the same
as recorded above.

| Log in `/private/tmp/gyoshuku-p2g-fat.wL5yRz` | Result |
|---|---|
| `initial-focused.log` | 81 tests, 0 failures, 1 existing opt-in skip, 27.573 s |
| `fat-volume.log` | Initial new-test run: host cases passed; FAT32/exFAT skipped, 3 tests total, 0 failures, 2.132 s |
| `focused-final.log` | 122 tests, 0 failures, 7 skips, 83.426 s |
| `build-final.log` | Debug build passed, 0.22 s |
| `full-final.log` | 403 tests, 0 failures, 11 skips, 578.602 s; includes 300 differential cases and 20 baseline byte matches |
| `ownership-final.log` | Final clone-adoption guard and related ownership tests: 19 tests, 0 failures, 3 image skips, 3.783 s |
| `build-after-ownership.log` | Final debug build passed, 0.55 s |

The full run preceded the last clone-descriptor adoption guard and its new test.
After that change, the final targeted run rebuilt the final source and reran
`ArchiveOwnedFileTests`, every new volume scenario, the unchanged
`SplicedArchiveOutputTests`, and TarUpdater operation/output/cancellation/fault
tests. The full suite was not repeated after this last guard. Its 11 skips were
the eight opt-in tests listed in the original report plus the three image tests.
The existing APFS free-space assertion passed with 0 B consumed. All runs exited
successfully; there were no failing test runs in this correction.

**Real FAT32, exFAT, and HFS+ image execution was unavailable here.** Each
`hdiutil create` attempt failed with exit 1 and “装置が構成されていません” (device
not configured); none reached a successful attach. The three new image tests
therefore skipped. Their complete regression body passed on the host filesystem.
The other four skips in the final focused run were the existing opt-in compressed
tar >4 GiB test and three large ZIP re-encryption tests. No real-image pass is
claimed; the orchestrator can run `--filter FATVolumeTests` on an attach-capable
host without another opt-in variable.

Commands below use `P2_FAT=/private/tmp/gyoshuku-p2g-fat.wL5yRz`:

```sh
git -C /Users/nagash/Github/KaitoKit archive 73c1b9f | tar -x -C "$P2_FAT/KaitoKit"
rsync -a --exclude .git --exclude .build --exclude .agents --exclude .codex ./ "$P2_FAT/GyoshukuKit/"

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift test \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" \
  --filter 'SplicedArchiveOutputTests|TarUpdaterOutputModeTests|TarUpdaterCancellationTests|TarUpdaterVerificationFaultTests|ArchiveRewriterTests|LHALifecycleTests|SevenZipLifecycleTests|TarWriterTests' \
  > "$P2_FAT/initial-focused.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift test \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" --filter FATVolumeTests > "$P2_FAT/fat-volume.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift test \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" \
  --filter 'FATVolumeTests|SplicedArchiveOutputTests|TarUpdaterOutputModeTests|TarUpdaterCancellationTests|TarUpdaterVerificationFaultTests|ArchiveRewriterTests|LHALifecycleTests|SevenZipLifecycleTests|TarWriterTests|ZipUpdaterOutputModeTests|ZipReencryption' \
  > "$P2_FAT/focused-final.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift build \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" > "$P2_FAT/build-final.log" 2>&1

GYOSHUKU_TAR_GIT_REPO=/Users/nagash/Github/GyoshukuKit \
GYOSHUKU_P2_COMPAT_OUTPUT="$P2_FAT/compat-bytes" \
GYOSHUKU_P2_COMPAT_BASELINE=/private/tmp/gyoshuku-p2g.HazIgb/baseline-bytes \
CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift test \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" > "$P2_FAT/full-final.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift test \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" \
  --filter 'ArchiveOwnedFileTests|FATVolumeTests|SplicedArchiveOutputTests|TarUpdaterOutputModeTests|TarUpdaterTests|TarUpdaterCancellationTests|TarUpdaterVerificationFaultTests' \
  > "$P2_FAT/ownership-final.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift build \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" > "$P2_FAT/build-after-ownership.log" 2>&1

rg -n 'ArchiveOwnedFile\(|O_CREAT|outputIdentity|destinationIdentity' Sources/GyoshukuKit
git diff --check
git status --short
```

The correction did not rerun the release scale, prototype oracle, or 9 GiB
opt-in probes; their earlier measurements above belong to the original P2-G run.
Final audit: all 123 Sources/Tests files match the isolated package byte for
byte, existing tests are unchanged, no public/SPI declarations or unsafe
concurrency annotations were added, and `git diff --check` passes. The
`ZipFileIdentity` and `ArchiveSourceSnapshot` definitions were compared against
`efdb651` and are unchanged; only the separate owned-output helper in that file
changed. HEAD remains `efdb651`.

## Orchestrator verification (2026-09-26 JST)

Isolated layout `$SCR/v4/{KaitoKit,GyoshukuKit}`: KaitoKit `73c1b9f` exported with `git archive`, GyoshukuKit
working tree copied with rsync (no `.build`, no `.git`). SwiftPM default build system.

| Run | Result |
|---|---|
| `swift test` (debug, all) | 399 tests, 0 failures, 10 skipped, 467 s. The skips are the eight opt-in tests listed above plus `ArchiveWriterP2CompatibilityTests` (`GYOSHUKU_P2_COMPAT_OUTPUT`) and `TarUpdaterInteropTests.testRealGitArchiveCommentIsPreserved` (`GYOSHUKU_TAR_GIT_REPO`), which were run separately below |
| Baseline bytes: GyoshukuKit `9fb6ee2` (git archive) + this compatibility test, `-DP2_G_BASELINE` | 1 test, 0 failures, 20 files |
| Release, `ArchiveWriterP2CompatibilityTests` against that baseline | pass: all 20 files byte-identical (the old placement/owner options reproduce the pre-P2 rewriter output) |
| Release, `TarUpdaterOracleTests` (`GYOSHUKU_TAR_ORACLE_DIR=$SCR/p3val`) | 18/18 cases; append and same-length rename equal the whole intended file, the others equal all member bytes and end with a fresh zero tail |
| Release, `TarUpdaterLargeMemberTests` (`GYOSHUKU_TAR_LARGE=1`) and both interop tests (real `git archive` of `9fb6ee2`) | pass |
| Independent readers on the 18 oracle outputs | for every output, `bsdtar -tvf` listing and `bsdtar -xOf` content SHA-256 equal the intended image's, `7zz t` reports "Everything is Ok", and Python `tarfile` (name, type, size, uid, gid, linkname, content SHA-256) equals the intended image. GNU tar is not installed; not checked |

Release `TAR-SCALE`, 100,000 × 1 KiB, APFS clone mode (load average 3.8–5.6 because another build was running):

| Operation | Updater open ms | Rewriter open ms | Open delta | Updater commit ms | Rewriter commit ms |
|---|---:|---:|---:|---:|---:|
| Delete first | 516.1 | 418.0 | +23.5 % | 56.8 | 977.7 |
| Delete last | 500.6 | 407.9 | +22.7 % | 9.4 | 943.6 |
| Rename, same length | 485.0 | 407.9 | +18.9 % | 7.4 | 932.9 |
| Rename, different length | 480.8 | 408.6 | +17.7 % | 57.3 | 925.5 |
| Append | 480.8 | 407.9 | +17.9 % | 4.2 | 922.0 |
| Replace | 483.5 | 410.5 | +17.8 % | 52.7 | 924.2 |

All AC-G15 limits hold (open ≤ rewriter + 25 %; first delete ≤ 150 ms; last delete, same-length rename and append ≤ 20 ms).
Write and verification-read byte counts equal Codex's run.

## S11 correction 2 — temporary inode range (2026-09-26 JST)

The orchestrator reported 404 tests with two failures, both FAT32 assertions
that an empty file had an unassigned inode. Its C probes on real images observed
FAT32 empty-file IDs of `UINT64_MAX - 1`, `- 3`, and `- 4` in different directories,
and exFAT IDs of `UINT64_MAX`, `- 1`, and `- 2`. These are a descending counter
of temporary IDs for empty vnodes, not a fixed pair or one shared ID. Those
measurements came from the orchestrator; they were not repeated in this sandbox.

`ArchiveOwnedFile.hasAssignedInode` now rejects every inode at or above `2^63`.
The comment records the descending fake range and the lower real cluster/CNID/
object ID range. This is the only production-code change from correction 1;
descriptor/path checks, foreign-file preservation, and the original-source
checks retain their behavior.

The real-image ownership checks now run at the mount root, `cases/ownership/`,
and `cases/ownership/deeper/`. They assert the numeric fake range without assuming
an exact ID or comparing IDs between distinct empty files. They retain the first
write changing the inode (now writing 4 KiB), truncation returning to the fake
range, rejection of the recorded non-empty identity after truncation, and
preservation of a replacement empty file at the old path while removing only
the moved owned file. Nested directories still receive exact contents checks;
mount-root checks cover the two test paths to allow filesystem management files.
All existing TarUpdater, direct SplicedArchiveOutput/scratch, writer/rewriter,
and ZIP scenarios remain. The new `testAssignedInodeRange` covers both sides
of `2^63` and several high IDs beyond the old two-value predicate even when
image attachment is unavailable.

### Commands and results for correction 2

Reused `/private/tmp/gyoshuku-p2g-fat.wL5yRz/{GyoshukuKit,KaitoKit}`. A read-only
byte comparison against `git -C /Users/nagash/Github/KaitoKit archive 73c1b9f`
confirmed all 1,379 committed KaitoKit files in the isolated export. Its full
commit is `73c1b9f89978f51e6bdfaebec01b28755f39341b`. All 123 GyoshukuKit
Sources/Tests files matched the isolated build/test copy. No live sibling was
built or edited; no commit was made.

Commands below use `P2_FAT=/private/tmp/gyoshuku-p2g-fat.wL5yRz`:

```sh
rsync -a --exclude .git --exclude .build --exclude .agents --exclude .codex ./ "$P2_FAT/GyoshukuKit/"

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift build \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" > "$P2_FAT/correction2-build.log" 2>&1

CLANG_MODULE_CACHE_PATH="$P2_FAT/cache" swift test \
  --package-path "$P2_FAT/GyoshukuKit" --build-system native --disable-sandbox \
  --cache-path "$P2_FAT/cache" \
  --filter 'ArchiveOwnedFileTests|FATVolumeTests|SplicedArchiveOutputTests|TarUpdaterOutputModeTests|TarUpdaterTests|TarUpdaterCancellationTests|TarUpdaterVerificationFaultTests|ArchiveRewriterTests|LHALifecycleTests|SevenZipLifecycleTests|TarWriterTests|ZipUpdaterOutputModeTests|ZipReencryption' \
  > "$P2_FAT/correction2-focused.log" 2>&1

git diff --check
git status --short
```

| Log in `/private/tmp/gyoshuku-p2g-fat.wL5yRz` | Result |
|---|---|
| `correction2-build.log` | Debug build passed, 0.69 s |
| `correction2-focused.log` | 127 tests, 0 failures, 7 skips, 86.560 s |

Both commands exited 0. The new boundary test, host-volume scenarios, and
replacement/cleanup regressions passed. Three skips were the FAT32, exFAT, and
HFS+ image tests: each attempted `hdiutil create -size 128m -fs ... -volname
GYOSHUKU .../volume.dmg`, which exited 1 with “装置が構成されていません” (device
not configured), before attach. No corrected real-image pass is claimed here.
The other four skips were the existing compressed-tar >4 GiB test and three
large ZIP re-encryption tests. The filter also selected `CompressedTarWriterTests`
through `TarWriterTests`; there is no separate `SevenZipLifecycleTests` suite,
while the host-volume cases exercise the 7z writer/rewriter lifecycle.

`git diff --check` passed. Byte comparison with `efdb651` confirmed that
`ZipFileIdentity` and `ArchiveSourceSnapshot` remain unchanged. The full suite
and size/throughput benchmarks were not rerun for this predicate correction;
earlier results above retain their original scope. HEAD remains `efdb651`.

## Orchestrator verification of the FAT / exFAT corrections (2026-09-26 JST)

Found by the orchestrator's KaitoFinder run on hdiutil images: every sequential-mode `TarUpdater` commit on FAT32 / exFAT failed
with `sourceChanged` and left the output behind. Probe facts (C program on fresh images): an empty file created with
`O_CREAT|O_EXCL` gets a fake inode from a decreasing counter at the top of the range (UINT64_MAX, UINT64_MAX-1, … -4 observed, one
per empty file; `ftruncate(0)` hands out a new one), and the first write replaces it with the cluster number. fstat and lstat agree
at every moment.

Isolated layout `$SCR/v4`: this working tree next to KaitoKit `d35f2da` (git archive). Host with working hdiutil.

| Run | Result |
|---|---|
| `swift test` after correction 1 | 404 tests, 2 failures (`FATVolumeTests.testFAT32` assumed fixed fake values), 10 skipped |
| `swift test` after correction 2 | 405 tests, 0 failures, 10 skipped (opt-in); `FATVolumeTests` FAT32 / exFAT / HFS+ / host all pass on real images |
| Standalone probe (open → remove [→ add] → commit) on fresh FAT32 and exFAT images | both commits succeed with strategy `sequential`; only the original and the committed outputs remain |
| KaitoFinder `TarUpdateEditTests` (FAT32 / exFAT / HFS+ edits match APFS) against this tree | pass |
