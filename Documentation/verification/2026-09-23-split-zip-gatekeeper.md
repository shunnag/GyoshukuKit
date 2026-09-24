# 分割 ZIP の拒否順と ArchiveRewriter.volumeSet（2026-09-23）

環境: macOS 27.2 / Apple Silicon / Swift 6（`swift test`）。依存の KaitoKit は隣の checkout
（`ArchiveVolumeSet` を含むブランチ）。利用側の設計は KaitoFinder の
`Documentation/pending/2026-09-23-split-archive-deferred-save.md` §6。

## 変更

- `ZipUpdateLayout` の判定順を EOCD の発見 → 曖昧な終端 → **disk 欄と巻内 entry 数** → SFX prefix → 終端後のデータ →
  ZIP64 / 中央ディレクトリの順にした。native 分割 ZIP の最終巻（`n.zip`）は先頭が local header ではないため、
  以前は `editingRefused(.sfxPrefix)` と報告されていた。今は `probe` と `open` の両方が
  `invalidArchive("分割 ZIP は編集できません")` を返す。`UpdateGatekeeper` の case は増やしていない。
- `ArchiveRewriter.volumeSet` は、open 時に内部の KaitoKit reader が連結した分割巻を返す（単一ファイルは nil）。
  `checkUnchanged` は URL 自身のファイルだけを見るので、分割セットを編集する呼出側は自身の記録と照合する。

## 自動検証

`swift test`（全体）: GyoshukuKitTests 245 件実行、skip 1、失敗 0。
追加: 先頭が local header でない最終巻と disk 番号 ≠ 0 の EOCD が split として拒否されること、本物の SFX は従来どおり
`sfxPrefix`、終端後データより split の判定が先であること。3 巻に分けた 7z / tar の `volumeSet` が `lstat` と一致し、
単一ファイルでは nil であること。
