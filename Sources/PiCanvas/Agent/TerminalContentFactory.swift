import AppKit

/// The single place that decides how a node's terminal is created.
///
/// The canvas never imports the terminal library directly: `AgentContent` is the
/// seam, which keeps the canvas buildable and testable on its own.
enum TerminalContentFactory {
    @MainActor
    static func make(spec: NodeSpec) -> AgentContent {
        #if GHOSTTY_TERMINAL
        // libghostty is the intended backend. If its process-wide state failed to
        // initialise (a broken config, say), fall back rather than leaving the
        // canvas unable to open a terminal.
        if GhosttyApp.shared.isRunning {
            return GhosttySurfaceContent()
        }
        #endif
        return SwiftTermContent()
    }
}
