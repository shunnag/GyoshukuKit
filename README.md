# GyoshukuKit (凝縮Kit)

GyoshukuKit は macOS 向けの純 Swift 書庫**書き込み**フレームワークです。
読み取り専用の [KaitoKit](https://github.com/shunnag/KaitoKit)(解凍Kit)と対を
なし、書庫の作成と、既存書庫への追加・削除・改名を担います。

- 対象: macOS 26 以上、Swift 6、Apple Silicon
- 外部依存: なし。zlib、libbz2、Apple Compression など OS 同梱のものだけを
  サポートされた形で使用
- ライセンス: MIT

対応予定の形式は **ZIP → tar → 7z → LHA/LZH** の順です。RAR は license が
明示的に禁じているため作成しません。

## 状態

設計段階。実装はこれから。[設計書](Documentation/design.md)。

> **GyoshukuKit (凝縮Kit)** is a pure-Swift archive **writing** framework for
> macOS, the counterpart to the read-only
> [KaitoKit](https://github.com/shunnag/KaitoKit) (解凍Kit, the extraction kit).
> It creates archives and adds to, deletes from and renames within existing ones.
>
> Requires macOS 26 or later, Swift 6, Apple Silicon. No external dependencies —
> only OS-bundled zlib, libbz2 and Apple Compression through supported APIs. MIT
> licensed. Formats are planned in the order ZIP, tar, 7z, LHA/LZH; RAR is never
> written, because its licence explicitly forbids it.
>
> Currently at the design stage — see the [design document](Documentation/design.md).
