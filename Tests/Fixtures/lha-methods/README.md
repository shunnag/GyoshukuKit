# LH5 の既定出力

2026-10-06 に `feature/write-methods-levels` の `06d005dbb4997a8152aac1f77fae02e5d87b58f3` の writer で固定した、既存
`LHAWriterTests` の出力。プロジェクト所有の合成入力（MIT）から作成し、外部実装のコードは含まない。
method / level の追加時に再生成せず、`LHADefaultOutputTests` が書庫全体を byte 比較する。
1 MiB を超える入力は既存 `LHAWriterStreamedMemberIdentityTests` の凍結 SHA-256 でも守る。

| file | 既存の試験 | SHA-256 |
|---|---|---|
| `lh5-edges.lzh` | `testEmptyOneByteDictionarySizedAndLongRunFiles` | `4c9b45010c41a5aea19bd3fad9d2a36c1c89f07a9683edf2b5deafdf4148f301` |
| `lh5-repetitive.lzh` | `testRepetitiveMiBReallyCompresses` | `e71943ce91205473f32e24b1a0a7f0bad90c3f29ed05110fec48c52fca51b40a` |
| `lh5-japanese.lzh` | `testJapaneseNamesAreCP932` | `c41a57ebac7bf422a46869911520e094b6999efef9185c592ba6f3b10e457383` |

固定手順は変更前に `swift test --filter 'LHAWriterTests|LHAWriterStreamedMemberIdentityTests'` を実行し、
`.build/verification/{lha-edges,lha-repetitive,lha-japanese}/archive.lzh` をこの directory へコピーした。
全11試験と Lhasa / 7zz の照合に成功した。
