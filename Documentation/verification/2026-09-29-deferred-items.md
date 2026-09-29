# 2026-09-29 後回しにしていた整理項目の処理記録（GyoshukuKit）

2026-09-28 のコード品質レビューで見送った項目を、Fable（orchestrator と advisor）と Codex の相談の上で「実施」か「据え置き（理由付き）」に振り分けた記録。
判断基準は「KaitoKit / GyoshukuKit を他の人や AI が使うときに使い勝手が良いのはどちらか」。

## 実施

| 項目 | 内容 | commit |
|---|---|---|
| GK-B F11 | `TarChunkLayout` → `TarChunkCutter` | 4d6a2a6 |
| GK-B F9 | 三つの scratch 型を一つの `ScratchFile`（作成直後に unlink、fd のみ）に | f75ef3f |
| GK-T F18 | 参照ツール欠如は skip ではなく失敗（`ReferenceTool.require` / `optional`） | ce328e8 |
| GK-B F4 (a) | `SevenZipUpdater` の状態を可能な範囲で `private` に（scoping probe） | e7f9725 |
| SPI doc | `ArchiveUpdater.CommitStrategy` の doc を内部名でなく挙動で書く | e7f9725 |
| file 名 | `SourcePrefetchLimiter.swift`・`ZipRebuild+HeaderRewrite.swift`・test の `IOEvents`、`ZipUpdateSource` 別名の削除 | e7f9725 |
| GK-A F7 | `zip16/32/64/zipSet` → `le16/32/64/leSet`（LHA・圧縮 tar も使うため） | a3cc21f |
| GK-B F7 (b) | 形式共通の出力 engine を `Segmented*` に改名し、`CompressedTarSplice*` と語を分ける | a3cc21f |
| GK-B F4 (b) | `SevenZipFolderWorkset` に folder ごとの状態と準備を集める | d93991c |

## 据え置き（理由付きで閉じる）

| 項目 | 理由 | 合意 |
|---|---|---|
| `CompressedTarSpliceDeterminismTests` の 3 class | 形式ごとに `--filter` で選べるようにした意図的な構成で、file の header に明記されている | Fable |
| KaitoFinder `Documentation/pending/specs-2026-09-26/*` の旧名（`ZipUpdateSource`・`SevenZipUpdatePlan` など） | 日付付きの spec は当時の記録として残す | Fable |

## 検証

`swift test` 全量（FATVolumeTests を含む）、`gyoshuku-bench` の出力 size の main との一致、CI（macos-26 / xcode-27）。詳細は PR。
