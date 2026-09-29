import AppKit

/// Content for a note node: a markdown file with a plain-text editor and a
/// rendered preview.
///
/// The file is the source of truth. Typing schedules a debounced save; leaving
/// write mode, closing the node or quitting flushes it, so there is no Save
/// button. The preview is rendered natively from `AttributedString(markdown:)`
/// — no web view.
@MainActor
final class NoteContent: NodeContent {

    let view: NSView

    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    /// Font sizes at 100% zoom.
    static let editorFontSize: CGFloat = 13
    static let previewFontSize: CGFloat = 14

    private let noteURL: URL
    private let noteView: NoteContentView
    private var saveWork: DispatchWorkItem?
    private var lastTitle = ""

    private(set) var contentScale: CGFloat = 1

    init(noteURL: URL) {
        self.noteURL = noteURL
        let text = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
        noteView = NoteContentView(text: text)
        view = noteView
        noteView.onTextEdit = { [weak self] value in
            self?.textEdited(value)
        }
        noteView.onCommit = { [weak self] in
            self?.flush()
        }
        noteView.setScale(1)
        lastTitle = NoteContent.title(of: text)
    }

    // MARK: - Editing

    /// The source text.
    var text: String {
        get { noteView.text }
        set {
            noteView.text = newValue
            textEdited(newValue)
        }
    }

    var isPreviewing: Bool { noteView.isPreviewing }

    /// The node title derived from the first heading, whether or not an edit has
    /// happened yet.
    var title: String { NoteContent.title(of: noteView.text) }

    /// Whether the markdown editor holds the keyboard (for tests).
    var editorIsFirstResponder: Bool { noteView.editorIsFirstResponder }

    func setPreviewing(_ previewing: Bool) {
        // Leaving write mode commits what is on screen.
        if previewing { flush() }
        noteView.setPreviewing(previewing)
    }

    /// The rendered preview. Rendered on demand so tests (and a mode change)
    /// always see the current source.
    var renderedPreview: NSAttributedString { noteView.renderedPreview }

    func focus() {
        noteView.focusActiveView()
    }

    func beginEditing() {
        noteView.setPreviewing(false)
        noteView.focusActiveView()
    }

    /// Writes whatever is in the editor right now.
    func flush() {
        saveWork?.cancel()
        saveWork = nil
        write(noteView.text)
    }

    func commitPendingEdits() {
        flush()
    }

    func setContentScale(_ scale: CGFloat) {
        guard abs(scale - contentScale) > 0.001 else { return }
        contentScale = scale
        noteView.setScale(scale)
    }

    // MARK: - Saving and titling

    private func textEdited(_ text: String) {
        scheduleSave(text)
        let title = NoteContent.title(of: text)
        guard !title.isEmpty, title != lastTitle else { return }
        lastTitle = title
        onTitleChange?(title)
    }

    private func scheduleSave(_ text: String) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(text) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func write(_ text: String) {
        do {
            try text.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[PiCanvas] could not save note %@: %@", noteURL.path, error.localizedDescription)
        }
    }

    /// The first non-empty line, with leading hashes stripped: enough for the
    /// node's title bar and the switcher.
    private static func title(of text: String) -> String {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        var title = line.trimmingCharacters(in: .whitespaces)
        while title.hasPrefix("#") {
            title.removeFirst()
        }
        return title.trimmingCharacters(in: .whitespaces)
    }
}

/// A note's box: a Write/Preview toggle over one scroll view whose document
/// view is swapped between a plain monospaced editor and the rendered preview.
final class NoteContentView: NSView {

    private enum Mode: Int {
        case write = 0
        case preview = 1

        var title: String {
            switch self {
            case .write: return "Write"
            case .preview: return "Preview"
            }
        }
    }

    private let scrollView = NSScrollView()
    private let editor = NSTextView()
    private let preview = NSTextView()
    private var mode: Mode = .write
    private var scale: CGFloat = 1
    /// The Write / Preview click targets, rebuilt on every layout.
    private var toggleTargets: [(mode: Mode, rect: CGRect)] = []

    /// Fired on every keystroke in write mode.
    var onTextEdit: ((String) -> Void)?
    /// Fired when an edit is about to be left behind (switching to preview).
    var onCommit: (() -> Void)?

    override var isFlipped: Bool { true }

    init(text: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.058, blue: 0.066, alpha: 1).cgColor

        // The editor: plain markdown, monospaced, wrapping.
        editor.string = text
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
        editor.insertionPointColor = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 1)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        // Markdown is the format; smart quotes would corrupt code samples.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        prepare(editor)
        editor.delegate = self

        // The preview: the same text, rendered, and clickable links.
        preview.isEditable = false
        preview.isSelectable = true
        preview.drawsBackground = false
        preview.textContainerInset = NSSize(width: 6, height: 6)
        preview.linkTextAttributes = [
            .foregroundColor: NSColor(srgbRed: 0.45, green: 0.68, blue: 1.0, alpha: 1),
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        prepare(preview)
        preview.delegate = self

        scrollView.documentView = editor
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func prepare(_ textView: NSTextView) {
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }

    var text: String {
        get { editor.string }
        set { editor.string = newValue }
    }

    var isPreviewing: Bool { mode == .preview }

    var renderedPreview: NSAttributedString {
        renderPreview()
        return preview.attributedString()
    }

    func setPreviewing(_ previewing: Bool) {
        let newMode: Mode = previewing ? .preview : .write
        guard newMode != mode else { return }
        if mode == .write { onCommit?() }
        // If the editor had the keyboard, hand it to whichever view replaces it:
        // typing into a hidden editor would be invisible but real.
        let wasFocused = window?.firstResponder === editor || window?.firstResponder === preview
        mode = newMode
        if mode == .preview {
            renderPreview()
            scrollView.documentView = preview
        } else {
            scrollView.documentView = editor
        }
        if wasFocused { focusActiveView() }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func focusActiveView() {
        guard let window else { return }
        window.makeFirstResponder(mode == .preview ? preview : editor)
    }

    /// Whether the markdown editor itself holds the keyboard (for tests).
    var editorIsFirstResponder: Bool { window?.firstResponder === editor }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        let editorSize = min(max(NoteContent.editorFontSize * scale, 4), 30)
        editor.font = NSFont.monospacedSystemFont(ofSize: editorSize, weight: .regular)
        if mode == .preview {
            renderPreview()
        }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private var chromeScale: CGFloat { CanvasView.chromeScale(forZoom: scale) }
    private var headerHeight: CGFloat { max(26 * chromeScale, 24) }
    private var toggleFont: NSFont { NSFont.systemFont(ofSize: max(10.5 * chromeScale, 9), weight: .medium) }

    override func layout() {
        super.layout()
        let header = headerHeight
        let font = toggleFont
        let height = max(18 * chromeScale, 16)
        var x = 8 * chromeScale
        toggleTargets = []
        for mode in [Mode.write, .preview] {
            let title = mode.title as NSString
            let width = title.size(withAttributes: [.font: font]).width + 20 * chromeScale
            toggleTargets.append((
                mode,
                CGRect(x: x, y: (header - height) / 2, width: width, height: height).integral
            ))
            x += width + 2 * chromeScale
        }
        scrollView.frame = CGRect(
            x: 0,
            y: header,
            width: bounds.width,
            height: max(bounds.height - header, 0)
        )
    }

    /// A flat toggle drawn like the rest of the chrome, so it tracks zoom with
    /// the title bar instead of fighting it.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for target in toggleTargets {
            let selected = target.mode == mode
            if selected {
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).setFill()
                NSBezierPath(
                    roundedRect: target.rect,
                    xRadius: target.rect.height / 2,
                    yRadius: target.rect.height / 2
                ).fill()
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: toggleFont,
                .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: selected ? 0.92 : 0.45),
                .paragraphStyle: paragraph
            ]
            let title = target.mode.title as NSString
            let size = title.size(withAttributes: attributes)
            title.draw(
                in: CGRect(
                    x: target.rect.minX,
                    y: target.rect.midY - size.height / 2,
                    width: target.rect.width,
                    height: size.height
                ),
                withAttributes: attributes
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for target in toggleTargets where target.rect.contains(point) {
            setPreviewing(target.mode == .preview)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for target in toggleTargets {
            addCursorRect(target.rect, cursor: .pointingHand)
        }
    }

    private func renderPreview() {
        let previewSize = min(max(NoteContent.previewFontSize * scale, 5), 34)
        let rendered = MarkdownPreview.render(
            editor.string,
            baseFontSize: previewSize,
            textColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
            secondaryColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.62),
            linkColor: NSColor(srgbRed: 0.45, green: 0.68, blue: 1.0, alpha: 1),
            codeColor: NSColor(srgbRed: 0.88, green: 0.76, blue: 0.52, alpha: 1),
            codeBackground: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
        )
        preview.textStorage?.setAttributedString(rendered)
    }
}

extension NoteContentView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === editor else { return }
        onTextEdit?(editor.string)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
