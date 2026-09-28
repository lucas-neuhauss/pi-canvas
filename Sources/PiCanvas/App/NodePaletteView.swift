import AppKit

/// A view whose origin is the top left, so the palette's layout reads top-down
/// like the code that computes it.
final class NodePaletteCard: NSView {
    override var isFlipped: Bool { true }
}

/// The node switcher: a search field over a list of everything on the canvas.
///
/// Deliberately an overlay rather than a window: it keeps the canvas visible
/// (so you can see a node light up as you move through the list), needs no window
/// management, and cannot end up behind the terminal it is switching to.
final class NodePaletteView: NSView {

    /// Chosen node. The caller focuses it and hides the palette.
    var onSelect: ((UUID) -> Void)?
    /// Dismissed without choosing, e.g. with Escape.
    var onDismiss: (() -> Void)?

    private static let cardWidth: CGFloat = 560
    private static let rowHeight: CGFloat = 44
    private static let maxListHeight: CGFloat = 320
    private static let searchHeight: CGFloat = 44

    private let card = NodePaletteCard()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let listView = NodePaletteListView()

    private var allEntries: [NodePaletteEntry] = []
    private var ranked: [NodePaletteEntry] = []
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

    func present(entries: [NodePaletteEntry], from window: NSWindow?) {
        allEntries = entries
        searchField.stringValue = ""
        isHidden = false
        listView.selectedIndex = 0
        updateResults(keepingSelection: false)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)

        // A local monitor guarantees Escape closes it regardless of how the field
        // editor routes the key.
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self, self.isPresenting else { return event }
                if event.keyCode == 53 {
                    self.dismiss()
                    return nil
                }
                return event
            }
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
        guard index >= 0, index < ranked.count else { return }
        let entry = ranked[index]
        // Remove the monitor before hiding, so no stray Escape is swallowed later.
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isHidden = true
        onSelect?(entry.id)
    }

    /// The single place that decides what the list shows.
    private func updateResults(keepingSelection: Bool) {
        let query = searchField.stringValue
        let previous = ranked.indices.contains(listView.selectedIndex)
            ? ranked[listView.selectedIndex].id
            : nil

        // A single digit picks by position rather than filtering, so the numbers
        // beside the rows always mean something.
        if let index = NodePaletteRanking.indexForDigit(query, count: allEntries.count) {
            ranked = NodePaletteRanking.ranked(allEntries, query: "")
            listView.entries = ranked
            listView.selectedIndex = index
            return
        }

        ranked = NodePaletteRanking.ranked(allEntries, query: query)
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
            height: NodePaletteView.searchHeight - 10
        )
        y += NodePaletteView.searchHeight
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
            height: max(CGFloat(max(ranked.count, 1)) * NodePaletteView.rowHeight, scrollView.contentSize.height)
        )
    }

    private func listHeight() -> CGFloat {
        let rows = max(CGFloat(ranked.count), 1)
        return min(rows * NodePaletteView.rowHeight, NodePaletteView.maxListHeight)
    }

    private func cardFrame() -> CGRect {
        let width = min(NodePaletteView.cardWidth, bounds.width - 60)
        let height = NodePaletteView.searchHeight + listHeight() + 12
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

extension NodePaletteView: NSTextFieldDelegate {

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
            // A digit picks that row; otherwise take the highlighted one.
            if let index = NodePaletteRanking.indexForDigit(searchField.stringValue, count: ranked.count) {
                activate(index: index)
            } else {
                activate(index: listView.selectedIndex)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
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
final class NodePaletteListView: NSView {

    var entries: [NodePaletteEntry] = [] {
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
        CGRect(x: 0, y: CGFloat(index) * NodePaletteListView.rowHeight, width: bounds.width, height: NodePaletteListView.rowHeight)
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
        let index = Int(point.y / NodePaletteListView.rowHeight)
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
            at: CGPoint(x: 14, y: (NodePaletteListView.rowHeight - size.height) / 2),
            withAttributes: attributes
        )
    }

    private func drawRow(_ entry: NodePaletteEntry, index: Int, rect: CGRect) {
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

        // Kind dot, matching the node chrome.
        let dotDiameter: CGFloat = 8
        let accent = entry.kind.accent
        NSColor(
            srgbRed: CGFloat(accent.0),
            green: CGFloat(accent.1),
            blue: CGFloat(accent.2),
            alpha: 1
        ).setFill()
        NSBezierPath(ovalIn: CGRect(
            x: left,
            y: rect.minY + (rect.height - dotDiameter) / 2,
            width: dotDiameter,
            height: dotDiameter
        )).fill()
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
        let title = entry.title.isEmpty ? entry.kind.displayName : entry.title
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
