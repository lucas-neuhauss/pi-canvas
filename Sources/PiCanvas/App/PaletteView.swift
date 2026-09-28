import AppKit

/// A view whose origin is the top left, so the palette's layout reads top-down
/// like the code that computes it.
final class PaletteCard: NSView {
    override var isFlipped: Bool { true }
}

/// The node switcher: a search field over a list of everything on the canvas.
///
/// Deliberately an overlay rather than a window: it keeps the canvas visible
/// (so you can see a node light up as you move through the list), needs no window
/// management, and cannot end up behind the terminal it is switching to.
final class PaletteView: NSView {

    /// A row was chosen.
    var onSelectRow: ((PaletteRow) -> Void)?
    /// The user asked to remove a row, with ⌫.
    var onDeleteRow: ((PaletteRow) -> Void)?
    /// The user asked to rename a row, with F2.
    var onRenameRow: ((PaletteRow) -> Void)?
    /// Text was submitted while asking for a name.
    var onSubmitText: ((String) -> Void)?
    /// Dismissed without choosing, e.g. with Escape.
    var onDismiss: (() -> Void)?

    /// A palette either lists things or asks for one line of text.
    private enum Mode {
        case list
        case prompt
    }

    private var mode: Mode = .list
    private var allowsCreate = false
    private let hintLabel = NSTextField(labelWithString: "")

    private static let cardWidth: CGFloat = 560
    private static let rowHeight: CGFloat = 44
    private static let maxListHeight: CGFloat = 320
    private static let searchHeight: CGFloat = 44

    private let card = PaletteCard()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let listView = PaletteListView()

    private var allEntries: [PaletteRow] = []
    private var ranked: [PaletteRow] = []
    private var keyMonitor: Any?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Construction

    private func build() {
        wantsLayer = true

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(srgbRed: 0.106, green: 0.110, blue: 0.125, alpha: 0.99).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.5
        card.layer?.shadowRadius = 30
        card.layer?.shadowOffset = CGSize(width: 0, height: 12)
        addSubview(card)

        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        searchField.textColor = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1)
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Go to terminal…",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
            ]
        )
        searchField.delegate = self
        card.addSubview(searchField)

        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42)
        hintLabel.isHidden = true
        card.addSubview(hintLabel)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = listView
        card.addSubview(scrollView)

        listView.onActivate = { [weak self] index in
            self?.activate(index: index)
        }
    }

    // MARK: - Presenting

    var isPresenting: Bool { !isHidden }

    /// Type text into the field and refresh. Used by the launch flags below.
    func setQuery(_ query: String) {
        searchField.stringValue = query
        updateResults(keepingSelection: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)
    }

    func present(entries: [PaletteRow], from window: NSWindow?) {
        presentList(rows: entries, title: "Go to terminal…", placeholder: "Go to terminal…", allowsCreate: false, from: window)
    }

    /// A list of things to choose from.
    func presentList(
        rows: [PaletteRow],
        title: String,
        placeholder: String,
        allowsCreate: Bool,
        from window: NSWindow?
    ) {
        mode = .list
        self.allowsCreate = allowsCreate
        allEntries = rows
        searchField.stringValue = ""
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
            ]
        )
        hintLabel.stringValue = title
        isHidden = false
        listView.selectedIndex = 0
        updateResults(keepingSelection: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)
        installKeyMonitor()
    }

    /// One line of text, e.g. naming a workspace.
    func presentPrompt(title: String, placeholder: String, initialText: String, from window: NSWindow?) {
        mode = .prompt
        allowsCreate = false
        allEntries = []
        ranked = []
        listView.entries = []
        searchField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
            ]
        )
        searchField.stringValue = initialText
        hintLabel.stringValue = title
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        // A local monitor guarantees Escape closes it regardless of how the field
        // editor routes the key.
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isPresenting else { return event }
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            // F2 renames the highlighted row, the same key that renames a node.
            if event.keyCode == 120, self.mode == .list,
               self.ranked.indices.contains(self.listView.selectedIndex) {
                let row = self.ranked[self.listView.selectedIndex]
                if !row.isCreate {
                    self.removeKeyMonitor()
                    self.isHidden = true
                    self.onRenameRow?(row)
                }
                return nil
            }
            return event
        }
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        onDismiss?()
    }

    func activate(index: Int) {
        guard mode == .list, index >= 0, index < ranked.count else { return }
        let row = ranked[index]
        // Remove the monitor before hiding, so no stray Escape is swallowed later.
        removeKeyMonitor()
        isHidden = true
        onSelectRow?(row)
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// The single place that decides what the list shows.
    private func updateResults(keepingSelection: Bool) {
        guard mode == .list else { return }
        let query = searchField.stringValue
        let previous = ranked.indices.contains(listView.selectedIndex)
            ? ranked[listView.selectedIndex].id
            : nil

        // A single digit picks by position rather than filtering, so the numbers
        // beside the rows always mean something.
        if let index = PaletteRanking.indexForDigit(query, count: allEntries.count) {
            ranked = PaletteRanking.ranked(allEntries, query: "")
            listView.entries = ranked
            listView.selectedIndex = index
            return
        }

        var results = PaletteRanking.ranked(allEntries, query: query)

        // Offer to create whatever was typed, unless it already exists.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let exists = allEntries.contains { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
        if allowsCreate, !trimmed.isEmpty, !exists {
            results.insert(
                PaletteRow(
                    id: UUID(),
                    title: "Create “\(trimmed)”",
                    subtitle: "New workspace with an empty canvas",
                    status: nil,
                    statusKind: .idle,
                    isAttention: false,
                    dotColor: nil,
                    haystackExtra: "create new",
                    lastFocused: nil,
                    createName: trimmed
                ),
                at: 0
            )
        }

        ranked = results
        listView.entries = ranked

        if keepingSelection, let previous, let index = ranked.firstIndex(where: { $0.id == previous }) {
            listView.selectedIndex = index
        } else {
            listView.selectedIndex = 0
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        card.frame = cardFrame()
        let inset: CGFloat = 12
        var y: CGFloat = 10
        searchField.frame = CGRect(
            x: inset,
            y: y,
            width: card.bounds.width - inset * 2,
            height: PaletteView.searchHeight - 10
        )
        y += PaletteView.searchHeight
        let listHeight = listHeight()
        scrollView.frame = CGRect(
            x: inset,
            y: y,
            width: card.bounds.width - inset * 2,
            height: listHeight
        )
        listView.frame = CGRect(
            x: 0,
            y: 0,
            width: scrollView.contentSize.width,
            height: max(CGFloat(max(ranked.count, 1)) * PaletteView.rowHeight, scrollView.contentSize.height)
        )
    }

    private func listHeight() -> CGFloat {
        let rows = max(CGFloat(ranked.count), 1)
        return min(rows * PaletteView.rowHeight, PaletteView.maxListHeight)
    }

    private func cardFrame() -> CGRect {
        let width = min(PaletteView.cardWidth, bounds.width - 60)
        let height = PaletteView.searchHeight + listHeight() + 12
        return CGRect(
            x: ((bounds.width - width) / 2).rounded(),
            y: max(60, (bounds.height * 0.14).rounded()),
            width: width,
            height: height
        )
    }

    // MARK: - Backdrop

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.03, green: 0.035, blue: 0.045, alpha: 0.45).setFill()
        bounds.fill()
    }

    /// A click outside the card dismisses, which is what every palette does.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !card.frame.contains(point) {
            dismiss()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While hidden this must not swallow clicks meant for the canvas.
        isHidden ? nil : super.hitTest(point)
    }
}

// MARK: - Keyboard

extension PaletteView: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        updateResults(keepingSelection: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            listView.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            listView.moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if mode == .prompt {
                let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return true }
                removeKeyMonitor()
                isHidden = true
                onSubmitText?(text)
                return true
            }
            // A digit picks that row; otherwise take the highlighted one.
            if let index = PaletteRanking.indexForDigit(searchField.stringValue, count: ranked.count) {
                activate(index: index)
            } else {
                activate(index: listView.selectedIndex)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)):
            // Only when there is nothing to delete in the query.
            guard mode == .list, searchField.stringValue.isEmpty,
                  ranked.indices.contains(listView.selectedIndex) else { return false }
            let row = ranked[listView.selectedIndex]
            guard !row.isCreate else { return true }
            removeKeyMonitor()
            isHidden = true
            onDeleteRow?(row)
            return true
        default:
            return false
        }
    }
}

// MARK: - The list

/// Draws the rows. A hand-drawn list rather than NSTableView: the rows are
/// bespoke (dot, title, subtitle, status pill, index), and this keeps the look
/// identical to the canvas chrome without cell reuse or nibs.
final class PaletteListView: NSView {

    var entries: [PaletteRow] = [] {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }

    var selectedIndex: Int = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
            scrollSelectionToVisible()
        }
    }

    var onActivate: ((Int) -> Void)?

    private static let rowHeight: CGFloat = 44

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    private func rowRect(_ index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * PaletteListView.rowHeight, width: bounds.width, height: PaletteListView.rowHeight)
    }

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let next = selectedIndex + delta
        if next < 0 {
            selectedIndex = entries.count - 1
        } else if next >= entries.count {
            selectedIndex = 0
        } else {
            selectedIndex = next
        }
    }

    private func scrollSelectionToVisible() {
        guard !entries.isEmpty else { return }
        scrollToVisible(rowRect(selectedIndex).insetBy(dx: 0, dy: -4))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / PaletteListView.rowHeight)
        guard index >= 0, index < entries.count else { return }
        selectedIndex = index
        onActivate?(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty else {
            drawEmptyState()
            return
        }

        for (index, entry) in entries.enumerated() {
            let rect = rowRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            drawRow(entry, index: index, rect: rect)
        }
    }

    private func drawEmptyState() {
        let text = "Nothing to switch to — ⌘T for a terminal, ⌘P for a pi agent"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: 14, y: (PaletteListView.rowHeight - size.height) / 2),
            withAttributes: attributes
        )
    }

    private func drawRow(_ entry: PaletteRow, index: Int, rect: CGRect) {
        let isSelected = index == selectedIndex
        if isSelected {
            NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: 0.22).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 2), xRadius: 8, yRadius: 8).fill()
        }

        // Index number, only meaningful for the first nine rows.
        var left = rect.minX + 14
        if index < 9 {
            let number = "\(index + 1)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: isSelected ? 0.7 : 0.3)
            ]
            (number as NSString).draw(at: CGPoint(x: left, y: rect.minY + 14), withAttributes: attributes)
        }
        left += 18

        // Kind dot, matching the node chrome. Create rows get a plus instead.
        let dotDiameter: CGFloat = 8
        if entry.isCreate {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(srgbRed: 0.55, green: 0.75, blue: 1.0, alpha: 1)
            ]
            ("+" as NSString).draw(at: CGPoint(x: left - 1, y: rect.minY + (rect.height - 17) / 2), withAttributes: attributes)
        } else if let dotColor = entry.dotColor {
            dotColor.setFill()
            NSBezierPath(ovalIn: CGRect(
                x: left,
                y: rect.minY + (rect.height - dotDiameter) / 2,
                width: dotDiameter,
                height: dotDiameter
            )).fill()
        }
        left += dotDiameter + 10

        // Status pill, right aligned.
        var right = rect.maxX - 14
        if let status = entry.status, !status.isEmpty {
            let colors = entry.statusKind.colors
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: colors.text
            ]
            let size = (status as NSString).size(withAttributes: attributes)
            let pill = CGRect(
                x: right - size.width - 12,
                y: rect.midY - 8,
                width: size.width + 12,
                height: 16
            )
            colors.background.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            (status as NSString).draw(
                at: CGPoint(x: pill.minX + 6, y: pill.minY + 3),
                withAttributes: attributes
            )
            right = pill.minX - 10
        }

        // Title and subtitle.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92),
            .paragraphStyle: paragraph
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.40),
            .paragraphStyle: paragraph
        ]

        let textWidth = max(right - left, 40)
        let title = entry.title.isEmpty ? entry.haystackExtra : entry.title
        let titleHeight: CGFloat = 17
        (title as NSString).draw(
            in: CGRect(x: left, y: rect.minY + 7, width: textWidth, height: titleHeight),
            withAttributes: titleAttributes
        )
        (entry.subtitle as NSString).draw(
            in: CGRect(x: left, y: rect.minY + 23, width: textWidth, height: 15),
            withAttributes: subtitleAttributes
        )
    }
}
