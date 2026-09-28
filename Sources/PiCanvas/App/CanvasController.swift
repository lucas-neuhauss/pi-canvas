import AppKit

/// Owns the node lifecycle: creating, restoring, closing and persisting nodes,
/// and keeping the canvas view in sync with the persisted model.
@MainActor
final class CanvasController: NSObject {

    static let defaultNodeSize = CGSize(width: 720, height: 440)

    let canvas: CanvasView
    private let workspaceStore: WorkspaceStore
    private let scrollbackStore: ScrollbackStore
    private let assetStore: AssetStore

    /// One canvas's worth of metadata. The nodes themselves live in `specs`,
    /// tagged with the workspace they belong to.
    private struct WorkspaceRecord {
        var id: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date
        /// Remembered while the workspace is not on screen.
        var viewport: CanvasViewport
        var workingDirectory: String
        var useOrder: Int
    }

    private var workspaceRecords: [WorkspaceRecord] = []
    private(set) var activeWorkspaceID: UUID = UUID()
    /// Nodes whose process has been started, so switching to a workspace starts
    /// its nodes once and only once.
    private var startedNodes: Set<UUID> = []
    /// Incremented every time a workspace is opened; see `WorkspaceFile.useOrder`.
    private var workspaceUseCounter = 0

    private(set) var specs: [UUID: NodeSpec] = [:]
    private var contents: [UUID: NodeContent] = [:]
    private var watchers: [UUID: PiSessionWatcher] = [:]
    private var cascadeIndex = 0

    /// Creates the content for a node. Injected so the canvas does not depend on
    /// the terminal implementation. Given the asset store so image content can
    /// resolve its file.
    var contentFactory: ((NodeSpec, AssetStore) -> NodeContent)?

    /// Where pi keeps its session transcripts. Overridable so tests can drive the
    /// agent-status chain without touching the user's real sessions.
    var sessionsRoot: URL?

    /// Last zoom pushed into the terminals, so panning does not re-apply it.
    private var lastAppliedContentScale: CGFloat = 1

    /// Nodes whose agent has finished a run and is waiting for a human.
    private(set) var agentsNeedingAttention: [UUID] = []

    /// Token/cost totals per pi node, straight from the transcripts.
    private(set) var agentUsage: [UUID: PiUsage] = [:]

    /// When each node was last focused, so the switcher can put recent ones first.
    private var focusTimes: [UUID: Date] = [:]

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
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        scrollbackStore: ScrollbackStore = ScrollbackStore(),
        assetStore: AssetStore = AssetStore()
    ) {
        self.canvas = canvas
        self.workspaceStore = workspaceStore
        self.scrollbackStore = scrollbackStore
        self.assetStore = assetStore
        super.init()
        canvas.canvasDelegate = self
    }

    var nodeCount: Int {
        specs.values.filter { $0.workspaceID == activeWorkspaceID || $0.workspaceID == nil }.count
    }

    /// Name of the workspace on screen.
    var activeWorkspaceName: String {
        workspaceRecords.first { $0.id == activeWorkspaceID }?.name ?? "Workspace"
    }

    var workspaceCount: Int { workspaceRecords.count }
    var zoom: CGFloat { canvas.zoom }
    var focusedNodeID: UUID? { canvas.focusedNodeID }
    var currentWorkingDirectory: String { defaultWorkingDirectory }

    // MARK: - Restore / persist

    /// Restores every workspace, then puts the most recently used one on screen.
    ///
    /// Only the visible workspace's nodes are started: opening the app should not
    /// spawn the agents from workspaces you are not using.
    func restore() {
        let files = workspaceStore.loadAll()
        var adopted: WorkspaceFile?
        if let legacy = workspaceStore.adoptLegacyLayoutIfNeeded(existing: files) {
            adopted = legacy
        }

        var records: [WorkspaceRecord] = []
        var nodeSpecs: [(workspace: UUID, nodes: [NodeSpec])] = []

        for file in files + [adopted].compactMap({ $0 }) {
            records.append(WorkspaceRecord(
                id: file.id,
                name: file.name,
                createdAt: file.createdAt,
                updatedAt: file.updatedAt,
                viewport: CanvasViewport(
                    zoom: CGFloat(file.layout.zoom),
                    panX: CGFloat(file.layout.panX),
                    panY: CGFloat(file.layout.panY)
                ),
                workingDirectory: file.layout.lastWorkingDirectory,
                useOrder: file.useOrder
            ))
            // Tolerate nodes written before workspaces existed.
            nodeSpecs.append((file.id, file.layout.nodes.map { spec in
                var spec = spec
                if spec.workspaceID == nil { spec.workspaceID = file.id }
                return spec
            }))
        }

        if records.isEmpty {
            records.append(WorkspaceRecord(
                id: UUID(),
                name: "Default",
                createdAt: Date(),
                updatedAt: Date(),
                viewport: CanvasViewport(),
                workingDirectory: ProcessResolver.launchWorkingDirectory,
                useOrder: 0
            ))
        }

        workspaceUseCounter = records.map(\.useOrder).max() ?? 0
        workspaceRecords = records.sorted { ordering($0, $1) }

        // One snapshot covers every workspace, so switching cannot delete another
        // workspace's scrollback.
        let allNodeIDs = nodeSpecs.flatMap { $0.nodes.map(\.id) }
        scrollbackStore.prune(keeping: Set(allNodeIDs))
        // Same for image assets: bytes are only dropped once no workspace in any
        // of the files refers to them.
        let allAssets = nodeSpecs.flatMap { $0.nodes.compactMap(\.asset) }
        assetStore.prune(keeping: Set(allAssets))

        let active = workspaceRecords[0]
        activeWorkspaceID = active.id
        defaultWorkingDirectory = ProcessResolver.normalizedDirectory(active.workingDirectory)
        canvas.setViewport(
            zoom: active.viewport.zoom,
            pan: CGPoint(x: active.viewport.panX, y: active.viewport.panY),
            notify: false
        )

        for group in nodeSpecs {
            let isActive = group.workspace == activeWorkspaceID
            for spec in group.nodes {
                add(spec: spec, start: isActive, select: false)
            }
        }
        applyWorkspaceVisibility()

        if let first = canvas.nodeViews.first(where: { $0.workspaceID == activeWorkspaceID }) {
            canvas.select(first, focusContent: false)
        }
        onStateChange?()
    }

    // MARK: - Workspaces

    /// Shows one workspace and hides the rest. Nothing is stopped: the agents in
    /// other workspaces keep running while you are elsewhere.
    func activateWorkspace(id: UUID) {
        guard id != activeWorkspaceID,
              let record = workspaceRecords.first(where: { $0.id == id }) else { return }
        captureActiveWorkspaceViewport()
        installActiveWorkspace(record)
    }

    /// Newest use first, with the timestamp as a tiebreak for files written
    /// before the counter existed.
    private func ordering(_ lhs: WorkspaceRecord, _ rhs: WorkspaceRecord) -> Bool {
        if lhs.useOrder != rhs.useOrder { return lhs.useOrder > rhs.useOrder }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func installActiveWorkspace(_ record: WorkspaceRecord) {
        activeWorkspaceID = record.id
        // "Most recently used" has to mean the workspace you moved *to*, not the
        // one you moved away from, or the switcher's ordering inverts.
        if let index = workspaceRecords.firstIndex(where: { $0.id == record.id }) {
            workspaceUseCounter += 1
            workspaceRecords[index].useOrder = workspaceUseCounter
            workspaceRecords[index].updatedAt = Date()
        }
        defaultWorkingDirectory = ProcessResolver.normalizedDirectory(record.workingDirectory)
        canvas.setViewport(
            zoom: record.viewport.zoom,
            pan: CGPoint(x: record.viewport.panX, y: record.viewport.panY),
            notify: false
        )
        applyWorkspaceVisibility()
        startPendingNodes(in: record.id)
        persistAll()

        if let first = canvas.nodeViews.first(where: { $0.workspaceID == record.id && !$0.isHidden }) {
            canvas.select(first, focusContent: true)
        } else {
            canvas.select(nil, focusContent: false)
            canvas.window?.makeFirstResponder(canvas)
        }
        onStateChange?()
    }

    private func captureActiveWorkspaceViewport() {
        guard let index = workspaceRecords.firstIndex(where: { $0.id == activeWorkspaceID }) else { return }
        workspaceRecords[index].viewport = canvas.viewport
        workspaceRecords[index].workingDirectory = defaultWorkingDirectory
    }

    private func applyWorkspaceVisibility() {
        for node in canvas.nodeViews {
            node.isHidden = node.workspaceID != activeWorkspaceID
        }
        canvas.layoutNodes()
    }

    /// Nodes that were never started (because their workspace was not the one in
    /// use at launch) start the first time that workspace is opened.
    private func startPendingNodes(in workspaceID: UUID) {
        for (id, spec) in specs where (spec.workspaceID ?? workspaceID) == workspaceID && !startedNodes.contains(id) {
            guard let content = contents[id] as? ProcessContent else { continue }
            startedNodes.insert(id)
            let request = ProcessResolver.request(for: spec)
            NSLog(
                "[PiCanvas] node %@ start kind=%@ cwd=%@ argv=%@",
                id.uuidString, spec.kind.rawValue, request.workingDirectory,
                request.arguments.joined(separator: " ")
            )
            content.start(request)
        }
    }

    @discardableResult
    func createWorkspace(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = WorkspaceRecord(
            id: UUID(),
            name: trimmed.isEmpty ? "Workspace \(workspaceRecords.count + 1)" : trimmed,
            createdAt: Date(),
            updatedAt: Date(),
            viewport: CanvasViewport(),
            workingDirectory: defaultWorkingDirectory,
            useOrder: 0
        )
        captureActiveWorkspaceViewport()
        workspaceRecords.insert(record, at: 0)
        installActiveWorkspace(record)
        return record.id
    }

    func renameWorkspace(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = workspaceRecords.firstIndex(where: { $0.id == id }) else { return }
        workspaceRecords[index].name = trimmed
        workspaceRecords[index].updatedAt = Date()
        persistAll()
        onStateChange?()
    }

    /// Deleting a workspace closes its nodes, and therefore stops their agents.
    /// The last workspace cannot be deleted: there is always a canvas.
    func deleteWorkspace(id: UUID) {
        guard workspaceRecords.count > 1,
              workspaceRecords.contains(where: { $0.id == id }) else { return }

        let nodeIDs = canvas.nodeViews.filter { $0.workspaceID == id }.map(\.nodeID)
        for nodeID in nodeIDs {
            close(nodeID: nodeID, persisting: false)
        }

        workspaceRecords.removeAll { $0.id == id }
        workspaceStore.delete(id: id)

        if activeWorkspaceID == id {
            activeWorkspaceID = workspaceRecords[0].id
            installActiveWorkspace(workspaceRecords[0])
        } else {
            persistAll()
            onStateChange?()
        }
    }

    var workspaceEntries: [(id: UUID, name: String, nodeCount: Int, needingAttention: Int, isActive: Bool, updatedAt: Date)] {
        workspaceRecords.map { record in
            let nodes = specs.values.filter { $0.workspaceID == record.id }
            let attention = nodes.filter { agentsNeedingAttention.contains($0.id) }.count
            return (record.id, record.name, nodes.count, attention, record.id == activeWorkspaceID, record.updatedAt)
        }
    }

    /// Moves to the next waiting agent, switching workspace if that is where it is.
    func jumpToNextAgentNeedingAttention() -> UUID? {
        let candidates = agentsNeedingAttention
            .filter { canvas.nodeView(withID: $0) != nil }
            .sorted()
        guard !candidates.isEmpty else { return nil }

        for id in candidates.reversed() {
            guard let spec = specs[id], let workspace = spec.workspaceID,
                  workspace != activeWorkspaceID else { continue }
            // Prefer an agent that is already on screen; only switch if there is none.
            if candidates.contains(where: { specs[$0]?.workspaceID == activeWorkspaceID }) { break }
            if let record = workspaceRecords.first(where: { $0.id == workspace }) {
                captureActiveWorkspaceViewport()
                installActiveWorkspace(record)
            }
            break
        }

        guard let target = nextAttentionTarget(from: candidates),
              let node = canvas.nodeView(withID: target) else { return nil }
        reveal(node.worldFrame)
        canvas.select(node, focusContent: true)
        return target
    }

    private func nextAttentionTarget(from candidates: [UUID]) -> UUID? {
        let onScreen = candidates.filter { specs[$0]?.workspaceID == activeWorkspaceID }
        let ordered = (onScreen.isEmpty ? candidates : onScreen).sorted()
        guard !ordered.isEmpty else { return nil }
        if let current = canvas.focusedNodeID, let index = ordered.firstIndex(of: current) {
            return ordered[(index + 1) % ordered.count]
        }
        return ordered[0]
    }

    // MARK: - Persistence

    /// The active workspace record, creating one if `restore()` never ran. Without
    /// this a controller that was only constructed would silently persist nothing,
    /// which is a trap for tests and for any future caller.
    private func ensureActiveWorkspaceRecord() {
        guard workspaceRecords.isEmpty else { return }
        workspaceRecords = [
            WorkspaceRecord(
                id: activeWorkspaceID,
                name: "Default",
                createdAt: Date(),
                updatedAt: Date(),
                viewport: canvas.viewport,
                workingDirectory: defaultWorkingDirectory,
                useOrder: {
                    workspaceUseCounter += 1
                    return workspaceUseCounter
                }()
            )
        ]
    }

    /// Saves every workspace. Changes can happen to a workspace that is not on
    /// screen — an agent exiting closes its node — so this is not limited to the
    /// visible one.
    func persistAll() {
        ensureActiveWorkspaceRecord()
        syncSpecsFromNodes()
        for record in workspaceRecords {
            workspaceStore.scheduleSave(makeWorkspaceFile(record))
        }
    }

    private func makeWorkspaceFile(_ record: WorkspaceRecord) -> WorkspaceFile {
        let isActive = record.id == activeWorkspaceID
        let viewport = isActive ? canvas.viewport : record.viewport
        let directory = isActive ? defaultWorkingDirectory : record.workingDirectory
        let orderedIDs = canvas.orderedNodeIDs
        let nodes = orderedIDs.compactMap { id -> NodeSpec? in
            guard let spec = specs[id], (spec.workspaceID ?? record.id) == record.id else { return nil }
            return spec
        }
        return WorkspaceFile(
            id: record.id,
            name: record.name,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            useOrder: record.useOrder,
            layout: LayoutFile(
                zoom: Double(viewport.zoom),
                panX: Double(viewport.panX),
                panY: Double(viewport.panY),
                lastWorkingDirectory: directory,
                nodes: nodes
            )
        )
    }

    /// The active workspace as it would be written. Used by tests.
    func currentWorkspaceFile() -> WorkspaceFile? {
        guard let record = workspaceRecords.first(where: { $0.id == activeWorkspaceID }) else { return nil }
        syncSpecsFromNodes()
        return makeWorkspaceFile(record)
    }

    /// Debounced save of the current state.
    func persist() {
        persistAll()
    }

    /// Synchronous save. Used on quit and by the self-test.
    func saveNow() {
        ensureActiveWorkspaceRecord()
        syncSpecsFromNodes()
        for record in workspaceRecords {
            workspaceStore.saveNow(makeWorkspaceFile(record))
        }
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
            worldFrame: CGRect(origin: origin, size: size),
            workspaceID: activeWorkspaceID
        )
        add(spec: spec, start: true, select: true)
        reveal(spec.worldFrame)
    }

    // MARK: - Image nodes

    /// Copies a dropped image into the asset store and creates a node for it,
    /// centred on the drop point. Returns the new node's ID, or nil when the
    /// file could not be stored.
    @discardableResult
    func createImageNode(contentsOf url: URL, at worldPoint: CGPoint? = nil) -> UUID? {
        let assetName: String
        do {
            assetName = try assetStore.store(contentsOf: url)
        } catch {
            NSLog("[PiCanvas] could not add image %@: %@", url.path, error.localizedDescription)
            return nil
        }

        let pixelSize = AssetStore.pixelSize(ofImageAt: assetStore.url(for: assetName))
        let size = CanvasController.imageNodeSize(pixelSize: pixelSize)
        let centre = worldPoint ?? canvas.viewportCentreWorldPoint()
        let origin = CGPoint(
            x: (centre.x - size.width / 2).rounded(),
            y: (centre.y - size.height / 2).rounded()
        )
        let spec = NodeSpec(
            kind: .image,
            worldFrame: CGRect(origin: origin, size: size),
            workingDirectory: defaultWorkingDirectory,
            executable: "",
            arguments: [],
            title: url.lastPathComponent,
            asset: assetName,
            workspaceID: activeWorkspaceID
        )
        add(spec: spec, start: true, select: true)
        reveal(spec.worldFrame)
        return spec.id
    }

    /// The size a dropped image gets: its own aspect ratio, capped so a 6K
    /// screenshot arrives 640pt wide and grown so a favicon still leaves room
    /// for the node chrome.
    static func imageNodeSize(pixelSize: CGSize?) -> CGSize {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: 480, height: 320)
        }
        let maxSide: CGFloat = 640
        let longest = max(pixelSize.width, pixelSize.height)
        var scale = min(1, maxSide / longest)
        // Grow small images until both node minimums are met, but only while
        // the long side still fits the cap. An extreme panorama is left short
        // rather than made enormous; its ratio matters more than the minimum.
        let minimum = max(
            NodeMetrics.minWorldWidth / pixelSize.width,
            NodeMetrics.minWorldHeight / pixelSize.height,
            1
        )
        if longest * scale * minimum <= maxSide {
            scale *= minimum
        }
        return CGSize(
            width: max((pixelSize.width * scale).rounded(), 1),
            height: max((pixelSize.height * scale).rounded(), 1)
        )
    }

    /// The ratio a node resizes along, read back from the stored asset (with the
    /// node's own frame as the fallback when the file has gone missing).
    private func imageAspectRatio(for spec: NodeSpec) -> CGFloat? {
        if let asset = spec.asset,
           let pixelSize = AssetStore.pixelSize(ofImageAt: assetStore.url(for: asset)),
           pixelSize.width > 0, pixelSize.height > 0 {
            return pixelSize.width / pixelSize.height
        }
        let frame = spec.worldFrame
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame.width / frame.height
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
        var spec = spec
        if spec.workspaceID == nil { spec.workspaceID = activeWorkspaceID }
        let node = NodeFrameView(nodeID: spec.id, worldFrame: spec.worldFrame, kind: spec.kind)
        node.workspaceID = spec.workspaceID
        node.title = spec.displayTitle
        node.subtitle = Self.abbreviate(spec.workingDirectory)
        specs[spec.id] = spec

        let content = contentFactory?(spec, assetStore) ?? MissingNodeContent()
        contents[spec.id] = content
        wire(content: content, node: node)
        content.setContentScale(canvas.zoom)
        node.contentView = content.view
        // Images resize along their own ratio; terminals fill any box.
        if spec.kind == .image {
            node.contentAspectRatio = imageAspectRatio(for: spec)
        }
        canvas.addNodeView(node)
        // Only the workspace on screen is visible.
        node.isHidden = spec.workspaceID != activeWorkspaceID

        // Give the terminal its real pixel size before anything spawns, so the
        // PTY is created with the right grid instead of 0x0 and catching up.
        node.layoutSubtreeIfNeeded()

        // Paint last session's output before the new process prints its prompt,
        // so a restart does not erase what you were reading. pi nodes are skipped:
        // pi redraws its own transcript from the session file, and injecting an
        // old TUI frame would be noise.
        if spec.kind == .shell,
           let process = content as? ProcessContent,
           let snapshot = scrollbackStore.load(for: spec.id) {
            process.restoreScrollback(snapshot)
        }

        if start {
            startNode(id: spec.id)
        }
        startStatusWatcher(for: spec, node: node)
        if select {
            canvas.select(node, focusContent: true)
        }
        onStateChange?()
        persist()
    }

    /// Starts a node's process once, recording that it has been started so a later
    /// workspace switch does not start it a second time. Content that owns no
    /// process (an image) has nothing to start and is left alone.
    private func startNode(id: UUID) {
        guard !startedNodes.contains(id), let spec = specs[id] else { return }
        guard let content = contents[id] as? ProcessContent else { return }
        startedNodes.insert(id)
        let request = ProcessResolver.request(for: spec)
        NSLog(
            "[PiCanvas] node %@ start kind=%@ cwd=%@ argv=%@",
            id.uuidString, spec.kind.rawValue, request.workingDirectory,
            request.arguments.joined(separator: " ")
        )
        content.start(request)
    }

    private func wire(content: NodeContent, node: NodeFrameView) {
        let id = node.nodeID

        content.onTitleChange = { [weak self] title in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            // Remember what the terminal calls itself, but never let it overwrite a
            // name the user chose.
            self.specs[id]?.title = title
            if self.specs[id]?.customTitle == nil {
                node.title = title
            }
            self.persist()
        }

        content.onFocus = { [weak self] in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            self.canvas.select(node, focusContent: false)
        }

        // Process lifecycle only exists for terminals.
        guard let process = content as? ProcessContent else { return }

        process.onExit = { [weak self] code in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            // The process is gone; the transcript is no longer a live status.
            self.watchers[id]?.stop()
            self.watchers[id] = nil
            let describing = code.map { "exit \($0)" } ?? "killed by signal"
            let grid = process.reportedGrid
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

        process.onDirectoryChange = { [weak self] directory in
            guard let self, let node = self.canvas.nodeView(withID: id) else { return }
            node.subtitle = Self.abbreviate(directory)
        }
    }

    func close(nodeID: UUID, persisting: Bool = true) {
        guard let node = canvas.nodeView(withID: nodeID) else { return }
        let asset = specs[nodeID]?.asset
        watchers[nodeID]?.stop()
        watchers[nodeID] = nil
        agentsNeedingAttention.removeAll { $0 == nodeID }
        agentUsage[nodeID] = nil
        focusTimes[nodeID] = nil
        startedNodes.remove(nodeID)
        scrollbackStore.remove(for: nodeID)
        (contents[nodeID] as? ProcessContent)?.terminate()
        contents[nodeID] = nil
        canvas.removeNodeView(node)
        specs[nodeID] = nil
        // Assets are deduplicated by hash, so one only goes away when the last
        // node referring to it does.
        if let asset, !specs.values.contains(where: { $0.asset == asset }) {
            assetStore.remove(asset)
        }
        onStateChange?()
        if persisting { persist() }
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
            guard let process = content as? ProcessContent,
                  let snapshot = process.snapshotScrollback() else { continue }
            scrollbackStore.save(snapshot, for: id)
        }

        for content in contents.values {
            (content as? ProcessContent)?.terminate()
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

    /// Brings a node into view and gives its terminal focus.
    func focusNode(id: UUID) {
        guard let node = canvas.nodeView(withID: id) else { return }
        reveal(node.worldFrame)
        canvas.select(node, focusContent: true)
    }

    /// The node switcher's rows: this workspace's nodes only.
    func paletteEntries() -> [PaletteRow] {
        canvas.orderedNodeIDs.compactMap { id -> PaletteRow? in
            guard let node = canvas.nodeView(withID: id), let spec = specs[id],
                  (spec.workspaceID ?? activeWorkspaceID) == activeWorkspaceID else { return nil }
            let accent = spec.kind.accent
            return PaletteRow(
                id: id,
                title: node.title,
                subtitle: Self.abbreviate(spec.workingDirectory),
                status: node.statusText,
                statusKind: node.statusKind,
                isAttention: agentsNeedingAttention.contains(id),
                dotColor: NSColor(
                    srgbRed: CGFloat(accent.0),
                    green: CGFloat(accent.1),
                    blue: CGFloat(accent.2),
                    alpha: 1
                ),
                haystackExtra: spec.kind.displayName,
                lastFocused: focusTimes[id]
            )
        }
    }

    /// The workspace switcher's rows: every workspace, plus an offer to make one.
    func workspacePaletteRows() -> [PaletteRow] {
        var rows = workspaceRecords.sorted { ordering($0, $1) }.map { record -> PaletteRow in
            let nodes = specs.values.filter { $0.workspaceID == record.id }
            let attention = nodes.filter { agentsNeedingAttention.contains($0.id) }.count
            var subtitle = "\(nodes.count) node\(nodes.count == 1 ? "" : "s")"
            if let first = nodes.first {
                subtitle += " · " + Self.abbreviate(first.workingDirectory)
            }
            return PaletteRow(
                id: record.id,
                title: record.name,
                subtitle: subtitle,
                status: attention > 0
                    ? (attention == 1 ? "needs you" : "\(attention) need you")
                    : (record.id == activeWorkspaceID ? "current" : nil),
                statusKind: attention > 0 ? .needsAttention : .idle,
                isAttention: attention > 0,
                dotColor: nil,
                haystackExtra: "workspace",
                lastFocused: record.updatedAt
            )
        }
        rows.append(PaletteRow(
            id: UUID(),
            title: "New workspace…",
            subtitle: "Start an empty canvas",
            status: nil,
            statusKind: .idle,
            isAttention: false,
            dotColor: nil,
            haystackExtra: "workspace new create",
            lastFocused: nil,
            createName: ""
        ))
        return rows
    }

    /// Workspaces by most recently used, for the switcher.
    func orderedWorkspaceRows() -> [PaletteRow] {
        workspacePaletteRows().filter { !$0.isCreate }
    }

    /// Names a node. An empty name clears it, so the terminal's own title shows
    /// again.
    func renameNode(id: UUID, to name: String) {
        guard var spec = specs[id], let node = canvas.nodeView(withID: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        spec.customTitle = trimmed.isEmpty ? nil : trimmed
        specs[id] = spec
        node.title = spec.displayTitle
        persist()
        onStateChange?()
    }

    /// Starts an inline rename on the focused node.
    @discardableResult
    func renameFocusedNode() -> Bool {
        guard let id = canvas.focusedNodeID ?? canvas.selectedNodeID,
              let node = canvas.nodeView(withID: id) else { return false }
        node.beginRenaming()
        return true
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

    func canvasView(_ canvas: CanvasView, didRename nodeID: UUID, to title: String) {
        renameNode(id: nodeID, to: title)
    }

    func canvasView(_ canvas: CanvasView, didReceiveImageDropOf url: URL, atWorldPoint point: CGPoint) -> Bool {
        createImageNode(contentsOf: url, at: point) != nil
    }

    func canvasView(_ canvas: CanvasView, nodeID: UUID, didReceiveDropFrom sourceNodeID: UUID) -> Bool {
        // Only a pi node has an agent to hand the path to, and only an image
        // node produces one.
        guard let target = specs[nodeID], target.kind == .pi,
              let source = specs[sourceNodeID], source.kind == .image,
              let asset = source.asset,
              let content = contents[nodeID] else { return false }
        content.send(text: assetStore.url(for: asset).path + "\n")
        focusNode(id: nodeID)
        return true
    }

    func canvasView(_ canvas: CanvasView, didFocus nodeID: UUID?) {
        for (id, content) in contents {
            content.setFocused(id == nodeID)
        }
        if let nodeID {
            focusTimes[nodeID] = Date()
            contents[nodeID]?.focus()
        }
        onStateChange?()
    }
}
