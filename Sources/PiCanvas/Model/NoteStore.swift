import Foundation

/// A note's markdown file, kept beside the workspaces rather than inside them.
///
/// One file per note node (`notes/<uuid>.md`), so a workspace layout stays small
/// and a note can be read or edited with any editor. The node only remembers
/// the id.
final class NoteStore {

    let directory: URL

    static var defaultDirectory: URL {
        LayoutStore.defaultDirectory.appendingPathComponent("notes", isDirectory: true)
    }

    init(directory: URL? = nil) {
        let directory = directory ?? NoteStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md")
    }

    func load(_ id: UUID) -> String? {
        try? String(contentsOf: url(for: id), encoding: .utf8)
    }

    func save(_ text: String, for id: UUID) {
        do {
            try text.write(to: url(for: id), atomically: true, encoding: .utf8)
        } catch {
            NSLog("[PiCanvas] could not save note: %@", error.localizedDescription)
        }
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drops notes no node references any more, so closing a workspace does not
    /// leave its markdown files behind forever.
    func prune(keeping ids: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".md") {
            let stem = String(name.dropLast(3))
            guard let id = UUID(uuidString: stem), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
