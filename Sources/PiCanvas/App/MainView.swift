import AppKit

/// A button that runs a closure. Avoids `@objc` selector plumbing for the
/// handful of controls in the status bar.
final class ClosureButton: NSButton {

    var onAction: (() -> Void)?

    init(title: String, tooltip: String? = nil, onAction: (() -> Void)? = nil) {
        self.onAction = onAction
        super.init(frame: .zero)
        self.title = title
        self.toolTip = tooltip
        self.bezelStyle = .rounded
        self.controlSize = .small
        self.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        self.target = self
        self.action = #selector(fire)
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        onAction?()
    }
}

/// The strip along the bottom of the window: what is on the canvas on the left,
/// viewport and creation controls on the right.
final class StatusBarView: NSView {

    let statusLabel = NSTextField(labelWithString: "")
    let pathLabel = NSTextField(labelWithString: "")
    let zoomLabel = NSTextField(labelWithString: "100%")

    var onNewTerminal: (() -> Void)?
    var onNewPi: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?
    var onZoomFit: (() -> Void)?
    var onChooseFolder: (() -> Void)?

    private let barColor = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.090, alpha: 1)
    private let borderColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = barColor.cgColor
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func styleLabel(_ label: NSTextField, size: CGFloat, weight: NSFont.Weight, color: NSColor, monospaced: Bool = false) {
        label.font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func build() {
        styleLabel(statusLabel, size: 11, weight: .medium, color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72))
        styleLabel(pathLabel, size: 11, weight: .regular, color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.42))
        styleLabel(zoomLabel, size: 11, weight: .medium, color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72), monospaced: true)

        let folderButton = ClosureButton(title: "Folder", tooltip: "Choose the folder new nodes start in") { [weak self] in
            self?.onChooseFolder?()
        }
        let fitButton = ClosureButton(title: "Fit", tooltip: "Zoom to fit every node (⌘9)") { [weak self] in
            self?.onZoomFit?()
        }
        let zoomOutButton = ClosureButton(title: "−", tooltip: "Zoom out (⌘−)") { [weak self] in
            self?.onZoomOut?()
        }
        let zoomInButton = ClosureButton(title: "+", tooltip: "Zoom in (⌘+)") { [weak self] in
            self?.onZoomIn?()
        }
        zoomOutButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        zoomInButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let resetButton = ClosureButton(title: "100%", tooltip: "Actual size (⌘0)") { [weak self] in
            self?.onZoomReset?()
        }

        let terminalButton = ClosureButton(title: "New Terminal", tooltip: "Start a shell on the canvas (⌘T)") { [weak self] in
            self?.onNewTerminal?()
        }
        let piButton = ClosureButton(title: "New pi", tooltip: "Start a pi agent on the canvas (⌘P)") { [weak self] in
            self?.onNewPi?()
        }

        let leftStack = NSStackView(views: [statusLabel, pathLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 12
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [
            folderButton,
            fitButton,
            zoomOutButton,
            zoomLabel,
            zoomInButton,
            resetButton,
            terminalButton,
            piButton
        ])
        rightStack.orientation = .horizontal
        rightStack.spacing = 6
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12)
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        borderColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(nodeCount: Int, zoom: CGFloat, workingDirectory: String, needingAttention: Int = 0) {
        if needingAttention > 0 {
            statusLabel.stringValue = needingAttention == 1
                ? "1 agent needs you — ⌘J"
                : "\(needingAttention) agents need you — ⌘J"
            statusLabel.textColor = NodeStatusKind.needsAttention.colors.text
        } else {
            statusLabel.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72)
            if nodeCount == 0 {
                statusLabel.stringValue = "Empty canvas — ⌘T terminal, ⌘P pi agent"
            } else if nodeCount == 1 {
                statusLabel.stringValue = "1 node"
            } else {
                statusLabel.stringValue = "\(nodeCount) nodes"
            }
        }
        pathLabel.stringValue = workingDirectory
        zoomLabel.stringValue = "\(Int((zoom * 100).rounded()))%"
    }
}

/// Window content: the canvas, with the status bar pinned to the bottom.
final class MainView: NSView {

    static let statusBarHeight: CGFloat = 34

    let canvas: CanvasView
    let statusBar = StatusBarView()
    /// The node switcher, shown over everything else.
    let palette = NodePaletteView()

    override var isFlipped: Bool { true }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        addSubview(canvas)
        addSubview(statusBar)
        addSubview(palette)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let barHeight = MainView.statusBarHeight
        canvas.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - barHeight, 0))
        statusBar.frame = CGRect(
            x: 0,
            y: bounds.height - barHeight,
            width: bounds.width,
            height: barHeight
        )
        // The switcher covers the whole window, status bar included.
        palette.frame = bounds
    }
}
