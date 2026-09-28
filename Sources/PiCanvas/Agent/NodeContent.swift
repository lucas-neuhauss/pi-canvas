import Foundation
import AppKit

/// A node's content: the thing a node shows. Terminals own a process; an image,
/// a label, a note or a web page does not. This is the seam between the canvas
/// and whatever implements a kind, so the canvas code never depends on the
/// terminal (or image viewer, or web view) implementation.
@MainActor
protocol NodeContent: AnyObject {
    /// The view to install inside the node frame.
    var view: NSView { get }

    /// Called when the content changes its own title (a terminal reports one via
    /// OSC; process-less kinds generally have none).
    var onTitleChange: ((String) -> Void)? { get set }
    /// Called when the content itself takes focus (e.g. the user clicked it).
    var onFocus: (() -> Void)? { get set }

    /// Make the content the first responder.
    func focus()

    /// Show or hide the focused appearance.
    func setFocused(_ focused: Bool)

    /// Scale the rendered content. The canvas zoom drives this so content grows
    /// and shrinks with the canvas; a node's *size* is what changes how much
    /// content it shows.
    func setContentScale(_ scale: CGFloat)

    /// The scale last accepted by `setContentScale`.
    var contentScale: CGFloat { get }

    /// Type text into the content, as if the user had typed it. Meaningful for
    /// terminals; other kinds ignore it.
    func send(text: String)

    /// The content as text, when the implementation can read it back. Used by
    /// the scrollback snapshot and by the self-test.
    func readText() -> String?
}

extension NodeContent {
    func focus() {}
    func setFocused(_ focused: Bool) {}
    func setContentScale(_ scale: CGFloat) {}
    var contentScale: CGFloat { 1 }
    func send(text: String) {}
    func readText() -> String? { nil }
}

/// Content that owns a child process (a terminal). Process-starting is optional
/// at the seam: the canvas treats a node as launchable only when its content
/// implements this refinement, so an image needs neither a PTY nor a lifecycle
/// it has no use for.
@MainActor
protocol ProcessContent: NodeContent {
    /// Called when the child process exits. `nil` means it was killed by a signal.
    var onExit: ((Int32?) -> Void)? { get set }
    /// Called when the process reports a new working directory (OSC 7).
    var onDirectoryChange: ((String) -> Void)? { get set }

    /// Launch the process. Must be called exactly once, after the view is in a window.
    func start(_ request: ProcessRequest)

    /// Kill the child process and tear down the PTY.
    func terminate()

    /// Last grid size the terminal reported, or `(0, 0)` when unknown.
    var reportedGrid: (cols: Int, rows: Int) { get }

    // MARK: Scrollback persistence (optional; implemented where supported)

    var supportsScrollbackSnapshot: Bool { get }
    func snapshotScrollback() -> Data?
    func restoreScrollback(_ data: Data)
}

extension ProcessContent {
    var reportedGrid: (cols: Int, rows: Int) { (0, 0) }
    var supportsScrollbackSnapshot: Bool { false }
    func snapshotScrollback() -> Data? { nil }
    func restoreScrollback(_ data: Data) {}
}
