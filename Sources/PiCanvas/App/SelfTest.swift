import AppKit

/// Headless integration tests for the canvas: window, nodes, and *synthesised
/// mouse events* driving the real interaction code paths.
///
///     PiCanvas --self-test
///
/// Exits non-zero if anything fails.
@MainActor
enum SelfTest {

    // MARK: - Harness

    private final class Checker {
        var passed = 0
        var failures: [String] = []

        func check(_ condition: Bool, _ description: String) {
            if condition {
                passed += 1
                print("  ok   \(description)")
            } else {
                failures.append(description)
                print("  FAIL \(description)")
            }
        }

        func equal<T: Equatable>(_ actual: T, _ expected: T, _ description: String) {
            if actual == expected {
                passed += 1
                print("  ok   \(description)")
            } else {
                failures.append("\(description): expected \(expected), got \(actual)")
                print("  FAIL \(description): expected \(expected), got \(actual)")
            }
        }

        func close(_ actual: CGFloat, _ expected: CGFloat, _ description: String) {
            close(actual, expected, 0.51, description)
        }

        func close(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat, _ description: String) {
            if abs(actual - expected) <= tolerance {
                passed += 1
                print("  ok   \(description)")
            } else {
                failures.append("\(description): expected \(expected), got \(actual)")
                print("  FAIL \(description): expected \(expected), got \(actual)")
            }
        }
    }

    /// Records what the controller asked of a node's content.
    private final class RecordingContent: AgentContent {
        let view: NSView = NSView(frame: .zero)
        var onTitleChange: ((String) -> Void)?
        var onExit: ((Int32?) -> Void)?
        var onFocus: (() -> Void)?
        var onDirectoryChange: ((String) -> Void)?

        private(set) var startedRequests: [ProcessRequest] = []
        private(set) var terminateCount = 0
        private(set) var focusCount = 0

        func start(_ request: ProcessRequest) { startedRequests.append(request) }
        func terminate() { terminateCount += 1 }
        func focus() { focusCount += 1 }
        func setFocused(_ focused: Bool) {}
    }

    /// Shared, reference-typed recorder of the contents the controller created.
    private final class ContentRecorder {
        var contents: [UUID: RecordingContent] = [:]

        @MainActor
        func make(_ spec: NodeSpec) -> AgentContent {
            let content = RecordingContent()
            contents[spec.id] = content
            return content
        }

        func content(for id: UUID?) -> RecordingContent? {
            guard let id else { return nil }
            return contents[id]
        }
    }

    // MARK: - Entry point

    static func run() -> Int32 {
        let checker = Checker()
        print("PiCanvas self-test")

        let canvasFrame = CGRect(x: 0, y: 0, width: 1440, height: 860)
        let canvas = CanvasView(frame: canvasFrame)
        let window = NSWindow(
            contentRect: canvasFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        canvas.frame = canvasFrame
        canvas.layoutSubtreeIfNeeded()

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-selftest-layout.json")
        try? FileManager.default.removeItem(at: layoutURL)

        let controller = CanvasController(canvas: canvas, store: LayoutStore(fileURL: layoutURL))
        let recorder = ContentRecorder()
        controller.contentFactory = { spec in recorder.make(spec) }

        testCoordinateConversion(canvas: canvas, checker: checker)
        testZoom(canvas: canvas, checker: checker)
        testDragMove(canvas: canvas, controller: controller, checker: checker)
        testResize(canvas: canvas, controller: controller, checker: checker)
        testProcessRequest(controller: controller, recorder: recorder, checker: checker)
        testDelete(canvas: canvas, controller: controller, recorder: recorder, checker: checker)
        testPersistence(canvas: canvas, controller: controller, layoutURL: layoutURL, checker: checker)
        testZOrder(canvas: canvas, controller: controller, checker: checker)
        testTerminalRoundTrip(checker: checker)
        testResizeReflow(checker: checker)

        print("")
        if checker.failures.isEmpty {
            print("PASS — \(checker.passed) checks")
            return 0
        }
        print("FAIL — \(checker.failures.count) failing of \(checker.passed + checker.failures.count) checks")
        for failure in checker.failures {
            print("  - \(failure)")
        }
        return 1
    }

    // MARK: - Tests

    private static func testCoordinateConversion(canvas: CanvasView, checker: Checker) {
        print("\ncoordinate conversion")
        canvas.setViewport(zoom: 1, pan: CGPoint(x: 40, y: -25), notify: false)

        let world = CGPoint(x: 123.5, y: -67.25)
        let screen = canvas.screenPoint(fromWorld: world)
        let roundTrip = canvas.worldPoint(fromScreen: screen)
        checker.close(roundTrip.x, world.x, 0.001, "world→screen→world round trip x")
        checker.close(roundTrip.y, world.y, 0.001, "world→screen→world round trip y")

        canvas.setViewport(zoom: 2.5, pan: CGPoint(x: -100, y: 300), notify: false)
        let scaled = canvas.screenRect(fromWorld: CGRect(x: 10, y: 20, width: 100, height: 50))
        checker.equal(scaled, CGRect(x: -75, y: 350, width: 250, height: 125), "screen rect scales with zoom")

        canvas.setViewport(zoom: 1, pan: .zero, notify: false)
    }

    private static func testZoom(canvas: CanvasView, checker: Checker) {
        print("\nzoom")
        canvas.setViewport(zoom: 1, pan: .zero, notify: false)

        // Zooming must keep the world point under the cursor pinned.
        let anchor = CGPoint(x: 900, y: 400)
        let worldBefore = canvas.worldPoint(fromScreen: anchor)
        canvas.setZoom(1.8, anchorScreen: anchor, notify: false)
        let worldAfter = canvas.worldPoint(fromScreen: anchor)
        checker.close(worldAfter.x, worldBefore.x, 0.001, "zoom keeps anchor point fixed (x)")
        checker.close(worldAfter.y, worldBefore.y, 0.001, "zoom keeps anchor point fixed (y)")
        checker.close(canvas.zoom, 1.8, 0.001, "zoom applied")

        canvas.setZoom(99, notify: false)
        checker.close(canvas.zoom, canvas.maxZoom, 0.001, "zoom clamps to maxZoom")
        canvas.setZoom(0.0001, notify: false)
        checker.close(canvas.zoom, canvas.minZoom, 0.001, "zoom clamps to minZoom")
        canvas.setViewport(zoom: 1, pan: .zero, notify: false)
    }

    private static func testDragMove(canvas: CanvasView, controller: CanvasController, checker: Checker) {
        print("\ndrag to move")
        canvas.setViewport(zoom: 1, pan: .zero, notify: false)
        controller.newNode(kind: .shell)

        guard let id = canvas.focusedNodeID ?? canvas.nodeViews.first?.nodeID,
              let node = canvas.nodeView(withID: id) else {
            checker.check(false, "node created")
            return
        }
        checker.check(true, "node created")

        let before = node.worldFrame
        // Grab the title bar away from the close button and drag 120×60.
        let grab = CGPoint(x: node.frame.midX, y: node.frame.minY + 10)
        let target = CGPoint(x: grab.x + 120, y: grab.y + 60)
        drag(canvas: canvas, from: grab, to: target, on: node)

        checker.close(node.worldFrame.origin.x, before.origin.x + 120, "node moved right by 120")
        checker.close(node.worldFrame.origin.y, before.origin.y + 60, "node moved down by 60")
        checker.close(node.worldFrame.width, before.width, "width unchanged by move")
        checker.close(node.worldFrame.height, before.height, "height unchanged by move")
    }

    private static func testResize(canvas: CanvasView, controller: CanvasController, checker: Checker) {
        print("\nresize")
        guard let node = canvas.nodeViews.last else {
            checker.check(false, "node available")
            return
        }

        let before = node.worldFrame
        let grip = CGPoint(x: node.frame.maxX - 6, y: node.frame.maxY - 6)
        let target = CGPoint(x: grip.x + 100, y: grip.y + 80)
        drag(canvas: canvas, from: grip, to: target, on: node)

        checker.close(node.worldFrame.width, before.width + 100, "width grew by 100")
        checker.close(node.worldFrame.height, before.height + 80, "height grew by 80")
        checker.close(node.worldFrame.origin.x, before.origin.x, "origin unchanged by resize")
        checker.close(node.worldFrame.origin.y, before.origin.y, "origin unchanged by resize")

        // Shrinking far past the minimum must clamp, not invert.
        let grip2 = CGPoint(x: node.frame.maxX - 6, y: node.frame.maxY - 6)
        let target2 = CGPoint(x: grip2.x - 2000, y: grip2.y - 2000)
        drag(canvas: canvas, from: grip2, to: target2, on: node)
        checker.close(node.worldFrame.width, NodeMetrics.minWorldWidth, 1, "width clamps to minimum")
        checker.close(node.worldFrame.height, NodeMetrics.minWorldHeight, 1, "height clamps to minimum")
        checker.check(node.worldFrame.width > 0 && node.worldFrame.height > 0, "size stays positive")
    }

    private static func testProcessRequest(
        controller: CanvasController,
        recorder: ContentRecorder,
        checker: Checker
    ) {
        print("\nprocess launch")
        guard let firstID = recorder.contents.keys.first, let content = recorder.contents[firstID] else {
            checker.check(false, "content recorded")
            return
        }
        checker.equal(content.startedRequests.count, 1, "process started exactly once")

        guard let request = content.startedRequests.first else { return }
        checker.equal(request.executable, "/bin/zsh", "shell nodes run zsh")
        checker.check(request.arguments.contains("-l"), "shell runs as a login shell")
        checker.equal(request.environment["TERM"], "xterm-256color", "TERM is set")
        checker.equal(request.environment["TERM_PROGRAM"], "PiCanvas", "TERM_PROGRAM identifies the app")
        checker.check(
            request.environment.keys.allSatisfy { !$0.hasPrefix("PI_") },
            "PI_* variables are stripped so nested agents do not inherit a session"
        )
        checker.check(
            request.environment["PATH"]?.contains("/opt/homebrew/bin") == true,
            "PATH is enriched for GUI launches"
        )
    }

    private static func testDelete(
        canvas: CanvasView,
        controller: CanvasController,
        recorder: ContentRecorder,
        checker: Checker
    ) {
        print("\ndelete")
        // Keep one extra node around so later tests still have something to work with.
        controller.newNode(kind: .shell)
        let countBefore = controller.nodeCount
        guard let id = canvas.nodeViews.last?.nodeID else {
            checker.check(false, "node available to delete")
            return
        }
        let content = recorder.content(for: id)
        let viewsBefore = canvas.nodeViews.count

        controller.close(nodeID: id)

        checker.equal(controller.nodeCount, countBefore - 1, "spec removed")
        checker.equal(canvas.nodeViews.count, viewsBefore - 1, "view removed")
        checker.check(canvas.nodeView(withID: id) == nil, "node lookup returns nil after delete")
        checker.equal(content?.terminateCount, 1, "process terminated on close")

        // Closing the same node twice must not disturb the survivor.
        controller.close(nodeID: id)
        checker.equal(controller.nodeCount, countBefore - 1, "closing a missing node is a no-op")
    }

    private static func testPersistence(
        canvas: CanvasView,
        controller: CanvasController,
        layoutURL: URL,
        checker: Checker
    ) {
        print("\npersistence")
        guard let node = canvas.nodeViews.first else {
            checker.check(false, "node available to persist")
            return
        }
        node.worldFrame = CGRect(x: 42, y: -17, width: 512, height: 300)
        canvas.layoutNodes()
        controller.persist()
        controller.saveNow()

        let reloaded = LayoutStore(fileURL: layoutURL).load()
        checker.check(reloaded != nil, "layout file readable")
        guard let layout = reloaded else { return }
        checker.equal(layout.nodes.count, controller.nodeCount, "node count persisted")
        checker.close(CGFloat(layout.zoom), canvas.zoom, 0.001, "zoom persisted")

        guard let persisted = layout.nodes.first(where: { $0.id == node.nodeID }) else {
            checker.check(false, "node found in persisted layout")
            return
        }
        checker.close(CGFloat(persisted.x), 42, 0.001, "x persisted")
        checker.close(CGFloat(persisted.y), -17, 0.001, "y persisted")
        checker.close(CGFloat(persisted.width), 512, 0.001, "width persisted")
        checker.close(CGFloat(persisted.height), 300, 0.001, "height persisted")

        // Restoring into a fresh canvas must reproduce the layout.
        let canvas2 = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window2 = NSWindow(contentRect: canvas2.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window2.contentView = canvas2
        window2.makeKeyAndOrderFront(nil)

        let controller2 = CanvasController(canvas: canvas2, store: LayoutStore(fileURL: layoutURL))
        controller2.contentFactory = { _ in RecordingContent() }
        controller2.restore()

        checker.equal(controller2.nodeCount, layout.nodes.count, "restore recreates every node")
        if let restored = canvas2.nodeView(withID: node.nodeID) {
            checker.close(restored.worldFrame.origin.x, 42, 0.001, "restored x")
            checker.close(restored.worldFrame.size.width, 512, 0.001, "restored width")
        } else {
            checker.check(false, "restored node exists")
        }
        window2.close()
    }

    private static func testZOrder(canvas: CanvasView, controller: CanvasController, checker: Checker) {
        print("\nz-order")
        controller.newNode(kind: .pi)
        controller.newNode(kind: .shell)

        guard let first = canvas.nodeViews.first, let last = canvas.nodeViews.last else {
            checker.check(false, "nodes available")
            return
        }
        checker.check(canvas.orderedNodeIDs.last == last.nodeID, "newest node is on top")

        canvas.select(first, focusContent: false)
        checker.equal(canvas.orderedNodeIDs.last, first.nodeID, "selecting a node brings it to front")
        checker.equal(canvas.focusedNodeID, first.nodeID, "selection updates focus")
        checker.check(canvas.nodeViews.last === first, "view order matches model order")
    }

    // MARK: - Real PTY round trip

    /// End-to-end: spawn a real shell in a real PTY, type a command into it, and
    /// read the resulting output back out of the terminal buffer.
    private static func testTerminalRoundTrip(checker: Checker) {
        print("\nterminal round trip (real PTY)")

        let frame = CGRect(x: 0, y: 0, width: 820, height: 520)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)

        let content = TerminalContent()
        content.view.frame = frame
        window.contentView = content.view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content.view)

        let spec = ProcessResolver.makeSpec(
            kind: .shell,
            workingDirectory: NSTemporaryDirectory(),
            worldFrame: frame
        )
        content.start(ProcessResolver.request(for: spec))

        let producedOutput = waitUntil(timeout: 10) {
            (content.bufferText()?.isEmpty == false)
        }
        checker.check(producedOutput, "a login shell starts and writes a prompt")

        checker.check(content.lastReportedCols > 40, "PTY received a sane column count (\(content.lastReportedCols))")
        checker.check(content.lastReportedRows > 10, "PTY received a sane row count (\(content.lastReportedRows))")

        // The echoed command contains the literal `$((6*7))`, so finding
        // PICANVAS_42 in the buffer proves the shell *executed* it.
        content.send(text: "echo PICANVAS_$((6*7))\n")
        let ranCommand = waitUntil(timeout: 10) {
            content.bufferText()?.contains("PICANVAS_42") == true
        }
        checker.check(ranCommand, "typed input reaches the shell and output comes back")

        var exited = false
        content.onExit = { _ in exited = true }
        content.terminate()
        let reaped = waitUntil(timeout: 6) { exited }
        checker.check(reaped, "terminate() reaps the process")

        window.close()
    }

    /// Resizing a node must give the PTY a new grid, not scale the glyphs.
    /// This is the whole reason zoom resizes the view instead of transforming it.
    private static func testResizeReflow(checker: Checker) {
        print("\nresize reflow (real PTY)")

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)

        let content = TerminalContent()
        window.contentView = content.view
        window.makeKeyAndOrderFront(nil)

        let spec = ProcessResolver.makeSpec(
            kind: .shell,
            workingDirectory: NSTemporaryDirectory(),
            worldFrame: window.frame
        )
        content.start(ProcessResolver.request(for: spec))
        _ = waitUntil(timeout: 10) { content.lastReportedCols > 0 }

        let narrowCols = content.lastReportedCols
        let narrowRows = content.lastReportedRows
        checker.check(narrowCols > 0 && narrowRows > 0, "PTY starts with a grid (\(narrowCols)x\(narrowRows))")

        window.setContentSize(NSSize(width: 1040, height: 640))
        let widened = waitUntil(timeout: 8) {
            content.lastReportedCols > narrowCols && content.lastReportedRows > narrowRows
        }
        checker.check(
            widened,
            "growing the node gives the PTY a bigger grid (\(narrowCols)x\(narrowRows) → \(content.lastReportedCols)x\(content.lastReportedRows))"
        )

        let wideCols = content.lastReportedCols
        window.setContentSize(NSSize(width: 420, height: 260))
        let narrowed = waitUntil(timeout: 8) { content.lastReportedCols < wideCols }
        checker.check(
            narrowed,
            "shrinking the node reduces the grid (\(wideCols) → \(content.lastReportedCols))"
        )

        content.terminate()
        _ = waitUntil(timeout: 6) { false }
        window.close()
    }

    /// Spins the run loop until `condition` holds or the timeout elapses.
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    // MARK: - Event synthesis

    private static func drag(canvas: CanvasView, from: CGPoint, to: CGPoint, on node: NodeFrameView) {
        guard let down = mouseEvent(.leftMouseDown, at: from, in: canvas),
              let dragged = mouseEvent(.leftMouseDragged, at: to, in: canvas),
              let up = mouseEvent(.leftMouseUp, at: to, in: canvas) else {
            return
        }
        node.mouseDown(with: down)
        node.mouseDragged(with: dragged)
        node.mouseUp(with: up)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at canvasPoint: CGPoint, in canvas: CanvasView) -> NSEvent? {
        guard let window = canvas.window else { return nil }
        let windowPoint = canvas.convert(canvasPoint, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}
