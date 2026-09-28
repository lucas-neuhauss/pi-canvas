import Foundation

/// Turns a `NodeSpec` into something we can actually launch, and knows how to
/// create sensible specs in the first place.
enum ProcessResolver {

    /// Directory used for new nodes when the user has not chosen one.
    /// When the app is launched from Finder the working directory is `/`, which
    /// is useless, so fall back to the home directory.
    static var launchWorkingDirectory: String {
        let cwd = FileManager.default.currentDirectoryPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue, cwd != "/" {
            return cwd
        }
        return NSHomeDirectory()
    }

    static func normalizedDirectory(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue { return path }
        return NSHomeDirectory()
    }

    /// A clean environment for agent processes.
    ///
    /// Two things matter here:
    /// 1. We strip every `PI_*` variable. PiCanvas may itself be launched from a
    ///    `pi` session, and a nested `pi` must not inherit that session's
    ///    identity (`PI_SESSION_FILE`, `PI_SESSION_ID`, …) or it would consider
    ///    itself a child of the parent agent.
    /// 2. We set the terminal identity ourselves so programs that adapt to the
    ///    host terminal see something sensible.
    static func sanitizedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for key in environment.keys where key.hasPrefix("PI_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "TERM_PROGRAM")
        environment.removeValue(forKey: "TERM_PROGRAM_VERSION")

        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "PiCanvas"
        environment["TERM_PROGRAM_VERSION"] = PiCanvasVersion.string
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }

        // GUI launches get a minimal PATH. Append the usual suspects so `pi` and
        // its tools resolve even before the login shell has run.
        let home = NSHomeDirectory()
        var pathComponents = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        let extras = [
            "\(home)/.npm-global/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin"
        ]
        for extra in extras where !pathComponents.contains(extra) {
            pathComponents.append(extra)
        }
        environment["PATH"] = pathComponents.joined(separator: ":")

        return environment
    }

    /// A brand new spec for a node of `kind`.
    static func makeSpec(kind: NodeKind, workingDirectory: String, worldFrame: CGRect) -> NodeSpec {
        let directory = normalizedDirectory(workingDirectory)
        switch kind {
        case .shell:
            return NodeSpec(
                kind: .shell,
                worldFrame: worldFrame,
                workingDirectory: directory,
                // Login shell so the user's PATH and tooling are present.
                executable: "/bin/zsh",
                arguments: ["-l"]
            )
        case .pi:
            // Bind the node to its own pi session up front. `--session-id`
            // resumes exactly that conversation on relaunch (and creates it the
            // first time), so restarting PiCanvas does not throw away the
            // agents' context, and two agents in one directory stay separate.
            //
            // No `--name`: a name in pi's session list is the user's to give,
            // and handing them auto-generated ones makes the list harder to
            // read than an unnamed session.
            let sessionID = UUID().uuidString.lowercased()
            let agent = "pi --session-id \(shellQuoted(sessionID))"

            // When pi exits, hand the node over to a normal login shell rather
            // than leaving a dead pane behind: quitting the agent should leave
            // you with a usable terminal in the same directory.
            let command = "\(agent); exec /bin/zsh -l"

            return NodeSpec(
                kind: .pi,
                worldFrame: worldFrame,
                workingDirectory: directory,
                executable: "/bin/zsh",
                arguments: ["-lc", command],
                sessionID: sessionID
            )
        }
    }

    /// Single-quote a value for safe interpolation into a shell command line.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func request(for spec: NodeSpec) -> ProcessRequest {
        ProcessRequest(
            executable: spec.executable,
            arguments: spec.arguments,
            environment: sanitizedEnvironment(),
            workingDirectory: normalizedDirectory(spec.workingDirectory),
            displayName: spec.kind.displayName
        )
    }
}

enum PiCanvasVersion {
    static let string = "0.1.0"
}
