import Foundation

/// Reads and writes the canvas layout to
/// `~/Library/Application Support/PiCanvas/layout.json`.
///
/// Writes are debounced and atomic, so dragging a node around does not hammer
/// the disk and a crash mid-write cannot corrupt the file.
final class LayoutStore {
    let fileURL: URL

    private let queue = DispatchQueue(label: "com.neuhaus.picanvas.layoutstore")
    private var pendingSave: DispatchWorkItem?
    /// Bumped on every save so a debounced write that was queued before an
    /// explicit save cannot clobber it with older state.
    private var generation = 0
    private static let debounceInterval: TimeInterval = 0.6

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PiCanvas", isDirectory: true)
    }

    init(fileURL: URL? = nil) {
        let directory = fileURL?.deletingLastPathComponent() ?? LayoutStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("layout.json")
    }

    // MARK: - Load

    func load() -> LayoutFile? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        guard let layout = try? decoder.decode(LayoutFile.self, from: data) else {
            NSLog("[PiCanvas] layout.json could not be decoded; starting fresh")
            return nil
        }
        guard layout.version == LayoutFile.currentVersion else {
            NSLog("[PiCanvas] layout.json has unsupported version \(layout.version); starting fresh")
            return nil
        }
        return layout
    }

    // MARK: - Save

    /// Debounced save. Only the most recent state within the debounce window is
    /// written. The layout is captured by value on the calling (main) thread so
    /// the background queue never touches AppKit state.
    func scheduleSave(_ layout: LayoutFile) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSave?.cancel()
            self.generation += 1
            let generation = self.generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == generation else { return }
                self.write(layout)
            }
            self.pendingSave = work
            self.queue.asyncAfter(deadline: .now() + LayoutStore.debounceInterval, execute: work)
        }
    }

    /// Write immediately, bypassing the debounce. Used on quit and by tests.
    func saveNow(_ layout: LayoutFile) {
        queue.sync {
            pendingSave?.cancel()
            pendingSave = nil
            generation += 1
            write(layout)
        }
    }

    private func write(_ layout: LayoutFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(layout)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[PiCanvas] failed to save layout: \(error.localizedDescription)")
        }
    }
}
