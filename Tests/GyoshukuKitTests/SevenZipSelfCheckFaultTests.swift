import Foundation
import XCTest
@_spi(SevenZipEditLayout) import KaitoKit
@_spi(Testing) @testable import GyoshukuKit

final class SevenZipSelfCheckFaultTests: XCTestCase {
    func testEveryFaultIsDetectedAndCleaned() throws {
        let root = try TestSupport.directory("7z-faults")
        let simple = try SevenZipEditSupport.source(root)
        let faults: [SevenZipUpdater.Fault] = [.flipMovedPackByte, .flipAppendedPackByte, .flipReencodedPackByte,
            .flipConvertedPackByte, .corruptSerializedName, .dropLastPackFromModel]
        for fault in faults {
            let source = fault == .flipReencodedPackByte ? SevenZipEditSupport.fixture("m") : simple
            let before = try Data(contentsOf: source)
            let work = try TestSupport.work(in: root), output = work.appendingPathComponent("output.7z")
            let updater = try SevenZipUpdater.open(url: source, output: output, options: WriterOptions(password: "new"))
            switch fault {
            case .flipMovedPackByte: try updater.remove(entriesAt: [0])
            case .flipAppendedPackByte: try updater.add(data: Data(repeating: 1, count: 999), as: "addition")
            case .flipReencodedPackByte:
                let reader = try SevenZipEditSupport.reader(source)
                let model = try XCTUnwrap(SevenZipEditModel.read(reader))
                try updater.remove(entriesAt: [model.filesByFolder.first { $0.count > 1 }!.first!])
            case .flipConvertedPackByte: try updater.reencryptExistingEntries(currentPassword: nil)
            default: try updater.rename(entryAt: 0, to: "changed")
            }
            XCTAssertThrowsError(try SevenZipUpdater.$testingFault.withValue(fault) { try updater.commit() }, "\(fault)") { error in
                guard case UpdaterRouteError.outputVerificationFailed(let reason) = error else { return XCTFail("\(fault): \(error)") }
                print("7Z-FAULT \(fault) \(reason)")
                let stage: String
                switch fault {
                case .flipMovedPackByte: stage = "V5" // the shared component's V5 is 7z V2
                case .flipAppendedPackByte, .flipReencodedPackByte: stage = "V3"
                case .flipConvertedPackByte: stage = "V3a"
                case .corruptSerializedName: stage = "V1"
                case .dropLastPackFromModel: stage = "V0"
                }
                XCTAssertTrue(reason.contains(stage), reason)
            }
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
        }
    }
}
