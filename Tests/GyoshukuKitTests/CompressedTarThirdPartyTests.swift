import Foundation
@_spi(TarEditLayout) import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class CompressedTarThirdPartyTests: XCTestCase {
    func testThirdPartyFramingAndMixedBzip2Levels() throws {
        let root = try ZipTestSupport.directory("p3-third-party")
        _ = try CompressedTarTestSupport.fixture(root, .tarGzip)
        let raw = root.appendingPathComponent("input.tar")
        let script = """
        import sys,subprocess,gzip,bz2,lzma,zlib
        b=open(sys.argv[1],'rb').read(); kind=sys.argv[3]
        if kind=='gzip': out=subprocess.check_output(['/usr/bin/gzip','-6c',sys.argv[1]])
        elif kind=='bsdtar':
            subprocess.check_call(['/usr/bin/bsdtar','-czf',sys.argv[2],'@'+sys.argv[1]])
            out=open(sys.argv[2],'rb').read()
        elif kind=='bzip2': out=subprocess.check_output(['/usr/bin/bzip2','-c',sys.argv[1]])
        elif kind=='xz': out=subprocess.check_output(['/opt/homebrew/bin/xz','-c',sys.argv[1]])
        elif kind=='xz-blocks': out=subprocess.check_output(['/opt/homebrew/bin/xz','--check=crc32','--block-size=1MiB','-c',sys.argv[1]])
        elif kind=='bz-streams': out=b''.join(bz2.compress(b[i:i+900000]) for i in range(0,len(b),900000))
        elif kind=='sync':
            c=zlib.compressobj(6,zlib.DEFLATED,31); out=b''
            for i in range(0,len(b),131072): out+=c.compress(b[i:i+131072])+c.flush(zlib.Z_SYNC_FLUSH)
            out+=c.flush(zlib.Z_FINISH)
        elif kind=='gzip-members': out=gzip.compress(b[:len(b)//2])+gzip.compress(b[len(b)//2:])
        elif kind=='xz-padding': out=lzma.compress(b,check=lzma.CHECK_CRC32)+bytes(8)
        open(sys.argv[2],'wb').write(out)
        """
        for kind in ["gzip", "bsdtar", "bzip2", "xz", "xz-blocks", "bz-streams", "sync", "gzip-members", "xz-padding"] {
            let format: GyoshukuKit.ArchiveFormat = kind.hasPrefix("xz") ? .tarXZ : kind.hasPrefix("bz") ? .tarBzip2 : .tarGzip
            let source = root.appendingPathComponent(kind + "." + TarP2Support.suffix(format))
            try ZipTestSupport.run("/usr/bin/python3", ["-c", script, raw.path, source.path, kind], in: root, log: "make-\(kind)")
            let unchanged = root.appendingPathComponent("unchanged-\(kind)." + TarP2Support.suffix(format))
            let copied = try CompressedTarTestSupport.edit(source, format: format, output: unchanged) { _ in }
            XCTAssertEqual(copied.strategy, .unchanged)
            XCTAssertEqual(try Data(contentsOf: unchanged), try Data(contentsOf: source))
            let output = root.appendingPathComponent("out-\(kind)." + TarP2Support.suffix(format))
            let result = try CompressedTarTestSupport.edit(source, format: format, output: output,
                options: .init(bzip2Level: 1)) { try $0.add(data: Data([1,2,3]), as: "added", modificationDate: ZipTestSupport.date, permissions: nil) }
            if ["xz-blocks", "bz-streams", "sync"].contains(kind) {
                guard case .splice = result.strategy else { return XCTFail("\(kind): \(result.strategy)") }
            } else if ["xz", "gzip-members", "xz-padding"].contains(kind) {
                guard case .fullEncode(.framing) = result.strategy else { return XCTFail("\(kind): \(result.strategy)") }
            } else { XCTAssertEqual(result.strategy, .fullEncode(.noReusableChunk)) }
            if kind == "bz-streams" {
                let map = try CompressedTarTestSupport.open(output).tarEditingSnapshot()!.chunkMap!
                if case .bzip2(let map) = map { XCTAssertEqual(Set(map.streams.map(\.level)), [1,9]) }
            }
            try CompressedTarCompatibility.verify(output, format: format)
        }
    }
}

final class CompressedTarCompatibilityTests: XCTestCase {
    func testNewAndOldLayoutsThroughIndependentTools() throws {
        for format in CompressedTarTestSupport.formats {
            for aligned in [false, true] {
                let root = try ZipTestSupport.directory("p3-compat-\(format)-\(aligned)")
                let source = try CompressedTarTestSupport.fixture(root, format, aligned: aligned)
                let output = root.appendingPathComponent("out." + TarP2Support.suffix(format))
                _ = try CompressedTarTestSupport.edit(source, format: format, output: output) {
                    try $0.remove(entriesAt: [2]); try $0.rename(entryAt: 0, to: "renamed");
                    try $0.add(data: Data([5]), as: "added", modificationDate: ZipTestSupport.date, permissions: nil)
                }
                try CompressedTarCompatibility.verify(output, format: format)
            }
        }
    }
}

enum CompressedTarCompatibility {
    static func verify(_ output: URL, format: GyoshukuKit.ArchiveFormat) throws {
        let root = output.deletingLastPathComponent(), label = output.lastPathComponent
        let tool = format == .tarGzip ? "/usr/bin/gzip" : format == .tarBzip2 ? "/usr/bin/bzip2" : "/opt/homebrew/bin/xz"
        try ZipTestSupport.run(tool, ["-t", output.path], in: root, log: label + "-codec")
        try ZipTestSupport.run("/usr/bin/bsdtar", ["-tvf", output.path], in: root, log: label + "-bsd-list")
        try ZipTestSupport.run("/opt/homebrew/bin/7zz", ["t", output.path], in: root, log: label + "-7zz-test")
        let raw = output.appendingPathExtension("decoded.tar")
        let script = """
        import sys,subprocess,tarfile,gzip,bz2,lzma,hashlib
        p,raw,codec=sys.argv[1:]; b=open(p,'rb').read()
        d={'gz':gzip.decompress,'bz':bz2.decompress,'xz':lzma.decompress}[codec](b)
        open(raw,'wb').write(d)
        with tarfile.open(p) as t:
            a=[(i.name,i.size,hashlib.sha256(t.extractfile(i).read()).hexdigest() if i.isfile() else '') for i in t]
        with tarfile.open(raw) as t:
            b=[(i.name,i.size,hashlib.sha256(t.extractfile(i).read()).hexdigest() if i.isfile() else '') for i in t]
        assert a==b
        assert subprocess.check_output(['/usr/bin/bsdtar','-tvf',p])==subprocess.check_output(['/usr/bin/bsdtar','-tvf',raw])
        assert subprocess.check_output(['/usr/bin/bsdtar','-xOf',p])==subprocess.check_output(['/usr/bin/bsdtar','-xOf',raw])
        stream=subprocess.check_output(['/opt/homebrew/bin/7zz','x','-so',p])
        assert stream==d
        listing=subprocess.run(['/opt/homebrew/bin/7zz','l','-si','-ttar'],input=stream,stdout=subprocess.PIPE,check=True).stdout
        assert b'ERROR' not in listing
        print('compatibility',codec,len(a),hashlib.sha256(d).hexdigest())
        """
        try ZipTestSupport.run("/usr/bin/python3", ["-c", script, output.path, raw.path, format == .tarGzip ? "gz" : format == .tarBzip2 ? "bz" : "xz"], in: root, log: label + "-content")
        try FileManager.default.removeItem(at: raw)
    }
}
