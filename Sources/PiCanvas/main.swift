import AppKit
import Darwin

/// PiCanvas may itself have been launched from inside a `pi` session. Strip the
/// parent's agent identity before anything spawns a child: libghostty inherits
/// this process's environment, so a nested `pi` would otherwise believe it
/// belongs to the session that started PiCanvas.
for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("PI_") {
    unsetenv(key)
}

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

    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
