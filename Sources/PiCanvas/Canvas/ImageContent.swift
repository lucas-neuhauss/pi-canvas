import AppKit

/// The private pasteboard type a node drag carries. Kept out of the public
/// pasteboard types so a drag from one node to another is only ever offered to
/// node frames: a terminal underneath can neither swallow it nor guess what to
/// do with it.
enum NodeDragPasteboard {
    static let type = NSPasteboard.PasteboardType("com.neuhaus.picanvas.node")

    /// The dragged node's ID, read back by the drop target.
    static func sourceNodeID(from pasteboard: NSPasteboard) -> UUID? {
        pasteboard.string(forType: NodeDragPasteboard.type).flatMap(UUID.init(uuidString:))
    }
}

/// Content for an image node: the image, scaled to fill the node, and a drag
/// source that hands the asset's path to whatever the node is dropped on.
@MainActor
final class ImageContent: NodeContent {

    let view: NSView

    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    /// The copied asset this node renders. Exposed for diagnostics and tests.
    let assetURL: URL

    init(nodeID: UUID, assetURL: URL) {
        self.assetURL = assetURL
        let image = NSImage(contentsOf: assetURL)
        view = ImageContentView(nodeID: nodeID, assetURL: assetURL, image: image)
    }

    func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

/// The image itself. Owns the mouse so a press-and-drag begins a node drag
/// rather than moving the node — the title bar is how you move a node, exactly
/// as the terminals behave.
final class ImageContentView: NSView, NSDraggingSource {

    let nodeID: UUID
    let assetURL: URL

    private let imageView = NSImageView()
    private let image: NSImage?
    private var dragStart: CGPoint?
    private var didBeginDrag = false

    init(nodeID: UUID, assetURL: URL, image: NSImage?) {
        self.nodeID = nodeID
        self.assetURL = assetURL
        self.image = image
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.058, blue: 0.066, alpha: 1).cgColor
        layer?.cornerRadius = NodeMetrics.contentCornerRadius
        layer?.masksToBounds = true

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    /// Every event in the content belongs to the drag source, not the image
    /// subview, so a press-and-drag always starts a node drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A missing asset still draws something explanatory rather than an
        // empty hole where the image was.
        guard image == nil else { return }
        let message = "image missing" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
        ]
        let size = message.size(withAttributes: attributes)
        message.draw(
            at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    // MARK: - Drag out

    /// The pasteboard item a node drag contributes: the source node's identity.
    /// `acceptNodeDrop` reads it back with `NodeDragPasteboard`.
    func makeDragPasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(nodeID.uuidString, forType: NodeDragPasteboard.type)
        return item
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        didBeginDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, !didBeginDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - dragStart.x, point.y - dragStart.y) > 4 else { return }
        didBeginDrag = true

        let draggingItem = NSDraggingItem(pasteboardWriter: makeDragPasteboardItem())

        let size = dragThumbnailSize()
        draggingItem.setDraggingFrame(
            CGRect(
                x: dragStart.x - size.width / 2,
                y: dragStart.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            contents: dragThumbnail(size: size)
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    private func dragThumbnailSize() -> NSSize {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return NSSize(width: 64, height: 64)
        }
        let longest: CGFloat = 96
        let scale = longest / max(image.size.width, image.size.height)
        return NSSize(
            width: max(image.size.width * scale, 24),
            height: max(image.size.height * scale, 24)
        )
    }

    private func dragThumbnail(size: NSSize) -> NSImage? {
        guard let image else { return nil }
        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.85
        )
        thumbnail.unlockFocus()
        return thumbnail
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
