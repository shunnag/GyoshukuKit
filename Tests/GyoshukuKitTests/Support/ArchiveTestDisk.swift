import Foundation
import Darwin
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
        // hdiutil detach は CI で一時的に "No such file or directory" で失敗することがある（2026-10-08 job 113264557496）。再試行し、既に外れていれば成功とする。
        for attempt in 1...3 {
            do {
                try Self.command(["detach", "-force", mount.path])
                attached = false
                return
            } catch {
                var mountInfo = stat(), directoryInfo = stat()
                let mountStatus = stat(mount.path, &mountInfo)
                if mountStatus != 0 && errno == ENOENT {
                    attached = false
                    return
                }
                if mountStatus == 0 && stat(directory.path, &directoryInfo) == 0
                    && mountInfo.st_dev == directoryInfo.st_dev {
                    attached = false
                    return
                }
                if attempt == 3 { throw error }
                Thread.sleep(forTimeInterval: Double(attempt))
            }
        }
    }

    deinit {
        // detach に失敗した mount の中を再帰削除しない。
        do { try detach(); try FileManager.default.removeItem(at: directory) } catch {}
    }
}
