# LHA updater fixtures

Copied from KaitoKit commit `ef06e22`, `Tests/Fixtures/lha-raw-layout/` (P4-K).
The unchanged manifest describes the original archives, synthetic construction,
decoded byte lengths and SHA-256 hashes. The tests check those hashes before use.
The manifest's golden JSON and tool references describe the upstream provenance;
they are not dependencies of these tests and are not duplicated here.

`level1-large-packed.header.b64` contains only a header. The test materializes its
logical size as a sparse file to check the UInt32 packed-size refusal without
allocating or reading a 4 GiB payload. Other base64 files contain complete archives.

The independent Swift builder is `Support/LHAUpdateSupport.swift`. It creates
level 0/1/2/3 headers without calling the production header writer.
