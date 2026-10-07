import Foundation

// encoder の source と同じ module でビルドする非 XCTest harness。
enum WriterError: Error { case compression(Int), invalidState, invalidOption(String) }

let args = CommandLine.arguments
if args[1] == "prepare" {
    let directory = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text = TestCorpus.englishLike(size: 8 << 20)
    let dyld = try Data(contentsOf: URL(fileURLWithPath: "/usr/lib/dyld"))
    let zsh = try Data(contentsOf: URL(fileURLWithPath: "/bin/zsh"))
    var mixed = Data()
    // 種類を交互に置き、suffix 探索と小 heap の復元をともに通す。
    let random = TestCorpus.random(1 << 20)
    for offset in stride(from: 0, to: 2 << 20, by: 256 << 10) {
        let zshOffset = offset % ((zsh.count / (256 << 10)) * (256 << 10))
        mixed.append(text[offset..<offset + (256 << 10)])
        mixed.append(dyld[offset..<offset + (256 << 10)])
        mixed.append(zsh[zshOffset..<zshOffset + (256 << 10)])
        mixed.append(random[(offset % random.count)..<(offset % random.count) + (256 << 10)])
    }
    for (name, bytes) in [("text", text), ("dyld", dyld), ("zsh", zsh), ("mixed", mixed),
                           ("empty", Data()), ("one", Data([0xA7])),
                           ("zeros", Data(repeating: 0, count: 65_536))] {
        try bytes.write(to: directory.appendingPathComponent(name + ".bin"))
    }
} else {
    let input = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let variantI = args[3] == "I"
    let order = Int(args[4])!, memory = Int(args[5])! << 20
    let restoration = PPMdRestorationMethod(rawValue: UInt16(args[6])!)!
    let runs = Int(args[7])!, width = Int(args[8])!
    for _ in 0..<runs {
        var result = Data()
        let start = ProcessInfo.processInfo.systemUptime
        let encoder = try PPMdStreamEncoder(order: order, memorySize: memory, variantI: variantI,
            restoration: restoration, header: variantI
                ? PPMd8EncoderProperties(order: order, memorySize: memory, restoration: restoration).header : Data())
        if width == 0 {
            try encoder.write(input, finish: true) { result.append($0) }
        } else {
            for offset in stride(from: 0, to: input.count, by: width) {
                try encoder.write(input[offset..<min(offset + width, input.count)], finish: false) { result.append($0) }
            }
            try encoder.write(Data(), finish: true) { result.append($0) }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("\(result.count)\t\(elapsed)\t\(Double(input.count) / 1_000_000 / elapsed)")
        if args.count > 9 { try result.write(to: URL(fileURLWithPath: args[9])) }
    }
}
