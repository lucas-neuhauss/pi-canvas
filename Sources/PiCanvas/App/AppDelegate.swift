import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var window: NSWindow!
    private var mainView: MainView!
    private var controller: CanvasController!
    private var signalSources: [DispatchSourceSignal] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = AppIcon.make()

        buildMainMenu()

        let canvas = CanvasView(frame: .zero)
        mainView = MainView(canvas: canvas)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PiCanvas"
        window.minSize = NSSize(width: 760, height: 500)
        window.appearance = NSAppearance(named: .darkAqua)
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.contentView = mainView
        window.setFrameAutosaveName("PiCanvasMainWindow")
        window.center()
        self.window = window

        controller = CanvasController(canvas: canvas)
        controller.contentFactory = { spec, stores in
            NodeContentFactory.make(spec: spec, stores: stores)
        }

        mainView.statusBar.onNewTerminal = { [weak self] in self?.controller.newNode(kind: .shell) }
        mainView.statusBar.onNewPi = { [weak self] in self?.controller.newNode(kind: .pi) }
        mainView.statusBar.onZoomIn = { [weak self] in self?.controller.zoomIn() }
        mainView.statusBar.onZoomOut = { [weak self] in self?.controller.zoomOut() }
        mainView.statusBar.onZoomReset = { [weak self] in self?.controller.resetZoom() }
        mainView.statusBar.onZoomFit = { [weak self] in self?.controller.zoomToFit() }
        mainView.statusBar.onChooseFolder = { [weak self] in self?.controller.chooseWorkingDirectory() }
        mainView.statusBar.onSwitchWorkspace = { [weak self] in self?.showWorkspacePalette(nil) }
        controller.onStateChange = { [weak self] in self?.refreshStatus() }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        installSignalHandlers()

        // Say so in the log when something outranks our keyboard default, so a
        // terminal that still shows accents is explainable.
        if let warning = KeyboardDefaults.overrideWarning() {
            NSLog("[PiCanvas] %@", warning)
        } else {
            NSLog("[PiCanvas] held keys repeat (press-and-hold disabled)")
        }

        #if GHOSTTY_TERMINAL
        // Start libghostty before any node exists: it owns the process-wide app
        // and the config that every surface inherits.
        if !GhosttyApp.shared.start() {
            NSLog("[PiCanvas] libghostty failed to start: %@", GhosttyApp.shared.startupError ?? "unknown")
        } else {
            NSLog(
                "[PiCanvas] libghostty ready — font %@ at %.1fpt, %d config diagnostics",
                GhosttyApp.shared.fontFamily ?? "(default)",
                Double(GhosttyApp.shared.baseFontSize),
                GhosttyApp.shared.diagnostics.count
            )
        }
        #endif

        // Restore only once the window is on screen: terminals need a window
        // before their process starts.
        controller.restore()
        refreshStatus()
        applyLaunchArguments()
    }

    /// Launch-time scripting, handy for testing and for wiring the app into
    /// other tools:
    ///
    ///     PiCanvas --new-terminal --new-pi
    private func applyLaunchArguments() {
        var showPalette = false
        var paletteQuery: String?

        for argument in CommandLine.arguments {
            switch argument {
            case "--new-terminal":
                controller.newNode(kind: .shell)
            case "--new-pi":
                controller.newNode(kind: .pi)
            case "--show-palette":
                showPalette = true
            case "--show-workspaces":
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.showWorkspacePalette(nil)
                }
            case "--rename":
                // Start an inline rename once the terminals have set their titles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.controller.renameFocusedNode()
                }
            default:
                if argument.hasPrefix("--palette-query=") {
                    paletteQuery = String(argument.dropFirst("--palette-query=".count))
                }
                continue
            }
        }

        guard showPalette else { return }
        // Let the window lay out (and the nodes start) before showing the switcher.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.showTerminalPalette(nil)
            if let paletteQuery {
                self.mainView.palette.setQuery(paletteQuery)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// A `kill` should behave like quitting: the canvas saves its layout and
    /// scrollback snapshots on the way out instead of losing them.
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signal(signalNumber, SIG_IGN)
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.terminateAll()
    }

    private func refreshStatus() {
        guard let controller, let mainView else { return }
        mainView.statusBar.update(
            nodeCount: controller.nodeCount,
            zoom: controller.zoom,
            workingDirectory: CanvasController.abbreviate(controller.currentWorkingDirectory),
            needingAttention: controller.agentsNeedingAttention.count,
            workspace: controller.activeWorkspaceName
        )
        let count = controller.nodeCount
        var title = count == 0 ? "PiCanvas" : "PiCanvas — \(count) node\(count == 1 ? "" : "s")"
        if let cost = PiUsage.formatCost(controller.totalAgentCost) {
            title += " · \(cost)"
        }
        window.title = title
    }

    // MARK: - Actions

    @objc private func newTerminal(_ sender: Any?) {
        controller.newNode(kind: .shell)
    }

    @objc private func newPiAgent(_ sender: Any?) {
        controller.newNode(kind: .pi)
    }

    @objc private func newNote(_ sender: Any?) {
        controller.createNoteNode()
    }

    @objc private func newBrowser(_ sender: Any?) {
        controller.createBrowserNode()
    }

    @objc private func newTextLabel(_ sender: Any?) {
        controller.createTextNode(at: controller.canvas.viewportCentreWorldPoint())
    }

    @objc private func addImage(_ sender: Any?) {
        controller.chooseImage()
    }

    @objc private func chooseFolder(_ sender: Any?) {
        controller.chooseWorkingDirectory()
    }

    @objc private func closeNode(_ sender: Any?) {
        if !controller.closeFocusedNode() {
            window.performClose(sender)
        }
    }

    @objc private func renameNode(_ sender: Any?) {
        controller.renameFocusedNode()
    }

    @objc private func zoomIn(_ sender: Any?) { controller.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { controller.zoomOut() }
    @objc private func zoomActual(_ sender: Any?) { controller.resetZoom() }
    @objc private func zoomFit(_ sender: Any?) { controller.zoomToFit() }

    @objc private func jumpToNextAgent(_ sender: Any?) {
        controller.jumpToNextAgentNeedingAttention()
    }

    /// ⌘K: the keyboard way to move between nodes. Pressing it again closes it.
    @objc private func showTerminalPalette(_ sender: Any?) {
        if mainView.palette.isPresenting {
            mainView.palette.dismiss()
            return
        }

        mainView.palette.onDismiss = { [weak self] in
            self?.restoreTerminalFocus()
        }
        mainView.palette.onSelectRow = { [weak self] row in
            guard !row.isCreate else { return }
            self?.controller.focusNode(id: row.id)
        }
        mainView.palette.onDeleteRow = nil
        mainView.palette.onRenameRow = nil
        mainView.palette.onSubmitText = nil
        mainView.palette.presentList(
            rows: controller.paletteEntries(),
            title: "↑↓ move · ⇥ next · ↵ go · esc close",
            placeholder: "Go to terminal…",
            allowsCreate: false,
            from: window
        )
    }

    /// ⌘⇧K: switch, create, rename and delete workspaces.
    @objc private func showWorkspacePalette(_ sender: Any?) {
        if mainView.palette.isPresenting {
            mainView.palette.dismiss()
            return
        }

        mainView.palette.onDismiss = { [weak self] in
            self?.restoreTerminalFocus()
        }
        mainView.palette.onSelectRow = { [weak self] row in
            guard let self else { return }
            if row.isCreate {
                // A row with no name asks for one; "Create “x”" already has it.
                if let name = row.createName, !name.isEmpty {
                    self.controller.createWorkspace(named: name)
                } else {
                    self.promptForWorkspaceName(
                        title: "Name the new workspace",
                        initial: ""
                    ) { name in
                        self.controller.createWorkspace(named: name)
                    }
                }
                return
            }
            self.controller.activateWorkspace(id: row.id)
        }
        mainView.palette.onRenameRow = { [weak self] row in
            guard let self else { return }
            self.promptForWorkspaceName(title: "Rename workspace", initial: row.title) { name in
                self.controller.renameWorkspace(id: row.id, to: name)
            }
        }
        mainView.palette.onDeleteRow = { [weak self] row in
            self?.confirmDeleteWorkspace(row)
        }
        mainView.palette.onSubmitText = nil
        mainView.palette.presentList(
            rows: controller.workspacePaletteRows(),
            title: "↑↓ move · ↵ switch · F2 rename · ⌫ delete · esc close",
            placeholder: "Switch workspace…",
            allowsCreate: true,
            from: window
        )
    }

    private func promptForWorkspaceName(title: String, initial: String, then commit: @escaping (String) -> Void) {
        mainView.palette.onDismiss = { [weak self] in
            self?.restoreTerminalFocus()
        }
        mainView.palette.onSubmitText = { name in commit(name) }
        mainView.palette.presentPrompt(
            title: "\(title) — return to confirm, esc to cancel",
            placeholder: "Workspace name",
            initialText: initial,
            from: window
        )
    }

    private func confirmDeleteWorkspace(_ row: PaletteRow) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(row.title)”?"
        alert.informativeText = "Its terminals and agents are closed. Other workspaces are unaffected."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            controller.deleteWorkspace(id: row.id)
        }
    }

    @objc private func nextWorkspace(_ sender: Any?) { cycleWorkspace(by: 1) }
    @objc private func previousWorkspace(_ sender: Any?) { cycleWorkspace(by: -1) }

    private func cycleWorkspace(by offset: Int) {
        let rows = controller.orderedWorkspaceRows()
        guard rows.count > 1 else { return }
        let current = rows.firstIndex { $0.id == controller.activeWorkspaceID } ?? 0
        let next = (current + offset + rows.count) % rows.count
        controller.activateWorkspace(id: rows[next].id)
        refreshStatus()
    }

    /// Handing focus back matters: opening the switcher took it from the terminal.
    private func restoreTerminalFocus() {
        if let id = controller.focusedNodeID {
            controller.focusNode(id: id)
        } else {
            window.makeFirstResponder(mainView.canvas)
        }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeNode(_:)), #selector(zoomFit(_:)):
            return (controller?.nodeCount ?? 0) > 0
        case #selector(jumpToNextAgent(_:)):
            return !(controller?.agentsNeedingAttention.isEmpty ?? true)
        case #selector(showTerminalPalette(_:)):
            return (controller?.nodeCount ?? 0) > 0
        case #selector(showWorkspacePalette(_:)), #selector(nextWorkspace(_:)), #selector(previousWorkspace(_:)):
            return (controller?.workspaceCount ?? 0) > 0
        case #selector(renameNode(_:)):
            return controller?.focusedNodeID != nil
        default:
            return true
        }
    }

    // MARK: - Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        appMenu.addItem(
            withTitle: "About PiCanvas",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide PiCanvas",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit PiCanvas",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // File
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let newTerminalItem = NSMenuItem(
            title: "New Terminal",
            action: #selector(newTerminal(_:)),
            keyEquivalent: "t"
        )
        newTerminalItem.target = self
        fileMenu.addItem(newTerminalItem)

        let newPiItem = NSMenuItem(
            title: "New pi Agent",
            action: #selector(newPiAgent(_:)),
            keyEquivalent: "p"
        )
        newPiItem.target = self
        fileMenu.addItem(newPiItem)

        fileMenu.addItem(.separator())

        let newNoteItem = NSMenuItem(
            title: "New Note",
            action: #selector(newNote(_:)),
            keyEquivalent: "n"
        )
        newNoteItem.target = self
        fileMenu.addItem(newNoteItem)

        let newLabelItem = NSMenuItem(
            title: "New Text Label",
            action: #selector(newTextLabel(_:)),
            keyEquivalent: "t"
        )
        newLabelItem.keyEquivalentModifierMask = [.command, .shift]
        newLabelItem.target = self
        fileMenu.addItem(newLabelItem)

        let newBrowserItem = NSMenuItem(
            title: "New Browser",
            action: #selector(newBrowser(_:)),
            keyEquivalent: "b"
        )
        newBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        newBrowserItem.target = self
        fileMenu.addItem(newBrowserItem)

        let addImageItem = NSMenuItem(
            title: "Add Image…",
            action: #selector(addImage(_:)),
            keyEquivalent: "i"
        )
        addImageItem.keyEquivalentModifierMask = [.command, .shift]
        addImageItem.target = self
        fileMenu.addItem(addImageItem)

        fileMenu.addItem(.separator())

        let folderItem = NSMenuItem(
            title: "Choose Folder for New Nodes…",
            action: #selector(chooseFolder(_:)),
            keyEquivalent: "o"
        )
        folderItem.target = self
        fileMenu.addItem(folderItem)

        fileMenu.addItem(.separator())

        let renameItem = NSMenuItem(
            title: "Rename Node…",
            action: #selector(renameNode(_:)),
            // F2, the rename key almost everywhere else.
            keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!)
        )
        renameItem.target = self
        fileMenu.addItem(renameItem)

        let closeNodeItem = NSMenuItem(
            title: "Close Node",
            action: #selector(closeNode(_:)),
            keyEquivalent: "w"
        )
        closeNodeItem.target = self
        fileMenu.addItem(closeNodeItem)

        let closeWindowItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindowItem)

        // Edit — needed so ⌘C/⌘V/⌘A reach the terminal through the responder chain.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        // View
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "=")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)

        let goToItem = NSMenuItem(
            title: "Go to Terminal…",
            action: #selector(showTerminalPalette(_:)),
            keyEquivalent: "k"
        )
        goToItem.target = self
        viewMenu.addItem(goToItem)

        let workspacesItem = NSMenuItem(
            title: "Workspaces…",
            action: #selector(showWorkspacePalette(_:)),
            keyEquivalent: "k"
        )
        workspacesItem.keyEquivalentModifierMask = [.command, .shift]
        workspacesItem.target = self
        viewMenu.addItem(workspacesItem)

        let nextWorkspaceItem = NSMenuItem(
            title: "Next Workspace",
            action: #selector(nextWorkspace(_:)),
            keyEquivalent: "\t"
        )
        nextWorkspaceItem.keyEquivalentModifierMask = [.control]
        nextWorkspaceItem.target = self
        viewMenu.addItem(nextWorkspaceItem)

        let previousWorkspaceItem = NSMenuItem(
            title: "Previous Workspace",
            action: #selector(previousWorkspace(_:)),
            keyEquivalent: "\t"
        )
        previousWorkspaceItem.keyEquivalentModifierMask = [.control, .shift]
        previousWorkspaceItem.target = self
        viewMenu.addItem(previousWorkspaceItem)

        viewMenu.addItem(.separator())

        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)

        let zoomActualItem = NSMenuItem(title: "Actual Size", action: #selector(zoomActual(_:)), keyEquivalent: "0")
        zoomActualItem.target = self
        viewMenu.addItem(zoomActualItem)

        let zoomFitItem = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomFit(_:)), keyEquivalent: "9")
        zoomFitItem.target = self
        viewMenu.addItem(zoomFitItem)

        viewMenu.addItem(.separator())

        let jumpItem = NSMenuItem(
            title: "Next Agent Needing Attention",
            action: #selector(jumpToNextAgent(_:)),
            keyEquivalent: "j"
        )
        jumpItem.target = self
        viewMenu.addItem(jumpItem)

        // Window
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
