import AppKit

/// A stand-in used when no terminal implementation is installed. It keeps the
/// canvas fully usable (and testable) independently of the terminal library.
final class MissingContentView: NSView {

    private let label = NSTextField(labelWithString: "terminal unavailable")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.058, blue: 0.066, alpha: 1).cgColor
        label.textColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
        label.font = NSFont.systemFont(ofSize: 12)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame = CGRect(
            x: 0,
            y: (bounds.height - label.frame.height) / 2,
            width: bounds.width,
            height: label.frame.height
        )
    }
}

@MainActor
final class MissingContent: AgentContent {
    let view: NSView = MissingContentView(frame: .zero)
    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onFocus: (() -> Void)?
    var onDirectoryChange: ((String) -> Void)?

    func start(_ request: ProcessRequest) {}
    func terminate() {}
    func focus() {}
    func setFocused(_ focused: Bool) {}
}
