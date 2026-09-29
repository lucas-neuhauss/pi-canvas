import AppKit
import Darwin

/// PiCanvas may itself have been launched from inside a `pi` session. Strip the
/// parent's agent identity before anything spawns a child: libghostty inherits
/// this process's environment, so a nested `pi` would otherwise believe it
/// belongs to the session that started PiCanvas.
for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("PI_") {
    unsetenv(key)
}

// Terminal views need held keys to repeat rather than open the accent picker.
// Registered before AppKit processes any key event.
KeyboardDefaults.apply()

// Top-level code is not implicitly main-actor isolated in Swift 5 language
// mode, but the process entry point genuinely runs on the main thread, so this
// is safe. The delegate is held by the enclosing scope for the process's
// lifetime (`run()` never returns), which matters because `NSApplication.delegate`
// is a weak reference.
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments

    // Headless integration tests: `PiCanvas --self-test`
    if arguments.contains("--self-test") {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let status = SelfTest.run()
        fflush(stdout)
        exit(status)
    }

    // Offscreen render harness: `PiCanvas --render-preview <path.png>`
    if let flagIndex = arguments.firstIndex(of: "--render-preview") {
        let path = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : "/tmp/picanvas-preview.png"
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        PreviewHarness.run(outputPath: path)
        application.terminate(nil)
    }

    // A note node with representative markdown, for judging the preview and the
    // Write mode visually. `--render-note <path.png> [--zoom 2] [--write]`
    if let flagIndex = arguments.firstIndex(of: "--render-note") {
        let path = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : "/tmp/picanvas-note.png"
        var zoom: CGFloat = 1
        if let zoomIndex = arguments.firstIndex(of: "--zoom"), arguments.count > zoomIndex + 1 {
            zoom = CGFloat(Double(arguments[zoomIndex + 1]) ?? 1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        PreviewHarness.runNote(
            outputPath: path,
            zoom: zoom,
            showPreview: !arguments.contains("--write")
        )
        application.terminate(nil)
    }

    // A browser node with a data-URL page, for judging its chrome visually.
    // `--render-browser <path.png> [--zoom 2]`
    if let flagIndex = arguments.firstIndex(of: "--render-browser") {
        let path = arguments.count > flagIndex + 1 ? arguments[flagIndex + 1] : "/tmp/picanvas-browser.png"
        var zoom: CGFloat = 1
        if let zoomIndex = arguments.firstIndex(of: "--zoom"), arguments.count > zoomIndex + 1 {
            zoom = CGFloat(Double(arguments[zoomIndex + 1]) ?? 1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        PreviewHarness.runBrowser(outputPath: path, zoom: zoom)
        application.terminate(nil)
    }

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
