import Foundation

/// Keeps a text snapshot of each node's terminal buffer between launches.
///
/// Snapshots live in their own directory rather than in `layout.json`, so the
/// layout stays small and readable and a huge scrollback cannot make saving it
/// slow. Only the last `maxBytes` are kept, aligned to a line boundary.
final class ScrollbackStore {

    /// 256 KB per node is plenty of history and bounds the write cost.
    static let maxBytes = 256 * 1024

    let directory: URL

    static var defaultDirectory: URL {
        LayoutStore.defaultDirectory.appendingPathComponent("scrollback", isDirectory: true)
    }

    init(directory: URL? = nil) {
        let directory = directory ?? ScrollbackStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    private func url(for nodeID: UUID) -> URL {
        directory.appendingPathComponent("\(nodeID.uuidString).txt")
    }

    func save(_ data: Data, for nodeID: UUID) {
        guard !data.isEmpty else {
            remove(for: nodeID)
            return
        }
        let capped = ScrollbackStore.cap(data)
        do {
            try capped.write(to: url(for: nodeID), options: .atomic)
        } catch {
            NSLog("[PiCanvas] failed to save scrollback: \(error.localizedDescription)")
        }
    }

    func load(for nodeID: UUID) -> Data? {
        try? Data(contentsOf: url(for: nodeID))
    }

    func remove(for nodeID: UUID) {
        try? FileManager.default.removeItem(at: url(for: nodeID))
    }

    /// Drops snapshots for nodes that no longer exist, so the directory cannot
    /// grow forever.
    func prune(keeping nodeIDs: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".txt") {
            let stem = String(name.dropLast(4))
            guard let id = UUID(uuidString: stem), !nodeIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The buffer snapshot covers every row on screen, so a mostly empty
    /// terminal would restore as a wall of blank lines that pushes the new
    /// prompt to the bottom. Drop them and keep one trailing newline.
    static func trimmingTrailingBlankLines(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) else { return data }
        while let last = text.last, last == "\n" || last == " " || last == "\t" {
            text.removeLast()
        }
        guard !text.isEmpty else { return Data() }
        return Data((text + "\n").utf8)
    }

    /// Keeps the most recent output, starting at a line boundary.
    static func cap(_ data: Data, limit: Int = ScrollbackStore.maxBytes) -> Data {
        guard data.count > limit else { return data }
        let tail = data.suffix(limit)
        if let newline = tail.firstIndex(of: 0x0A) {
            let start = tail.index(after: newline)
            if start < tail.endIndex {
                return Data(tail[start...])
            }
        }
        return Data(tail)
    }
}
