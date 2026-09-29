import AppKit

/// Offscreen render harness.
///
/// Builds a real window with real nodes, renders it to PNG (and PDF, as a
/// fallback for anything the bitmap capture misses) and exits. This exists so
/// the UI can be inspected without a human, without Screen Recording
/// permission, and without a display server.
///
///     PiCanvas --render-preview /tmp/preview.png
enum PreviewHarness {

    @MainActor
    static func run(outputPath: String, settleSeconds: Double = 2.5) {
        let canvasFrame = CGRect(x: 0, y: 0, width: 1440, height: 860)
        let canvas = CanvasView(frame: canvasFrame)
        let main = MainView(canvas: canvas)
        main.frame = CGRect(x: 0, y: 0, width: canvasFrame.width, height: canvasFrame.height + MainView.statusBarHeight)

        let window = NSWindow(
            contentRect: main.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = main
        window.makeKeyAndOrderFront(nil)

        // Keep the preview away from the user's real layout file.
        let previewLayout = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-preview-layout.json")
        try? FileManager.default.removeItem(at: previewLayout)

        let controller = CanvasController(
            canvas: canvas,
            workspaceStore: WorkspaceStore(
                directory: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("picanvas-preview-ws"),
                legacyLayoutURL: previewLayout
            )
        )
        controller.contentFactory = { spec, stores in
            NodeContentFactory.make(spec: spec, stores: stores)
        }

        let projectDirectory = FileManager.default.currentDirectoryPath
        controller.newNode(kind: .shell, workingDirectory: projectDirectory)
        controller.newNode(kind: .pi, workingDirectory: projectDirectory)
        controller.zoomToFit()

        main.statusBar.update(
            nodeCount: controller.nodeCount,
            zoom: controller.zoom,
            workingDirectory: CanvasController.abbreviate(controller.currentWorkingDirectory)
        )

        // Let AppKit lay out and draw before capturing. Terminals need real time
        // to spawn their process and paint the first frame.
        main.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settleSeconds))
        main.layoutSubtreeIfNeeded()
        main.displayIfNeeded()

        var wroteSomething = false

        if let rep = main.bitmapImageRepForCachingDisplay(in: main.bounds) {
            main.cacheDisplay(in: main.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                wroteSomething = write(data, to: outputPath)
            }
        }

        if let layerPNG = renderLayer(main, scale: 2) {
            _ = write(layerPNG, to: outputPath + ".layer.png")
        }

        let pdf = main.dataWithPDF(inside: main.bounds)
        if !pdf.isEmpty {
            _ = write(pdf, to: outputPath + ".pdf")
        }

        FileHandle.standardError.write(Data("preview: capture \(wroteSomething ? "ok" : "FAILED") ".utf8))

        // Reap the child processes we spawned for the screenshot.
        controller.terminateAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        exit(wroteSomething ? 0 : 1)
    }

    /// A note node with representative markdown, for judging the preview and the
    /// Write mode without a human.
    ///
    ///     PiCanvas --render-note <path.png> [--zoom 2] [--write]
    @MainActor
    static func runNote(outputPath: String, zoom: CGFloat = 1, showPreview: Bool = true, settleSeconds: Double = 1.0) {
        let canvasFrame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let canvas = CanvasView(frame: canvasFrame)
        let main = MainView(canvas: canvas)
        main.frame = CGRect(x: 0, y: 0, width: canvasFrame.width, height: canvasFrame.height + MainView.statusBarHeight)

        let window = NSWindow(contentRect: main.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = main
        window.makeKeyAndOrderFront(nil)

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-note-shot-\(UUID().uuidString)")
        let controller = CanvasController(
            canvas: canvas,
            workspaceStore: WorkspaceStore(
                directory: base.appendingPathComponent("ws"),
                legacyLayoutURL: base.appendingPathComponent("layout.json")
            ),
            scrollbackStore: ScrollbackStore(directory: base.appendingPathComponent("scrollback")),
            assetStore: AssetStore(directory: base.appendingPathComponent("assets")),
            noteStore: NoteStore(directory: base.appendingPathComponent("notes"))
        )
        var contents: [UUID: NodeContent] = [:]
        controller.contentFactory = { spec, stores in
            let content = NodeContentFactory.make(spec: spec, stores: stores)
            contents[spec.id] = content
            return content
        }

        let sample = """
        # Plan

        Bold **bolder** here, italic *slanted* here, and `code`.

        - [ ] unchecked task
        - [x] checked task
        - plain bullet

        1. first
        2. second

        > quoted text

        ```swift
        let x = 1
        ```

        ## Second heading
        """
        let id = controller.createNoteNode(text: sample)
        if showPreview {
            (contents[id] as? NoteContent)?.setPreviewing(true)
        }
        canvas.setViewport(zoom: zoom, pan: .zero, notify: false)
        if let node = canvas.nodeView(withID: id) {
            node.worldFrame = CGRect(x: 20, y: 20, width: 560, height: 640)
            canvas.layoutNodes()
        }

        main.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settleSeconds))
        main.layoutSubtreeIfNeeded()
        main.displayIfNeeded()

        if let rep = main.bitmapImageRepForCachingDisplay(in: main.bounds) {
            main.cacheDisplay(in: main.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                _ = write(data, to: outputPath)
            }
        }
        if let layerPNG = renderLayer(main, scale: 2) {
            _ = write(layerPNG, to: outputPath + ".layer.png")
        }
        FileHandle.standardError.write(Data("note preview: capture ok".utf8))
        exit(0)
    }

    /// A browser node with a data-URL page, for judging the address row and web
    /// view without a network.
    ///
    ///     PiCanvas --render-browser <path.png> [--zoom 2]
    @MainActor
    static func runBrowser(outputPath: String, zoom: CGFloat = 1, settleSeconds: Double = 1.5) {
        let canvasFrame = CGRect(x: 0, y: 0, width: 900, height: 720)
        let canvas = CanvasView(frame: canvasFrame)
        let main = MainView(canvas: canvas)
        main.frame = CGRect(x: 0, y: 0, width: canvasFrame.width, height: canvasFrame.height + MainView.statusBarHeight)

        let window = NSWindow(contentRect: main.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = main
        window.makeKeyAndOrderFront(nil)

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("picanvas-browser-shot-\(UUID().uuidString)")
        let controller = CanvasController(
            canvas: canvas,
            workspaceStore: WorkspaceStore(
                directory: base.appendingPathComponent("ws"),
                legacyLayoutURL: base.appendingPathComponent("layout.json")
            ),
            scrollbackStore: ScrollbackStore(directory: base.appendingPathComponent("scrollback")),
            assetStore: AssetStore(directory: base.appendingPathComponent("assets")),
            noteStore: NoteStore(directory: base.appendingPathComponent("notes"))
        )
        controller.contentFactory = { spec, stores in
            NodeContentFactory.make(spec: spec, stores: stores)
        }

        let html = """
        <html><body style="background:%231b1e24;color:%23e8eaf0;font-family:-apple-system;padding:28px">
        <h1 style="margin:0 0 10px">Docs</h1>
        <p>A page living next to the agents working on it.</p>
        <pre style="background:%23111;padding:12px;border-radius:6px">npm run dev</pre>
        </body></html>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let id = controller.createBrowserNode(url: URL(string: "data:text/html;charset=utf-8,\(encoded)"))
        canvas.setViewport(zoom: zoom, pan: .zero, notify: false)
        if let node = canvas.nodeView(withID: id) {
            node.worldFrame = CGRect(x: 20, y: 20, width: 700, height: 600)
            canvas.layoutNodes()
        }

        main.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(settleSeconds))
        main.layoutSubtreeIfNeeded()
        main.displayIfNeeded()

        if let rep = main.bitmapImageRepForCachingDisplay(in: main.bounds) {
            main.cacheDisplay(in: main.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                _ = write(data, to: outputPath)
            }
        }
        if let layerPNG = renderLayer(main, scale: 2) {
            _ = write(layerPNG, to: outputPath + ".layer.png")
        }
        FileHandle.standardError.write(Data("browser preview: capture ok".utf8))
        exit(0)
    }

    @MainActor
    private static func renderLayer(_ view: NSView, scale: CGFloat) -> Data? {
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        // Flipped AppKit views produce a mirrored layer tree in a y-up context.
        context.translateBy(x: 0, y: view.bounds.height)
        context.scaleBy(x: 1, y: -1)
        view.layer?.render(in: context)
        guard let image = context.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private static func write(_ data: Data, to path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("preview: write failed: \(error)".utf8))
            return false
        }
    }
}
