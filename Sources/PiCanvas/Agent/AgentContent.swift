import Foundation
import AppKit

/// A node's content: currently always a terminal hosting a PTY, but this
/// boundary keeps the canvas code independent of the terminal implementation.
@MainActor
protocol AgentContent: AnyObject {
    /// The view to install inside the node frame.
    var view: NSView { get }

    /// Called when the child process changes the terminal title.
    var onTitleChange: ((String) -> Void)? { get set }
    /// Called when the child process exits. `nil` means it was killed by a signal.
    var onExit: ((Int32?) -> Void)? { get set }
    /// Called when the terminal itself takes focus (e.g. the user clicked it).
    var onFocus: (() -> Void)? { get set }
    /// Called when the process reports a new working directory (OSC 7).
    var onDirectoryChange: ((String) -> Void)? { get set }

    /// Launch the process. Must be called exactly once, after the view is in a window.
    func start(_ request: ProcessRequest)

    /// Kill the child process and tear down the PTY.
    func terminate()

    /// Make the terminal the first responder.
    func focus()

    /// Show or hide the focused appearance.
    func setFocused(_ focused: Bool)

    /// Scale the rendered content. The canvas zoom drives this so text grows and
    /// shrinks with the canvas; a node's *size* is what changes how much content
    /// it shows.
    func setContentScale(_ scale: CGFloat)

    // MARK: Interaction and introspection

    /// Type text into the running process, as if the user had typed it.
    func send(text: String)

    /// The terminal's content as text, when the implementation can read it back.
    /// Used by the scrollback snapshot and by the self-test.
    func readText() -> String?

    /// The scale last accepted by `setContentScale`.
    var contentScale: CGFloat { get }

    // MARK: Diagnostics

    /// Last grid size the terminal reported, or `(0, 0)` when unknown.
    var reportedGrid: (cols: Int, rows: Int) { get }

    // MARK: Scrollback persistence (optional; implemented where supported)

    var supportsScrollbackSnapshot: Bool { get }
    func snapshotScrollback() -> Data?
    func restoreScrollback(_ data: Data)
}

extension AgentContent {
    var reportedGrid: (cols: Int, rows: Int) { (0, 0) }
    func setContentScale(_ scale: CGFloat) {}
    func send(text: String) {}
    func readText() -> String? { nil }
    var contentScale: CGFloat { 1 }
    var supportsScrollbackSnapshot: Bool { false }
    func snapshotScrollback() -> Data? { nil }
    func restoreScrollback(_ data: Data) {}
}
