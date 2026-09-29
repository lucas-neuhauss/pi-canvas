import AppKit
import WebKit

/// Content for a browser node: a web view with a minimal address row.
///
/// Deliberately not a browser. There are no tabs, bookmarks, history or
/// downloads; the URL is the whole state, persisted on every navigation so a
/// relaunch reopens the page. Anything that needs a real browser — video, heavy
/// auth — is allowed to be the wrong tool here.
@MainActor
final class BrowserContent: NodeContent {

    let view: NSView

    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    /// Fired when the page navigates, with the URL now being shown.
    var onURLChange: ((URL) -> Void)?

    private let browserView: BrowserContentView
    private(set) var contentScale: CGFloat = 1

    init(nodeID: UUID, url: URL?) {
        browserView = BrowserContentView(nodeID: nodeID, url: url)
        view = browserView
        browserView.onTitleChange = { [weak self] title in
            self?.onTitleChange?(title)
        }
        browserView.onURLChange = { [weak self] url in
            self?.onURLChange?(url)
        }
    }

    var url: URL? { browserView.currentURL }
    var pageTitle: String? { browserView.pageTitle }

    /// Navigates this node's page.
    func load(_ url: URL) {
        browserView.load(url)
    }

    func focus() {
        browserView.focusActiveView()
    }

    func beginEditing() {
        browserView.focusAddressField()
    }

    /// Zooming scales the page like it scales terminal glyphs.
    func setContentScale(_ scale: CGFloat) {
        guard abs(scale - contentScale) > 0.001 else { return }
        contentScale = scale
        browserView.setScale(scale)
    }

    // MARK: - Address parsing

    /// Turns what someone typed into a URL: bare hosts get https, local hosts
    /// get http, so a dev server needs no scheme. Nil when there is nothing to
    /// navigate to.
    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "data", "about"].contains(scheme) {
            return url
        }
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        return URL(string: "\(isLocalHost(host) ? "http" : "https")://\(trimmed)")
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let name = host.split(separator: ":").first.map(String.init)?.lowercased() ?? host.lowercased()
        if name == "localhost" || name == "127.0.0.1" || name == "0.0.0.0" || name == "::1" {
            return true
        }
        return name.hasSuffix(".local") || name.hasSuffix(".test")
    }
}

/// The browser's box: a slim address row (drag grip, back, forward, reload, URL
/// field) over a `WKWebView`.
final class BrowserContentView: NSView {

    private let grip: BrowserDragGripView
    private let backButton = NSButton(frame: .zero)
    private let forwardButton = NSButton(frame: .zero)
    private let reloadButton = NSButton(frame: .zero)
    private let addressField = NSTextField(frame: .zero)
    private let webView: WKWebView
    private var scale: CGFloat = 1
    private var isEditingAddress = false
    private var titleObservation: NSKeyValueObservation?

    var onTitleChange: ((String) -> Void)?
    var onURLChange: ((URL) -> Void)?

    override var isFlipped: Bool { true }

    init(nodeID: UUID, url: URL?) {
        grip = BrowserDragGripView(nodeID: nodeID)
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.058, blue: 0.066, alpha: 1).cgColor

        grip.toolTip = "Drag onto a pi node to send this URL"
        addSubview(grip)

        configure(backButton, symbol: "chevron.left", tooltip: "Back", action: #selector(goBack(_:)))
        configure(forwardButton, symbol: "chevron.right", tooltip: "Forward", action: #selector(goForward(_:)))
        configure(reloadButton, symbol: "arrow.clockwise", tooltip: "Reload", action: #selector(reload(_:)))

        addressField.isBezeled = false
        addressField.drawsBackground = true
        addressField.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.155, alpha: 1)
        addressField.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
        addressField.focusRingType = .none
        addressField.placeholderString = "Enter a URL"
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.wantsLayer = true
        addressField.layer?.cornerRadius = 5
        addressField.target = self
        addressField.action = #selector(submitAddress(_:))
        addressField.delegate = self
        addSubview(addressField)

        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        // Element inspection is delegated to Safari's Web Inspector rather than
        // grown into the app: setting this lets Safari attach to the page (with
        // the Develop menu enabled). No devtools UI lives here, on purpose.
        webView.isInspectable = true
        addSubview(webView)

        // The page's own title becomes the node's title.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            guard let title = webView.title, !title.isEmpty else { return }
            self?.onTitleChange?(title)
        }

        if let url {
            addressField.stringValue = url.absoluteString
            webView.load(URLRequest(url: url))
        }
        updateNavigationState()
        setScale(1)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - State

    var currentURL: URL? { webView.url }
    var pageTitle: String? { webView.title }
    /// Whether Safari's Web Inspector can attach (for tests).
    var isInspectable: Bool { webView.isInspectable }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func focusActiveView() {
        guard let window else { return }
        window.makeFirstResponder(webView)
    }

    func focusAddressField() {
        guard let window else { return }
        window.makeFirstResponder(addressField)
        addressField.currentEditor()?.selectAll(nil)
    }

    func setScale(_ scale: CGFloat) {
        self.scale = scale
        let chrome = CanvasView.chromeScale(forZoom: scale)
        addressField.font = NSFont.systemFont(ofSize: max(11 * chrome, 9))
        webView.pageZoom = min(max(scale, 0.3), 3)
        for button in [backButton, forwardButton, reloadButton] {
            button.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: max(11 * chrome, 9),
                weight: .medium
            )
        }
        needsLayout = true
    }

    private var chromeScale: CGFloat { CanvasView.chromeScale(forZoom: scale) }
    private var rowHeight: CGFloat { max(30 * chromeScale, 28) }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.target = self
        button.action = action
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.65)
        button.toolTip = tooltip
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addSubview(button)
    }

    override func layout() {
        super.layout()
        let row = rowHeight
        let side = min(row - 2, 24 * chromeScale)
        let y = (row - side) / 2
        var x = 8 * chromeScale

        grip.frame = CGRect(x: x, y: y, width: side, height: side).integral
        x += side + 4 * chromeScale

        for button in [backButton, forwardButton, reloadButton] {
            button.frame = CGRect(x: x, y: y, width: side, height: side).integral
            x += side + 2 * chromeScale
        }

        addressField.frame = CGRect(
            x: x,
            y: y + 1,
            width: max(bounds.width - x - 8 * chromeScale, 20),
            height: side - 2
        ).integral
        webView.frame = CGRect(
            x: 0,
            y: row,
            width: bounds.width,
            height: max(bounds.height - row, 0)
        )
    }

    // MARK: - Actions

    @objc private func goBack(_ sender: Any?) { webView.goBack() }
    @objc private func goForward(_ sender: Any?) { webView.goForward() }
    @objc private func reload(_ sender: Any?) { webView.reload() }

    @objc private func submitAddress(_ sender: Any?) {
        guard let url = BrowserContent.normalizedURL(from: addressField.stringValue) else {
            NSSound.beep()
            addressField.stringValue = webView.url?.absoluteString ?? ""
            return
        }
        webView.load(URLRequest(url: url))
        window?.makeFirstResponder(webView)
    }

    private func updateNavigationState() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        backButton.alphaValue = webView.canGoBack ? 1 : 0.35
        forwardButton.alphaValue = webView.canGoForward ? 1 : 0.35
    }

    private func publishLocation() {
        guard let url = webView.url else { return }
        if !isEditingAddress {
            addressField.stringValue = url.absoluteString
        }
        onURLChange?(url)
    }
}

// MARK: - WKNavigationDelegate

extension BrowserContentView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavigationState()
        publishLocation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigationState()
        publishLocation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateNavigationState()
        NSLog("[PiCanvas] browser node could not load: %@", error.localizedDescription)
    }
}

extension BrowserContentView: NSTextFieldDelegate {

    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditingAddress = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditingAddress = false
    }
}

/// The grip that starts a node drag from the address row. Dropping it on a pi
/// node sends the page's URL, the same gesture images use for their path.
final class BrowserDragGripView: NSView, NSDraggingSource {

    let nodeID: UUID
    private var dragStart: CGPoint?
    private var didBeginDrag = false

    init(nodeID: UUID) {
        self.nodeID = nodeID
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45).setFill()
        let dot = max(bounds.width * 0.13, 2)
        let gap = dot * 2
        let startX = bounds.midX - gap
        let startY = bounds.midY - gap
        for row in 0..<3 {
            for column in 0..<3 {
                NSBezierPath(ovalIn: CGRect(
                    x: startX + CGFloat(column) * gap,
                    y: startY + CGFloat(row) * gap,
                    width: dot,
                    height: dot
                )).fill()
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
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

        let item = NSPasteboardItem()
        item.setString(nodeID.uuidString, forType: NodeDragPasteboard.type)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let size = bounds.size
        draggingItem.setDraggingFrame(
            CGRect(
                x: dragStart.x - size.width / 2,
                y: dragStart.y - size.height / 2,
                width: size.width,
                height: size.height
            ),
            contents: snapshot()
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
