import Foundation
internal import KaitoKit

enum EditingReaderOptions {
    static func make(limits: ReadLimits? = nil, expansion: ArchiveExpansionLimit? = nil, password: String? = nil) -> ReaderOptions {
        var options = ReaderOptions(
            limits: limits ?? ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max),
            password: password,
            appleDoublePolicy: .expose
        )
        options.expansionLimit = expansion
        return options
    }
}
