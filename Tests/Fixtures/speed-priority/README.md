# 速さ優先の既定出力 fixture

`speed2/integrate` の `3b74afb`、速さ優先の実装前にこのMacで生成した17種類の書庫。
`SpeedPriorityDefaultOutputTests.testDefaultMatchesBaseCommit` が通常試験で byte を比較する。
入力は同テストの固定 Data、更新日時は `TestSupport.date`、ZIP の時間帯は Asia/Tokyo、並列数は1。
Apple / 自前 XZ、ZIP Zstandard、7z の非solidと各solid方式、tar.xz / tar.lz、単独XZ / lzipを含む。

fixture は変更後の writer から再生成しない。
