import AppKit

/// The single place that decides how a node's content is created from its spec.
///
/// The canvas never imports a terminal library (or, later, a web view) directly:
/// `NodeContent` is the seam, which keeps the canvas buildable and testable on
/// its own.
enum NodeContentFactory {
    @MainActor
    static func make(spec: NodeSpec, assetStore: AssetStore) -> NodeContent {
        switch spec.kind {
        case .shell, .pi:
            #if GHOSTTY_TERMINAL
            // libghostty is the intended backend. If its process-wide state failed to
            // initialise (a broken config, say), fall back rather than leaving the
            // canvas unable to open a terminal.
            if GhosttyApp.shared.isRunning {
                return GhosttySurfaceContent()
            }
            #endif
            return SwiftTermContent()

        case .image:
            guard let asset = spec.asset else {
                return MissingNodeContent(message: "image asset missing")
            }
            return ImageContent(nodeID: spec.id, assetURL: assetStore.url(for: asset))

        case .text:
            return TextContent(text: spec.text ?? "")

        case .note, .browser:
            // The seam is ready for these; the content is not built yet.
            return MissingNodeContent(message: "\(spec.kind.displayName) nodes are not implemented yet")
        }
    }
}
