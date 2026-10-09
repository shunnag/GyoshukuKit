import Foundation
import CryptoKit
import Darwin
import Synchronization
import XCTest
@testable import GyoshukuKit

final class BatchAdditionLongPoleTests: XCTestCase {
    private static let limit = 64 << 10
    // 1ae1894の項目・batch API、threads 1/4/16/36で確認した固定出力。
    private static let branchHashes: [String: [Int: String]] = [
        "zip-lzma": [
            0: "69292e8bc873ce26021bdc5596e45b6dd934f0f88e2e9effbd46aeb22393fd80",
            3: "56a0ba2b30f7f3caedd3038db9cf052d9b21dedaca4b24f5ab5b63e4fb85b08b",
            5: "033d9b8dfe66d0895242761eecd102c82b4921201020ad18ae920fd0b37a8248"
        ],
        "zip-ppmd": [
            0: "9a7d1e20e2759fc500f72bab03b58ec11e06f979e365cb9c80152dde14773861",
            3: "130f3b7fec6ada8569d9eef6f0749306e2d10070320b83272d5716bfd0370c25",
            5: "09fd4262fd25aac57bd99242a8fca2f5634a4001787bf61f5f270807f5594cfc"
        ],
        "zip-zstd": [
            0: "929b57c1655831a107dd75d6d06f03bfa75ff54d8b47ede2c68b783596b2fbc2",
            3: "56559a4c3c7089d332f13832c5ab933e36710d11a58d094f47b395161855b82e",
            5: "106a8bf42af5f1e7e3ce06b368dc719ce9f8f9c41d5e135edc98e23cdd7aa15b"
        ],
        "7z-lzma": [
            0: "cee55489b2ae082a572cfa751a1e7afda2cb85efdee73106e646b76b2f8f82ba",
            3: "b59129cea333ba5401b8f833f7596d250639f85a818e44630323f78a88bc271f",
            5: "219f823a96ec62b97d66950b9ebe58b237222db80b2a438cca533f0abb485b28"
        ],
        "7z-ppmd": [
            0: "dc8ee76e696bd3ee74f9d3e9607d987a8fcf9da531f004d626e1470521303b69",
            3: "ef4156e88af7ad68eb6486f88576cfd799d2e4e1c031d4f8c484f73264b75ce0",
            5: "996c1fe37fba737091528acf54a42cf9b451c337ed78ddf33e271b9642d454e6"
        ],
        "7z-bzip2": [
            0: "3239ca2c1918df87c2fa5c5d5109a03afae937bc52cb690a8d0a1fd1f8f9cb8d",
            3: "382a7b72e184ca750eb2ede212cbf3eb507d30241eca5303f9be5f48d14cd56d",
            5: "6c95beb45badb8b09167560da91db4e802475913ec13fe6f8921846fb32963b2"
        ],
        "7z-lzma-solid": [
            0: "1e4bf1a2a5c4d1ef9d74c95664a0bbc737f589848eac6342ef0ca18a01aacba5",
            3: "918af6b698c2f69f01ad4586353ee8b0a2dc266c914e2a7d4a6a1bd42682da23",
            5: "a0ab942561c781fe460a603f0dfbc06f8e84af8c82a1a4a9f9195525a53a6b7f"
        ],
        "7z-ppmd-solid": [
            0: "4f642754042a134dba4540fe50e1ca17991fe2a14e719e4d47dc2b8f73c3eaa6",
            3: "b948de67973e231f3ecbcf662b071c7314084a403ec3a801ec84a6ceddd08dc1",
            5: "df5816d28f4de254880df76891b692c493fb96a4566b060cdb3cdc6ee71d5e13"
        ]
    ]
    private struct Case: Sendable {
        let name: String
        let format: ArchiveFormat
        let options: WriterOptions
    }

    private static var cases: [Case] {
        let zip: [CompressionMethod] = [.lzma, .ppmd, .zstd]
        let seven: [SevenZipCompressionMethod] = [.lzma, .ppmd, .bzip2]
        return zip.map { Case(name: "zip-\($0)", format: .zip,
            options: .init(compressionMethod: $0, ppmdMemoryMiB: 1, lzmaLevel: 0, useCompressionHeuristic: false)) }
            + seven.map { Case(name: "7z-\($0)", format: .sevenZip,
                options: .init(sevenZipMethod: $0, bzip2Level: 1, ppmdMemoryMiB: 1, lzmaLevel: 0)) }
            + [SevenZipCompressionMethod.lzma, .ppmd].map { Case(name: "7z-\($0)-solid", format: .sevenZip,
                options: .init(sevenZipMethod: $0, sevenZipSolid: .on(blockSize: UInt64(limit), filesPerBlock: nil),
                    ppmdMemoryMiB: 1, lzmaLevel: 0)) }
    }

    private func inputs(_ root: URL, largeIndex: Int = 5, multiple: Bool = false, count: Int = 6) throws -> [ArchiveAddition] {
        let pattern = LHATestSupport.random(8192) + Data(repeating: 0x61, count: 8192)
        return try (0..<count).map { index in
            let size = index == largeIndex ? (512 << 10) + 7 : multiple && index == 1 ? (256 << 10) : Self.limit / 2
            var data = Data()
            while data.count < size { data.append(pattern.prefix(min(pattern.count, size - data.count))) }
            let file = root.appendingPathComponent("source-\(index)")
            try data.write(to: file)
            XCTAssertEqual(chmod(file.path, 0o644), 0)
            try AdditionProgressTestSupport.timestamp(file)
            return .init(path: "file-\(index)", source: .contents(of: file))
        }
    }

    // 小さい入力上限で実際のstream経路を通し、先行を無効にした従来batchとも通知列を比較する。
    func testBytesAndEventsMatchItemAndPreviousBatchAllPositionsAndThreadCounts() throws {
        let root = try TestSupport.directory("batch-lpt-identity")
        defer { try? FileManager.default.removeItem(at: root) }
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for c in Self.cases {
                for largeIndex in [0, 3, 5] {
                    let items = try inputs(root, largeIndex: largeIndex)
                    var expected: Data?
                    for threads in [1, 4, 16, 36] {
                        var previousEvents: [ArchiveAdditionEvent] = []
                        for mode in ["item", "previous", "early"] {
                            try BatchAdditionTestSupport.resetDates(items)
                            var options = c.options; options.compressionThreads = threads
                            let output = root.appendingPathComponent("archive")
                            let writer = try ArchiveWriter.create(url: output, format: c.format, options: options)
                            var events: [ArchiveAdditionEvent] = []
                            if mode == "item" { try BatchAdditionTestSupport.singles(writer, items) }
                            else {
                                try ArchiveWriter.$testingDisablesEarlyLongPoles.withValue(mode == "previous") {
                                    try writer.add(items, events: {
                                        events.append($0)
                                        XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: c.format))
                                    })
                                }
                            }
                            XCTAssertLessThanOrEqual(writer.pendingInputBytes, options.maximumPendingInputBytes(for: c.format))
                            try writer.finish()
                            let bytes = try Data(contentsOf: output)
                            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                            XCTAssertEqual(hash, Self.branchHashes[c.name]![largeIndex]!, "\(c.name), t=\(threads), \(mode)")
                            if let expected { XCTAssertEqual(bytes, expected, "\(c.name), large=\(largeIndex), t=\(threads), \(mode)") }
                            else { expected = bytes }
                            if mode == "previous" { previousEvents = events }
                            if mode == "early" { XCTAssertEqual(events, previousEvents, "\(c.name), t=\(threads), large=\(largeIndex)") }
                            try FileManager.default.removeItem(at: output)
                        }
                    }
                }
            }
        }
    }

    func testLargestEncoderStartsBeforeFirstMediumEmissionAndOnlyOneStartsEarly() throws {
        let root = try TestSupport.directory("batch-lpt-start")
        defer { try? FileManager.default.removeItem(at: root) }
        // threads=36でも通常窓に収まらない位置に最大入力を置く。
        let items = try inputs(root, largeIndex: 40, multiple: true, count: 41)
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for c in Self.cases {
                for threads in [4, 16, 36] {
                    let started = DispatchSemaphore(value: 0), starts = Mutex<[Int]>([])
                    var options = c.options; options.compressionThreads = threads
                    let output = root.appendingPathComponent(UUID().uuidString)
                    try FileJob.$testingEncoderStarted.withValue({ index in
                        starts.withLock { $0.append(index) }
                        if index == 40 { started.signal() }
                    }) {
                        // 従来の窓では最後の大項目に着手できない状態を作り、先行開始を決定的に確認する。
                        try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in
                            if index == 0 { XCTAssertEqual(started.wait(timeout: .now() + 5), .success, c.name) }
                        }) {
                            let writer = try ArchiveWriter.create(url: output, format: c.format, options: options)
                            try writer.add(items, events: {
                                if case .didFinish(0) = $0 { XCTAssertEqual(starts.withLock { $0.first }, 40, c.name) }
                            })
                            try writer.finish()
                        }
                    }
                }
            }
        }
    }

    // 項目APIの予約workerが残る場合は先行枠を重ねず、通常の順序付き窓へ戻る。
    func testPreviousItemReservationPreventsAnotherEarlySevenZipJob() throws {
        let root = try TestSupport.directory("batch-lpt-prior-reservation")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root)
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for c in Self.cases where c.format == .sevenZip {
                let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let firstRead = Mutex(true), spools = Mutex(0)
                var options = c.options; options.compressionThreads = 4
                try ScratchFile.$testingCreated.withValue({ _ in spools.withLock { $0 += 1 } }) {
                    try SevenZipWriter.$testingWorkerRead.withValue({ name, _ in
                        if name == "prior-long", firstRead.withLock({ if !$0 { return false }; $0 = false; return true }) {
                            entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success, c.name)
                        }
                    }) {
                        let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: c.format, options: options)
                        for index in 0..<2 {
                            try writer.add(data: Data(repeating: 0x61, count: Self.limit / 2),
                                as: "prior-\(index)", modificationDate: TestSupport.date)
                        }
                        try writer.add(data: Data(repeating: 0x62, count: (512 << 10) + 7),
                            as: "prior-long", modificationDate: TestSupport.date)
                        let beforeBatch = spools.withLock { $0 }
                        try writer.add(items, events: {
                            if case .willStart(0) = $0 {
                                XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, c.name)
                                XCTAssertEqual(spools.withLock { $0 }, beforeBatch, c.name)
                                release.signal()
                            }
                        })
                        try writer.finish()
                    }
                }
            }
        }
    }

    func testEarlyFailureWaitsForEarlierWorkerOrPreparationFailure() throws {
        let root = try TestSupport.directory("batch-lpt-failures")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root)
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for c in Self.cases {
                for earlier in ["none", "read", "prepare"] {
                    let failed = DispatchSemaphore(value: 0)
                    var options = c.options; options.compressionThreads = 4
                    var finished: [Int] = []
                    try FileJob.$testingEncoderStarted.withValue({ index in
                        if index == 5 { failed.signal(); throw WriterError.compression(-81) }
                    }) {
                        try FileJob.$testingBeforeWorkerOpen.withValue({ index, _ in
                            if index == 0 { XCTAssertEqual(failed.wait(timeout: .now() + 5), .success) }
                            if index == 1, earlier == "read" { throw WriterError.compression(-82) }
                        }) {
                            try ArchiveWriter.$testingBeforeLstat.withValue({ index, _ in
                                if index == 1, earlier == "prepare" { throw WriterError.compression(-83) }
                            }) {
                                let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: c.format, options: options)
                                XCTAssertThrowsError(try writer.add(items, events: {
                                    if case let .didFinish(index) = $0 { finished.append(index) }
                                })) {
                                    let failure = $0 as? ArchiveAdditionError
                                    let index = earlier == "none" ? 5 : 1
                                    XCTAssertEqual(failure?.index, index, c.name)
                                    XCTAssertEqual(failure?.sourceURL, items[index].sourceURL)
                                    XCTAssertEqual(failure?.underlying as? WriterError,
                                        .compression(earlier == "none" ? -81 : earlier == "read" ? -82 : -83))
                                }
                            }
                        }
                    }
                    XCTAssertEqual(finished, Array(0..<(earlier == "none" ? 5 : 1)), c.name)
                }
            }
        }
    }

    func testSourceReplacedAfterEarlyCompletionIsChangedAtItsIndex() throws {
        let root = try TestSupport.directory("batch-lpt-replaced")
        defer { try? FileManager.default.removeItem(at: root) }
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for c in Self.cases {
                for phase in ["earlier", "emit"] {
                    let items = try inputs(root), encoded = DispatchSemaphore(value: 0)
                    var options = c.options; options.compressionThreads = 4
                    try FileJob.$testingEncoderFinished.withValue({ if $0 == 5 { encoded.signal() } }) {
                        let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: c.format, options: options)
                        XCTAssertThrowsError(try writer.add(items, events: {
                            let replace: Bool
                            switch $0 {
                            case .didFinish(0): replace = phase == "earlier"
                            case let .progress(5, progress): replace = phase == "emit" && progress.completedBytes == 0
                            default: replace = false
                            }
                            if replace {
                                XCTAssertEqual(encoded.wait(timeout: .now() + 5), .success, c.name)
                                try Data(repeating: 0, count: (512 << 10) + 7).write(to: items[5].sourceURL!, options: .atomic)
                            }
                        })) {
                            XCTAssertEqual(($0 as? ArchiveAdditionError)?.index, 5)
                            XCTAssertEqual(($0 as? ArchiveAdditionError)?.underlying as? WriterError, .sourceChanged(items[5].sourceURL!.path))
                        }
                    }
                }
            }
        }
    }

    func testCallbackFailureBeforeEarlyIndexIsUnwrappedAndJoinsEncoder() throws {
        let root = try TestSupport.directory("batch-lpt-callback")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root)
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for c in Self.cases {
                for phase in ["waiting", "immediate"] {
                    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), descriptors = Mutex(0)
                    let spools = Mutex<[Int32]>([])
                    var options = c.options; options.compressionThreads = 4
                    try ScratchFile.$testingCreated.withValue({ fd in spools.withLock { $0.append(fd) } }) {
                        try FileJob.$testingDescriptorChange.withValue({ delta in descriptors.withLock { $0 += delta } }) {
                            try FileJob.$testingEncoderStarted.withValue({ index in
                                if index == 5 { entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success) }
                            }) {
                                let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: c.format, options: options)
                                XCTAssertThrowsError(try writer.add(items, events: {
                                    if case .willStart(0) = $0 {
                                        if phase == "waiting" { XCTAssertEqual(entered.wait(timeout: .now() + 5), .success) }
                                        release.signal()
                                        throw AdditionProgressTestSupport.Failure.callback
                                    }
                                })) { XCTAssertEqual($0 as? AdditionProgressTestSupport.Failure, .callback) }
                            }
                        }
                    }
                    XCTAssertEqual(descriptors.withLock { $0 }, 0)
                    for fd in spools.withLock({ $0 }) { XCTAssertEqual(fcntl(fd, F_GETFD), -1); XCTAssertEqual(errno, EBADF) }
                }
            }
        }
    }

    func testAliasesAndRecursiveDirectoriesKeepEncoderStartAfterWillStart() throws {
        let root = try TestSupport.directory("batch-lpt-alias")
        defer { try? FileManager.default.removeItem(at: root) }
        try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
            for variant in ["duplicate", "hardlink", "directory"] {
                var items = try inputs(root)
                let source: URL
                if variant == "duplicate" { source = items[5].sourceURL! }
                else if variant == "hardlink" {
                    source = root.appendingPathComponent("alias")
                    try FileManager.default.linkItem(at: items[5].sourceURL!, to: source)
                } else {
                    source = root.appendingPathComponent("recursive")
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                    try Data([1]).write(to: source.appendingPathComponent("child"))
                }
                items.insert(.init(path: "alias", source: .contents(of: source)), at: 1)
                let announced = Mutex(Set<Int>())
                try FileJob.$testingEncoderStarted.withValue({ index in
                    XCTAssertTrue(announced.withLock { $0.contains(index) }, variant)
                }) {
                    let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString),
                        options: .init(compressionMethod: .lzma, lzmaLevel: 0, compressionThreads: 4))
                    try writer.add(items, events: {
                        if case let .willStart(index) = $0 { announced.withLock { _ = $0.insert(index) } }
                    })
                    try writer.finish()
                }
            }
        }
    }

    func testCancellationJoinsEarlyEncoderAndClosesSourceAndSpoolDescriptors() async throws {
        let root = try TestSupport.directory("batch-lpt-cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = try inputs(root)
        for c in Self.cases {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let descriptors = Mutex((current: 0, maximum: 0)), spools = Mutex<[Int32]>([]), firstRead = Mutex(true)
            let task = Task.detached {
                try EntryCompressionConfiguration.$testingInputLimit.withValue(Self.limit) {
                    try FileJob.$testingDescriptorChange.withValue({ delta in
                        descriptors.withLock { $0.current += delta; $0.maximum = max($0.maximum, $0.current) }
                    }) {
                        try ScratchFile.$testingCreated.withValue({ fd in spools.withLock { $0.append(fd) } }) {
                            try FileJob.$testingDuringWorkerRead.withValue({ index, _ in
                                if index == 5, firstRead.withLock({ if !$0 { return false }; $0 = false; return true }) {
                                    entered.signal(); XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                                }
                            }) {
                                var options = c.options; options.compressionThreads = 4
                                let writer = try ArchiveWriter.create(url: root.appendingPathComponent(UUID().uuidString), format: c.format, options: options)
                                try writer.add(items, events: nil)
                            }
                        }
                    }
                }
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, c.name)
            let start = Date()
            task.cancel(); release.signal()
            do { try await task.value; XCTFail("取消しが必要") }
            catch { XCTAssertTrue(error is CancellationError, "\(c.name): \(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), 2)
            XCTAssertEqual(descriptors.withLock { $0.current }, 0)
            XCTAssertLessThanOrEqual(descriptors.withLock { $0.maximum }, 4)
            XCTAssertFalse(spools.withLock { $0.isEmpty })
            for fd in spools.withLock({ $0 }) { XCTAssertEqual(fcntl(fd, F_GETFD), -1); XCTAssertEqual(errno, EBADF) }
        }
    }
}
