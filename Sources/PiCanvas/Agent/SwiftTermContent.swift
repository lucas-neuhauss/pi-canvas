import AppKit
import SwiftTerm
import Darwin

/// A node's content: a real PTY hosted by SwiftTerm, running an arbitrary
/// process (a login shell, or `pi`).
///
/// We use `LocalProcessTerminalView` rather than driving `TerminalView` +
/// `LocalProcess` ourselves. The trade-off is documented in
/// `docs/SWIFTTERM_API.md`: the higher-level class owns its internal adapter, so
/// there is no overridable raw-byte hook to build scrollback capture on — but it
/// gives us process lifecycle callbacks, clipboard handling and input coalescing
/// for free, which is the right deal for now.
@MainActor
final class SwiftTermContent: AgentContent {

    let view: NSView

    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onFocus: (() -> Void)?
    var onDirectoryChange: ((String) -> Void)?

    private let terminal: LocalProcessTerminalView
    private var didTerminate = false
    private var started = false

    /// Last grid size the terminal reported, for diagnostics and tests.
    private(set) var lastReportedCols = 0
    private(set) var lastReportedRows = 0

    /// Read the visible buffer back as text.
    func readText() -> String? {
        let data = terminal.getBufferAsData(kind: .active, encoding: .utf8)
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// How long to wait for SIGTERM to be honoured before escalating to SIGKILL.
    private static let killEscalationDelay: TimeInterval = 2.0

    init() {
        // `TerminalOptions` has no public memberwise initialiser, so start from
        // the library's default and adjust the fields we care about.
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.termName = "xterm-256color"

        let terminal = LocalProcessTerminalView(
            frame: .zero,
            font: SwiftTermContent.terminalFont,
            options: options
        )
        terminal.nativeBackgroundColor = SwiftTermContent.backgroundColor
        terminal.nativeForegroundColor = SwiftTermContent.foregroundColor
        terminal.caretColor = SwiftTermContent.caretColor
        terminal.selectedTextBackgroundColor = SwiftTermContent.selectionColor
        // A canvas full of terminals should scroll its own content, not the page.
        terminal.scrollSensitivity = 1.0
        // Small tabs, not a chunky scroller, inside a node.
        terminal.scrollerStyle = .overlay

        self.terminal = terminal
        self.view = terminal
        terminal.processDelegate = self
    }

    // MARK: - Appearance

    static let terminalFont: NSFont = {
        NSFont(name: "Menlo", size: baseFontSize) ?? NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
    }()

    /// Font size at 100% zoom.
    static let baseFontSize: CGFloat = 12.5
    /// Below this the cell metrics get silly; above it a node stops looking like
    /// a terminal.
    static let minFontSize: CGFloat = 4
    static let maxFontSize: CGFloat = 30

    /// Last font size actually applied, so we can skip redundant work.
    private var appliedFontSize: CGFloat = SwiftTermContent.baseFontSize

    /// Current glyph size, for diagnostics and tests.
    var contentFontSize: CGFloat { appliedFontSize }

    /// The scale last accepted by `setContentScale`.
    var contentScale: CGFloat { appliedFontSize / SwiftTermContent.baseFontSize }

    static let backgroundColor = NSColor(srgbRed: 0.055, green: 0.058, blue: 0.067, alpha: 1)
    static let foregroundColor = NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1)
    static let caretColor = NSColor(srgbRed: 0.45, green: 0.70, blue: 1.0, alpha: 1)
    static let selectionColor = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 0.35)

    // MARK: - AgentContent

    func start(_ request: ProcessRequest) {
        guard !started else { return }
        started = true

        // SwiftTerm replaces the child environment wholesale when one is
        // supplied, so ProcessResolver hands us a complete environment.
        let environment = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()

        terminal.startProcess(
            executable: request.executable,
            args: request.arguments,
            environment: environment,
            execName: (request.executable as NSString).lastPathComponent,
            currentDirectory: request.workingDirectory
        )
    }

    func terminate() {
        guard !didTerminate else { return }
        didTerminate = true

        var pid: pid_t?
        if let process = terminal.process, process.shellPid > 0 {
            pid = process.shellPid
        } else {
            pid = nil
        }
        terminal.terminate()

        // `terminate()` only sends SIGTERM. An agent that ignores it would leak a
        // process and keep the canvas node haunted, so escalate.
        if let pid, pid > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + SwiftTermContent.killEscalationDelay) { [weak self] in
                guard let self else { return }
                if let process = self.terminal.process, process.running, process.shellPid > 0 {
                    kill(process.shellPid, SIGKILL)
                }
            }
        }

        terminal.updateUiClosed()
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(terminal)
    }

    func setFocused(_ focused: Bool) {
        // The node's border communicates focus; nothing to do inside the terminal.
    }

    /// Zooming the canvas scales the glyphs, so a node's text shrinks when you
    /// zoom out instead of staying a fixed size inside a shrinking box. Because
    /// the font and the node's pixel size scale together, the grid (cols × rows)
    /// stays essentially constant — resizing a node is what reveals more content.
    func setContentScale(_ scale: CGFloat) {
        let target = min(max(SwiftTermContent.baseFontSize * scale, SwiftTermContent.minFontSize), SwiftTermContent.maxFontSize)
        // Quantise so a pinch does not rebuild the font on every event.
        let quantised = (target * 4).rounded() / 4
        guard abs(quantised - appliedFontSize) > 0.01 else { return }
        appliedFontSize = quantised

        let familyName = terminal.font.fontName
        terminal.font = NSFont(name: familyName, size: quantised)
            ?? NSFont.monospacedSystemFont(ofSize: quantised, weight: .regular)
    }

    var reportedGrid: (cols: Int, rows: Int) { (lastReportedCols, lastReportedRows) }

    // MARK: Scrollback persistence

    var supportsScrollbackSnapshot: Bool { true }

    /// The whole buffer as plain text. SwiftTerm trims trailing whitespace per
    /// line and separates with `\n`.
    func snapshotScrollback() -> Data? {
        let data = terminal.getBufferAsData(kind: .active, encoding: .utf8)
        guard !data.isEmpty else { return nil }
        let trimmed = ScrollbackStore.trimmingTrailingBlankLines(data)
        guard !trimmed.isEmpty else { return nil }
        return ScrollbackStore.cap(trimmed)
    }

    /// Paints a previous snapshot into the (still empty) terminal.
    ///
    /// `feed` writes bytes literally, and the buffer snapshot uses bare `\n`, so
    /// the newlines are turned into CRLF here — otherwise restored lines would
    /// staircase to the right instead of starting at column 0.
    func restoreScrollback(_ data: Data) {
        guard !data.isEmpty, var text = String(data: data, encoding: .utf8) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\n", with: "\r\n")
        terminal.feed(text: text)
    }

    /// Type text into the running process.
    func send(text: String) {
        terminal.send(txt: text)
    }
}

// MARK: - LocalProcessTerminalViewDelegate

/// All four required callbacks, delivered on the main actor.
extension SwiftTermContent: LocalProcessTerminalViewDelegate {

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // The terminal resized its own PTY; we only record the size.
        lastReportedCols = newCols
        lastReportedRows = newRows
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onTitleChange?(trimmed)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        onDirectoryChange?(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?(exitCode)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        NSLog("[PiCanvas] process failed to start: \(String(describing: error))")
        onTitleChange?("failed to start")
        onExit?(127)
    }
}
