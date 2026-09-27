import Foundation
import Darwin

/// What a `pi` node's agent is doing, derived from its session file.
enum PiAgentState: Equatable {
    /// No session file yet: pi is sitting at the prompt, ready for a first message.
    case ready
    /// A run is in flight, optionally labelled with the tool it is running.
    case working(String)
    /// The run finished; pi is waiting for the next message.
    case waitingForYou

    var displayText: String {
        switch self {
        case .ready: return "ready"
        case .working(let label): return label
        case .waitingForYou: return "needs you"
        }
    }

    var statusKind: NodeStatusKind {
        switch self {
        case .ready: return .idle
        case .working: return .running
        case .waitingForYou: return .needsAttention
        }
    }
}

/// Token and cost totals for one agent session, accumulated from the transcript.
struct PiUsage: Equatable {
    var costUSD: Double = 0
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    /// Context size of the most recent turn, i.e. how full the window is.
    var lastContextTokens = 0
    var turns = 0
    var model: String?
    var provider: String?

    var isEmpty: Bool { turns == 0 && model == nil }

    /// Compact money for a title bar: `$0.0008`, `$0.012`, `$1.24`.
    var costText: String? { PiUsage.formatCost(costUSD) }

    /// Compact money for anywhere: `$0.0008`, `$0.012`, `$1.24`.
    static func formatCost(_ usd: Double) -> String? {
        guard usd > 0 else { return nil }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        if usd < 1 { return String(format: "$%.3f", usd) }
        return String(format: "$%.2f", usd)
    }

    var detailText: String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        if let model {
            parts.append(provider.map { "\(model) (\($0))" } ?? model)
        }
        parts.append("\(turns) turn\(turns == 1 ? "" : "s")")
        if lastContextTokens > 0 {
            parts.append("context \(PiUsage.formatTokens(lastContextTokens))")
        }
        if inputTokens > 0 || outputTokens > 0 {
            parts.append("↑\(PiUsage.formatTokens(inputTokens)) ↓\(PiUsage.formatTokens(outputTokens))")
        }
        if let costText {
            parts.append(costText)
        }
        return parts.joined(separator: " · ")
    }

    static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// Tails a pi session file and reports what the agent is doing.
///
/// pi writes one JSON object per line as work completes, so the *last* entry
/// tells us the state precisely:
///
/// - `user` message            → pi received a prompt, it is thinking
/// - `assistant` + `toolUse`   → pi is running the tools it just called
/// - `toolResult`              → a tool finished, the model is about to continue
/// - `assistant` + `stop`      → the run is over, pi waits for the user
///
/// This is the reason a PiCanvas node can tell you it needs attention without
/// hooking into the agent at all: the transcript is the status API.
///
/// Notifications are deliberately *not* posted for `working` states, so a busy
/// canvas stays quiet until something actually wants a human.
@MainActor
final class PiSessionWatcher {

    private let sessionID: String
    private let sessionsRoot: URL
    private let pollInterval: TimeInterval
    private let onStateChange: (PiAgentState) -> Void
    private let onUsageChange: ((PiUsage) -> Void)?

    private var timer: Timer?
    private var fileURL: URL?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var startedMidLine = false

    private(set) var state: PiAgentState = .ready {
        didSet {
            guard state != oldValue else { return }
            onStateChange(state)
        }
    }

    /// Token/cost totals so far, updated as the transcript grows.
    private(set) var usage = PiUsage() {
        didSet {
            guard usage != oldValue else { return }
            onUsageChange?(usage)
        }
    }

    /// - Parameters:
    ///   - workingDirectory: the directory pi runs in; sessions are grouped by
    ///     real path, so symlinks are resolved.
    ///   - sessionID: the id PiCanvas passed to `pi --session-id`.
    ///   - sessionsRoot: override for tests; defaults to
    ///     `$PI_CODING_AGENT_DIR/sessions` or `~/.pi/agent/sessions`.
    init(
        workingDirectory: String,
        sessionID: String,
        sessionsRoot: URL? = nil,
        pollInterval: TimeInterval = 0.7,
        onStateChange: @escaping (PiAgentState) -> Void,
        onUsageChange: ((PiUsage) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.sessionsRoot = sessionsRoot ?? PiSessionWatcher.defaultSessionsRoot()
        self.pollInterval = pollInterval
        self.onStateChange = onStateChange
        self.onUsageChange = onUsageChange
        self.directory = PiSessionWatcher.sessionDirectory(
            for: workingDirectory,
            under: self.sessionsRoot
        )
    }

    private let directory: URL

    deinit {
        timer?.invalidate()
    }

    // MARK: - Paths

    /// `~/.pi/agent/sessions`, honouring pi's own override.
    static func defaultSessionsRoot() -> URL {
        if let configured = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    /// pi groups sessions by the real path of the working directory, using
    /// `--${cwd.replace(/^[/\\]/, "").replace(/[/\\:]/g, "-")}--`, so we must
    /// reproduce it exactly — including resolving symlinks.
    static func sessionDirectory(for workingDirectory: String, under root: URL) -> URL {
        var path = resolvedRealPath(workingDirectory)
        if path.hasPrefix("/") || path.hasPrefix("\\") {
            path.removeFirst()
        }
        let slug = "--" + path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-") + "--"
        return root.appendingPathComponent(slug, isDirectory: true)
    }

    /// `URL.resolvingSymlinksInPath()` leaves `/tmp` alone; pi resolves it to
    /// `/private/tmp`, so the session directory would not be found. `realpath`
    /// agrees with pi.
    private static func resolvedRealPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        locateFile()
        if fileURL != nil {
            attach()
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Finds `<timestamp>_<sessionID>.jsonl` inside the directory.
    private func locateFile() {
        guard fileURL == nil else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let suffix = "_\(sessionID).jsonl"
        guard let match = names.filter({ $0.hasSuffix(suffix) }).sorted().last else { return }
        fileURL = directory.appendingPathComponent(match)
    }

    // MARK: - Reading

    /// Reads the tail of an existing session so a node restored after a restart
    /// shows its real state immediately instead of "ready".
    private func attach() {
        guard let fileURL, let size = fileSize(fileURL) else { return }
        let window: UInt64 = 512 * 1024
        let start = size > window ? size - window : 0
        offset = start
        startedMidLine = start > 0
        pending = Data()
        readNewData()
    }

    private func poll() {
        if fileURL == nil {
            locateFile()
            guard fileURL != nil else { return }
            attach()
            return
        }
        readNewData()
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    private func readNewData() {
        guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {
            // Truncated or replaced: start over.
            offset = 0
            pending = Data()
            startedMidLine = false
        }
        guard size > offset else { return }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return
        }
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        consume(data)
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending.subdata(in: pending.startIndex..<newline)
            pending.removeSubrange(pending.startIndex...newline)
            if startedMidLine {
                // The first chunk may have begun in the middle of a line.
                startedMidLine = false
                continue
            }
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        switch object["type"] as? String {
        case "model_change":
            if let modelId = object["modelId"] as? String {
                usage.model = modelId
                usage.provider = object["provider"] as? String
            }
            return

        case "message":
            break

        default:
            return
        }

        guard let message = object["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return
        }

        switch role {
        case "user":
            state = .working("thinking")

        case "assistant":
            accumulateUsage(from: message)
            let stopReason = message["stopReason"] as? String
            if stopReason == "toolUse" || stopReason == "tool_calls" {
                state = .working(lastToolName(in: message) ?? "working")
            } else {
                // `stop`, `length`, `aborted`, anything else: the run is over and
                // pi is back at the prompt.
                state = .waitingForYou
            }

        case "toolResult":
            let tool = message["toolName"] as? String
            state = .working(tool ?? "working")

        default:
            break
        }
    }

    private func lastToolName(in message: [String: Any]) -> String? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        return content.last { $0["type"] as? String == "toolCall" }?["name"] as? String
    }

    /// Adds one assistant turn's `usage` to the running totals.
    private func accumulateUsage(from message: [String: Any]) {
        if let model = message["model"] as? String {
            usage.model = model
            usage.provider = message["provider"] as? String
        }
        guard let usageObject = message["usage"] as? [String: Any] else { return }

        usage.turns += 1
        if let input = usageObject["input"] as? Int { usage.inputTokens += input }
        if let output = usageObject["output"] as? Int { usage.outputTokens += output }
        if let cacheRead = usageObject["cacheRead"] as? Int { usage.cacheReadTokens += cacheRead }
        if let cacheWrite = usageObject["cacheWrite"] as? Int { usage.cacheWriteTokens += cacheWrite }
        if let total = usageObject["totalTokens"] as? Int { usage.lastContextTokens = total }
        if let cost = usageObject["cost"] as? [String: Any], let total = cost["total"] as? Double {
            usage.costUSD += total
        }
    }
}
