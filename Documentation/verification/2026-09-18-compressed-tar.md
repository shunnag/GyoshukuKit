# tar.bz2 / tar.xz のストリーム出力（2026-09-18）

macOS 27.2 / Xcode 27.0 / Apple Silicon。macOS 26・Intelでの実行は未確認。

`ArchiveFormat.tarBzip2` / `.tarXZ`、`WriterOptions.bzip2Level`（1〜9、既定9）を追加した。
既存TarWriterのレコード出力を共通TarCompressorへ渡し、BZip2はmacOSのlibbz2、
XZはApple Compressionの固定設定を使う。製品は外部CLIを起動しない。
元ファイルの変更検知、リンク、取消し、失敗時の出力削除、書き換えの公開境界は既存tarと共通。

- `GYOSHUKU_LARGE_TAR_TESTS=1 swift test`: **202件、失敗0、skip0**。
  初回524.715秒、KaitoKitのSwap追加後の再実行523.278秒。
- 独立ツール: BSD tar、Python bz2/lzma/tarfile、bzip2/xz CLI、7zz。
  全entryのbytes、空書庫、tar block境界、UTF-8名、1/3/37 byte入力、
  大きな最終入力、bzip2全level、cancel、原本変更、atomic rewriteを確認。
- **4 GiB + 513 byte**の実ファイルを両形式で作成し、後続entryも含めて検証。
  SHA-256: `763f370bb3466c282fe66ec8c245f1e830dc105c0677dfbc881824467ef3ec9c`。
  Pythonは全byte比較、bsdtarは一覧、7zzは整合性、KaitoKitは逐次SHAを確認した。
  テストだけ明示的にreader上限を上げる。製品の既定4 GiB上限は変更していない。
- KaitoFinderの8 MiB APFSテストボリュームで容量不足を発生させ、
  書庫SHA・世代・undo・一時ファイルの後始末を確認した。
- KaitoFinder `Tools/benchmark_tar_memory.py` は製品sourceを `swiftc -O` で使い、
  16/64/256 MiBの入力を逐次生成して測定した。固定seedの擬似乱数で、
  XZのピークRSSは101.13／101.14／101.20 MiB、bzip2は14.80／14.53／14.53 MiB。
  最大入力の所要時間はXZ58.84秒、bzip2 14.56秒。生成・SHA計算も時間に含む。

ログ:
`/private/tmp/kaitofinder-compressed-tar-gyoshuku-full.log`、
`/private/tmp/kaitofinder-sevenzip-swap-gyoshuku-full.log`、
`/private/tmp/kaitofinder-compressed-tar-memory.log`。

保存パネルの複合拡張子はKaitoFinder側で実画面の修正・検証中。
エンジンの正常性とアプリの保存確定を区別する。

実装資料は [Apple Compressionの公開API](https://developer.apple.com/documentation/compression) と
[bzip2の公開API文書](https://sourceware.org/bzip2/manual/manual.html)。
第三者compressorの実装ソースは読んでいない。
