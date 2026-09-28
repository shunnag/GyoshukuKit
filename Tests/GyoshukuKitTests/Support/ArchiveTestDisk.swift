import Foundation
import XCTest

final class ArchiveTestDisk {
    private let directory: URL
    let mount: URL
    private var attached = false

    init(_ fileSystem: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gyoshuku-disk-" + UUID().uuidString)
        mount = directory.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("volume.dmg")
        do {
            try Self.command(["create", "-size", "128m", "-fs", fileSystem, "-volname", "GYOSHUKU", image.path])
            try Self.command(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
            attached = true
        } catch {
            try? Self.command(["detach", "-force", mount.path])
            try? FileManager.default.removeItem(at: directory)
            throw XCTSkip("hdiutil \(fileSystem) image unavailable: \(error)")
        }
    }

    private static func command(_ arguments: [String]) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ReferenceTool.hdiutil)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "hdiutil", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "\(arguments.first ?? ""): \(String(decoding: bytes, as: UTF8.self))"
            ])
        }
    }

    func detach() throws {
        guard attached else { return }
        try Self.command(["detach", "-force", mount.path])
        attached = false
    }

    deinit {
        // detach に失敗した mount の中を再帰削除しない。
        do { try detach(); try FileManager.default.removeItem(at: directory) } catch {}
    }
}
