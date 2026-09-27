import AppKit

/// The single place that decides how a node's terminal is created.
///
/// The canvas never imports the terminal library directly: `AgentContent` is the
/// seam, which keeps the canvas buildable and testable on its own.
enum TerminalContentFactory {
    @MainActor
    static func make(spec: NodeSpec) -> AgentContent {
        SwiftTermContent()
    }
}
