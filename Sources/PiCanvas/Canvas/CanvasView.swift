import AppKit
import UniformTypeIdentifiers

struct CanvasViewport: Equatable {
    var zoom: CGFloat = 1
    var panX: CGFloat = 0
    var panY: CGFloat = 0
}

@MainActor
protocol CanvasViewDelegate: AnyObject {
    /// The viewport (zoom/pan) changed.
    func canvasView(_ canvas: CanvasView, didChangeViewport viewport: CanvasViewport)
    /// A node was moved or resized and the interaction ended.
    func canvasViewDidChangeLayout(_ canvas: CanvasView)
    /// A node asked to be closed (its × button was clicked).
    func canvasView(_ canvas: CanvasView, didRequestClose nodeID: UUID)
    /// The selection changed.
    func canvasView(_ canvas: CanvasView, didChangeSelection selection: UUID?)
    /// The focused node changed and its content should take first responder.
    func canvasView(_ canvas: CanvasView, didFocus nodeID: UUID?)
    /// The user renamed a node.
    func canvasView(_ canvas: CanvasView, didRename nodeID: UUID, to title: String)
    /// An image file was dropped on the canvas. Returns true when a node was made.
    func canvasView(_ canvas: CanvasView, didReceiveImageDropOf url: URL, atWorldPoint point: CGPoint) -> Bool
    /// A web link was dropped on the canvas. Returns true when a node was made.
    func canvasView(_ canvas: CanvasView, didReceiveLinkDropOf url: URL, atWorldPoint point: CGPoint) -> Bool
    /// A double-click landed on empty canvas: make a text label there.
    func canvasView(_ canvas: CanvasView, didRequestTextNodeAt point: CGPoint)
    /// A context-menu request to create a node at a world point.
    func canvasView(_ canvas: CanvasView, didRequestNewNodeOfKind kind: NodeKind, at point: CGPoint)
    /// A context-menu request to pick an image file to place at a world point.
    func canvasView(_ canvas: CanvasView, didRequestImagePickerAt point: CGPoint)
    /// A node was dropped onto another node. Returns true when the drop was used.
    func canvasView(_ canvas: CanvasView, nodeID: UUID, didReceiveDropFrom sourceNodeID: UUID) -> Bool
}

/// An infinite, zoomable, pannable plane that hosts node views.
///
/// Design note: nodes are positioned by computing their screen frame from a
/// world-space frame (`screen = world * zoom + pan`). We deliberately do *not*
/// apply a `CALayer` transform to the container, because scaling a terminal by
/// transform makes its text blurry and its mouse coordinates lie. Instead the
/// terminal always renders at native 1:1 pixels and zoom simply makes the node
/// occupy more (or fewer) pixels, which means more (or fewer) columns and rows.
/// Node chrome (title bars, buttons) is drawn in constant screen pixels so it
/// stays legible at every zoom level.
final class CanvasView: NSView {

    weak var canvasDelegate: CanvasViewDelegate?

    private(set) var zoom: CGFloat = 1
    private(set) var pan: CGPoint = .zero

    var minZoom: CGFloat = 0.2
    var maxZoom: CGFloat = 3.0

    private(set) var nodeViews: [NodeFrameView] = []
    private(set) var selectedNodeID: UUID?
    private(set) var focusedNodeID: UUID?

    private var isPanning = false
    private var panStartScreen: CGPoint = .zero
    private var panStartPan: CGPoint = .zero
    private var didMoveDuringPan = false

    /// Grid spacing in world units.
    private let gridSpacing: CGFloat = 28
    /// The grid is doubled until its on-screen spacing reaches this.
    private let minGridScreenSpacing: CGFloat = 14

    private let backgroundColor = NSColor(srgbRed: 0.086, green: 0.090, blue: 0.102, alpha: 1)
    private let gridColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.055)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        // Dropping an image file or a link anywhere on the plane makes a node.
        registerForDraggedTypes([.fileURL, .URL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Coordinate conversion

    var viewport: CanvasViewport {
        CanvasViewport(zoom: zoom, panX: pan.x, panY: pan.y)
    }

    func screenPoint(fromWorld point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.x, y: point.y * zoom + pan.y)
    }

    func worldPoint(fromScreen point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.x) / zoom, y: (point.y - pan.y) / zoom)
    }

    func screenRect(fromWorld rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * zoom + pan.x,
            y: rect.origin.y * zoom + pan.y,
            width: rect.size.width * zoom,
            height: rect.size.height * zoom
        )
    }

    func worldRect(fromScreen rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.origin.x - pan.x) / zoom,
            y: (rect.origin.y - pan.y) / zoom,
            width: rect.size.width / zoom,
            height: rect.size.height / zoom
        )
    }

    var visibleWorldRect: CGRect {
        worldRect(fromScreen: bounds)
    }

    // MARK: - Viewport mutation

    func setViewport(zoom newZoom: CGFloat, pan newPan: CGPoint, notify: Bool) {
        zoom = min(max(newZoom, minZoom), maxZoom)
        pan = newPan
        layoutNodes()
        if notify { canvasDelegate?.canvasView(self, didChangeViewport: viewport) }
    }

    /// Zooms while keeping the world point under `anchorScreen` pinned to that screen point.
    func setZoom(_ newZoom: CGFloat, anchorScreen: CGPoint? = nil, notify: Bool = true) {
        let anchor = anchorScreen ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let clamped = min(max(newZoom, minZoom), maxZoom)
        guard abs(clamped - zoom) > 0.0005 else { return }
        let anchorWorld = worldPoint(fromScreen: anchor)
        zoom = clamped
        pan = CGPoint(x: anchor.x - anchorWorld.x * zoom, y: anchor.y - anchorWorld.y * zoom)
        layoutNodes()
        if notify { canvasDelegate?.canvasView(self, didChangeViewport: viewport) }
    }

    func zoomIn(anchorScreen: CGPoint? = nil) {
        setZoom(zoom * 1.25, anchorScreen: anchorScreen)
    }

    func zoomOut(anchorScreen: CGPoint? = nil) {
        setZoom(zoom / 1.25, anchorScreen: anchorScreen)
    }

    func resetZoom(anchorScreen: CGPoint? = nil) {
        setZoom(1.0, anchorScreen: anchorScreen)
    }

    func panBy(_ delta: CGPoint, notify: Bool = true) {
        pan.x += delta.x
        pan.y += delta.y
        layoutNodes()
        if notify { canvasDelegate?.canvasView(self, didChangeViewport: viewport) }
    }

    /// Fits every visible node on screen with a comfortable margin.
    func zoomToFit() {
        let visible = visibleNodeViews
        guard !visible.isEmpty else {
            zoom = 1
            pan = .zero
            layoutNodes()
            canvasDelegate?.canvasView(self, didChangeViewport: viewport)
            return
        }

        var worldBounds = visible[0].worldFrame
        for node in visible.dropFirst() {
            worldBounds = worldBounds.union(node.worldFrame)
        }

        let margin: CGFloat = 70
        let availableWidth = max(bounds.width - margin * 2, 80)
        let availableHeight = max(bounds.height - margin * 2, 80)
        guard worldBounds.width > 0, worldBounds.height > 0 else { return }

        let fitZoom = min(availableWidth / worldBounds.width, availableHeight / worldBounds.height)
        let targetZoom = min(max(fitZoom, minZoom), maxZoom)

        let centreWorld = CGPoint(x: worldBounds.midX, y: worldBounds.midY)
        zoom = targetZoom
        pan = CGPoint(
            x: bounds.midX - centreWorld.x * targetZoom,
            y: bounds.midY - centreWorld.y * targetZoom
        )
        layoutNodes()
        canvasDelegate?.canvasView(self, didChangeViewport: viewport)
    }

    /// The world point at the centre of the viewport — where new nodes are born.
    func viewportCentreWorldPoint() -> CGPoint {
        worldPoint(fromScreen: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - Nodes

    func addNodeView(_ node: NodeFrameView) {
        node.nodeDelegate = nodeDelegateProxy
        nodeViews.append(node)
        addSubview(node)
        layoutNodes()
        bringToFront(node)
    }

    func removeNodeView(_ node: NodeFrameView) {
        nodeViews.removeAll { $0 === node }
        node.removeFromSuperview()
        if selectedNodeID == node.nodeID {
            selectedNodeID = nil
            canvasDelegate?.canvasView(self, didChangeSelection: nil)
        }
        if focusedNodeID == node.nodeID { focusedNodeID = nil }
        layoutNodes()
    }

    func nodeView(withID id: UUID) -> NodeFrameView? {
        nodeViews.first { $0.nodeID == id }
    }

    var orderedNodeIDs: [UUID] {
        nodeViews.map(\.nodeID)
    }

    func bringToFront(_ node: NodeFrameView) {
        guard nodeViews.last !== node else { return }
        nodeViews.removeAll { $0 === node }
        nodeViews.append(node)
        addSubview(node, positioned: .above, relativeTo: nil)
    }

    /// Selects a node. `focusContent` asks the delegate to give the node's
    /// terminal keyboard focus.
    func select(_ node: NodeFrameView?, focusContent: Bool) {
        let newSelection = node?.nodeID
        if selectedNodeID != newSelection {
            selectedNodeID = newSelection
            for candidate in nodeViews {
                candidate.isSelected = (candidate === node)
            }
            canvasDelegate?.canvasView(self, didChangeSelection: newSelection)
        }

        guard let node else {
            focusedNodeID = nil
            for candidate in nodeViews { candidate.isFocused = false }
            canvasDelegate?.canvasView(self, didFocus: nil)
            return
        }

        bringToFront(node)
        let focusChanged = focusedNodeID != node.nodeID
        focusedNodeID = node.nodeID
        for candidate in nodeViews {
            candidate.isFocused = (candidate === node)
        }
        if focusContent || focusChanged {
            canvasDelegate?.canvasView(self, didFocus: node.nodeID)
        }
    }

    /// Nodes that are actually on screen. Hidden ones belong to another workspace.
    var visibleNodeViews: [NodeFrameView] {
        nodeViews.filter { !$0.isHidden }
    }

    /// The visible node under a point, if any.
    func node(at canvasPoint: CGPoint) -> NodeFrameView? {
        visibleNodeViews.last { $0.frame.contains(canvasPoint) }
    }

    // MARK: - File drops

    /// The first dropped file that is an image, if any.
    func droppedImageURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return urls.compactMap { $0 as? URL }.first
    }

    /// Creates an image node for a file dropped at a canvas point. Split from
    /// the `NSDraggingDestination` methods so the logic is testable without a
    /// synthetic drag session.
    @discardableResult
    func handleImageDrop(pasteboard: NSPasteboard, canvasPoint: CGPoint) -> Bool {
        guard let url = droppedImageURL(from: pasteboard) else { return false }
        let world = worldPoint(fromScreen: canvasPoint)
        return canvasDelegate?.canvasView(self, didReceiveImageDropOf: url, atWorldPoint: world) ?? false
    }

    /// The first dropped item that is a web link, if any. A file URL (an image
    /// from Finder) never matches.
    func droppedWebURL(from pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) ?? []
        return urls.compactMap { $0 as? URL }.first { url in
            guard let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "http" || scheme == "https") && url.host != nil
        }
    }

    /// Creates a browser node for a link dropped at a canvas point.
    @discardableResult
    func handleWebURLDrop(pasteboard: NSPasteboard, canvasPoint: CGPoint) -> Bool {
        guard let url = droppedWebURL(from: pasteboard) else { return false }
        let world = worldPoint(fromScreen: canvasPoint)
        return canvasDelegate?.canvasView(self, didReceiveLinkDropOf: url, atWorldPoint: world) ?? false
    }

    private func acceptsCanvasDrop(from pasteboard: NSPasteboard) -> Bool {
        droppedWebURL(from: pasteboard) != nil || droppedImageURL(from: pasteboard) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsCanvasDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsCanvasDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        if handleWebURLDrop(pasteboard: sender.draggingPasteboard, canvasPoint: point) {
            return true
        }
        return handleImageDrop(pasteboard: sender.draggingPasteboard, canvasPoint: point)
    }

    // MARK: - Context menu

    /// The world point the context menu was opened at, so creation items land
    /// where the user right-clicked.
    private var contextMenuWorldPoint: CGPoint = .zero

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        // A node owns its right-clicks (terminals bring their own menus); the
        // creation menu belongs to the empty canvas.
        guard node(at: point) == nil else { return nil }
        contextMenuWorldPoint = worldPoint(fromScreen: point)

        let menu = NSMenu()
        menu.addItem(contextItem("New Terminal", #selector(contextNewTerminal(_:))))
        menu.addItem(contextItem("New pi Agent", #selector(contextNewPi(_:))))
        menu.addItem(.separator())
        menu.addItem(contextItem("New Text Label", #selector(contextNewTextLabel(_:))))
        menu.addItem(contextItem("New Note", #selector(contextNewNote(_:))))
        menu.addItem(contextItem("New Browser", #selector(contextNewBrowser(_:))))
        menu.addItem(contextItem("Add Image…", #selector(contextAddImage(_:))))
        return menu
    }

    private func contextItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func contextNewTerminal(_ sender: Any?) {
        canvasDelegate?.canvasView(self, didRequestNewNodeOfKind: .shell, at: contextMenuWorldPoint)
    }

    @objc private func contextNewPi(_ sender: Any?) {
        canvasDelegate?.canvasView(self, didRequestNewNodeOfKind: .pi, at: contextMenuWorldPoint)
    }

    @objc private func contextNewTextLabel(_ sender: Any?) {
        canvasDelegate?.canvasView(self, didRequestNewNodeOfKind: .text, at: contextMenuWorldPoint)
    }

    @objc private func contextNewNote(_ sender: Any?) {
        canvasDelegate?.canvasView(self, didRequestNewNodeOfKind: .note, at: contextMenuWorldPoint)
    }

    @objc private func contextNewBrowser(_ sender: Any?) {
        canvasDelegate?.canvasView(self, didRequestNewNodeOfKind: .browser, at: contextMenuWorldPoint)
    }

    @objc private func contextAddImage(_ sender: Any?) {
        canvasDelegate?.canvasView(self, didRequestImagePickerAt: contextMenuWorldPoint)
    }

    /// Recomputes every node's screen frame. Called after any zoom/pan/frame change.
    func layoutNodes() {
        let chromeScale = CanvasView.chromeScale(forZoom: zoom)
        for node in nodeViews {
            node.chromeScale = chromeScale
            node.frame = screenRect(fromWorld: node.worldFrame).integral
            node.needsLayout = true
        }
        needsDisplay = true
    }

    /// Node chrome tracks zoom, but only within a range where it stays usable:
    /// title bars and buttons at 20% zoom would otherwise be unreadable specks,
    /// and at 300% they would eat the node.
    static func chromeScale(forZoom zoom: CGFloat) -> CGFloat {
        min(max(zoom, 0.6), 1.5)
    }

    // MARK: - Events

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if CanvasView.isZoomScroll(event) {
            let factor = exp(-event.scrollingDeltaY * 0.012)
            setZoom(zoom * factor, anchorScreen: location)
        } else {
            // A plain two-finger scroll pans, matching every other canvas app.
            panBy(CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
        }
    }

    /// Whether a scroll is a zoom gesture.
    ///
    /// Both ⌘ and ⌥ are accepted because the conventions differ: browsers, Figma
    /// and Preview zoom with ⌘, while Photoshop, Sketch and Maestro zoom with ⌥.
    /// Shift is deliberately *not* included — it is how you bypass mouse
    /// reporting to select text in a terminal.
    static func isZoomScroll(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option)
    }

    /// Whether the canvas should consume this scroll itself.
    ///
    /// A zoom gesture always belongs to the canvas, even directly over the
    /// focused terminal: otherwise zooming stops working whenever you are typing,
    /// which is exactly when you tend to want it.
    func canvasHandlesScroll(_ event: NSEvent, at canvasPoint: CGPoint) -> Bool {
        if CanvasView.isZoomScroll(event) { return true }
        return !terminalHandlesScroll(at: canvasPoint)
    }

    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        setZoom(zoom * (1 + event.magnification), anchorScreen: location)
    }

    override func mouseDown(with event: NSEvent) {
        // Only reachable when the click missed every node.
        window?.makeFirstResponder(self)

        // Double-clicking the plane is how a text label is born.
        if event.clickCount == 2 {
            let world = worldPoint(fromScreen: convert(event.locationInWindow, from: nil))
            canvasDelegate?.canvasView(self, didRequestTextNodeAt: world)
            return
        }

        isPanning = true
        didMoveDuringPan = false
        panStartScreen = convert(event.locationInWindow, from: nil)
        panStartPan = pan
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning else { return }
        let location = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: location.x - panStartScreen.x, y: location.y - panStartScreen.y)
        if abs(delta.x) > 2 || abs(delta.y) > 2 { didMoveDuringPan = true }
        setViewport(
            zoom: zoom,
            pan: CGPoint(x: panStartPan.x + delta.x, y: panStartPan.y + delta.y),
            notify: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning && !didMoveDuringPan {
            select(nil, focusContent: false)
        }
        isPanning = false
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete / forward delete
            if let id = selectedNodeID {
                canvasDelegate?.canvasView(self, didRequestClose: id)
            } else {
                super.keyDown(with: event)
            }
        case 53: // escape
            select(nil, focusContent: false)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        select(nil, focusContent: false)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        drawGrid()
    }

    private func drawGrid() {
        var spacing = gridSpacing
        while spacing * zoom < minGridScreenSpacing {
            spacing *= 2
        }

        let world = visibleWorldRect
        let dotRadius = min(max(1.0 * zoom, 0.7), 1.8)
        let path = NSBezierPath()
        var drawn = 0
        let maxDots = 24_000

        var worldY = (world.minY / spacing).rounded(.down) * spacing
        while worldY <= world.maxY {
            var worldX = (world.minX / spacing).rounded(.down) * spacing
            while worldX <= world.maxX {
                let screen = screenPoint(fromWorld: CGPoint(x: worldX, y: worldY))
                path.appendOval(in: NSRect(
                    x: screen.x - dotRadius,
                    y: screen.y - dotRadius,
                    width: dotRadius * 2,
                    height: dotRadius * 2
                ))
                drawn += 1
                if drawn >= maxDots { break }
                worldX += spacing
            }
            if drawn >= maxDots { break }
            worldY += spacing
        }

        gridColor.setFill()
        path.fill()
    }

    // MARK: - Node delegate routing

    private lazy var nodeDelegateProxy = NodeDelegateProxy(canvas: self)

    // MARK: - Click-to-focus

    /// A local event monitor, installed while the canvas is in a window.
    ///
    /// Terminals swallow mouse events, so the canvas cannot learn from its own
    /// `mouseDown` that a click landed inside a node. The monitor runs before
    /// dispatch and only *observes*: it never consumes the event, so text
    /// selection and mouse reporting inside the terminal still work.
    private var clickMonitor: Any?
    /// Routes scrolling away from terminals that are not the focused one.
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitors()
        } else {
            installMonitors()
        }
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
    }

    private func installMonitors() {
        if clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                if let self, event.window === self.window {
                    self.noteClick(atWindowPoint: event.locationInWindow)
                }
                return event
            }
        }

        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let canvasPoint = self.convert(event.locationInWindow, from: nil)
                // Status-bar and other chrome clicks arrive here too.
                guard self.bounds.contains(canvasPoint) else { return event }
                // Otherwise the canvas pans (or zooms), and the terminal under the
                // pointer never sees the event.
                guard self.canvasHandlesScroll(event, at: canvasPoint) else { return event }
                self.scrollWheel(with: event)
                return nil
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    /// Whether the terminal under this point should scroll itself.
    ///
    /// Only the focused node does. Scrolling across a canvas of terminals should
    /// move the canvas; otherwise the terminal that happens to be under the
    /// pointer scrolls its own history, which is almost never what you meant.
    /// With nothing focused, no terminal is affected at all.
    func terminalHandlesScroll(at canvasPoint: CGPoint) -> Bool {
        guard let node = node(at: canvasPoint) else { return false }
        return node.nodeID == focusedNodeID
    }

    private func noteClick(atWindowPoint point: CGPoint) {
        let canvasPoint = convert(point, from: nil)
        // Status-bar clicks convert to canvas coordinates too; ignore them.
        guard bounds.contains(canvasPoint) else { return }
        guard let node = node(at: canvasPoint) else { return }
        select(node, focusContent: false)
    }
}

/// Routes node events into the canvas, which forwards them to the controller.
/// Keeps `NodeFrameView` with a single delegate while still letting the
/// controller observe everything.
@MainActor
private final class NodeDelegateProxy: NodeFrameViewDelegate {
    private weak var canvas: CanvasView?

    init(canvas: CanvasView) {
        self.canvas = canvas
    }

    func nodeFrameViewDidRequestClose(_ node: NodeFrameView) {
        guard let canvas else { return }
        canvas.canvasDelegate?.canvasView(canvas, didRequestClose: node.nodeID)
    }

    func nodeFrameViewDidBeginInteraction(_ node: NodeFrameView) {
        canvas?.select(node, focusContent: false)
    }

    func nodeFrameViewDidChangeFrame(_ node: NodeFrameView) {
        canvas?.layoutNodes()
    }

    func nodeFrameViewDidEndInteraction(_ node: NodeFrameView) {
        guard let canvas else { return }
        canvas.layoutNodes()
        canvas.canvasDelegate?.canvasViewDidChangeLayout(canvas)
    }

    func nodeFrameViewDidRequestFocus(_ node: NodeFrameView) {
        canvas?.select(node, focusContent: true)
    }

    func nodeFrameView(_ node: NodeFrameView, didRenameTo title: String) {
        guard let canvas else { return }
        canvas.canvasDelegate?.canvasView(canvas, didRename: node.nodeID, to: title)
    }

    func nodeFrameView(_ node: NodeFrameView, didReceiveDropFrom sourceNodeID: UUID) -> Bool {
        guard let canvas else { return false }
        return canvas.canvasDelegate?.canvasView(canvas, nodeID: node.nodeID, didReceiveDropFrom: sourceNodeID) ?? false
    }

    func nodeFrameViewDidTakeFirstResponder(_ node: NodeFrameView) {
        canvas?.select(node, focusContent: false)
    }
}
