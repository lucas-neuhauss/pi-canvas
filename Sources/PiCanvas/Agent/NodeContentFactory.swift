import AppKit

/// The stores node content may need: image nodes resolve their file in the
/// asset store, note nodes live in the note store. Bundled so the factory's
/// signature does not grow a parameter per kind.
struct NodeStores {
    let assets: AssetStore
    let notes: NoteStore
}

/// The single place that decides how a node's content is created from its spec.
///
/// The canvas never imports a terminal library (or, later, a web view) directly:
/// `NodeContent` is the seam, which keeps the canvas buildable and testable on
/// its own.
enum NodeContentFactory {
    @MainActor
    static func make(spec: NodeSpec, stores: NodeStores) -> NodeContent {
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
            return ImageContent(nodeID: spec.id, assetURL: stores.assets.url(for: asset))

        case .text:
            return TextContent(text: spec.text ?? "")

        case .note:
            guard let noteID = spec.noteID else {
                return MissingNodeContent(message: "note file missing")
            }
            return NoteContent(noteURL: stores.notes.url(for: noteID))

        case .browser:
            return BrowserContent(nodeID: spec.id, url: spec.url.flatMap(URL.init(string:)))
        }
    }
}
