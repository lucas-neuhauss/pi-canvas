import Foundation

/// Reads and writes workspaces.
///
/// One file per workspace, plus the legacy single-canvas `layout.json` which is
/// adopted as the first workspace. Files are small and few, so they are read by
/// listing the directory rather than through an index that could drift out of
/// sync with them.
final class WorkspaceStore {

    let directory: URL
    /// The single-canvas layout this app used before workspaces existed.
    let legacyLayoutURL: URL

    private let queue = DispatchQueue(label: "com.neuhaus.picanvas.workspacestore")
    /// One pending write per workspace: saving all of them must not have them
    /// cancel each other, which a single slot would do.
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    private var generations: [UUID: Int] = [:]
    private static let debounceInterval: TimeInterval = 0.6

    init(directory: URL? = nil, legacyLayoutURL: URL? = nil) {
        let base = LayoutStore.defaultDirectory
        let directory = directory ?? base.appendingPathComponent("workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.legacyLayoutURL = legacyLayoutURL ?? base.appendingPathComponent("layout.json")
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Dates

    /// ISO-8601 *with fractional seconds*: two workspaces touched within the same
    /// second must still be orderable, and switching between them is a sub-second
    /// event. Whole-second timestamps made "most recently used" a coin toss.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateFormatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = dateFormatter.date(from: text) { return date }
            // Tolerate a file written without fractional seconds.
            if let date = wholeSecondFormatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unparseable date \(text)"
            )
        }
        return decoder
    }

    // MARK: - Load

    /// Every stored workspace, newest first.
    func loadAll() -> [WorkspaceFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let decoder = WorkspaceStore.makeDecoder()
        var workspaces: [WorkspaceFile] = []
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { continue }
            if let workspace = try? decoder.decode(WorkspaceFile.self, from: data) {
                workspaces.append(workspace)
            } else {
                NSLog("[PiCanvas] skipping unreadable workspace file %@", name)
            }
        }
        return workspaces.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Adopts the pre-workspaces layout, if there is one and nothing else exists.
    ///
    /// The legacy file is left in place rather than deleted: it costs nothing and
    /// it means an older build still opens what it wrote.
    func adoptLegacyLayoutIfNeeded(existing: [WorkspaceFile]) -> WorkspaceFile? {
        guard existing.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: legacyLayoutURL),
              let layout = try? JSONDecoder().decode(LayoutFile.self, from: data),
              !layout.nodes.isEmpty else { return nil }
        NSLog("[PiCanvas] adopting %d nodes from layout.json into a workspace", layout.nodes.count)
        let workspace = WorkspaceFile(name: "Default", layout: layout)
        saveNow(workspace)
        return workspace
    }

    // MARK: - Save

    func scheduleSave(_ workspace: WorkspaceFile) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = workspace.id
            self.pendingSaves[id]?.cancel()
            let generation = (self.generations[id] ?? 0) + 1
            self.generations[id] = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generations[id] == generation else { return }
                self.write(workspace)
            }
            self.pendingSaves[id] = work
            self.queue.asyncAfter(deadline: .now() + WorkspaceStore.debounceInterval, execute: work)
        }
    }

    func saveNow(_ workspace: WorkspaceFile) {
        queue.sync {
            pendingSaves[workspace.id]?.cancel()
            pendingSaves[workspace.id] = nil
            generations[workspace.id] = (generations[workspace.id] ?? 0) + 1
            write(workspace)
        }
    }

    private func write(_ workspace: WorkspaceFile) {
        do {
            let data = try WorkspaceStore.makeEncoder().encode(workspace)
            try data.write(to: url(for: workspace.id), options: .atomic)
        } catch {
            NSLog("[PiCanvas] failed to save workspace: \(error.localizedDescription)")
        }
    }

    func delete(id: UUID) {
        queue.sync {
            pendingSaves[id]?.cancel()
            pendingSaves[id] = nil
            generations[id] = nil
            try? FileManager.default.removeItem(at: url(for: id))
        }
    }

    /// Where a workspace's nodes will be persisted, for diagnostics.
    func fileURL(for id: UUID) -> URL { url(for: id) }
}
