# 全形式の空書庫とリリース前検証（2026-09-17）

環境: macOS 27.0 arm64、Xcode 27。既存の編集予約・大規模パスの変更を含む作業ツリーを検証した。
開始2026-09-17、追加検証2026-09-18。

`EmptyArchiveTests` は ZIP / tar / tar.gz / 7z / LHA について、項目なしの finish、
読み取りと reopen、全項目削除から commit、空になった書庫への再追加を検査する。
writer は既に正しい空 LHA の終端 byte を出していたが、KaitoKit の形式検出が拒否していた。
KaitoKit 側で名前 hint を伴う1 byteの空 LHA を受理し、両テストを成功させた。
KaitoFinder でも全削除・undo・redo・再追加を関連44テストで確認している。

lhasa は空 LHA の list/test を成功とするが、7-Zip 26.03 は拒否する。
この違いは失敗を隠して成功扱いせず、独立ツールの互換性の限界として記録する。

`swift test` は **188件、失敗・skipとも0**。
4 GiB境界、65,536項目、暗号化、パス予約、source変更、取消し、atomic commit、
7zz/unzip/ditto/tar/lhasa 等での照合を含む既存全件も実行した。
ログ: `/private/tmp/kaitofinder-release-gyoshuku-final.log`。
空書庫の修正前と修正後は `...-empty-writers-before.log` / `...-empty-writers-after.log`。

## LHAのメモリ改善

全member保持を測定し、256 MiB random入力が1,219,788,800 bytesのpeak RSSとなることを確認した。
LHAWriterを1 MiBの入力と8 KiBの辞書履歴に分け、同じbit writerを継続する構成へ変更。
raw fallbackは未完成出力、圧縮候補はmode0600・直後unlinkのspoolへ置き、入力全体をメモリに保持しない。
各入力の一部として履歴を持たせ、履歴は再出力せずmatchの検索だけに使う。
容量不足・取消し・入力変更はArchiveWriterの既存abort経路へ伝播し、元の書庫はatomic publishまで保持する。

追加の `LHABoundedWriterTests` 4件は、1 MiBの前後・stored fallback・後続member・短いread・
入力途中の失敗・同じinodeのhardlink無効化・取消しを検査する。lhasaと7zzで内容・CRCを確認。
既存LHA/encoder/空書庫と合わせ23件、skip・失敗0。KaitoFinderでは8 MiB APFS volumeへの
32 MiB追加でENOSPCを発生させ、原本byte・undo・世代・cleanupを関連45件で検証した。

`KaitoFinder/Tools/benchmark_lha_memory.py --max-rss-mib 96` は製品の実sourceを `swiftc -O` で測定する。
driverは小さいread要求に応じて入力を作り、全体を保持しない。各サイズ/パターンを別プロセスで実行し、
出力をlhasaのtestに渡す。256 MiB randomはpeak RSS **15,040,512 bytes**、約4.02秒
（旧約4.05秒）、storedの書庫サイズは旧と同一。16/64 MiBも約14 MiBの範囲だった。
repeat 256 MiBは約8.55 MiB、書庫サイズ4,372→2,238 bytes。
旧sourceは96 MiBゲートに失敗し、新sourceは16/64/256 MiB×2パターンで成功した。
メモリ削減の代わりに作業用ディスクはraw bytesと圧縮候補を保持する。アプリ全体のRSSの主張ではない。

ログ: `/private/tmp/kaitofinder-release-lha-streaming-final.log`、`...-lha-document-final.log`、
`...-lha-memory.log`（旧）、`...-lha-memory-final.log`（新）、`...-lha-memory-gate-before.log`。
LHA変更後の全件再実行も **192件、skip・失敗0**（約317秒）。
ログ: `/private/tmp/kaitofinder-release-gyoshuku-final-streaming.log`。

追加4回帰テストはASan/UBSanでも全件成功し、診断0。
SwiftPM helperはASanの遅いロードで起動できなかったため、同じtest bundleを
ASan runtimeの `DYLD_INSERT_LIBRARIES` を設定した `xctest -XCTest GyoshukuKitTests.LHABoundedWriterTests`
で直接実行した。ログ: `/private/tmp/kaitofinder-release-lha-asan-run.log`。
出力形式の追加計画は KaitoFinder の `Documentation/compression-roadmap.md` を参照。

## アプリ側の最終接続確認（2026-09-18）

Macのロック解除後、最終コードを組み込んだKaitoFinder全758件は失敗0。
通常の全件実行でskipする履歴の1件は、別プロセスの4回の起動で成功した。
実ドラッグ・タブ・置換・保存パネル・更新設定を含むUI結合53件も失敗・skip 0。
署名済みReleaseの起動も確認済み。詳細はKaitoFinderの
`Documentation/verification/2026-09-17-release-hardening.md`に記録する。
