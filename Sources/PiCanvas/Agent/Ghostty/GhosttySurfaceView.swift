import AppKit
import GhosttyKit

@MainActor
protocol GhosttySurfaceViewDelegate: AnyObject {
    func surfaceView(_ view: GhosttySurfaceView, didChangeTitle title: String)
    func surfaceView(_ view: GhosttySurfaceView, didChangeWorkingDirectory directory: String)
    func surfaceView(_ view: GhosttySurfaceView, didExitWith exitCode: Int32?)
    func surfaceViewDidRequestClose(_ view: GhosttySurfaceView)
}

/// Hosts one libghostty surface.
///
/// Deliberately thin: libghostty creates and owns the Metal layer inside the
/// view it is handed, and renders on its own schedule, so there is no layer
/// setup and no draw loop here. The host's job is to size the surface, forward
/// input, and answer the action callbacks.
final class GhosttySurfaceView: NSView, NSTextInputClient {

    weak var surfaceDelegate: GhosttySurfaceViewDelegate?

    private(set) var surface: ghostty_surface_t?

    private var pendingStart: SurfaceStart?
    private var appliedFontSize: CGFloat = 0
    private var mouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_DEFAULT
    private var markedText = NSMutableAttributedString()
    private var didReportExit = false

    /// Everything needed to create the surface, held until the view is in a window.
    struct SurfaceStart {
        var command: String?
        var workingDirectory: String?
        var environment: [String: String]
        var fontSize: CGFloat
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    deinit {
        // `surface` is freed in `terminate()`; nothing else to do here because
        // touching a C pointer from deinit is not safe under actor isolation.
    }

    // MARK: - Lifecycle

    func start(_ start: SurfaceStart) {
        pendingStart = start
        appliedFontSize = start.fontSize
        createSurfaceIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        createSurfaceIfPossible()
    }

    private func createSurfaceIfPossible() {
        guard surface == nil, let start = pendingStart, window != nil else { return }
        guard let app = GhosttyApp.shared.app else { return }

        var config = ghostty_surface_config_new()
        // The view is both the platform handle and our userdata, so the action
        // callback can recover it without a side table.
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        config.userdata = selfPointer
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: selfPointer)
        )
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)
        config.font_size = Float(start.fontSize)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.wait_after_command = false

        let workingDirectory = start.workingDirectory ?? NSHomeDirectory()
        let command = start.command ?? ""

        // Strings only need to outlive the call; ghostty copies them.
        var created: ghostty_surface_t?
        workingDirectory.withCString { cwd in
            command.withCString { cmd in
                config.working_directory = cwd
                config.command = cmd
                created = withEnvironment(start.environment, into: &config) {
                    ghostty_surface_new(app, &config)
                }
            }
        }

        surface = created
        pendingStart = nil
        updateSurfaceSize()
    }

    /// Builds the C env var array for the duration of `body`.
    private func withEnvironment<T>(
        _ environment: [String: String],
        into config: inout ghostty_surface_config_s,
        _ body: () -> T
    ) -> T {
        guard !environment.isEmpty else { return body() }
        let keys = environment.keys.map { strdup($0) }
        let values = environment.values.map { strdup($0) }
        defer {
            keys.forEach { free($0) }
            values.forEach { free($0) }
        }

        var pairs = zip(keys, values).map { ghostty_env_var_s(key: $0, value: $1) }
        return pairs.withUnsafeMutableBufferPointer { buffer in
            config.env_vars = buffer.baseAddress
            config.env_var_count = buffer.count
            return body()
        }
    }

    func terminate() {
        guard let surface else { return }
        // Ask the child to wind down, then release the surface. libghostty kills
        // the pty when the surface is freed.
        ghostty_surface_request_close(surface)
        ghostty_surface_free(surface)
        self.surface = nil
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: - Geometry

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
        let size = surfacePixelSize()
        guard size.width > 0, size.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
    }

    /// Pixel dimensions, which is what the surface wants (not points).
    private func surfacePixelSize() -> CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    var gridSize: (cols: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }

    func setOccluded(_ occluded: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    // MARK: - Font size (canvas zoom)

    /// Sets the glyph size, which is how canvas zoom scales text.
    ///
    /// libghostty has no absolute "set font size" call; its own host changes
    /// font size through the `increase_font_size:N` binding action, whose
    /// argument is a float. Tracking the applied size lets us always issue the
    /// exact delta, which keeps the size absolute from our point of view.
    func applyFontSize(_ target: CGFloat) {
        let clamped = min(max(target, 4), 40)
        guard surface != nil else {
            appliedFontSize = clamped
            return
        }
        guard appliedFontSize > 0 else {
            appliedFontSize = clamped
            return
        }
        let delta = clamped - appliedFontSize
        guard abs(delta) > 0.01 else { return }
        performBindingAction(delta > 0 ? "increase_font_size:\(delta)" : "decrease_font_size:\(-delta)")
        appliedFontSize = clamped
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    // MARK: - Reading content back

    /// Type text into the running process, as if the user had typed it.
    func sendText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    /// The surface's text, used for scrollback snapshots.
    func readText() -> String? {
        guard let surface else { return nil }

        var selection = ghostty_selection_s()
        selection.top_left = ghostty_point_s(
            tag: GHOSTTY_POINT_SURFACE,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        selection.bottom_right = ghostty_point_s(
            tag: GHOSTTY_POINT_SURFACE,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        selection.rectangle = false

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return nil }
        let buffer = UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len))
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - Actions from libghostty

    func handle(action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            if let pointer = action.action.set_title.title {
                surfaceDelegate?.surfaceView(self, didChangeTitle: String(cString: pointer))
            }
            return true

        case GHOSTTY_ACTION_PWD:
            if let pointer = action.action.pwd.pwd {
                surfaceDelegate?.surfaceView(self, didChangeWorkingDirectory: String(cString: pointer))
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            if shape != mouseShape {
                mouseShape = shape
                window?.invalidateCursorRects(for: self)
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            reportExit(Int32(bitPattern: action.action.child_exited.exit_code))
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW:
            // The surface wants to go away (the child asked to close).
            surfaceDelegate?.surfaceViewDidRequestClose(self)
            reportExit(nil)
            return true

        default:
            return false
        }
    }

    private func reportExit(_ code: Int32?) {
        guard !didReportExit else { return }
        didReportExit = true
        surfaceDelegate?.surfaceView(self, didExitWith: code)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: GhosttyCursor.cursor(for: mouseShape))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let translationMods = GhosttyMods.toAppKit(
            ghostty_surface_key_translation_mods(surface, GhosttyMods.toGhostty(event.modifierFlags))
        )
        let translationEvent = event.ghosttyTranslationEvent(translationMods)

        var keyEvent = event.ghosttyKeyEvent(
            event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
            translationMods: translationEvent.modifierFlags
        )
        let text = translationEvent.ghosttyCharacters ?? event.ghosttyCharacters

        let handled: Bool
        if let text, !text.isEmpty {
            handled = text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            handled = ghostty_surface_key(surface, keyEvent)
        }

        // Ghostty did not consume it: give AppKit a chance (menu shortcuts, IME).
        if !handled {
            interpretKeyEvents([event])
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        // Only modifiers that ghostty tracks as their own state matter.
        let keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        _ = ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - NSTextInputClient (IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        unmarkText()
        guard let surface else { return }
        let text: String
        switch string {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        default: return
        }
        guard !text.isEmpty else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        guard let surface else { return }
        let text = markedText.string
        text.withCString { pointer in
            ghostty_surface_preedit(surface, pointer, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText = NSMutableAttributedString()
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// Where the IME candidate window should appear.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let inView = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        let inWindow = convert(inView, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: - Mouse

    private func mouseMods(_ event: NSEvent) -> ghostty_input_mods_e {
        GhosttyMods.toGhostty(event.modifierFlags)
    }

    /// ghostty wants the position in view points with the origin at the top left.
    private func mousePosition(_ event: NSEvent) -> (Double, Double) {
        let local = convert(event.locationInWindow, from: nil)
        return (Double(local.x), Double(bounds.height - local.y))
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        let (x, y) = mousePosition(event)
        ghostty_surface_mouse_pos(surface, x, y, mouseMods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mouseMods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mouseMods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let (x, y) = mousePosition(event)
        ghostty_surface_mouse_pos(surface, x, y, mouseMods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mouseMods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mouseMods(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        let (x, y) = mousePosition(event)
        ghostty_surface_mouse_pos(surface, x, y, mouseMods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mouseMods(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mouseMods(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let (x, y) = mousePosition(event)
        ghostty_surface_mouse_pos(surface, x, y, mouseMods(event))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // Park the cursor far outside the grid so hover state clears.
        ghostty_surface_mouse_pos(surface, -1, -1, mouseMods(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Trackpads report very small deltas; ghostty's own host doubles them.
            x *= 2
            y *= 2
        }
        let mods = GhosttyScrollMods(
            precision: event.hasPreciseScrollingDeltas,
            momentum: event.momentumPhase
        )
        ghostty_surface_mouse_scroll(surface, Double(x), Double(y), mods.rawValue)
    }
}

/// The packed scroll modifier word: bit 0 is precision, bits 1-3 are momentum.
struct GhosttyScrollMods {
    var rawValue: ghostty_input_scroll_mods_t

    init(precision: Bool, momentum: NSEvent.Phase) {
        var value: Int32 = 0
        if precision { value |= 0b0000_0001 }
        value |= Int32(GhosttyScrollMods.momentumValue(momentum)) << 1
        rawValue = value
    }

    private static func momentumValue(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began: return 1
        case .stationary: return 2
        case .changed: return 3
        case .ended: return 4
        case .cancelled: return 5
        case .mayBegin: return 6
        default: return 0
        }
    }
}

/// Maps ghostty's mouse shape enum onto AppKit cursors.
enum GhosttyCursor {

    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .iBeam
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
            return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_HELP:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_WAIT, GHOSTTY_MOUSE_SHAPE_PROGRESS:
            return .arrow
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL, GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
             GHOSTTY_MOUSE_SHAPE_ZOOM_OUT:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COPY:
            return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_ALIAS:
            return .dragLink
        case GHOSTTY_MOUSE_SHAPE_MOVE, GHOSTTY_MOUSE_SHAPE_ALL_SCROLL:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE:
            return NSCursor.fromSymbol("arrow.up.right.and.arrow.down.left") ?? .crosshair
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE, GHOSTTY_MOUSE_SHAPE_NW_RESIZE, GHOSTTY_MOUSE_SHAPE_SE_RESIZE:
            return NSCursor.fromSymbol("arrow.up.left.and.arrow.down.right") ?? .crosshair
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
            return NodeCursor.resize([.top])
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return NodeCursor.resize([.bottom])
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            return NodeCursor.resize([.right])
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
            return NodeCursor.resize([.left])
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE:
            return NodeCursor.resize([.top, .right])
        case GHOSTTY_MOUSE_SHAPE_SW_RESIZE:
            return NodeCursor.resize([.bottom, .left])
        default:
            return .arrow
        }
    }
}
