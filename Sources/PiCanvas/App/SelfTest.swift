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

    /// Records the node-chrome callbacks a person's gestures produce.
    private final class RecordingNodeDelegate: NodeFrameViewDelegate {
        var renamed: [String] = []
        var focusRequests = 0
        var closeRequests = 0

        func nodeFrameViewDidRequestClose(_ node: NodeFrameView) { closeRequests += 1 }
        func nodeFrameViewDidBeginInteraction(_ node: NodeFrameView) {}
        func nodeFrameViewDidChangeFrame(_ node: NodeFrameView) {}
        func nodeFrameViewDidEndInteraction(_ node: NodeFrameView) {}
        func nodeFrameViewDidRequestFocus(_ node: NodeFrameView) { focusRequests += 1 }
        func nodeFrameViewDidTakeFirstResponder(_ node: NodeFrameView) {}
        func nodeFrameView(_ node: NodeFrameView, didRenameTo title: String) { renamed.append(title) }
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

        let controller = CanvasController(canvas: canvas, workspaceStore: WorkspaceStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("picanvas-ws-\(UUID().uuidString)"), legacyLayoutURL: layoutURL))
        let recorder = ContentRecorder()
        controller.contentFactory = { spec in recorder.make(spec) }

        testCoordinateConversion(canvas: canvas, checker: checker)
        testZoom(canvas: canvas, checker: checker)
        testDragMove(canvas: canvas, controller: controller, checker: checker)
        testResize(canvas: canvas, controller: controller, checker: checker)
        testProcessRequest(controller: controller, recorder: recorder, checker: checker)
        testDelete(canvas: canvas, controller: controller, recorder: recorder, checker: checker)
        testPersistence(checker: checker)
        testZOrder(canvas: canvas, controller: controller, checker: checker)
        testPiSessionBinding(checker: checker)
        testAgentStatusWatcher(checker: checker)
        testGhosttyConfig(checker: checker)
        testAttentionAndJump(checker: checker)
        testScrollRouting(checker: checker)
        testZoomScrollRouting(checker: checker)
        testExitBehaviour(checker: checker)
        testKeyRepeat(checker: checker)
        testNodePalette(checker: checker)
        testRenaming(checker: checker)
        testWorkspaces(checker: checker)
        testScrollbackPersistence(checker: checker)
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

        // Every border resizes, not just the bottom-right corner.
        node.worldFrame = CGRect(x: 400, y: 200, width: 600, height: 400)
        canvas.layoutNodes()

        let leftEdge = CGPoint(x: node.frame.minX + 3, y: node.frame.midY)
        drag(canvas: canvas, from: leftEdge, to: CGPoint(x: leftEdge.x + 80, y: leftEdge.y), on: node)
        checker.close(node.worldFrame.origin.x, 480, 1, "dragging the left edge moves the origin right")
        checker.close(node.worldFrame.width, 520, 1, "dragging the left edge shrinks the width")
        checker.close(node.worldFrame.maxX, 1000, 1, "the right edge stays put")

        let topEdge = CGPoint(x: node.frame.midX, y: node.frame.minY + 3)
        drag(canvas: canvas, from: topEdge, to: CGPoint(x: topEdge.x, y: topEdge.y + 60), on: node)
        checker.close(node.worldFrame.origin.y, 260, 1, "dragging the top edge moves the origin down")
        checker.close(node.worldFrame.height, 340, 1, "dragging the top edge shortens the height")
        checker.close(node.worldFrame.maxY, 600, 1, "the bottom edge stays put")

        let rightEdge = CGPoint(x: node.frame.maxX - 3, y: node.frame.midY)
        drag(canvas: canvas, from: rightEdge, to: CGPoint(x: rightEdge.x + 100, y: rightEdge.y), on: node)
        checker.close(node.worldFrame.width, 620, 1, "dragging the right edge grows the width")

        // The top band is thinner than the sides so the title bar stays grabbable:
        // a little below the very top edge, a drag should move instead of resize.
        node.worldFrame = CGRect(x: 400, y: 200, width: 600, height: 400)
        canvas.layoutNodes()
        let originBefore = node.worldFrame.origin
        let sizeBefore = node.worldFrame.size
        let titleGrab = CGPoint(x: node.frame.midX, y: node.frame.minY + 14)
        drag(canvas: canvas, from: titleGrab, to: CGPoint(x: titleGrab.x + 50, y: titleGrab.y + 30), on: node)
        checker.close(node.worldFrame.origin.x, originBefore.x + 50, 1, "the title bar still moves the node")
        checker.close(node.worldFrame.width, sizeBefore.width, 1, "and does not resize it")
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

    /// Persistence now has two layers: a workspace file holds a canvas, and the
    /// legacy single-canvas file is adopted as the first workspace.
    private static func testPersistence(checker: Checker) {
        print("\npersistence")

        let canvasFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let canvas = CanvasView(frame: canvasFrame)
        let window = NSWindow(
            contentRect: canvasFrame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-persist-\(UUID().uuidString)")
        let legacyURL = directory.appendingPathComponent("layout.json")
        let store = WorkspaceStore(directory: directory, legacyLayoutURL: legacyURL)
        let controller = CanvasController(canvas: canvas, workspaceStore: store)
        controller.contentFactory = { _ in RecordingContent() }

        controller.newNode(kind: .shell)
        guard let node = canvas.nodeViews.first else {
            checker.check(false, "node available to persist")
            window.close()
            return
        }
        node.worldFrame = CGRect(x: 42, y: -17, width: 512, height: 300)
        canvas.layoutNodes()
        controller.saveNow()

        let reloaded = store.loadAll()
        checker.equal(reloaded.count, 1, "one workspace file is written")
        guard let layout = reloaded.first?.layout else {
            checker.check(false, "workspace file readable")
            window.close()
            return
        }
        checker.equal(layout.nodes.count, controller.nodeCount, "node count persisted")
        checker.close(CGFloat(layout.zoom), canvas.zoom, 0.001, "zoom persisted")

        guard let persisted = layout.nodes.first(where: { $0.id == node.nodeID }) else {
            checker.check(false, "node found in the persisted workspace")
            window.close()
            return
        }
        checker.close(CGFloat(persisted.x), 42, 0.001, "x persisted")
        checker.close(CGFloat(persisted.y), -17, 0.001, "y persisted")
        checker.close(CGFloat(persisted.width), 512, 0.001, "width persisted")
        checker.close(CGFloat(persisted.height), 300, 0.001, "height persisted")
        checker.equal(persisted.workspaceID, reloaded.first?.id, "the node remembers its workspace")

        // Restoring into a fresh canvas must reproduce the canvas.
        let canvas2 = CanvasView(frame: canvasFrame)
        let window2 = NSWindow(contentRect: canvasFrame, styleMask: [.titled], backing: .buffered, defer: false)
        window2.contentView = canvas2
        window2.makeKeyAndOrderFront(nil)

        let controller2 = CanvasController(canvas: canvas2, workspaceStore: store)
        controller2.contentFactory = { _ in RecordingContent() }
        controller2.restore()

        checker.equal(controller2.nodeCount, layout.nodes.count, "restore recreates every node")
        checker.equal(controller2.workspaceCount, 1, "restore brings back the workspace")
        if let restored = canvas2.nodeView(withID: node.nodeID) {
            checker.close(restored.worldFrame.origin.x, 42, 0.001, "restored x")
            checker.close(restored.worldFrame.size.width, 512, 0.001, "restored width")
        } else {
            checker.check(false, "restored node exists")
        }
        window2.close()
        window.close()
        try? FileManager.default.removeItem(at: directory)
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

    /// `pi` nodes must own a pi session from the moment they are created, so a
    /// restart resumes the conversation instead of starting a blank agent.
    private static func testPiSessionBinding(checker: Checker) {
        print("\npi session binding")

        let spec = ProcessResolver.makeSpec(
            kind: .pi,
            workingDirectory: "/Users/someone/Project Name",
            worldFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        guard let sessionID = spec.sessionID else {
            checker.check(false, "pi spec carries a session id")
            return
        }
        checker.check(true, "pi spec carries a session id")
        checker.equal(sessionID, sessionID.lowercased(), "session id is lower case")
        checker.equal(sessionID.count, 36, "session id is a UUID")
        checker.check(UUID(uuidString: sessionID) != nil, "session id parses as a UUID")

        let command = spec.arguments.last ?? ""
        checker.check(command.contains("pi --session-id '\(sessionID)'"), "the session id is passed to pi")
        checker.check(!command.contains("--name"), "pi sessions are left unnamed, since naming them is the user's call")
        checker.check(command.contains("; exec /bin/zsh -l"), "quitting pi hands the node to a login shell")

        let other = ProcessResolver.makeSpec(
            kind: .pi,
            workingDirectory: "/Users/someone/Project Name",
            worldFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        checker.check(other.sessionID != sessionID, "two agents in one directory get separate sessions")

        // And it must survive a save/load cycle, or restore would start fresh.
        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-session-test.json")
        let store = LayoutStore(fileURL: layoutURL)
        store.saveNow(LayoutFile(lastWorkingDirectory: "/tmp", nodes: [spec]))
        checker.equal(store.load()?.nodes.first?.sessionID, sessionID, "session id survives persistence")

        let shell = ProcessResolver.makeSpec(
            kind: .shell,
            workingDirectory: "/tmp",
            worldFrame: .zero
        )
        checker.check(shell.sessionID == nil, "shell nodes have no pi session")
    }

    /// The agent status is derived purely from pi's session transcript, so the
    /// state machine and the file tailing both need to be right.
    private static func testAgentStatusWatcher(checker: Checker) {
        print("\npi agent status watcher")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-watch-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/Users/someone/Project Name"
        let directory = PiSessionWatcher.sessionDirectory(for: cwd, under: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        checker.equal(
            PiSessionWatcher.sessionDirectory(for: "/tmp", under: root).lastPathComponent,
            "--private-tmp--",
            "session directory resolves symlinks the way pi does"
        )
        checker.equal(
            PiSessionWatcher.sessionDirectory(for: "/Users/me/a:b", under: root).lastPathComponent,
            "--Users-me-a-b--",
            "session directory replaces colons like pi does"
        )
        checker.equal(
            directory.lastPathComponent,
            "--Users-someone-Project Name--",
            "session directory slug matches pi's grouping (spaces preserved)"
        )

        let sessionID = "11112222-3333-4444-5555-666677778888"
        let file = directory.appendingPathComponent("2026-01-01T00-00-00-000Z_\(sessionID).jsonl")

        var observed: [PiAgentState] = []
        let watcher = PiSessionWatcher(
            workingDirectory: cwd,
            sessionID: sessionID,
            sessionsRoot: root,
            pollInterval: 0.05
        ) { state in
            observed.append(state)
        }
        checker.equal(watcher.state, .ready, "a node with no transcript yet reads as ready")
        checker.equal(PiAgentState.ready.statusKind, .idle, "ready is not an alarm")
        checker.equal(PiAgentState.waitingForYou.statusKind, .needsAttention, "needs-you is highlighted")
        checker.equal(PiAgentState.waitingForYou.displayText, "needs you", "needs-you reads well")
        watcher.start()

        func append(_ line: String) {
            // FileHandle(forWritingTo:) does not create the file, and pi creates
            // its transcript lazily too.
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
        func timestamp(_ offset: Int) -> String {
            "2026-01-01T00:00:\(String(format: "%02d", offset)).000Z"
        }

        append("{\"type\":\"session\",\"version\":3,\"id\":\"\(sessionID)\",\"timestamp\":\"\(timestamp(0))\",\"cwd\":\"\(cwd)\"}")
        checker.check(
            waitUntil(timeout: 3) { watcher.state == .ready },
            "a transcript with only a header still reads as ready"
        )

        // A user prompt starts a run.
        append("{\"type\":\"message\",\"id\":\"a1\",\"parentId\":null,\"timestamp\":\"\(timestamp(1))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"do the thing\"}]}}")
        checker.check(
            waitUntil(timeout: 3) { watcher.state == .working("thinking") },
            "a user message means the agent is working"
        )

        // The model calls a tool.
        append("{\"type\":\"message\",\"id\":\"a2\",\"parentId\":\"a1\",\"timestamp\":\"\(timestamp(2))\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"toolUse\",\"content\":[{\"type\":\"text\",\"text\":\"running\"},{\"type\":\"toolCall\",\"name\":\"bash\",\"arguments\":{}}]}}")
        checker.check(
            waitUntil(timeout: 3) { watcher.state == .working("bash") },
            "a pending tool call names the tool (got \(watcher.state.displayText))"
        )

        // The tool returns; the model is still going.
        append("{\"type\":\"message\",\"id\":\"a3\",\"parentId\":\"a2\",\"timestamp\":\"\(timestamp(3))\",\"message\":{\"role\":\"toolResult\",\"toolName\":\"bash\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}")
        checker.check(
            waitUntil(timeout: 3) { watcher.state == .working("bash") },
            "a tool result keeps the agent working"
        )

        // The run finishes: this is the state worth surfacing.
        append("{\"type\":\"message\",\"id\":\"a4\",\"parentId\":\"a3\",\"timestamp\":\"\(timestamp(4))\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\",\"model\":\"test-model\",\"provider\":\"test-provider\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}],\"usage\":{\"input\":1000,\"output\":200,\"cacheRead\":50,\"cacheWrite\":0,\"totalTokens\":1250,\"cost\":{\"total\":0.004}}}}")
        checker.check(
            waitUntil(timeout: 3) { watcher.state == .waitingForYou },
            "a finished run means the agent needs you"
        )
        checker.check(observed.contains(.waitingForYou), "the change was reported to the canvas")

        // Usage and cost are accumulated for the node.
        checker.check(
            waitUntil(timeout: 3) { watcher.usage.turns == 1 },
            "one assistant turn was counted"
        )
        checker.equal(watcher.usage.lastContextTokens, 1250, "context size comes from the last turn")
        checker.equal(watcher.usage.model, "test-model", "model name is read from the transcript")
        checker.equal(watcher.usage.provider, "test-provider", "provider is read from the transcript")
        checker.equal(watcher.usage.costText, "$0.0040", "cost is formatted for a title bar")
        checker.check(watcher.usage.detailText.contains("test-model (test-provider)"), "detail mentions the model")
        checker.check(watcher.usage.detailText.contains("context 1.2k"), "detail mentions the context size")

        // A second turn accumulates rather than replaces.
        append("{\"type\":\"message\",\"id\":\"a6\",\"parentId\":\"a5\",\"timestamp\":\"\(timestamp(6))\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\",\"model\":\"test-model\",\"provider\":\"test-provider\",\"content\":[{\"type\":\"text\",\"text\":\"done again\"}],\"usage\":{\"input\":500,\"output\":100,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":1900,\"cost\":{\"total\":0.001}}}}")
        checker.check(
            waitUntil(timeout: 3) { watcher.usage.turns == 2 },
            "a second turn is counted"
        )
        checker.equal(watcher.usage.inputTokens, 1500, "input tokens accumulate")
        checker.equal(watcher.usage.lastContextTokens, 1900, "context reflects the newest turn")
        checker.equal(watcher.usage.costText, "$0.0050", "cost accumulates")

        // A new prompt starts the cycle again.
        append("{\"type\":\"message\",\"id\":\"a5\",\"parentId\":\"a4\",\"timestamp\":\"\(timestamp(5))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"again\"}]}}")
        checker.check(
            waitUntil(timeout: 3) { watcher.state == .working("thinking") },
            "a follow-up prompt goes back to working"
        )

        watcher.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// The terminal should look like the user's Ghostty, so the config parser is
    /// worth testing properly: it is pure string handling with a lot of edges.
    private static func testGhosttyConfig(checker: Checker) {
        print("\nghostty config")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-config-\(UUID().uuidString)", isDirectory: true)
        let themes = root.appendingPathComponent("themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)

        // Colours.
        checker.equal(GhosttyTheme.color("#ff8800")?.redComponent, 1.0, "#rrggbb parses")
        checker.close(CGFloat(GhosttyTheme.color("#ff8800")?.greenComponent ?? 0), 0.533, 0.01, "green component")
        checker.equal(GhosttyTheme.color("#f80")?.redComponent, 1.0, "#rgb shorthand parses")
        checker.equal(GhosttyTheme.color("red")?.greenComponent, 0.0, "named colours parse")
        checker.check(GhosttyTheme.color("not-a-colour") == nil, "garbage colours are rejected")
        checker.equal(GhosttyTheme.boolean("true"), true, "booleans parse")
        checker.equal(GhosttyTheme.boolean("false"), false, "false parses")

        // A theme file, included by name.
        let themeFile = themes.appendingPathComponent("my-theme")
        try? """
        background = #101010
        foreground = #f0f0f0
        palette = 0=#000000,1=#cc0000
        cursor-color = #F1FA8C
        """.write(to: themeFile, atomically: true, encoding: .utf8)

        // An included config, pulled in with config-file.
        let included = root.appendingPathComponent("included")
        try? "font-size = 15\ncursor-style = bar\n".write(to: included, atomically: true, encoding: .utf8)

        let main = root.appendingPathComponent("config")
        try? """
        # a comment
        font-family = "Maple Mono NF, Menlo"
        font-size = 14
        cursor-style = block
        cursor-style-blink = false
        theme = my-theme
        palette = 2=#00cc00
        config-file = ./included
        config-file = ?./does-not-exist
        macos-window-buttons = hidden
        """.write(to: main, atomically: true, encoding: .utf8)

        let theme = GhosttyTheme.load(configPaths: [main], themeDirectories: [themes])

        checker.equal(theme.fontFamily, "Maple Mono NF", "font family takes the first of a list")
        checker.equal(theme.fontSize, 15, "an included file overrides the top-level value")
        checker.close(CGFloat(theme.cursorColor?.redComponent ?? 0), 0.9451, 0.001, "cursor colour from the theme")
        checker.equal(theme.cursorStyle?.shapeName, "bar", "the include's cursor shape wins")
        checker.equal(theme.cursorStyle?.blink, false, "blink is carried through")
        checker.close(CGFloat(theme.background?.redComponent ?? 0), 0.0627, 0.001, "theme background")
        checker.close(CGFloat(theme.foreground?.redComponent ?? 0), 0.9412, 0.001, "theme foreground")
        checker.equal(theme.palette[0]?.redComponent, 0.0, "theme palette entry 0")
        checker.close(CGFloat(theme.palette[1]?.redComponent ?? 0), 0.8, 0.001, "theme palette entry 1")
        checker.close(CGFloat(theme.palette[2]?.greenComponent ?? 0), 0.8, 0.001, "palette entry from the main file")
        checker.check(theme.paletteColors16 == nil, "an incomplete palette is not installed")
        checker.check(theme.warnings.isEmpty, "no warnings for a well-formed config (got \(theme.warnings))")
        checker.equal(theme.sources.count, 3, "main, theme and include were all read")

        // Optional includes that are missing are fine; required ones warn.
        let strict = root.appendingPathComponent("strict")
        try? "config-file = ./nope\n".write(to: strict, atomically: true, encoding: .utf8)
        checker.equal(
            GhosttyTheme.load(configPaths: [strict], themeDirectories: [themes]).warnings.count,
            1,
            "a missing required include warns"
        )

        // A full 16-colour palette is accepted.
        let paletteFile = root.appendingPathComponent("palette")
        let entries = (0..<16).map { "palette = \($0)=#010203" }.joined(separator: "\n")
        try? (entries + "\n").write(to: paletteFile, atomically: true, encoding: .utf8)
        let full = GhosttyTheme.load(configPaths: [paletteFile], themeDirectories: [themes])
        checker.equal(full.paletteColors16?.count, 16, "a full palette resolves to 16 colours")

        checker.check(
            GhosttyTheme.load(configPaths: [], themeDirectories: []).isEmpty,
            "no config means no overrides"
        )

        // Diagnostic: what the user's own config resolves to on this machine.
        let userTheme = GhosttyTheme.current
        if !userTheme.isEmpty {
            print("  ---- from \(userTheme.sources.joined(separator: ", "))")
            print("       font: \(userTheme.fontFamily ?? "(unset)") @ \(userTheme.fontSize.map { String(format: "%.1f", $0) } ?? "(unset)")")
            print("       cursor: \(userTheme.cursorStyle.map { "\($0.shapeName)\($0.blink ? " blinking" : "")" } ?? "(unset)")\(userTheme.cursorColor != nil ? " coloured" : "")")
        } else {
            print("  ---- no user ghostty config found")
        }

        try? FileManager.default.removeItem(at: root)
    }

    /// Holding a letter in a terminal must repeat the key, not open macOS's
    /// accent picker. The fix is a registered default, so assert it is in place
    /// and that a deliberate user override would be detected rather than fought.
    private static func testKeyRepeat(checker: Checker) {
        print("\nkey repeat")
        KeyboardDefaults.apply()

        checker.check(
            KeyboardDefaults.repeatsHeldKeys,
            "held keys repeat instead of showing accented characters"
        )
        checker.check(
            !UserDefaults.standard.bool(forKey: KeyboardDefaults.pressAndHoldKey),
            "press-and-hold is disabled for AppKit to read"
        )
        // The default must not be a persistent write: the user's own settings win.
        let appDomain = UserDefaults.standard.persistentDomain(forName: "com.neuhaus.picanvas")
        checker.check(
            appDomain?[KeyboardDefaults.pressAndHoldKey] == nil,
            "we register the default rather than writing to the user's preferences"
        )
        checker.check(
            KeyboardDefaults.overrideWarning() == nil || KeyboardDefaults.explicitOverride() != nil,
            "an override warning only appears when something really overrides us"
        )
    }

    /// A zoom gesture belongs to the canvas even when it lands on the focused
    /// terminal, and shift must stay available to the terminal (it bypasses mouse
    /// reporting so you can select text).
    private static func testZoomScrollRouting(checker: Checker) {
        print("\nzoom scroll routing")

        func scrollEvent(_ flags: CGEventFlags, deltaY: Int32 = 12) -> NSEvent? {
            guard let cgEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: deltaY,
                wheel2: 0,
                wheel3: 0
            ) else { return nil }
            cgEvent.flags = flags
            return NSEvent(cgEvent: cgEvent)
        }

        guard let command = scrollEvent(.maskCommand),
              let option = scrollEvent(.maskAlternate),
              let shift = scrollEvent(.maskShift),
              let plain = scrollEvent([]) else {
            checker.check(false, "scroll events could be constructed")
            return
        }

        checker.check(CanvasView.isZoomScroll(command), "⌘-scroll is a zoom gesture")
        checker.check(CanvasView.isZoomScroll(option), "⌥-scroll is a zoom gesture too")
        checker.check(!CanvasView.isZoomScroll(plain), "a plain scroll is not a zoom gesture")
        checker.check(!CanvasView.isZoomScroll(shift), "shift-scroll is not a zoom gesture")

        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-zoomscroll-\(UUID().uuidString).json")
        let controller = CanvasController(canvas: canvas, workspaceStore: WorkspaceStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("picanvas-ws-\(UUID().uuidString)"), legacyLayoutURL: layoutURL))
        controller.contentFactory = { _ in RecordingContent() }

        controller.newNode(kind: .shell)
        controller.newNode(kind: .shell)
        guard let focused = canvas.nodeViews.last, let other = canvas.nodeViews.first else {
            checker.check(false, "nodes created")
            window.close()
            return
        }
        let onFocused = CGPoint(x: focused.frame.midX, y: focused.frame.midY)
        let onOther = CGPoint(x: other.frame.midX, y: other.frame.midY)

        checker.check(
            canvas.canvasHandlesScroll(command, at: onFocused),
            "⌘-scroll zooms the canvas even over the focused terminal"
        )
        checker.check(
            canvas.canvasHandlesScroll(option, at: onFocused),
            "⌥-scroll zooms the canvas even over the focused terminal"
        )
        checker.check(
            !canvas.canvasHandlesScroll(plain, at: onFocused),
            "a plain scroll still reaches the focused terminal"
        )
        checker.check(
            !canvas.canvasHandlesScroll(shift, at: onFocused),
            "shift-scroll is left to the terminal, which uses it to select text"
        )
        checker.check(
            canvas.canvasHandlesScroll(plain, at: onOther),
            "a plain scroll over an unfocused terminal pans the canvas"
        )
        checker.check(
            canvas.canvasHandlesScroll(command, at: CGPoint(x: 5, y: 5)),
            "⌘-scroll over empty canvas zooms"
        )

        window.close()
    }

    /// The switcher earns its keep in what it shows when you type, so the ranking
    /// is tested directly, along with the rows the controller builds from nodes.
    private static func testNodePalette(checker: Checker) {
        print("\nnode switcher")

        // Matching quality
        checker.check(
            PaletteRanking.score("pi", in: "pi - canvas") > PaletteRanking.score("pi", in: "canvas pi"),
            "an earlier match scores higher"
        )
        checker.equal(PaletteRanking.score("zzz", in: "pi - canvas"), 0, "a miss scores zero")
        checker.check(PaletteRanking.score("pcn", in: "pi-canvas") > 0, "subsequences match, so initials work")
        checker.check(PaletteRanking.score("canvas", in: "~/Projects/pi-canvas") > 0, "paths are searchable")
        checker.check(PaletteRanking.score("", in: "anything") > 0, "an empty query matches everything")
        checker.check(
            PaletteRanking.score("canvas", in: "canvas") > PaletteRanking.score("canvas", in: "pi - canvas"),
            "an exact match beats a substring"
        )

        // Ordering
        let waiting = UUID()
        let recent = UUID()
        let stale = UUID()
        let entries = [
            PaletteRow(
                id: stale, title: "Terminal", subtitle: "~/work", status: nil,
                statusKind: .idle, isAttention: false, dotColor: nil,
                haystackExtra: "Terminal", lastFocused: nil
            ),
            PaletteRow(
                id: waiting, title: "π - canvas", subtitle: "~/Projects/pi-canvas",
                status: "needs you", statusKind: .needsAttention, isAttention: true,
                dotColor: nil, haystackExtra: "pi",
                lastFocused: Date(timeIntervalSince1970: 100)
            ),
            PaletteRow(
                id: recent, title: "zsh", subtitle: "~/tmp", status: nil,
                statusKind: .idle, isAttention: false, dotColor: nil,
                haystackExtra: "Terminal", lastFocused: Date(timeIntervalSince1970: 500)
            )
        ]

        checker.equal(
            PaletteRanking.ranked(entries, query: "").map(\.id),
            [waiting, recent, stale],
            "unqueried: agents that need you, then most recently focused"
        )
        checker.equal(
            PaletteRanking.ranked(entries, query: "need").first?.id,
            waiting,
            "typing a status finds the waiting agent"
        )
        checker.equal(
            PaletteRanking.ranked(entries, query: "tmp").first?.id,
            recent,
            "the working directory is searchable"
        )
        checker.equal(PaletteRanking.ranked(entries, query: "zzz").count, 0, "a query with no match shows nothing")

        // The digit shortcut
        checker.equal(PaletteRanking.indexForDigit("2", count: 3), 1, "a digit picks a row by position")
        checker.check(PaletteRanking.indexForDigit("9", count: 3) == nil, "a digit past the end picks nothing")
        checker.check(PaletteRanking.indexForDigit("0", count: 3) == nil, "there is no zeroth row")
        checker.check(PaletteRanking.indexForDigit("ab", count: 3) == nil, "text is not a digit")

        // What the controller actually lists
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-palette-\(UUID().uuidString).json")
        let controller = CanvasController(canvas: canvas, workspaceStore: WorkspaceStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("picanvas-ws-\(UUID().uuidString)"), legacyLayoutURL: layoutURL))
        controller.contentFactory = { _ in RecordingContent() }
        controller.newNode(kind: .shell)
        controller.newNode(kind: .pi)

        let listed = controller.paletteEntries()
        checker.equal(listed.count, 2, "every node is listed")
        checker.check(listed.allSatisfy { !$0.title.isEmpty }, "every row has a title")
        checker.check(listed.allSatisfy { !$0.subtitle.isEmpty }, "every row says where it runs")
        checker.check(listed.contains { $0.haystackExtra == "pi" }, "agents are listed alongside terminals")
        checker.check(listed.contains { $0.haystackExtra == "Terminal" }, "terminals are listed too")

        canvas.select(nil, focusContent: false)
        guard let target = canvas.nodeViews.first else {
            checker.check(false, "a node exists")
            window.close()
            return
        }
        controller.focusNode(id: target.nodeID)
        checker.equal(canvas.focusedNodeID, target.nodeID, "choosing a row focuses that node")
        checker.check(
            canvas.visibleWorldRect.intersects(target.worldFrame),
            "and brings it into view"
        )

        window.close()
    }

    /// A name you give a node has to beat the terminal's own title, and survive a
    /// restart. The inline editor gets tested through the same gestures a person
    /// uses, since double-click-to-rename is the whole interaction.
    private static func testRenaming(checker: Checker) {
        print("\nrenaming")

        // --- the inline editor -------------------------------------------------
        let node = NodeFrameView(
            nodeID: UUID(),
            worldFrame: CGRect(x: 0, y: 0, width: 420, height: 300),
            kind: .shell
        )
        let editorWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Hosted in a canvas, as it is in the app.
        let editorCanvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 420, height: 300))
        editorWindow.contentView = editorCanvas
        editorCanvas.addNodeView(node)
        editorWindow.makeKeyAndOrderFront(nil)
        node.title = "before"
        let delegate = RecordingNodeDelegate()
        node.nodeDelegate = delegate

        func click(_ count: Int, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: node.convert(point, to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: editorWindow.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: count,
                pressure: 1
            )
        }

        if let single = click(1, at: CGPoint(x: 210, y: 12)) {
            node.mouseDown(with: single)
        }
        checker.check(!node.isRenaming, "a single click on the title bar does not rename")

        if let double = click(2, at: CGPoint(x: 210, y: 12)) {
            node.mouseDown(with: double)
        }
        checker.check(node.isRenaming, "double-clicking the title bar starts an edit")
        checker.equal(node.renamingField?.stringValue, "before", "the field starts with the current name")

        node.renamingField?.stringValue = "intake form"
        node.commitRenaming()
        checker.check(!node.isRenaming, "committing closes the editor")
        checker.equal(delegate.renamed, ["intake form"], "the new name is reported")

        node.beginRenaming()
        node.renamingField?.stringValue = "discarded"
        node.cancelRenaming()
        checker.equal(delegate.renamed, ["intake form"], "cancelling reports nothing")
        checker.check(!node.isRenaming, "cancelling closes the editor")

        editorWindow.close()

        // --- naming, precedence and persistence --------------------------------
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-rename-\(UUID().uuidString).json")
        let store = WorkspaceStore(
            directory: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("picanvas-rename-ws-\(UUID().uuidString)"),
            legacyLayoutURL: layoutURL
        )
        let controller = CanvasController(canvas: canvas, workspaceStore: store)
        let recorder = ContentRecorder()
        controller.contentFactory = { spec in recorder.make(spec) }

        controller.newNode(kind: .shell)
        guard let id = canvas.nodeViews.last?.nodeID else {
            checker.check(false, "node created")
            window.close()
            return
        }

        controller.renameNode(id: id, to: "  auth refactor  ")
        checker.equal(canvas.nodeView(withID: id)?.title, "auth refactor", "the name is trimmed and shown")

        // The terminal naming itself must not win.
        recorder.content(for: id)?.onTitleChange?("zsh: ~/somewhere")
        checker.equal(
            canvas.nodeView(withID: id)?.title,
            "auth refactor",
            "a name you gave beats the terminal's own title"
        )

        controller.saveNow()
        checker.equal(
            store.loadAll().first?.layout.nodes.first?.customTitle,
            "auth refactor",
            "the name is persisted"
        )

        // Clearing it hands the title back to the terminal.
        controller.renameNode(id: id, to: "   ")
        checker.equal(
            canvas.nodeView(withID: id)?.title,
            "zsh: ~/somewhere",
            "clearing the name falls back to the terminal's title"
        )

        // And the name is what the switcher searches, which is the point of naming.
        controller.renameNode(id: id, to: "auth refactor")
        checker.equal(
            controller.paletteEntries().first?.title,
            "auth refactor",
            "the switcher lists the name you gave"
        )
        checker.equal(
            PaletteRanking.ranked(controller.paletteEntries(), query: "auth").count,
            1,
            "and can be found by typing it"
        )

        window.close()
    }

    /// Workspaces are the organisational layer, so the tests are about what
    /// survives a switch: running agents, their node views, and each canvas's own
    /// viewport.
    private static func testWorkspaces(checker: Checker) {
        print("\nworkspaces")

        let canvasFrame = CGRect(x: 0, y: 0, width: 1400, height: 800)
        func makeCanvas() -> (CanvasView, NSWindow) {
            let canvas = CanvasView(frame: canvasFrame)
            let window = NSWindow(
                contentRect: canvasFrame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = canvas
            window.makeKeyAndOrderFront(nil)
            return (canvas, window)
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-workspaces-\(UUID().uuidString)")
        // The pre-workspaces layout lived beside the workspaces directory, not
        // inside it, so mirror that.
        let legacyURL = directory.deletingLastPathComponent()
            .appendingPathComponent("picanvas-legacy-\(UUID().uuidString).json")
        let store = WorkspaceStore(directory: directory, legacyLayoutURL: legacyURL)

        // --- migration from the single-canvas layout -------------------------
        let legacySpec = ProcessResolver.makeSpec(
            kind: .shell,
            workingDirectory: "/tmp",
            worldFrame: CGRect(x: 10, y: 10, width: 400, height: 300)
        )
        LayoutStore(fileURL: legacyURL).saveNow(LayoutFile(lastWorkingDirectory: "/tmp", nodes: [legacySpec]))

        let (canvas, window) = makeCanvas()
        let recorder = ContentRecorder()
        let controller = CanvasController(canvas: canvas, workspaceStore: store)
        controller.contentFactory = { spec in recorder.make(spec) }
        controller.restore()

        checker.equal(controller.workspaceCount, 1, "the old single canvas becomes one workspace")
        checker.equal(controller.activeWorkspaceName, "Default", "and it is named Default")
        checker.equal(controller.nodeCount, 1, "with its nodes")
        checker.equal(
            canvas.nodeView(withID: legacySpec.id)?.workspaceID,
            controller.activeWorkspaceID,
            "adopted nodes are tagged with the workspace that adopted them"
        )
        checker.equal(recorder.content(for: legacySpec.id)?.startedRequests.count, 1, "its process starts")

        // --- a second workspace keeps the first one alive --------------------
        canvas.setViewport(zoom: 0.5, pan: CGPoint(x: 100, y: 50), notify: false)
        let firstWorkspace = controller.activeWorkspaceID
        let secondWorkspace = controller.createWorkspace(named: "Second")

        checker.equal(controller.workspaceCount, 2, "a workspace can be created")
        checker.equal(controller.activeWorkspaceName, "Second", "and becomes the one on screen")
        checker.equal(controller.nodeCount, 0, "which is empty")
        checker.equal(
            canvas.nodeView(withID: legacySpec.id)?.isHidden,
            true,
            "the other workspace's node is hidden"
        )
        checker.equal(
            recorder.content(for: legacySpec.id)?.terminateCount,
            0,
            "but its agent keeps running"
        )
        checker.equal(
            recorder.content(for: legacySpec.id)?.startedRequests.count,
            1,
            "and is not started twice"
        )
        let hiddenFrame = canvas.nodeView(withID: legacySpec.id)?.frame ?? .zero
        let hiddenCentre = CGPoint(x: hiddenFrame.midX, y: hiddenFrame.midY)
        checker.check(canvas.node(at: hiddenCentre) == nil, "a hidden node does not take clicks")
        checker.check(!canvas.terminalHandlesScroll(at: hiddenCentre), "nor scroll")

        // --- each canvas remembers its own viewport --------------------------
        canvas.setViewport(zoom: 1.7, pan: CGPoint(x: -30, y: -40), notify: false)
        controller.activateWorkspace(id: firstWorkspace)
        checker.close(canvas.zoom, 0.5, 0.001, "the first workspace's zoom comes back")
        checker.close(canvas.pan.x, 100, 0.001, "and its pan")
        checker.equal(
            canvas.nodeView(withID: legacySpec.id)?.isHidden,
            false,
            "its nodes are visible again"
        )
        controller.activateWorkspace(id: secondWorkspace)
        checker.close(canvas.zoom, 1.7, 0.001, "the second workspace's zoom comes back")

        // --- naming ---------------------------------------------------------
        controller.renameWorkspace(id: secondWorkspace, to: "  Auth refactor  ")
        checker.equal(controller.activeWorkspaceName, "Auth refactor", "a workspace can be renamed")
        controller.renameWorkspace(id: secondWorkspace, to: "   ")
        checker.equal(controller.activeWorkspaceName, "Auth refactor", "an empty name is ignored")

        // --- the switcher's rows ---------------------------------------------
        let rows = controller.workspacePaletteRows()
        checker.equal(rows.filter { !$0.isCreate }.count, 2, "every workspace is listed")
        checker.check(rows.contains { $0.isCreate }, "with an offer to create another")
        checker.check(
            controller.orderedWorkspaceRows().contains { $0.id == controller.activeWorkspaceID },
            "the active workspace is among them"
        )
        controller.activateWorkspace(id: firstWorkspace)
        checker.equal(controller.paletteEntries().count, 1, "the node list is the active workspace's")
        controller.activateWorkspace(id: secondWorkspace)
        checker.equal(controller.paletteEntries().count, 0, "and follows a switch")

        // --- restarting from disk --------------------------------------------
        controller.saveNow()
        let (canvas2, window2) = makeCanvas()
        let recorder2 = ContentRecorder()
        let controller2 = CanvasController(canvas: canvas2, workspaceStore: store)
        controller2.contentFactory = { spec in recorder2.make(spec) }
        controller2.restore()

        checker.equal(controller2.workspaceCount, 2, "both workspaces come back")
        checker.equal(controller2.nodeCount, 0, "the most recently used one opens first")
        checker.equal(
            recorder2.content(for: legacySpec.id)?.startedRequests.count,
            0,
            "nodes in workspaces you have not opened do not start"
        )
        controller2.activateWorkspace(id: firstWorkspace)
        checker.equal(controller2.nodeCount, 1, "opening the other workspace brings its nodes")
        checker.equal(
            recorder2.content(for: legacySpec.id)?.startedRequests.count,
            1,
            "and starts them then"
        )

        // --- deleting ---------------------------------------------------------
        controller2.activateWorkspace(id: secondWorkspace)
        controller2.deleteWorkspace(id: secondWorkspace)
        checker.equal(controller2.workspaceCount, 1, "a workspace can be deleted")
        checker.equal(controller2.activeWorkspaceName, "Default", "and the app falls back to another")
        controller2.deleteWorkspace(id: firstWorkspace)
        checker.equal(controller2.workspaceCount, 1, "the last workspace cannot be deleted")
        checker.equal(
            recorder2.content(for: legacySpec.id)?.terminateCount,
            0,
            "deleting a workspace does not stop another's agents"
        )

        // --- deleting the one you are in stops its agents --------------------
        let third = controller2.createWorkspace(named: "Third")
        controller2.newNode(kind: .shell)
        guard let thirdNode = canvas2.nodeViews.last?.nodeID else {
            checker.check(false, "node created in the third workspace")
            window.close()
            window2.close()
            return
        }
        controller2.deleteWorkspace(id: third)
        checker.equal(
            recorder2.content(for: thirdNode)?.terminateCount,
            1,
            "deleting a workspace stops the agents in it"
        )
        checker.equal(controller2.workspaceCount, 1, "and leaves the others")

        window.close()
        window2.close()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Quitting a shell should close its node, but a failure should leave it
    /// standing so the error is readable. Signals are abnormal too, so they stay.
    private static func testExitBehaviour(checker: Checker) {
        print("\nexit behaviour")

        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-exit-\(UUID().uuidString).json")
        let controller = CanvasController(canvas: canvas, workspaceStore: WorkspaceStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("picanvas-ws-\(UUID().uuidString)"), legacyLayoutURL: layoutURL))
        let recorder = ContentRecorder()
        controller.contentFactory = { spec in recorder.make(spec) }

        func startNode() -> (id: UUID, content: RecordingContent)? {
            controller.newNode(kind: .shell)
            guard let id = canvas.nodeViews.last?.nodeID, let content = recorder.content(for: id) else { return nil }
            return (id, content)
        }

        // A clean exit: the shell said goodbye, so the node goes with it.
        guard let clean = startNode() else {
            checker.check(false, "node created")
            window.close()
            return
        }
        let countBefore = controller.nodeCount
        clean.content.onExit?(0)
        checker.check(
            waitUntil(timeout: 3) { canvas.nodeView(withID: clean.id) == nil },
            "a clean exit closes its node"
        )
        checker.equal(controller.nodeCount, countBefore - 1, "the node is removed from the model too")
        checker.equal(recorder.content(for: clean.id)?.terminateCount, 1, "the surface is torn down")

        // A failure: stay put with the code visible.
        guard let failed = startNode() else {
            checker.check(false, "second node created")
            window.close()
            return
        }
        failed.content.onExit?(127)
        _ = waitUntil(timeout: 1) { false }
        checker.check(canvas.nodeView(withID: failed.id) != nil, "a failed command keeps its node")
        checker.equal(
            canvas.nodeView(withID: failed.id)?.statusText,
            "exited 127",
            "and reports the exit code"
        )
        checker.equal(
            canvas.nodeView(withID: failed.id)?.statusKind,
            .failure,
            "which is flagged as a failure"
        )

        // A signal is abnormal: keep the node as well.
        failed.content.onExit?(nil)
        _ = waitUntil(timeout: 1) { false }
        checker.check(canvas.nodeView(withID: failed.id) != nil, "a signalled process keeps its node")
        checker.equal(
            canvas.nodeView(withID: failed.id)?.statusText,
            "stopped",
            "and says it was stopped"
        )

        window.close()
    }

    /// Scrolling must move the canvas, not the terminal under the pointer —
    /// unless that terminal is the focused one. This pins the policy, which
    /// otherwise lives inside an event monitor and would drift silently.
    private static func testScrollRouting(checker: Checker) {
        print("\nscroll routing")

        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: canvas.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-scroll-\(UUID().uuidString).json")
        let controller = CanvasController(canvas: canvas, workspaceStore: WorkspaceStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("picanvas-ws-\(UUID().uuidString)"), legacyLayoutURL: layoutURL))
        controller.contentFactory = { _ in RecordingContent() }

        checker.check(
            !canvas.terminalHandlesScroll(at: CGPoint(x: 10, y: 10)),
            "an empty canvas routes scroll to itself"
        )

        controller.newNode(kind: .shell)
        guard let first = canvas.nodeViews.first else {
            checker.check(false, "node created")
            window.close()
            return
        }

        func centre(of node: NodeFrameView) -> CGPoint {
            // Recompute on demand: creating another node pans the viewport.
            CGPoint(x: node.frame.midX, y: node.frame.midY)
        }

        checker.check(
            canvas.terminalHandlesScroll(at: centre(of: first)),
            "the focused terminal keeps its own scrolling"
        )

        controller.newNode(kind: .shell)
        guard let second = canvas.nodeViews.last, second.nodeID != first.nodeID else {
            checker.check(false, "second node created")
            window.close()
            return
        }

        checker.check(
            canvas.terminalHandlesScroll(at: centre(of: second)),
            "the newly focused terminal scrolls itself"
        )
        checker.check(
            !canvas.terminalHandlesScroll(at: centre(of: first)),
            "a terminal that is not focused no longer steals scroll"
        )

        canvas.select(nil, focusContent: false)
        checker.check(
            !canvas.terminalHandlesScroll(at: centre(of: first)),
            "with nothing selected the first terminal is unaffected"
        )
        checker.check(
            !canvas.terminalHandlesScroll(at: centre(of: second)),
            "with nothing selected the second terminal is unaffected"
        )
        checker.check(
            !canvas.terminalHandlesScroll(at: CGPoint(x: 10, y: 10)),
            "with nothing selected empty canvas still pans"
        )

        canvas.select(first, focusContent: false)
        checker.check(
            canvas.terminalHandlesScroll(at: centre(of: first)),
            "selecting a terminal hands scrolling back to it"
        )

        window.close()
    }

    /// The whole agent-awareness chain: transcripts on disk → node status pills →
    /// the "needs you" count → jumping to the node that wants a human.
    private static func testAttentionAndJump(checker: Checker) {
        print("\nagent attention and jump")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-attention-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/Users/someone/Attention Project"
        let directory = PiSessionWatcher.sessionDirectory(for: cwd, under: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        /// Writes a transcript whose final entry produces the given state.
        func writeTranscript(sessionID: String, finished: Bool) {
            let file = directory.appendingPathComponent("2026-01-01T00-00-00-000Z_\(sessionID).jsonl")
            let stamp = "2026-01-01T00:00:00.000Z"
            let lines = [
                "{\"type\":\"session\",\"version\":3,\"id\":\"\(sessionID)\",\"timestamp\":\"\(stamp)\",\"cwd\":\"\(cwd)\"}",
                "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":null,\"timestamp\":\"\(stamp)\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"go\"}]}}",
                finished
                    ? "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"\(stamp)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"stop\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
                    : "{\"type\":\"message\",\"id\":\"a1\",\"parentId\":\"u1\",\"timestamp\":\"\(stamp)\",\"message\":{\"role\":\"assistant\",\"stopReason\":\"toolUse\",\"content\":[{\"type\":\"toolCall\",\"name\":\"bash\",\"arguments\":{}}]}}"
            ]
            try? lines.joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
        }

        let finishedSession = "aaaa0000-1111-4222-8333-444455556666"
        let busySession = "bbbb0000-1111-4222-8333-444455556666"
        writeTranscript(sessionID: finishedSession, finished: true)
        writeTranscript(sessionID: busySession, finished: false)

        // The node that wants attention sits far off-screen, so jumping must pan.
        let finishedNode = NodeSpec(
            kind: .pi,
            worldFrame: CGRect(x: 5000, y: 0, width: 600, height: 400),
            workingDirectory: cwd,
            executable: "/bin/zsh",
            arguments: ["-lc", "true"],
            sessionID: finishedSession
        )
        let busyNode = NodeSpec(
            kind: .pi,
            worldFrame: CGRect(x: 0, y: 0, width: 600, height: 400),
            workingDirectory: cwd,
            executable: "/bin/zsh",
            arguments: ["-lc", "true"],
            sessionID: busySession
        )

        let layoutURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-attention-\(UUID().uuidString).json")
        let store = LayoutStore(fileURL: layoutURL)
        store.saveNow(LayoutFile(
            zoom: 1,
            panX: 0,
            panY: 0,
            lastWorkingDirectory: cwd,
            nodes: [busyNode, finishedNode]
        ))

        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        let controller = CanvasController(
            canvas: canvas,
            workspaceStore: WorkspaceStore(
                directory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("picanvas-attention-ws-\(UUID().uuidString)"),
                legacyLayoutURL: layoutURL
            )
        )
        controller.sessionsRoot = root
        controller.contentFactory = { _ in RecordingContent() }
        controller.restore()

        checker.check(
            waitUntil(timeout: 5) { controller.agentsNeedingAttention == [finishedNode.id] },
            "only the finished agent asks for attention (got \(controller.agentsNeedingAttention.count))"
        )
        checker.equal(
            canvas.nodeView(withID: finishedNode.id)?.statusText,
            "needs you",
            "the finished node shows needs-you"
        )
        checker.equal(
            canvas.nodeView(withID: busyNode.id)?.statusText,
            "bash",
            "the running node names the tool it is using"
        )
        checker.equal(
            canvas.nodeView(withID: finishedNode.id)?.statusKind,
            .needsAttention,
            "the pill is highlighted"
        )

        let panBefore = canvas.pan
        let jumped = controller.jumpToNextAgentNeedingAttention()
        checker.equal(jumped, finishedNode.id, "jump targets the agent that needs you")
        checker.equal(canvas.focusedNodeID, finishedNode.id, "jump focuses that node")
        checker.check(canvas.pan != panBefore, "jump pans to bring an off-screen node into view")
        checker.check(
            canvas.visibleWorldRect.intersects(finishedNode.worldFrame),
            "the target node is on screen after the jump"
        )
        checker.equal(
            controller.jumpToNextAgentNeedingAttention(),
            finishedNode.id,
            "cycling with a single candidate stays on it"
        )

        // Closing the node must drop it from the attention list.
        controller.close(nodeID: finishedNode.id)
        checker.check(controller.agentsNeedingAttention.isEmpty, "closing a node clears its attention")
        checker.check(controller.jumpToNextAgentNeedingAttention() == nil, "nothing to jump to once it is closed")

        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// Scrollback must survive a restart for shell nodes: the buffer is
    /// snapshotted on quit and painted back before the new shell starts.
    private static func testScrollbackPersistence(checker: Checker) {
        print("\nscrollback persistence (real PTY)")

        // Capping keeps the newest output and whole lines.
        let big = Data((1...5000).map { "line\($0)\n" }.joined().utf8)
        let capped = ScrollbackStore.cap(big, limit: 200)
        checker.check(capped.count <= 200, "capping bounds the snapshot size (\(capped.count) bytes)")
        let cappedText = String(decoding: capped, as: UTF8.self)
        checker.check(cappedText.hasPrefix("line"), "capping starts at a line boundary")
        checker.check(cappedText.hasSuffix("line5000\n"), "capping keeps the most recent output")

        // The screen buffer is mostly blank rows, which must not be restored.
        let padded = Data("alpha\nbeta\n\n\n   \n\t\n\n".utf8)
        checker.equal(
            String(decoding: ScrollbackStore.trimmingTrailingBlankLines(padded), as: UTF8.self),
            "alpha\nbeta\n",
            "trailing blank rows are dropped"
        )
        checker.check(
            ScrollbackStore.trimmingTrailingBlankLines(Data("\n\n\n".utf8)).isEmpty,
            "an empty terminal snapshots as nothing"
        )

        let frame = CGRect(x: 0, y: 0, width: 820, height: 520)
        func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            return window
        }

        // 1. Produce real output.
        let firstWindow = makeWindow()
        let first = makeContent()
        first.view.frame = frame
        firstWindow.contentView = first.view
        let spec = ProcessResolver.makeSpec(kind: .shell, workingDirectory: NSTemporaryDirectory(), worldFrame: frame)
        first.start(ProcessResolver.request(for: spec))
        _ = waitUntil(timeout: 10) { first.readText()?.isEmpty == false }
        first.send(text: "echo SCROLLBACK_$((6*7))\n")
        checker.check(
            waitUntil(timeout: 10) { first.readText()?.contains("SCROLLBACK_42") == true },
            "the shell produced output to snapshot"
        )

        guard let snapshot = first.snapshotScrollback() else {
            checker.check(false, "a snapshot was captured")
            first.terminate()
            firstWindow.close()
            return
        }
        checker.check(true, "a snapshot was captured (\(snapshot.count) bytes)")
        checker.check(
            String(decoding: snapshot, as: UTF8.self).contains("SCROLLBACK_42"),
            "the snapshot holds the session output"
        )
        first.terminate()
        _ = waitUntil(timeout: 3) { false }
        firstWindow.close()

        // 2. Paint it into a fresh terminal before starting anything.
        let secondWindow = makeWindow()
        let second = makeContent()
        second.view.frame = frame
        secondWindow.contentView = second.view
        second.restoreScrollback(snapshot)
        let restoredText = second.readText() ?? ""
        checker.check(restoredText.contains("SCROLLBACK_42"), "a restored terminal shows the old output")

        // 3. Lines must not staircase: bare newlines in the snapshot become CRLF.
        let thirdWindow = makeWindow()
        let third = makeContent()
        third.view.frame = frame
        thirdWindow.contentView = third.view
        third.restoreScrollback(Data("ALPHA_LINE\nBRAVO_LINE\n".utf8))
        let lines = (third.readText() ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        checker.check(lines.contains { $0.hasPrefix("ALPHA_LINE") }, "restored lines start at column 0 (first line)")
        checker.check(lines.contains { $0.hasPrefix("BRAVO_LINE") }, "restored lines start at column 0 (no staircase)")
        thirdWindow.close()

        // 4. A restored terminal must still run a live shell.
        second.start(ProcessResolver.request(for: spec))
        _ = waitUntil(timeout: 10) { second.reportedGrid.cols > 0 }
        second.send(text: "echo AFTER_$((6*7))\n")
        checker.check(
            waitUntil(timeout: 10) { second.readText()?.contains("AFTER_42") == true },
            "a restored terminal still runs a shell"
        )
        checker.check(
            second.readText()?.contains("SCROLLBACK_42") == true,
            "the restored output is still there afterwards"
        )
        second.terminate()
        _ = waitUntil(timeout: 3) { false }
        secondWindow.close()
    }

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

        let content = makeContent()
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
            (content.readText()?.isEmpty == false)
        }
        checker.check(producedOutput, "a login shell starts and writes a prompt")

        checker.check(content.reportedGrid.cols > 40, "PTY received a sane column count (\(content.reportedGrid.cols))")
        checker.check(content.reportedGrid.rows > 10, "PTY received a sane row count (\(content.reportedGrid.rows))")

        // The echoed command contains the literal `$((6*7))`, so finding
        // PICANVAS_42 in the buffer proves the shell *executed* it.
        content.send(text: "echo PICANVAS_$((6*7))\n")
        let ranCommand = waitUntil(timeout: 10) {
            content.readText()?.contains("PICANVAS_42") == true
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

        let content = makeContent()
        window.contentView = content.view
        window.makeKeyAndOrderFront(nil)

        let spec = ProcessResolver.makeSpec(
            kind: .shell,
            workingDirectory: NSTemporaryDirectory(),
            worldFrame: window.frame
        )
        content.start(ProcessResolver.request(for: spec))
        _ = waitUntil(timeout: 10) { content.reportedGrid.cols > 0 }

        let narrowCols = content.reportedGrid.cols
        let narrowRows = content.reportedGrid.rows
        checker.check(narrowCols > 0 && narrowRows > 0, "PTY starts with a grid (\(narrowCols)x\(narrowRows))")

        window.setContentSize(NSSize(width: 1040, height: 640))
        let widened = waitUntil(timeout: 8) {
            content.reportedGrid.cols > narrowCols && content.reportedGrid.rows > narrowRows
        }
        checker.check(
            widened,
            "growing the node gives the PTY a bigger grid (\(narrowCols)x\(narrowRows) → \(content.reportedGrid.cols)x\(content.reportedGrid.rows))"
        )

        let wideCols = content.reportedGrid.cols
        window.setContentSize(NSSize(width: 420, height: 260))
        let narrowed = waitUntil(timeout: 8) { content.reportedGrid.cols < wideCols }
        checker.check(
            narrowed,
            "shrinking the node reduces the grid (\(wideCols) → \(content.reportedGrid.cols))"
        )

        // Zoom, by contrast, scales the glyphs and leaves the grid alone: the
        // font and the pixel size shrink together, which is what makes zooming
        // out feel like zooming out instead of cropping.
        window.setContentSize(NSSize(width: 1040, height: 640))
        _ = waitUntil(timeout: 8) { content.reportedGrid.cols > 100 }
        let colsAtFullSize = content.reportedGrid.cols
        let widthAtFullSize = Double(content.view.frame.width)
        content.setContentScale(0.5)
        window.setContentSize(NSSize(width: 520, height: 320))
        let scaled = waitUntil(timeout: 8) { abs(content.contentScale - 0.5) < 0.02 }
        checker.check(scaled, "the content scale was applied (\(content.contentScale))")
        // Cell metrics round to whole pixels, so the grid drifts a few percent;
        // what matters is that it does not halve (which is what happens when the
        // font stays fixed while the view shrinks).
        checker.check(
            abs(content.reportedGrid.cols - colsAtFullSize) <= max(6, colsAtFullSize / 10),
            "zooming out keeps roughly the same content (cols \(colsAtFullSize) → \(content.reportedGrid.cols))"
        )
        // And the space each column occupies must have shrunk with the view: that
        // is the implementation-agnostic way to assert the glyphs got smaller.
        let cellBefore = widthAtFullSize / Double(colsAtFullSize)
        let cellAfter = Double(content.view.frame.width) / Double(max(content.reportedGrid.cols, 1))
        let ratio = cellAfter / cellBefore
        checker.check(
            ratio > 0.4 && ratio < 0.65,
            "zooming out halves the space per column (\(String(format: "%.2f", cellBefore))px → \(String(format: "%.2f", cellAfter))px)"
        )

        content.setContentScale(1)
        content.terminate()
        _ = waitUntil(timeout: 6) { false }
        window.close()
    }

    /// The terminal implementation under test: whatever the app itself would
    /// build. Keeps this suite honest when the terminal backend changes.
    private static func makeContent() -> AgentContent {
        let spec = ProcessResolver.makeSpec(
            kind: .shell,
            workingDirectory: NSTemporaryDirectory(),
            worldFrame: CGRect(x: 0, y: 0, width: 800, height: 500)
        )
        return TerminalContentFactory.make(spec: spec)
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
