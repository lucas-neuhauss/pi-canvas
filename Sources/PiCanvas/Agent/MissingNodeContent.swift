import AppKit

/// A stand-in used when a node's content cannot be created — no terminal
/// implementation installed, an image whose asset went missing, or a kind that
/// is not implemented yet. It keeps the canvas fully usable (and testable)
/// independently of what is behind the seam.
final class MissingNodeContentView: NSView {

    private let label: NSTextField

    init(message: String) {
        label = NSTextField(labelWithString: message)
        super.init(frame: .zero)
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
final class MissingNodeContent: NodeContent {
    let view: NSView
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    init(message: String = "terminal unavailable") {
        view = MissingNodeContentView(message: message)
    }
}
