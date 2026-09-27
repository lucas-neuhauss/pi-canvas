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
final class TerminalContent: AgentContent {

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

    /// Read the visible buffer back as text. Used by the self-test today, and
    /// the foundation for scrollback persistence later.
    func bufferText() -> String? {
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
            font: TerminalContent.terminalFont,
            options: options
        )
        terminal.nativeBackgroundColor = TerminalContent.backgroundColor
        terminal.nativeForegroundColor = TerminalContent.foregroundColor
        terminal.caretColor = TerminalContent.caretColor
        terminal.selectedTextBackgroundColor = TerminalContent.selectionColor
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
        NSFont(name: "Menlo", size: 12.5) ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }()

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
            DispatchQueue.main.asyncAfter(deadline: .now() + TerminalContent.killEscalationDelay) { [weak self] in
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

    /// Type text into the running process (used by future automation hooks).
    func send(text: String) {
        terminal.send(txt: text)
    }
}

// MARK: - LocalProcessTerminalViewDelegate

/// All four required callbacks, delivered on the main actor.
extension TerminalContent: LocalProcessTerminalViewDelegate {

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
