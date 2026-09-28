import AppKit

/// Content for a text label: the text *is* the node.
///
/// There is no title bar and no process. Clicking the box selects and moves it;
/// double-clicking (or having just been created) starts editing in place.
/// Escape or losing first responder commits, which is when the text is handed
/// back to the canvas for persistence.
@MainActor
final class TextContent: NodeContent {

    let view: NSView

    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    /// Fired when an edit is committed (Escape, a click away, or quitting).
    var onTextChange: ((String) -> Void)?

    /// Font size at 100% zoom. One font, one size, scaled by the canvas.
    static let defaultFontSize: CGFloat = 15

    private let labelView: TextContentView
    private let baseFontSize = TextContent.defaultFontSize

    init(text: String) {
        labelView = TextContentView(text: text)
        view = labelView
        labelView.onTextChange = { [weak self] text in
            self?.onTextChange?(text)
        }
    }

    /// The text as last committed.
    var text: String {
        get { labelView.text }
        set { labelView.text = newValue }
    }

    var isEditing: Bool { labelView.isEditing }

    /// The editor, so callers (and tests) can drive it.
    var editor: LabelTextView { labelView.editor }

    func focus() {
        // Focus the box, not the editor: a single click selects for moving, a
        // double-click starts editing.
        guard let window = view.window else { return }
        window.makeFirstResponder(labelView)
    }

    func beginEditing() {
        labelView.beginEditing()
    }

    func commitPendingEdits() {
        labelView.commit()
    }

    /// Text scales with the canvas exactly as terminal glyphs do: the font
    /// grows and shrinks, the box stays the same size in world units.
    func setContentScale(_ scale: CGFloat) {
        labelView.setFontSize(baseFontSize * scale)
    }
}

/// A label's box: a wrapping, scrolling text editor that is inert until it is
/// asked to edit. While inert the view is transparent to the mouse, so the node
/// frame underneath receives the drags that move the node.
final class TextContentView: NSView, InlineEditableView {

    private let scrollView = NSScrollView()
    private let textView = LabelTextView()
    private var fontSize: CGFloat = TextContent.defaultFontSize

    /// Fired when an edit is committed.
    var onTextChange: ((String) -> Void)?

    private(set) var isEditing = false

    init(text: String) {
        super.init(frame: .zero)

        textView.string = text
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
        textView.insertionPointColor = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 1)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // Word wrap, grow downwards rather than sideways, scroll when there is
        // more text than box.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.onCancel = { [weak self] in self?.commit() }

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Focus lands on the box, not the editor; that is what lets a click
    /// elsewhere resign the editor and commit.
    override var acceptsFirstResponder: Bool { true }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            needsDisplay = true
        }
    }

    /// The editor, so callers (and tests) can drive it.
    var editor: LabelTextView { textView }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    /// While not editing, the label belongs to the node frame: clicks move it
    /// and a double-click starts editing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditing else { return nil }
        return super.hitTest(point)
    }

    func beginInlineEditing() {
        beginEditing()
    }

    func beginEditing() {
        guard !isEditing, let window else { return }
        isEditing = true
        needsDisplay = true
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    /// Commits the text and hands the keyboard back to the canvas. Escape and a
    /// click away both end up here.
    func commit() {
        guard isEditing else { return }
        isEditing = false
        needsDisplay = true
        if window?.firstResponder === textView {
            window?.makeFirstResponder(enclosingCanvas())
        }
        onTextChange?(textView.string)
    }

    func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 6), 40)
        guard abs(clamped - fontSize) > 0.1 else { return }
        fontSize = clamped
        textView.font = NSFont.systemFont(ofSize: clamped)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // An empty committed label still has to look like something you can
        // double-click.
        guard !isEditing, textView.string.isEmpty else { return }
        let message = "Double-click to write" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(fontSize, 13)),
            .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
        ]
        message.draw(at: CGPoint(x: 5, y: 5), withAttributes: attributes)
    }

    private func enclosingCanvas() -> CanvasView? {
        var candidate = superview
        while let view = candidate {
            if let canvas = view as? CanvasView { return canvas }
            candidate = view.superview
        }
        return nil
    }
}

extension TextContentView: NSTextViewDelegate {

    /// Fired when the editor loses first responder without going through
    /// `commit()` — clicking another node, switching workspaces, and so on.
    func textDidEndEditing(_ notification: Notification) {
        guard isEditing else { return }
        isEditing = false
        needsDisplay = true
        onTextChange?(textView.string)
    }
}

/// Escape commits. Return inserts a newline, because a label is not a form field.
final class LabelTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            super.cancelOperation(sender)
        }
    }
}
