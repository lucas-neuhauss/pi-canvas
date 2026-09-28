import AppKit

/// Owns the node lifecycle: creating, restoring, closing and persisting nodes,
/// and keeping the canvas view in sync with the persisted model.
@MainActor
final class CanvasController: NSObject {

    static let defaultNodeSize = CGSize(width: 720, height: 440)

    let canvas: CanvasView
    private let store: LayoutStore
    private let scrollbackStore: ScrollbackStore

    private(set) var specs: [UUID: NodeSpec] = [:]
    private var contents: [UUID: AgentContent] = [:]
    private var watchers: [UUID: PiSessionWatcher] = [:]
    private var cascadeIndex = 0

    /// Creates the terminal for a node. Injected so the canvas does not depend on
    /// the terminal implementation.
    var contentFactory: ((NodeSpec) -> AgentContent)?

    /// Where pi keeps its session transcripts. Overridable so tests can drive the
    /// agent-status chain without touching the user's real sessions.
    var sessionsRoot: URL?

    /// Last zoom pushed into the terminals, so panning does not re-apply it.
    private var lastAppliedContentScale: CGFloat = 1

    /// Nodes whose agent has finished a run and is waiting for a human.
    private(set) var agentsNeedingAttention: [UUID] = []

    /// Token/cost totals per pi node, straight from the transcripts.
    private(set) var agentUsage: [UUID: PiUsage] = [:]

    /// Combined spend across every node, for the window title.
    var totalAgentCost: Double {
        agentUsage.values.reduce(0) { $0 + $1.costUSD }
    }

    /// Directory new nodes are created in.
    private(set) var defaultWorkingDirectory: String = ProcessResolver.launchWorkingDirectory

    /// Fired whenever something the status bar displays changes.
    var onStateChange: (() -> Void)?

    init(
        canvas: CanvasView,
        store: LayoutStore = LayoutStore(),
        scrollbackStore: ScrollbackStore = ScrollbackStore()
    ) {
        self.canvas = canvas
        self.store = store
        self.scrollbackStore = scrollbackStore
        super.init()
        canvas.canvasDelegate = self
    }

    var nodeCount: Int { specs.count }
    var zoom: CGFloat { canvas.zoom }
    var focusedNodeID: UUID? { canvas.focusedNodeID }
    var currentWorkingDirectory: String { defaultWorkingDirectory }

    // MARK: - Restore / persist

    /// Restores the previous canvas, spawning a fresh process per node.
    func restore() {
        guard let layout = store.load() else { return }
        defaultWorkingDirectory = ProcessResolver.normalizedDirectory(layout.lastWorkingDirectory)
        canvas.setViewport(
            zoom: CGFloat(layout.zoom),
            pan: CGPoint(x: layout.panX, y: layout.panY),
            notify: false
        )
        scrollbackStore.prune(keeping: Set(layout.nodes.map(\.id)))
        for spec in layout.nodes {
            add(spec: spec, start: true, select: false)
        }
        if let first = layout.nodes.first, let node = canvas.nodeView(withID: first.id) {
            canvas.select(node, focusContent: false)
        }
        onStateChange?()
    }

    private func makeLayout() -> LayoutFile {
        syncSpecsFromNodes()
        let nodes = canvas.orderedNodeIDs.compactMap { specs[$0] }
        return LayoutFile(
            zoom: Double(canvas.zoom),
            panX: Double(canvas.pan.x),
            panY: Double(canvas.pan.y),
            lastWorkingDirectory: defaultWorkingDirectory,
            nodes: nodes
        )
    }

    /// Debounced save of the current state.
    func persist() {
        store.scheduleSave(makeLayout())
    }

    /// Synchronous save. Used on quit and by the self-test.
    func saveNow() {
        store.saveNow(makeLayout())
    }

    private func syncSpecsFromNodes() {
        for node in canvas.nodeViews {
            specs[node.nodeID]?.worldFrame = node.worldFrame
        }
    }

    // MARK: - Nodes

    func newNode(kind: NodeKind, workingDirectory: String? = nil) {
        let directory = workingDirectory ?? defaultWorkingDirectory
        let centre = canvas.viewportCentreWorldPoint()
        let size = CanvasController.defaultNodeSize
        cascadeIndex += 1
        let desired = CGPoint(
            x: (centre.x - size.width / 2).rounded(),
            y: (centre.y - size.height / 2).rounded()
        )
        let origin = freeOrigin(near: desired, size: size)
        let spec = ProcessResolver.makeSpec(
            kind: kind,
            workingDirectory: directory,
            worldFrame: CGRect(origin: origin, size: size)
        )
        add(spec: spec, start: true, select: true)
        reveal(spec.worldFrame)
    }

    /// Finds a spot for a new node that does not sit on top of an existing one.
    ///
    /// Nodes are tiled horizontally: anything whose vertical band overlaps the
    /// new node pushes it to the right. Once the row would get unreasonably
    /// wide, the node drops below the band instead.
    private func freeOrigin(near origin: CGPoint, size: CGSize) -> CGPoint {
        let frames = canvas.nodeViews.map(\.worldFrame)
        guard !frames.isEmpty else { return origin }

        let gap: CGFloat = 40
        let newRect = CGRect(origin: origin, size: size)
        let sameBand = frames.filter { $0.maxY > newRect.minY && $0.minY < newRect.maxY }
        guard !sameBand.isEmpty else { return origin }

        let rightmost = sameBand.map(\.maxX).max() ?? origin.x
        let toTheRight = CGPoint(x: (rightmost + gap).rounded(), y: origin.y)
        if toTheRight.x - origin.x <= size.width * 3 {
            return toTheRight
        }

        // The row is full: start a new one under everything in the way.
        let columnEnd = rightmost
        let lowest = frames
            .filter { $0.maxX > origin.x && $0.minX < columnEnd }
            .map(\.maxY)
            .max() ?? origin.y
        return CGPoint(x: origin.x, y: (lowest + gap).rounded())
    }

    /// Pans the viewport just enough to bring a newly created node into view.
    private func reveal(_ worldFrame: CGRect) {
        let screen = canvas.screenRect(fromWorld: worldFrame)
        let visible = canvas.bounds.insetBy(dx: 24, dy: 24)
        guard !visible.isEmpty else { return }

        var delta = CGPoint.zero
        if screen.maxX > visible.maxX {
            delta.x = visible.maxX - screen.maxX
        } else if screen.minX < visible.minX {
            delta.x = visible.minX - screen.minX
        }
        if screen.maxY > visible.maxY {
            delta.y = visible.maxY - screen.maxY
        } else if screen.minY < visible.minY {
            delta.y = visible.minY - screen.minY
        }
        if delta != .zero {
            canvas.panBy(delta)
        }
    }

    private func add(spec: NodeSpec, start: Bool, select: Bool) {
        let node = NodeFrameView(nodeID: spec.id, worldFrame: spec.worldFrame, kind: spec.kind)
        node.title = spec.title ?? spec.kind.displayName
        node.subtitle = Self.abbreviate(spec.workingDirectory)
        specs[spec.id] = spec

        let content = contentFactory?(spec) ?? MissingContent()
        contents[spec.id] = content
        wire(content: content, node: node)
        content.setContentScale(canvas.zoom)
        node.contentView = content.view
        canvas.addNodeView(node)

        // Give the terminal its real pixel size before anything spawns, so the
        // PTY is created with the right grid instead of 0x0 and catching up.
        node.layoutSubtreeIfNeeded()

        // Paint last session's output before the new process prints its prompt,
        // so a restart does not erase what you were reading. pi nodes are skipped:
        // pi redraws its own transcript from the session file, and injecting an
        // old TUI frame would be noise.
        if spec.kind == .shell, let snapshot = scrollbackStore.load(for: spec.id) {
            content.restoreScrollback(snapshot)
        }

        if start {
            let request = ProcessResolver.request(for: spec)
            NSLog("[PiCanvas] node %@ start kind=%@ cwd=%@ argv=%@", spec.id.uuidString, spec.kind.rawValue, request.workingDirectory, request.arguments.joined(separator: " "))
            content.start(request)
        }
        startStatusWatcher(for: spec, node: node)
        if select {
            canvas.select(node, focusContent: true)
        }
        onStateChange?()
        persist()
    }

    private func wire(content: AgentContent, node: NodeFrameView) {
        let id = node.nodeID

        content.onTitleChange = { [weak self] title in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            node.title = title
            self.specs[id]?.title = title
            self.persist()
        }

        content.onExit = { [weak self] code in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            // The process is gone; the transcript is no longer a live status.
            self.watchers[id]?.stop()
            self.watchers[id] = nil
            let describing = code.map { "exit \($0)" } ?? "killed by signal"
            let grid = content.reportedGrid
            NSLog("[PiCanvas] node %@ terminated: %@ (grid %dx%d)", id.uuidString, describing, grid.cols, grid.rows)

            // Leaving a shell should leave nothing behind, so a clean exit closes
            // the node. A failure keeps it so the error stays readable, which is
            // the whole reason the status pill exists.
            let exitedCleanly = (code == 0)
            if !exitedCleanly {
                node.statusKind = .failure
                node.statusText = code.map { "exited \($0)" } ?? "stopped"
            }
            self.onStateChange?()

            if exitedCleanly {
                // Deferred by a turn: this runs inside the terminal's own exit
                // callback, and tearing the surface down from there is not safe.
                DispatchQueue.main.async { [weak self] in
                    self?.close(nodeID: id)
                }
            }
        }

        content.onDirectoryChange = { [weak self] directory in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            node.subtitle = Self.abbreviate(directory)
        }

        content.onFocus = { [weak self] in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            self.canvas.select(node, focusContent: false)
        }
    }

    func close(nodeID: UUID) {
        guard let node = canvas.nodeView(withID: nodeID) else { return }
        watchers[nodeID]?.stop()
        watchers[nodeID] = nil
        agentsNeedingAttention.removeAll { $0 == nodeID }
        agentUsage[nodeID] = nil
        scrollbackStore.remove(for: nodeID)
        contents[nodeID]?.terminate()
        contents[nodeID] = nil
        canvas.removeNodeView(node)
        specs[nodeID] = nil
        onStateChange?()
        persist()
    }

    /// Closes the focused node. Returns false when nothing was closeable.
    @discardableResult
    func closeFocusedNode() -> Bool {
        guard let id = canvas.focusedNodeID ?? canvas.selectedNodeID else { return false }
        close(nodeID: id)
        return true
    }

    func terminateAll() {
        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()

        // Capture what is on screen before the processes go away, so reopening
        // the app shows the output you left behind.
        for (id, content) in contents where specs[id]?.kind == .shell {
            if let snapshot = content.snapshotScrollback() {
                scrollbackStore.save(snapshot, for: id)
            }
        }

        for content in contents.values {
            content.terminate()
        }
        contents.removeAll()
        saveNow()
    }

    // MARK: - Agent status

    /// pi nodes get a watcher on their session file, which is how a node can say
    /// "bash" or "needs you" without the canvas talking to the agent at all.
    private func startStatusWatcher(for spec: NodeSpec, node: NodeFrameView) {
        guard spec.kind == .pi, let sessionID = spec.sessionID else { return }
        let id = spec.id
        let watcher = PiSessionWatcher(
            workingDirectory: spec.workingDirectory,
            sessionID: sessionID,
            sessionsRoot: sessionsRoot,
            onStateChange: { [weak self] state in
                self?.apply(agentState: state, to: id)
            },
            onUsageChange: { [weak self] usage in
                self?.apply(usage: usage, to: id)
            }
        )
        watchers[id] = watcher
        node.statusText = watcher.state.displayText
        node.statusKind = watcher.state.statusKind
        watcher.start()
    }

    private func apply(agentState state: PiAgentState, to nodeID: UUID) {
        guard let node = canvas.nodeView(withID: nodeID) else { return }
        node.statusText = state.displayText
        node.statusKind = state.statusKind

        updateAttentionList(nodeID: nodeID, state: state)

        // An agent that has finished and wants a human should get attention even
        // if the user is looking at something else. A single Dock bounce is a
        // signal, not a nuisance.
        if state == .waitingForYou, !NSApp.isActive, canvas.focusedNodeID != nodeID {
            NSApp.requestUserAttention(.informationalRequest)
        }
        onStateChange?()
    }

    private func apply(usage: PiUsage, to nodeID: UUID) {
        agentUsage[nodeID] = usage
        guard let node = canvas.nodeView(withID: nodeID) else { return }
        node.costText = usage.costText
        let detail = usage.detailText
        node.toolTip = detail.isEmpty ? nil : detail
        onStateChange?()
    }

    private func updateAttentionList(nodeID: UUID, state: PiAgentState) {
        let needsAttention = (state == .waitingForYou)
        let alreadyListed = agentsNeedingAttention.contains(nodeID)
        if needsAttention && !alreadyListed {
            agentsNeedingAttention.append(nodeID)
        } else if !needsAttention && alreadyListed {
            agentsNeedingAttention.removeAll { $0 == nodeID }
        }
    }

    // MARK: - Navigation

    /// Cycles to the next agent that wants a human, revealing it if it is
    /// off-screen. This is the counterpart to the status pill: the canvas tells
    /// you who needs you, this takes you there.
    @discardableResult
    func jumpToNextAgentNeedingAttention() -> UUID? {
        let candidates = agentsNeedingAttention.filter { canvas.nodeView(withID: $0) != nil }
        guard !candidates.isEmpty else { return nil }

        let ordered = candidates.sorted()
        var target = ordered[0]
        if let current = canvas.focusedNodeID, let index = ordered.firstIndex(of: current) {
            target = ordered[(index + 1) % ordered.count]
        }
        if let node = canvas.nodeView(withID: target) {
            reveal(node.worldFrame)
            canvas.select(node, focusContent: true)
        }
        return target
    }

    // MARK: - Viewport

    func zoomIn() { canvas.zoomIn() }
    func zoomOut() { canvas.zoomOut() }
    func resetZoom() { canvas.resetZoom() }
    func zoomToFit() { canvas.zoomToFit() }

    // MARK: - Working directory

    func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "New nodes will start in this folder."
        panel.directoryURL = URL(fileURLWithPath: defaultWorkingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            defaultWorkingDirectory = url.path
            persist()
            onStateChange?()
        }
    }

    // MARK: - Helpers

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

extension CanvasController: CanvasViewDelegate {

    func canvasView(_ canvas: CanvasView, didChangeViewport viewport: CanvasViewport) {
        // Zoom scales what is inside the nodes, not just their frames.
        if abs(viewport.zoom - lastAppliedContentScale) > 0.005 {
            lastAppliedContentScale = viewport.zoom
            for content in contents.values {
                content.setContentScale(viewport.zoom)
            }
        }
        persist()
        onStateChange?()
    }

    func canvasViewDidChangeLayout(_ canvas: CanvasView) {
        persist()
    }

    func canvasView(_ canvas: CanvasView, didRequestClose nodeID: UUID) {
        close(nodeID: nodeID)
    }

    func canvasView(_ canvas: CanvasView, didChangeSelection selection: UUID?) {
        onStateChange?()
    }

    func canvasView(_ canvas: CanvasView, didFocus nodeID: UUID?) {
        for (id, content) in contents {
            content.setFocused(id == nodeID)
        }
        if let nodeID, let content = contents[nodeID] {
            content.focus()
        }
        onStateChange?()
    }
}
