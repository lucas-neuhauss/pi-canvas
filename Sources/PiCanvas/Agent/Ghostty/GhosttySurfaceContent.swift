import AppKit
import GhosttyKit

/// An `AgentContent` backed by libghostty.
///
/// The canvas does not care which terminal library is behind this; everything
/// terminal-specific lives here. The pleasant consequence of embedding Ghostty
/// is that the user's real Ghostty config — font, theme, palette, ligatures,
/// keybindings, mouse behaviour — applies to every node for free.
@MainActor
final class GhosttySurfaceContent: AgentContent {

    let view: NSView

    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onFocus: (() -> Void)?
    var onDirectoryChange: ((String) -> Void)?

    private let surfaceView: GhosttySurfaceView
    private var baseFontSize: CGFloat
    private var scale: CGFloat = 1
    private var didStart = false
    private var didTerminate = false

    /// Scrollback to paint into the terminal when it starts. libghostty has no
    /// API for feeding bytes into a surface, so this is printed by the child's
    /// shell instead — see `start(_:)`.
    private var pendingScrollback: Data?
    private var restoreFilePath: String?

    init() {
        surfaceView = GhosttySurfaceView(frame: .zero)
        view = surfaceView
        baseFontSize = GhosttyApp.shared.baseFontSize
        surfaceView.surfaceDelegate = self
    }

    deinit {
        if let restoreFilePath {
            try? FileManager.default.removeItem(atPath: restoreFilePath)
        }
    }

    // MARK: - Start / stop

    func start(_ request: ProcessRequest) {
        guard !didStart else { return }
        didStart = true

        var command = Self.shellCommand(
            executable: request.executable,
            arguments: request.arguments
        )

        // Paint last session's output before the new process takes over the
        // terminal. The surface command is always executed by a shell, so a
        // `cat` of the saved buffer is a legitimate way to reproduce it.
        if let snapshot = pendingScrollback, !snapshot.isEmpty,
           let path = writeRestoreFile(snapshot) {
            command = "cat \(Self.shellQuote(path)); exec \(command)"
            pendingScrollback = nil
        }

        surfaceView.start(
            GhosttySurfaceView.SurfaceStart(
                command: command,
                workingDirectory: request.workingDirectory,
                environment: request.environment,
                fontSize: baseFontSize * scale
            )
        )
    }

    func terminate() {
        guard !didTerminate else { return }
        didTerminate = true
        surfaceView.terminate()
        if let restoreFilePath {
            try? FileManager.default.removeItem(atPath: restoreFilePath)
            self.restoreFilePath = nil
        }
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(surfaceView)
    }

    func setFocused(_ focused: Bool) {
        // The node's border communicates focus; ghostty tracks it via the
        // first-responder transitions in the view.
    }

    // MARK: - Zoom

    func setContentScale(_ scale: CGFloat) {
        self.scale = scale
        surfaceView.applyFontSize(baseFontSize * scale)
    }

    var contentScale: CGFloat { scale }

    var reportedGrid: (cols: Int, rows: Int) { surfaceView.gridSize }

    // MARK: - Interaction and read-back

    func send(text: String) {
        surfaceView.sendText(text)
    }

    func readText() -> String? {
        surfaceView.readText()
    }

    var supportsScrollbackSnapshot: Bool { true }

    func snapshotScrollback() -> Data? {
        guard let text = surfaceView.readText(), !text.isEmpty else { return nil }
        let data = Data(text.utf8)
        let trimmed = ScrollbackStore.trimmingTrailingBlankLines(data)
        guard !trimmed.isEmpty else { return nil }
        return ScrollbackStore.cap(trimmed)
    }

    func restoreScrollback(_ data: Data) {
        pendingScrollback = data
    }

    private func writeRestoreFile(_ data: Data) -> String? {
        let directory = ScrollbackStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("restore-\(UUID().uuidString).txt")
        do {
            try data.write(to: url, options: .atomic)
            restoreFilePath = url.path
            return url.path
        } catch {
            NSLog("[PiCanvas] could not stage scrollback restore: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Building the shell command

    /// libghostty always runs the surface command through a shell
    /// (`/bin/sh -c`), so the argv must be quoted.
    static func shellCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - GhosttySurfaceViewDelegate

extension GhosttySurfaceContent: GhosttySurfaceViewDelegate {

    func surfaceView(_ view: GhosttySurfaceView, didChangeTitle title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onTitleChange?(trimmed)
    }

    func surfaceView(_ view: GhosttySurfaceView, didChangeWorkingDirectory directory: String) {
        guard !directory.isEmpty else { return }
        onDirectoryChange?(directory)
    }

    func surfaceView(_ view: GhosttySurfaceView, didExitWith exitCode: Int32?) {
        onExit?(exitCode)
    }

    func surfaceViewDidRequestClose(_ view: GhosttySurfaceView) {
        // pi/ghostty asked to close: surface this as an exit so the node shows it.
        onExit?(nil)
    }
}
