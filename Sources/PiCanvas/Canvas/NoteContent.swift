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
    }

    private let segmented: NSSegmentedControl
    private let scrollView = NSScrollView()
    private let editor = NSTextView()
    private let preview = NSTextView()
    private var mode: Mode = .write
    private var scale: CGFloat = 1

    /// Fired on every keystroke in write mode.
    var onTextEdit: ((String) -> Void)?
    /// Fired when an edit is about to be left behind (switching to preview).
    var onCommit: (() -> Void)?

    override var isFlipped: Bool { true }

    init(text: String) {
        segmented = NSSegmentedControl(labels: ["Write", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.058, blue: 0.066, alpha: 1).cgColor

        segmented.target = self
        segmented.action = #selector(modeChanged)
        segmented.controlSize = .small
        segmented.selectedSegment = Mode.write.rawValue
        addSubview(segmented)

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
        segmented.selectedSegment = newMode.rawValue
        if mode == .preview {
            renderPreview()
            scrollView.documentView = preview
        } else {
            scrollView.documentView = editor
        }
        if wasFocused { focusActiveView() }
        needsLayout = true
    }

    func focusActiveView() {
        guard let window else { return }
        window.makeFirstResponder(mode == .preview ? preview : editor)
    }

    /// Whether the markdown editor itself holds the keyboard (for tests).
    var editorIsFirstResponder: Bool { window?.firstResponder === editor }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        let chromeScale = CanvasView.chromeScale(forZoom: scale)
        let editorSize = min(max(NoteContent.editorFontSize * scale, 4), 30)
        editor.font = NSFont.monospacedSystemFont(ofSize: editorSize, weight: .regular)
        segmented.font = NSFont.systemFont(ofSize: 10 * chromeScale, weight: .medium)
        if mode == .preview {
            renderPreview()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let chromeScale = CanvasView.chromeScale(forZoom: scale)
        let headerHeight = 26 * chromeScale
        segmented.sizeToFit()
        segmented.frame = CGRect(
            x: 8 * chromeScale,
            y: (headerHeight - segmented.frame.height) / 2,
            width: segmented.frame.width,
            height: segmented.frame.height
        )
        scrollView.frame = CGRect(
            x: 0,
            y: headerHeight,
            width: bounds.width,
            height: max(bounds.height - headerHeight, 0)
        )
    }

    @objc private func modeChanged(_ sender: Any?) {
        setPreviewing(segmented.selectedSegment == Mode.preview.rawValue)
    }

    private func renderPreview() {
        let previewSize = min(max(NoteContent.previewFontSize * scale, 5), 34)
        let rendered = MarkdownPreview.render(
            editor.string,
            baseFontSize: previewSize,
            textColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
            secondaryColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6),
            linkColor: NSColor(srgbRed: 0.45, green: 0.68, blue: 1.0, alpha: 1),
            codeColor: NSColor(srgbRed: 0.88, green: 0.76, blue: 0.52, alpha: 1),
            codeBackground: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
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
