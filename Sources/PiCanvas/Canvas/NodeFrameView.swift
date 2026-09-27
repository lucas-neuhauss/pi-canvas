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

/// Sizes for a node's chrome, in *screen pixels* — deliberately not scaled by
/// zoom, so title bars and buttons stay usable at every zoom level while the
/// terminal inside reflows to fill whatever pixel area remains.
enum NodeMetrics {
    static let titleBarHeight: CGFloat = 26
    static let contentPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 10
    static let closeButtonSize: CGFloat = 16
    static let resizeHandleSize: CGFloat = 20
    static let minWorldWidth: CGFloat = 240
    static let minWorldHeight: CGFloat = 150
    static let contentCornerRadius: CGFloat = 4
}

/// One panel on the canvas: a title bar, a resize grip, and a content view
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
    /// Optional status pill, e.g. "exited (1)".
    var statusText: String? {
        didSet { if statusText != oldValue { needsDisplay = true } }
    }
    var statusIsWarning = false {
        didSet { needsDisplay = true }
    }

    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
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
        case resize
        case closeButton
    }

    private var dragMode: DragMode = .none
    private var dragStartWorldMouse: CGPoint = .zero
    private var dragStartWorldFrame: CGRect = .zero
    private var didDrag = false

    // MARK: - Init

    init(nodeID: UUID, worldFrame: CGRect, kind: NodeKind) {
        self.nodeID = nodeID
        self.worldFrame = worldFrame
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = NodeMetrics.cornerRadius
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
        let top = NodeMetrics.titleBarHeight + 2
        let pad = NodeMetrics.contentPadding
        let rect = CGRect(
            x: 1 + pad,
            y: top,
            width: max(bounds.width - 2 - pad * 2, 1),
            height: max(bounds.height - top - 1 - pad, 1)
        )
        return rect.integral
    }

    private var closeRect: CGRect {
        let size = NodeMetrics.closeButtonSize
        return CGRect(
            x: bounds.width - NodeMetrics.contentPadding - size,
            y: (NodeMetrics.titleBarHeight - size) / 2,
            width: size,
            height: size
        )
    }

    private var resizeRect: CGRect {
        let size = NodeMetrics.resizeHandleSize
        return CGRect(x: bounds.width - size, y: bounds.height - size, width: size, height: size)
    }

    private func isPointInTitleBar(_ point: CGPoint) -> Bool {
        point.y <= NodeMetrics.titleBarHeight
    }

    override func layout() {
        super.layout()
        contentView?.frame = contentRect
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: NodeMetrics.cornerRadius,
            cornerHeight: NodeMetrics.cornerRadius,
            transform: nil
        )
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(
            CGRect(x: 0, y: 0, width: max(bounds.width - NodeMetrics.closeButtonSize - 20, 1), height: NodeMetrics.titleBarHeight),
            cursor: .openHand
        )
        if let diagonal = NSCursor.fromSymbol("arrow.up.left.and.arrow.down.right") {
            addCursorRect(resizeRect, cursor: diagonal)
        } else {
            addCursorRect(resizeRect, cursor: .crosshair)
        }
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

        if resizeRect.contains(point) {
            dragMode = .resize
        } else if isPointInTitleBar(point) {
            dragMode = .move
        } else {
            // Clicking the node's padding: select and hand focus to the terminal.
            dragMode = .none
            nodeDelegate?.nodeFrameViewDidRequestFocus(self)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragMode == .move || dragMode == .resize, let world = worldPoint(for: event) else { return }
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
        case .resize:
            let width = max(dragStartWorldFrame.size.width + delta.x, NodeMetrics.minWorldWidth)
            let height = max(dragStartWorldFrame.size.height + delta.y, NodeMetrics.minWorldHeight)
            worldFrame.size = CGSize(width: width.rounded(), height: height.rounded())
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
        case .move, .resize:
            nodeDelegate?.nodeFrameViewDidEndInteraction(self)
            if !didDrag && mode == .move {
                nodeDelegate?.nodeFrameViewDidRequestFocus(self)
            }
        case .none:
            break
        }
        didDrag = false
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

        // The layer already paints the background and the corner radius; we only
        // draw the border, the title bar contents and the resize grip.
        let borderColor: NSColor
        var borderWidth: CGFloat = 1
        if isFocused {
            borderColor = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 0.95)
            borderWidth = 1
        } else if isSelected {
            borderColor = borderSelected
        } else {
            borderColor = borderIdle
        }

        context.saveGState()
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
            xRadius: NodeMetrics.cornerRadius,
            yRadius: NodeMetrics.cornerRadius
        )
        borderPath.lineWidth = borderWidth
        borderColor.setStroke()
        borderPath.stroke()

        // Separator under the title bar.
        separatorColor.setFill()
        NSRect(x: 1, y: NodeMetrics.titleBarHeight, width: bounds.width - 2, height: 1).fill()
        context.restoreGState()

        drawTitleBar()
        drawResizeGrip()
    }

    private func drawTitleBar() {
        let dotDiameter: CGFloat = 7
        let dotX = NodeMetrics.contentPadding + 1
        let dotY = (NodeMetrics.titleBarHeight - dotDiameter) / 2
        let accent = kind.accent
        NSColor(
            srgbRed: CGFloat(accent.0),
            green: CGFloat(accent.1),
            blue: CGFloat(accent.2),
            alpha: isFocused ? 1 : 0.75
        ).setFill()
        NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter)).fill()

        // Close button: an × whose contrast rises with focus / hover.
        let close = closeRect
        let closeAlpha: CGFloat = isFocused ? 0.55 : 0.3
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: closeAlpha).setStroke()
        let cross = NSBezierPath()
        let inset: CGFloat = 4.5
        cross.move(to: CGPoint(x: close.minX + inset, y: close.minY + inset))
        cross.line(to: CGPoint(x: close.maxX - inset, y: close.maxY - inset))
        cross.move(to: CGPoint(x: close.maxX - inset, y: close.minY + inset))
        cross.line(to: CGPoint(x: close.minX + inset, y: close.maxY - inset))
        cross.lineWidth = 1.4
        cross.stroke()

        // Status pill, if any.
        var textRightLimit = close.minX - 6
        if let statusText, !statusText.isEmpty {
            let font = NSFont.systemFont(ofSize: 10, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: statusIsWarning
                    ? NSColor(srgbRed: 1.0, green: 0.55, blue: 0.45, alpha: 1)
                    : NSColor(srgbRed: 0.6, green: 0.9, blue: 0.7, alpha: 1)
            ]
            let textSize = (statusText as NSString).size(withAttributes: attributes)
            let pillWidth = textSize.width + 12
            let pillHeight: CGFloat = 15
            let pillRect = CGRect(
                x: max(textRightLimit - pillWidth, dotX + dotDiameter + 8),
                y: (NodeMetrics.titleBarHeight - pillHeight) / 2,
                width: pillWidth,
                height: pillHeight
            )
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            (statusIsWarning
                ? NSColor(srgbRed: 1, green: 0.45, blue: 0.4, alpha: 0.14)
                : NSColor(srgbRed: 0.4, green: 0.9, blue: 0.6, alpha: 0.12)).setFill()
            pillPath.fill()
            (statusText as NSString).draw(
                in: CGRect(x: pillRect.minX + 6, y: pillRect.minY + 2, width: textSize.width, height: textSize.height),
                withAttributes: attributes
            )
            textRightLimit = pillRect.minX - 8
        }

        // Title (and subtitle), truncated to the space left of the pill / close button.
        let textOriginX = dotX + dotDiameter + 8
        let availableWidth = max(textRightLimit - textOriginX, 10)

        let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
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
            y: (NodeMetrics.titleBarHeight - titleHeight) / 2,
            width: availableWidth,
            height: titleHeight
        )

        let titleString = NSAttributedString(string: titleText, attributes: titleAttributes)
        titleString.draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if !subtitle.isEmpty {
            let usedWidth = min(titleString.size().width, availableWidth)
            let subtitleGap: CGFloat = 7
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
                    y: (NodeMetrics.titleBarHeight - subtitleHeight) / 2,
                    width: remaining,
                    height: subtitleHeight
                )
                NSAttributedString(string: subtitle, attributes: subtitleAttributes)
                    .draw(with: subtitleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }

    private func drawResizeGrip() {
        let rect = resizeRect
        let alpha: CGFloat = isFocused ? 0.42 : 0.22
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha).setStroke()
        let path = NSBezierPath()
        let step: CGFloat = 4
        let lines = 3
        let start = CGPoint(x: rect.maxX - 5, y: rect.maxY - 5)
        for index in 0..<lines {
            let offset = CGFloat(index) * step
            path.move(to: CGPoint(x: start.x - offset, y: start.y))
            path.line(to: CGPoint(x: start.x, y: start.y - offset))
        }
        path.lineWidth = 1.2
        path.stroke()
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
