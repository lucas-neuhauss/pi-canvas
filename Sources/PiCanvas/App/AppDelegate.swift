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
        controller.contentFactory = { spec in TerminalContentFactory.make(spec: spec) }

        mainView.statusBar.onNewTerminal = { [weak self] in self?.controller.newNode(kind: .shell) }
        mainView.statusBar.onNewPi = { [weak self] in self?.controller.newNode(kind: .pi) }
        mainView.statusBar.onZoomIn = { [weak self] in self?.controller.zoomIn() }
        mainView.statusBar.onZoomOut = { [weak self] in self?.controller.zoomOut() }
        mainView.statusBar.onZoomReset = { [weak self] in self?.controller.resetZoom() }
        mainView.statusBar.onZoomFit = { [weak self] in self?.controller.zoomToFit() }
        mainView.statusBar.onChooseFolder = { [weak self] in self?.controller.chooseWorkingDirectory() }
        controller.onStateChange = { [weak self] in self?.refreshStatus() }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        installSignalHandlers()

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
        for argument in CommandLine.arguments {
            switch argument {
            case "--new-terminal":
                controller.newNode(kind: .shell)
            case "--new-pi":
                controller.newNode(kind: .pi)
            default:
                continue
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
            needingAttention: controller.agentsNeedingAttention.count
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

    @objc private func chooseFolder(_ sender: Any?) {
        controller.chooseWorkingDirectory()
    }

    @objc private func closeNode(_ sender: Any?) {
        if !controller.closeFocusedNode() {
            window.performClose(sender)
        }
    }

    @objc private func zoomIn(_ sender: Any?) { controller.zoomIn() }
    @objc private func zoomOut(_ sender: Any?) { controller.zoomOut() }
    @objc private func zoomActual(_ sender: Any?) { controller.resetZoom() }
    @objc private func zoomFit(_ sender: Any?) { controller.zoomToFit() }

    @objc private func jumpToNextAgent(_ sender: Any?) {
        controller.jumpToNextAgentNeedingAttention()
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeNode(_:)), #selector(zoomFit(_:)):
            return (controller?.nodeCount ?? 0) > 0
        case #selector(jumpToNextAgent(_:)):
            return !(controller?.agentsNeedingAttention.isEmpty ?? true)
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

        let folderItem = NSMenuItem(
            title: "Choose Folder for New Nodes…",
            action: #selector(chooseFolder(_:)),
            keyEquivalent: "o"
        )
        folderItem.target = self
        fileMenu.addItem(folderItem)

        fileMenu.addItem(.separator())

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
