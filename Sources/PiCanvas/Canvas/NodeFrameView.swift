import AppKit

@MainActor
protocol NodeFrameViewDelegate: AnyObject {
    func nodeFrameViewDidRequestClose(_ node: NodeFrameView)
    func nodeFrameViewDidBeginInteraction(_ node: NodeFrameView)
    func nodeFrameViewDidChangeFrame(_ node: NodeFrameView)
    func nodeFrameViewDidEndInteraction(_ node: NodeFrameView)
    func nodeFrameViewDidRequestFocus(_ node: NodeFrameView)
    /// The terminal inside the node became first responder on its own (user clicked it).
    func nodeFrameViewDidTakeFirstResponder(_ node: NodeFrameView)
}

/// Base sizes for a node's chrome, in screen pixels at 100% zoom. Everything is
/// multiplied by `NodeFrameView.chromeScale` (driven by canvas zoom) so chrome
/// tracks zoom without becoming unusable at the extremes.
enum NodeMetrics {
    static let titleBarHeight: CGFloat = 26
    /// The gutter around the terminal. This is deliberately the same width as
    /// `resizeThickness`: the terminal must never sit underneath a resize band,
    /// because SwiftTerm claims its whole bounds (I-beam cursor rect plus its own
    /// tracking area) and would swallow the pointer there. So the visible gutter
    /// *is* the resize handle.
    static let contentPadding: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    static let closeButtonSize: CGFloat = 16
    /// How thick the draggable border is for edge resizing.
    static let resizeThickness: CGFloat = 8
    /// The top edge sits inside the title bar, so its grab band is thinner.
    static let topResizeThickness: CGFloat = 6
    static let minWorldWidth: CGFloat = 240
    static let minWorldHeight: CGFloat = 150
    static let contentCornerRadius: CGFloat = 4
}

/// How a node's status pill is coloured.
enum NodeStatusKind {
    case idle
    case running
    case needsAttention
    case failure

    /// Text and background colours for the pill.
    var colors: (text: NSColor, background: NSColor) {
        switch self {
        case .idle:
            return (
                NSColor(srgbRed: 0.72, green: 0.76, blue: 0.82, alpha: 1),
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
            )
        case .running:
            return (
                NSColor(srgbRed: 1.0, green: 0.78, blue: 0.38, alpha: 1),
                NSColor(srgbRed: 1.0, green: 0.72, blue: 0.3, alpha: 0.14)
            )
        case .needsAttention:
            return (
                NSColor(srgbRed: 0.55, green: 0.92, blue: 0.66, alpha: 1),
                NSColor(srgbRed: 0.4, green: 0.9, blue: 0.6, alpha: 0.16)
            )
        case .failure:
            return (
                NSColor(srgbRed: 1.0, green: 0.55, blue: 0.45, alpha: 1),
                NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 0.14)
            )
        }
    }
}

/// Which borders of a node a drag is resizing.
struct ResizeEdge: OptionSet, Equatable {
    let rawValue: Int

    static let left = ResizeEdge(rawValue: 1 << 0)
    static let right = ResizeEdge(rawValue: 1 << 1)
    static let top = ResizeEdge(rawValue: 1 << 2)
    static let bottom = ResizeEdge(rawValue: 1 << 3)

    var isCorner: Bool {
        (contains(.left) || contains(.right)) && (contains(.top) || contains(.bottom))
    }
}

/// Sizes derived from the current zoom.
struct NodeChrome {
    var scale: CGFloat

    var titleBarHeight: CGFloat { NodeMetrics.titleBarHeight * scale }
    var padding: CGFloat { NodeMetrics.contentPadding * scale }
    var cornerRadius: CGFloat { NodeMetrics.cornerRadius * scale }
    var closeSize: CGFloat { NodeMetrics.closeButtonSize * scale }
    var dotDiameter: CGFloat { 7 * scale }
    var pillHeight: CGFloat { 15 * scale }
    var titleFontSize: CGFloat { 12 * scale }
    var subtitleFontSize: CGFloat { 11 * scale }
    var pillFontSize: CGFloat { 10 * scale }
}

/// One panel on the canvas: a title bar, a resize border, and a content view
/// (the terminal). Holds its own world-space frame; the canvas converts that to
/// a screen frame on every layout pass.
final class NodeFrameView: NSView {

    let nodeID: UUID

    /// Position and size in canvas world units.
    var worldFrame: CGRect
    /// User-visible title (usually the terminal title).
    var title: String = "" {
        didSet { if title != oldValue { needsDisplay = true } }
    }
    /// Secondary text in the title bar, e.g. the working directory.
    var subtitle: String = "" {
        didSet { if subtitle != oldValue { needsDisplay = true } }
    }
    var kind: NodeKind = .shell {
        didSet { needsDisplay = true }
    }
    /// Optional status pill, e.g. "needs you" or "exited (1)".
    var statusText: String? {
        didSet { if statusText != oldValue { needsDisplay = true } }
    }
    var statusKind: NodeStatusKind = .idle {
        didSet { needsDisplay = true }
    }
    /// Session spend so far, drawn as dim text in the title bar.
    var costText: String? {
        didSet { if costText != oldValue { needsDisplay = true } }
    }

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }

    /// Chrome size multiplier, set by the canvas from the zoom level.
    var chromeScale: CGFloat = 1 {
        didSet {
            guard abs(chromeScale - oldValue) > 0.001 else { return }
            needsLayout = true
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    weak var nodeDelegate: NodeFrameViewDelegate?

    /// The terminal. Setting it installs it below the chrome.
    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let contentView {
                addSubview(contentView)
            }
            needsLayout = true
        }
    }

    private enum DragMode {
        case none
        case move
        case resize(ResizeEdge)
        case closeButton
    }

    private var dragMode: DragMode = .none
    private var dragStartWorldMouse: CGPoint = .zero
    private var dragStartWorldFrame: CGRect = .zero
    private var didDrag = false

    private var chrome: NodeChrome { NodeChrome(scale: chromeScale) }

    // MARK: - Init

    init(nodeID: UUID, worldFrame: CGRect, kind: NodeKind) {
        self.nodeID = nodeID
        self.worldFrame = worldFrame
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 9
        layer?.shadowOffset = .zero
        layer?.backgroundColor = NSColor(srgbRed: 0.106, green: 0.110, blue: 0.125, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Geometry

    override var isFlipped: Bool { true }

    var contentRect: CGRect {
        let chrome = chrome
        let top = chrome.titleBarHeight + 2
        let pad = chrome.padding
        let rect = CGRect(
            x: 1 + pad,
            y: top,
            width: max(bounds.width - 2 - pad * 2, 1),
            height: max(bounds.height - top - 1 - pad, 1)
        )
        return rect.integral
    }

    private var closeRect: CGRect {
        let chrome = chrome
        let size = chrome.closeSize
        return CGRect(
            x: bounds.width - chrome.padding - size,
            y: (chrome.titleBarHeight - size) / 2,
            width: size,
            height: size
        )
    }

    /// Which borders the point is close enough to drag. Being within the band of
    /// two perpendicular borders makes it a corner, which needs no special case.
    /// The top band is thinner so the title bar stays grabbable for moving.
    func resizeEdge(at point: CGPoint) -> ResizeEdge? {
        let edgeThickness = max(NodeMetrics.resizeThickness * chromeScale, 6)
        let topThickness = max(NodeMetrics.topResizeThickness * chromeScale, 4)

        var edge: ResizeEdge = []
        if point.x <= edgeThickness { edge.insert(.left) }
        if point.x >= bounds.width - edgeThickness { edge.insert(.right) }
        if point.y <= topThickness { edge.insert(.top) }
        if point.y >= bounds.height - edgeThickness { edge.insert(.bottom) }

        return edge.isEmpty ? nil : edge
    }

    override func layout() {
        super.layout()
        contentView?.frame = contentRect
        layer?.cornerRadius = chrome.cornerRadius
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: chrome.cornerRadius,
            cornerHeight: chrome.cornerRadius,
            transform: nil
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let chrome = chrome
        let edgeThickness = max(NodeMetrics.resizeThickness * chromeScale, 6)
        let topThickness = max(NodeMetrics.topResizeThickness * chromeScale, 4)

        // The close button gets a plain arrow, then the resize bands, then the
        // title bar (minus the close button and the top band) moves the node.
        addCursorRect(closeRect.insetBy(dx: -2, dy: -2), cursor: .arrow)

        // Every border and corner is draggable, with the matching native cursor.
        addCursorRect(CGRect(x: 0, y: topThickness, width: edgeThickness, height: max(bounds.height - topThickness - edgeThickness, 1)), cursor: NodeCursor.resize([.left]))
        addCursorRect(CGRect(x: bounds.width - edgeThickness, y: topThickness, width: edgeThickness, height: max(bounds.height - topThickness - edgeThickness, 1)), cursor: NodeCursor.resize([.right]))
        addCursorRect(CGRect(x: edgeThickness, y: 0, width: max(bounds.width - edgeThickness * 2, 1), height: topThickness), cursor: NodeCursor.resize([.top]))
        addCursorRect(CGRect(x: edgeThickness, y: bounds.height - edgeThickness, width: max(bounds.width - edgeThickness * 2, 1), height: edgeThickness), cursor: NodeCursor.resize([.bottom]))
        addCursorRect(CGRect(x: 0, y: 0, width: edgeThickness, height: topThickness), cursor: NodeCursor.resize([.left, .top]))
        addCursorRect(CGRect(x: bounds.width - edgeThickness, y: 0, width: edgeThickness, height: topThickness), cursor: NodeCursor.resize([.right, .top]))
        addCursorRect(CGRect(x: 0, y: bounds.height - edgeThickness, width: edgeThickness, height: edgeThickness), cursor: NodeCursor.resize([.left, .bottom]))
        addCursorRect(CGRect(x: bounds.width - edgeThickness, y: bounds.height - edgeThickness, width: edgeThickness, height: edgeThickness), cursor: NodeCursor.resize([.right, .bottom]))

        addCursorRect(
            CGRect(x: 0, y: topThickness, width: max(bounds.width - chrome.closeSize - chrome.padding * 2, 1), height: max(chrome.titleBarHeight - topThickness, 1)),
            cursor: .openHand
        )
    }

    // MARK: - Canvas helpers

    private func canvasPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        guard let superview else { return local }
        return superview.convert(local, from: self)
    }

    private func worldPoint(for event: NSEvent) -> CGPoint? {
        guard let canvas = superview as? CanvasView else { return nil }
        return canvas.worldPoint(fromScreen: canvasPoint(for: event))
    }

    // MARK: - Mouse interaction

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        nodeDelegate?.nodeFrameViewDidBeginInteraction(self)

        // The close button is small and specific, so it wins over the corner band.
        if closeRect.contains(point) {
            dragMode = .closeButton
            return
        }

        guard let world = worldPoint(for: event) else {
            dragMode = .none
            return
        }
        dragStartWorldMouse = world
        dragStartWorldFrame = worldFrame

        if let edge = resizeEdge(at: point) {
            dragMode = .resize(edge)
        } else if point.y <= chrome.titleBarHeight {
            dragMode = .move
        } else {
            // Clicking the node's padding: select and hand focus to the terminal.
            dragMode = .none
            nodeDelegate?.nodeFrameViewDidRequestFocus(self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let world = worldPoint(for: event) else { return }
        let delta = CGPoint(x: world.x - dragStartWorldMouse.x, y: world.y - dragStartWorldMouse.y)
        if abs(delta.x) > 0.5 || abs(delta.y) > 0.5 { didDrag = true }
        guard didDrag else { return }

        switch dragMode {
        case .move:
            let origin = CGPoint(
                x: dragStartWorldFrame.origin.x + delta.x,
                y: dragStartWorldFrame.origin.y + delta.y
            )
            worldFrame.origin = snap(origin)

        case .resize(let edge):
            worldFrame = resized(dragStartWorldFrame, by: delta, edges: edge)

        default:
            break
        }

        nodeDelegate?.nodeFrameViewDidChangeFrame(self)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let mode = dragMode
        dragMode = .none

        switch mode {
        case .closeButton:
            if closeRect.contains(point) {
                nodeDelegate?.nodeFrameViewDidRequestClose(self)
            }
        case .move:
            nodeDelegate?.nodeFrameViewDidEndInteraction(self)
            if !didDrag {
                nodeDelegate?.nodeFrameViewDidRequestFocus(self)
            }
        case .resize:
            nodeDelegate?.nodeFrameViewDidEndInteraction(self)
        case .none:
            break
        }
        didDrag = false
    }

    /// Applies a drag to the grabbed borders. The opposite borders stay put, so
    /// dragging the left edge moves the origin rather than the whole node.
    private func resized(_ start: CGRect, by delta: CGPoint, edges: ResizeEdge) -> CGRect {
        var frame = start
        let minWidth = NodeMetrics.minWorldWidth
        let minHeight = NodeMetrics.minWorldHeight

        if edges.contains(.right) {
            frame.size.width = max(start.width + delta.x, minWidth).rounded()
        }
        if edges.contains(.bottom) {
            frame.size.height = max(start.height + delta.y, minHeight).rounded()
        }
        if edges.contains(.left) {
            let width = max(start.width - delta.x, minWidth).rounded()
            frame.origin.x = (start.maxX - width).rounded()
            frame.size.width = width
        }
        if edges.contains(.top) {
            let height = max(start.height - delta.y, minHeight).rounded()
            frame.origin.y = (start.maxY - height).rounded()
            frame.size.height = height
        }
        return frame
    }

    /// Keeps dragged nodes on a whole world-unit grid so layouts stay tidy.
    private func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.rounded(), y: point.y.rounded())
    }

    // MARK: - Drawing

    private let borderIdle = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    private let borderSelected = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
    private let separatorColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let chrome = chrome

        let borderColor: NSColor
        if isFocused {
            borderColor = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 0.95)
        } else if isSelected {
            borderColor = borderSelected
        } else {
            borderColor = borderIdle
        }

        context.saveGState()
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: chrome.cornerRadius,
            yRadius: chrome.cornerRadius
        )
        borderPath.lineWidth = 1
        borderColor.setStroke()
        borderPath.stroke()

        // Separator under the title bar.
        separatorColor.setFill()
        NSRect(x: 1, y: chrome.titleBarHeight, width: bounds.width - 2, height: 1).fill()
        context.restoreGState()

        drawTitleBar()
    }

    private func drawTitleBar() {
        let chrome = chrome
        let dotDiameter = chrome.dotDiameter
        let dotX = chrome.padding + 1
        let dotY = (chrome.titleBarHeight - dotDiameter) / 2
        let accent = kind.accent
        NSColor(
            srgbRed: CGFloat(accent.0),
            green: CGFloat(accent.1),
            blue: CGFloat(accent.2),
            alpha: isFocused ? 1 : 0.75
        ).setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter)).fill()

        // Close button: an × whose contrast rises with focus.
        let close = closeRect
        let closeAlpha: CGFloat = isFocused ? 0.55 : 0.3
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: closeAlpha).setStroke()
        let cross = NSBezierPath()
        let inset = close.width * 0.28
        cross.move(to: CGPoint(x: close.minX + inset, y: close.minY + inset))
        cross.line(to: CGPoint(x: close.maxX - inset, y: close.maxY - inset))
        cross.move(to: CGPoint(x: close.maxX - inset, y: close.minY + inset))
        cross.line(to: CGPoint(x: close.minX + inset, y: close.maxY - inset))
        cross.lineWidth = max(1.0, 1.4 * chromeScale)
        cross.stroke()

        var textRightLimit = close.minX - 6 * chromeScale

        // Session cost, as quiet dim text before the pill.
        if let costText, !costText.isEmpty {
            let font = NSFont.monospacedDigitSystemFont(ofSize: chrome.pillFontSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.40)
            ]
            let size = (costText as NSString).size(withAttributes: attributes)
            let leftEdge = dotX + dotDiameter + 46 * chromeScale
            if textRightLimit - size.width - 12 * chromeScale > leftEdge {
                (costText as NSString).draw(
                    in: CGRect(
                        x: textRightLimit - size.width,
                        y: (chrome.titleBarHeight - size.height) / 2,
                        width: size.width,
                        height: size.height
                    ),
                    withAttributes: attributes
                )
                textRightLimit -= size.width + 12 * chromeScale
            }
        }

        // Status pill, if any.
        if let statusText, !statusText.isEmpty {
            let font = NSFont.systemFont(ofSize: chrome.pillFontSize, weight: .medium)
            let colors = statusKind.colors
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colors.text
            ]
            let textSize = (statusText as NSString).size(withAttributes: attributes)
            let pillWidth = textSize.width + 12 * chromeScale
            let pillHeight = chrome.pillHeight
            let pillRect = CGRect(
                x: max(textRightLimit - pillWidth, dotX + dotDiameter + 8),
                y: (chrome.titleBarHeight - pillHeight) / 2,
                width: pillWidth,
                height: pillHeight
            )
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            colors.background.setFill()
            pillPath.fill()
            (statusText as NSString).draw(
                in: CGRect(
                    x: pillRect.minX + 6 * chromeScale,
                    y: pillRect.midY - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                ),
                withAttributes: attributes
            )
            textRightLimit = pillRect.minX - 8 * chromeScale
        }

        // Title (and subtitle), truncated to the space left of the pill / close button.
        let textOriginX = dotX + dotDiameter + 8 * chromeScale
        let availableWidth = max(textRightLimit - textOriginX, 10)

        let titleFont = NSFont.systemFont(ofSize: chrome.titleFontSize, weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: chrome.subtitleFontSize, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let titleText = title.isEmpty ? kind.displayName : title
        let titleColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: isFocused ? 0.94 : 0.72)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph
        ]

        let titleHeight = titleFont.ascender - titleFont.descender
        let titleRect = CGRect(
            x: textOriginX,
            y: (chrome.titleBarHeight - titleHeight) / 2,
            width: availableWidth,
            height: titleHeight
        )

        let titleString = NSAttributedString(string: titleText, attributes: titleAttributes)
        titleString.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if !subtitle.isEmpty {
            let usedWidth = min(titleString.size().width, availableWidth)
            let subtitleGap = 7 * chromeScale
            let subtitleLeft = textOriginX + usedWidth + subtitleGap
            let remaining = textRightLimit - subtitleLeft
            if remaining > 30 {
                let subtitleAttributes: [NSAttributedString.Key: Any] = [
                    .font: subtitleFont,
                    .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.38),
                    .paragraphStyle: paragraph
                ]
                let subtitleHeight = subtitleFont.ascender - subtitleFont.descender
                let subtitleRect = CGRect(
                    x: subtitleLeft,
                    y: (chrome.titleBarHeight - subtitleHeight) / 2,
                    width: remaining,
                    height: subtitleHeight
                )
                NSAttributedString(string: subtitle, attributes: subtitleAttributes)
                    .draw(with: subtitleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

}

/// Native frame-resize cursors where available, SF Symbol cursors elsewhere.
enum NodeCursor {
    static func resize(_ edge: ResizeEdge) -> NSCursor {
        if #available(macOS 15.0, *) {
            if let position = position(for: edge) {
                return NSCursor.frameResize(position: position, directions: [.inward, .outward])
            }
        }
        return fallback(edge)
    }

    @available(macOS 15.0, *)
    private static func position(for edge: ResizeEdge) -> NSCursor.FrameResizePosition? {
        switch (edge.contains(.left), edge.contains(.right), edge.contains(.top), edge.contains(.bottom)) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return nil
        }
    }

    private static func fallback(_ edge: ResizeEdge) -> NSCursor {
        let horizontal = edge.contains(.left) || edge.contains(.right)
        let vertical = edge.contains(.top) || edge.contains(.bottom)
        if horizontal && vertical {
            if edge.contains(.top) && edge.contains(.left) {
                return NSCursor.fromSymbol("arrow.up.left.and.arrow.down.right") ?? .crosshair
            }
            if edge.contains(.bottom) && edge.contains(.right) {
                return NSCursor.fromSymbol("arrow.up.left.and.arrow.down.right") ?? .crosshair
            }
            return NSCursor.fromSymbol("arrow.up.right.and.arrow.down.left") ?? .crosshair
        }
        if horizontal { return .resizeLeftRight }
        return .resizeUpDown
    }
}

extension NSCursor {
    /// A cursor built from an SF Symbol, if one is available on this system.
    static func fromSymbol(_ name: String) -> NSCursor? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        return NSCursor(image: image, hotSpot: CGPoint(x: image.size.width / 2, y: image.size.height / 2))
    }
}
