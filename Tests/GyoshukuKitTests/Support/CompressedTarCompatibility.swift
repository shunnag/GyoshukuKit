import Foundation
import XCTest
@testable import GyoshukuKit

/// 圧縮 tar の出力を codec の検査、bsdtar、7-Zip、Python の tarfile で読み、展開した tar と一致することを確かめる。
enum CompressedTarCompatibility {
    static func verify(_ output: URL, format: GyoshukuKit.ArchiveFormat) throws {
        let root = output.deletingLastPathComponent(), label = output.lastPathComponent
        let tool = format == .tarGzip ? ReferenceTool.gzip : format == .tarBzip2 ? ReferenceTool.bzip2 : ReferenceTool.xz
        try TestSupport.run(tool, ["-t", output.path], in: root, log: label + "-codec")
        try TestSupport.run(ReferenceTool.bsdtar, ["-tvf", output.path], in: root, log: label + "-bsd-list")
        try TestSupport.run(ReferenceTool.sevenZip, ["t", output.path], in: root, log: label + "-7zz-test")
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
        try TestSupport.run(ReferenceTool.python3, ["-c", script, output.path, raw.path, format == .tarGzip ? "gz" : format == .tarBzip2 ? "bz" : "xz"], in: root, log: label + "-content")
        try FileManager.default.removeItem(at: raw)
    }
}
