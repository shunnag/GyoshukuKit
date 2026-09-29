import Foundation
import KaitoKit
import XCTest
@_spi(Testing) @testable import GyoshukuKit

final class ZipRebuildEquivalenceTests: XCTestCase {
    func testSmallCorpusMatrixMatchesLegacyBytes() throws {
        let directory = try TestSupport.directory("p1-equivalence")
        defer { try? FileManager.default.removeItem(at: directory) }
        var corpus: [URL] = []
        for (label, options, size) in [
            ("stored", WriterOptions(compressionMethod: .stored), 256),
            ("deflate", WriterOptions(compressionMethod: .deflate), 256),
            ("zipcrypto", WriterOptions(password: "pass", zipEncryption: .zipCrypto), 256),
            ("ae1", WriterOptions(password: "pass"), 7),
            ("ae2", WriterOptions(password: "pass"), 256)
        ] { corpus.append(try ZipEditTestSupport.fixture(directory, name: label + ".zip", payloadSize: size, options: options)) }
        for variant in ["plain", "redundant", "sentinel", "marker", "order", "gap", "tailgap", "padding", "unicode", "cdname"] {
            corpus.append(try ZipP1Corpus.crafted(directory, variant: variant))
        }
        corpus.append(try ZipP1Corpus.forceZIP64(directory))
        corpus += try ZipP1Corpus.external(directory)
        for source in corpus {
            let reader = try ArchiveReader.open(url: source, options: ArchiveUpdater.readerOptions)
            let count = reader.entries.count
            if source.lastPathComponent == "infozip-unicode.zip" {
                let input = try ArchiveFileSource(url: source), layout = try ZipUpdateLayout(source: input)
                let validated = try ZipCentralDirectory.validate(source: input, reader: reader,
                    centralOffset: layout.centralOffset, centralSize: layout.centralSize)
                XCTAssertTrue(try validated.records.contains { record in
                    try ZipRebuild.extraFields(ZipRebuild.CentralHeader(bytes: validated.bytes, range: record.centralRange).extra)
                        .contains { $0.id == 0x7075 }
                }, "Info-ZIP corpus must exercise Unicode Path extra")
            }
            if source.lastPathComponent == "ditto.zip" {
                XCTAssertTrue(try reader.entries.contains { try reader.rawRecord(of: $0)?.formatSpecific["hasDataDescriptor"] == "true" })
            }
            let file = try XCTUnwrap(reader.entries.first { $0.kind == .file })
            let same = String(repeating: "n", count: file.rawName.bytes.count)
            var operations: [[ZipEditTestSupport.Operation]] = [
                [.remove([0])], [.remove([count / 2])], [.remove([count - 1])],
                [.remove([0, count - 1])], [.remove(Array(0..<count))],
                [.rename(file.index, same)], [.rename(file.index, "x")],
                [.rename(file.index, "much-longer-renamed-path.txt")], [.rename(file.index, "改名後の日本語.txt")],
                [.remove([count - 1]), .rename(file.index, "renamed.txt")],
                [.remove([0]), .add("added.txt", Data([1, 2, 3]))],
                [.add("added.txt", Data([1, 2, 3])), .remove([0])],
                [.remove([0]), .add("added.txt", Data([1, 2, 3])), .remove([count - 1])],
                [.add("added.txt", Data([1, 2, 3])), .remove([0]), .add("second.txt", Data([4]))]
            ]
            if let folder = reader.entries.first(where: { $0.kind == .directory }),
               let child = reader.entries.first(where: { $0.name.hasPrefix(folder.name) && $0.index != folder.index }) {
                operations.append([.rename(folder.index, "changed/"), .rename(child.index, "changed/file.txt")])
            }
            for (index, ops) in operations.enumerated() {
                let output = try ZipEditTestSupport.compare(source, operations: ops, label: "\(source.deletingPathExtension().lastPathComponent)-\(index)")
                try FileManager.default.removeItem(at: output)
            }
            TestSupport.report("ZIP-ORACLE \(source.lastPathComponent): \(operations.count) byte-identical edits")
        }
    }

    func testMixedStoredDeflateAESZipCryptoAndFixedDirectory() throws {
        let directory = try TestSupport.directory("p1-equivalence-additions")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipEditTestSupport.fixture(directory)
        let disk = directory.appendingPathComponent("fixed-directory")
        let operations: [ZipEditTestSupport.Operation] = [.remove([0]), .rename(1, "renamed.txt"),
            .add("tiny.txt", Data([1, 2, 3])), .add("large.txt", Data(repeating: 42, count: 4096)), .directory("added-dir/", disk)]
        let variants = [WriterOptions(compressionMethod: .stored), WriterOptions(compressionMethod: .deflate),
                        WriterOptions(password: "pass"), WriterOptions(password: "pass", zipEncryption: .zipCrypto)]
        for (index, options) in variants.enumerated() {
            try ZipEditTestSupport.compare(source, operations: operations, label: "append-\(index)", options: options,
                expectedStrategy: .rebuildThenAppend, byteIdentical: options.password == nil || options.zipEncryption != .zipCrypto)
        }
    }

    func testZIP64CountCorpusMatchesLegacy() throws {
        let directory = try TestSupport.directory("p1-equivalence-count64")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipEditTestSupport.fixture(directory, count: 65_536, payloadSize: 0)
        try ZipEditTestSupport.compare(source, operations: [.remove([0, 1, 65_535])], label: "down")
        try ZipEditTestSupport.compare(source, operations: [.rename(0, "entry-999999.txt"), .add("added", Data([1]))], label: "mixed")
    }

    func testSparse4GiBUpAndDownMixedMatchesLegacyInChunks() throws {
        let directory = try TestSupport.directory("p1-equivalence-offset64")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try ZipP1Corpus.sparse(directory)
        let up = try ZipEditTestSupport.compare(source, operations: [.rename(0, "longer-first-name"), .add("added", Data([1]))],
                                         label: "up", expectedStrategy: .rebuildThenAppend)
        try ZipEditTestSupport.compare(up, operations: [.add("second", Data([2])), .remove([0])],
                                label: "down", expectedStrategy: .stagedRebuild)
    }
}

enum ZipP1Corpus {
    static func crafted(_ directory: URL, variant: String) throws -> URL {
        let url = directory.appendingPathComponent("crafted-\(variant).zip")
        let script = #"""
        import struct,zlib,sys
        p=lambda f,*v:struct.pack('<'+f,*v)
        kind=sys.argv[2]; records=b''; cds=[]
        names=[b'first.txt',b'middle.txt',b'last.txt',b'folder/',b'folder/file.txt']
        for i,name in enumerate(names):
            data=b'' if name.endswith(b'/') else bytes([i])*96
            crc=zlib.crc32(data); off=len(records); flags=0x800; wide=kind=='marker'
            ts=p('HHBI',0x5455,5,1,1700000001); lx=ts; cx=ts; cn=name
            if kind=='unicode':
                unicode=p('BI',1,zlib.crc32(name))+name
                lx+=p('HH',0x7075,len(unicode))+unicode; cx=lx
            if kind=='padding': lx+=b'\0\0'; cx+=b'\0\0'
            if kind=='cdname' and i==0: cn=b'first-central.txt'
            if kind in ['redundant','sentinel','marker']:
                cx=p('HHQQ',1,16,len(data),len(data))+cx
            if wide: flags|=8
            local=p('IHHHHHIIIHH',0x04034b50,20,flags,0,0,0x21,0 if wide else crc,
                    0 if wide else len(data),0 if wide else len(data),len(name),len(lx))+name+lx+data
            if wide: local+=p('IIQQ',0x08074b50,crc,len(data),len(data))
            records+=local
            if kind=='gap' and i==0: records+=b'gap-do-not-copy'*7
            size=0xffffffff if kind=='sentinel' else len(data)
            comment=b'comment\0padding' if kind=='padding' else b''
            cds.append(p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,45 if wide else 20,flags,0,0,0x21,
                crc,size,size,len(cn),len(cx),len(comment),0,0,(0o40755 if name.endswith(b'/') else 0o100644)<<16,off)+cn+cx+comment)
        if kind=='order': cds=[cds[2],cds[0],cds[1],cds[3],cds[4]]
        if kind=='tailgap': records+=b'last gap'
        cd=b''.join(cds); comment=b'archive\0comment' if kind=='padding' else b''
        open(sys.argv[1],'wb').write(records+cd+p('IHHHHIIH',0x06054b50,0,0,5,5,len(cd),len(records),len(comment))+comment)
        """#
        try TestSupport.run(ReferenceTool.python3, ["-c", script, url.path, variant], in: directory, log: "make-\(variant)")
        return url
    }

    static func forceZIP64(_ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("python-force64.zip")
        let script = #"""
        import io,zipfile,sys
        class NonSeekable(io.BytesIO):
            def seekable(self): return False
            def seek(self,*args): raise io.UnsupportedOperation()
        sink=NonSeekable()
        with zipfile.ZipFile(sink,'w',compression=zipfile.ZIP_DEFLATED) as z:
            for name in ['first.txt','middle.txt','last.txt','folder/','folder/file.txt']:
                info=zipfile.ZipInfo(name,(2023,11,14,22,13,20)); info.compress_type=zipfile.ZIP_DEFLATED
                with z.open(info,'w',force_zip64=True) as f: f.write(b'' if name.endswith('/') else b'payload'*11)
        open(sys.argv[1],'wb').write(sink.getvalue())
        """#
        try TestSupport.run(ReferenceTool.python3, ["-c", script, url.path], in: directory, log: "make-force64")
        return url
    }

    static func external(_ directory: URL) throws -> [URL] {
        let script = #"""
        import os,subprocess,sys,struct,zlib
        root=sys.argv[1]; disk=os.path.join(root,'external-input'); os.makedirs(os.path.join(disk,'folder'))
        for name in ['first.txt','middle.txt','last.txt','folder/file.txt','日本語.txt']:
            with open(os.path.join(disk,name),'wb') as f: f.write(b'payload'*11)
        subprocess.run(['/usr/bin/zip','-q',os.path.join(root,'infozip.zip'),'first.txt','middle.txt','last.txt','folder/','folder/file.txt','日本語.txt'],cwd=disk,check=True)
        subprocess.run(['/usr/bin/ditto','-c','-k','--norsrc',disk,os.path.join(root,'ditto.zip')],check=True)
        # Apple の zip は Unicode support 無しの build もある。生成物を保ち、7075 を足した対照 corpus も作る。
        raw=open(os.path.join(root,'infozip.zip'),'rb').read(); end=raw.rfind(b'PK\x05\x06'); cd=struct.unpack_from('<I',raw,end+16)[0]
        entries=[]; cursor=cd
        while cursor<end:
            n,e,c=struct.unpack_from('<HHH',raw,cursor+28); off=struct.unpack_from('<I',raw,cursor+42)[0]
            entries.append((off,raw[cursor:cursor+46+n+e+c])); cursor+=46+n+e+c
        records=b''; central=[]
        for i,(off,header) in enumerate(entries):
            nextoff=entries[i+1][0] if i+1<len(entries) else cd
            local=raw[off:nextoff]; n,e=struct.unpack_from('<HH',local,26); name=local[30:30+n]
            body=struct.pack('<BI',1,zlib.crc32(name))+name; extra=struct.pack('<HH',0x7075,len(body))+body
            lf=bytearray(local[:30]); struct.pack_into('<H',lf,28,e+len(extra)); newoff=len(records)
            records+=lf+local[30:30+n+e]+extra+local[30+n+e:]
            cn,ce=struct.unpack_from('<HH',header,28); cf=bytearray(header[:46])
            struct.pack_into('<H',cf,30,ce+len(extra)); struct.pack_into('<I',cf,42,newoff)
            central.append(cf+header[46:46+cn+ce]+extra+header[46+cn+ce:])
        directory=b''.join(central); ending=bytearray(raw[end:]); struct.pack_into('<II',ending,12,len(directory),len(records))
        open(os.path.join(root,'infozip-unicode.zip'),'wb').write(records+directory+ending)
        """#
        try TestSupport.run(ReferenceTool.python3, ["-c", script, directory.path], in: directory, log: "make-external")
        return [directory.appendingPathComponent("infozip.zip"), directory.appendingPathComponent("infozip-unicode.zip"),
                directory.appendingPathComponent("ditto.zip")]
    }

    static func sparse(_ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("sparse.zip")
        let script = #"""
        import struct,sys,zlib
        p=lambda f,*v:struct.pack('<'+f,*v)
        offset=0xffffffff-4; size=offset-31; crc=0; remaining=size; zeros=b'\0'*(1024*1024)
        while remaining:
            n=min(remaining,len(zeros)); crc=zlib.crc32(zeros[:n],crc); remaining-=n
        def local(name,n): return p('IHHHHHIIIHH',0x04034b50,20,0x800,0,0,0x21,crc if n else 0,n,n,len(name),0)+name
        def cd(name,n,off): return p('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0x800,0,0,0x21,crc if n else 0,n,n,len(name),0,0,0,0,0o100644<<16,off)+name
        with open(sys.argv[1],'wb') as f:
            f.write(local(b'x',size)); f.seek(offset); f.write(local(b'tail.txt',0)); central=f.tell()
            records=cd(b'x',size,0)+cd(b'tail.txt',0,offset); f.write(records); end64=f.tell()
            f.write(p('IQHHIIQQQQ',0x06064b50,44,0x033f,45,0,0,2,2,len(records),central))
            f.write(p('IIQI',0x07064b50,0,end64,1)); f.write(p('IHHHHIIH',0x06054b50,0,0,2,2,len(records),0xffffffff,0))
        """#
        try TestSupport.run(ReferenceTool.python3, ["-c", script, url.path], in: directory, log: "make-sparse")
        return url
    }
}
