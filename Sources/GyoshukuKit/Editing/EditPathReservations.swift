import Foundation

/// 比較用のパスを数える。元レコードの同名・正準等価も、片方の削除で空きにしない。
/// 成分ごとの木にし、深いパスでもすべての接頭辞文字列を複製しない。
final class EditPathReservations {
    private struct Node {
        var children: [String: Int] = [:]
        var entries = 0
        var files = 0
        var total = 0
    }
    private var nodes = [Node()]
    private var unused: [Int] = []

    init(_ paths: [(String, Bool)]) {
        for (path, directory) in paths { insert(path, directory: directory) }
    }

    private static func key(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func insert(_ path: String, directory: Bool) {
        var branch = [0]
        for part in ArchiveWriter.pathComponents(Self.key(path), omittingEmptySubsequences: false) {
            let parent = branch.last!, component = String(part)
            let child: Int
            if let existing = nodes[parent].children[component] { child = existing }
            else {
                if let available = unused.popLast() { child = available }
                else { child = nodes.count; nodes.append(Node()) }
                nodes[parent].children[component] = child
            }
            branch.append(child)
        }
        for node in branch { nodes[node].total += 1 }
        nodes[branch.last!].entries += 1
        if !directory { nodes[branch.last!].files += 1 }
    }

    func remove(_ path: String, directory: Bool) {
        let parts = ArchiveWriter.pathComponents(Self.key(path), omittingEmptySubsequences: false)
        var branch = [0]
        for part in parts {
            guard let child = nodes[branch.last!].children[String(part)] else {
                assertionFailure("未登録のパスを解除しました")
                return
            }
            branch.append(child)
        }
        let leaf = branch.last!
        assert(nodes[leaf].entries > 0)
        nodes[leaf].entries -= 1
        if !directory { nodes[leaf].files -= 1 }
        for node in branch { nodes[node].total -= 1 }
        // 改名を繰り返しても、使わなくなった枝は次の予約で再利用できる。
        for depth in stride(from: parts.count, through: 1, by: -1) {
            let child = branch[depth]
            guard nodes[child].total == 0 else { break }
            nodes[branch[depth - 1]].children.removeValue(forKey: String(parts[depth - 1]))
            nodes[child] = Node()
            unused.append(child)
        }
    }

    func validate(_ path: String, directory: Bool) throws {
        var node = 0
        // 空成分も残し、/ と結合文字を別々に扱う。
        for part in ArchiveWriter.pathComponents(Self.key(path), omittingEmptySubsequences: false) {
            if nodes[node].files > 0 { throw WriterError.invalidPath(path) }
            guard let child = nodes[node].children[String(part)] else { return }
            node = child
        }
        guard nodes[node].entries == 0 else { throw WriterError.duplicatePath(path) }
        guard directory || nodes[node].total == 0 else { throw WriterError.invalidPath(path) }
    }
}
