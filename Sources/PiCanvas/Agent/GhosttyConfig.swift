import AppKit
import Foundation

/// Reads the user's own Ghostty configuration.
///
/// The primary terminal backend (libghostty) reads this itself, so this exists
/// for two reasons: it keeps the SwiftTerm fallback looking like the user's
/// Ghostty instead of a hardcoded theme, and it makes the resolved settings
/// inspectable from the app's own diagnostics.
///
/// Supported keys are the ones that matter for a terminal surface's appearance:
/// `font-family`, `font-size`, `cursor-color`, `cursor-style`,
/// `cursor-style-blink`, `background`, `foreground`, `selection-background`,
/// `selection-foreground`, `palette`, `theme`, and `config-file` includes.
/// Everything else (keybinds, shell integration, macOS window behaviour) is
/// deliberately ignored.
struct GhosttyTheme: Equatable {

    var fontFamily: String?
    var fontSize: CGFloat?
    var cursorColor: NSColor?
    var cursorStyle: SwiftTermCursorStyle?
    var background: NSColor?
    var foreground: NSColor?
    var selectionBackground: NSColor?
    var selectionForeground: NSColor?
    /// Base 16 ANSI palette, by index.
    var palette: [Int: NSColor] = [:]

    /// Files actually read, for diagnostics.
    var sources: [String] = []
    /// Anything that looked wrong, for diagnostics.
    var warnings: [String] = []

    var isEmpty: Bool {
        fontFamily == nil && fontSize == nil && cursorColor == nil && cursorStyle == nil
            && background == nil && foreground == nil && selectionBackground == nil
            && selectionForeground == nil && palette.isEmpty
    }

    /// The 16 palette colours, when a full base palette was configured.
    var paletteColors16: [NSColor]? {
        guard palette.count >= 16 else { return nil }
        let colors = (0..<16).compactMap { palette[$0] }
        return colors.count == 16 ? colors : nil
    }

    // MARK: - Loading

    /// Parsed once per launch.
    static let current = GhosttyTheme.load()

    /// Ghostty's own search order: the XDG location first, then the macOS one,
    /// so the platform-native file wins.
    static var defaultConfigPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".config/ghostty/config"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")
        ]
    }

    /// Where `theme = <name>` is resolved from: the app bundle Ghostty ships its
    /// 400-odd bundled themes in, then the user's own themes directory.
    static var defaultThemeDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true),
            home.appendingPathComponent(".config/ghostty/themes", isDirectory: true)
        ]
    }

    static func load(
        configPaths: [URL] = GhosttyTheme.defaultConfigPaths,
        themeDirectories: [URL] = GhosttyTheme.defaultThemeDirectories
    ) -> GhosttyTheme {
        var theme = GhosttyTheme()
        var visited: Set<String> = []
        for path in configPaths {
            theme.apply(file: path, themeDirectories: themeDirectories, visited: &visited)
        }
        return theme
    }

    /// Applies a config file, following `config-file` includes depth-first.
    private mutating func apply(file: URL, themeDirectories: [URL], visited: inout Set<String>) {
        let key = file.standardizedFileURL.path
        guard !visited.contains(key) else { return }
        visited.insert(key)

        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return }
        sources.append(key)

        // A `theme` line acts as a base: its values apply, then later keys win.
        var pendingIncludes: [(URL, Bool)] = []

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }

            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }

            switch name {
            case "theme":
                if let themeFile = Self.themeFile(named: value, in: themeDirectories) {
                    apply(file: themeFile, themeDirectories: themeDirectories, visited: &visited)
                } else {
                    warnings.append("theme '\(value)' not found")
                }

            case "config-file":
                // A leading `?` means the include is optional.
                let optional = value.hasPrefix("?")
                let path = optional ? String(value.dropFirst()) : value
                let expanded = (path as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : file.deletingLastPathComponent().appendingPathComponent(expanded)
                pendingIncludes.append((url, optional))

            case "font-family":
                // Ghostty accepts a comma-separated fallback list; SwiftTerm has
                // no fallback mechanism, so take the first entry.
                let first = value.split(separator: ",").first.map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if let first, !first.isEmpty { fontFamily = first }

            case "font-size":
                if let size = Double(value) { fontSize = CGFloat(size) }

            case "cursor-color":
                if let color = Self.color(value) { cursorColor = color }

            case "cursor-style":
                cursorStyle = Self.parseCursorStyle(value, existing: cursorStyle)

            case "cursor-style-blink":
                cursorStyle = Self.parseCursorStyle(
                    cursorStyle?.shapeName ?? "block",
                    blink: Self.boolean(value)
                )

            case "background":
                if let color = Self.color(value) { background = color }

            case "foreground":
                if let color = Self.color(value) { foreground = color }

            case "selection-background":
                if let color = Self.color(value) { selectionBackground = color }

            case "selection-foreground":
                if let color = Self.color(value) { selectionForeground = color }

            case "palette":
                parsePalette(value)

            default:
                continue
            }
        }

        for (url, optional) in pendingIncludes {
            if FileManager.default.fileExists(atPath: url.path) {
                apply(file: url, themeDirectories: themeDirectories, visited: &visited)
            } else if !optional {
                warnings.append("included config not found: \(url.path)")
            }
        }
    }

    private static func themeFile(named name: String, in directories: [URL]) -> URL? {
        // An absolute or relative path is used directly.
        if name.contains("/") {
            let expanded = (name as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: expanded)
                ? URL(fileURLWithPath: expanded)
                : nil
        }
        for directory in directories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Value parsing

    private mutating func parsePalette(_ value: String) {
        // `palette = 4=#268bd2` or `palette = 4=#268bd2,12=#d33682`
        for entry in value.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  (0...255).contains(index),
                  let color = Self.color(parts[1].trimmingCharacters(in: .whitespaces)) else {
                warnings.append("could not parse palette entry '\(entry)'")
                continue
            }
            palette[index] = color
        }
    }

    /// `#rrggbb`, `#rrggbbaa`, `#rgb`, or one of the plain names Ghostty accepts.
    static func color(_ raw: String) -> NSColor? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        if !value.hasPrefix("#") {
            switch value.lowercased() {
            case "black": value = "#000000"
            case "white": value = "#ffffff"
            case "red": value = "#ff0000"
            case "green": value = "#00ff00"
            case "blue": value = "#0000ff"
            case "yellow": value = "#ffff00"
            case "magenta": value = "#ff00ff"
            case "cyan": value = "#00ffff"
            default: return nil
            }
        }

        var hex = String(value.dropFirst())
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let number = UInt32(hex, radix: 16) else { return nil }

        let red, green, blue, alpha: CGFloat
        if hex.count == 8 {
            red = CGFloat((number >> 24) & 0xFF) / 255
            green = CGFloat((number >> 16) & 0xFF) / 255
            blue = CGFloat((number >> 8) & 0xFF) / 255
            alpha = CGFloat(number & 0xFF) / 255
        } else {
            red = CGFloat((number >> 16) & 0xFF) / 255
            green = CGFloat((number >> 8) & 0xFF) / 255
            blue = CGFloat(number & 0xFF) / 255
            alpha = 1
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func boolean(_ raw: String) -> Bool {
        ["true", "yes", "1", "on"].contains(raw.lowercased())
    }

    static func parseCursorStyle(_ raw: String, existing: SwiftTermCursorStyle?) -> SwiftTermCursorStyle? {
        parseCursorStyle(raw, blink: existing?.blink ?? false)
    }

    static func parseCursorStyle(_ raw: String, blink: Bool) -> SwiftTermCursorStyle? {
        switch raw.lowercased() {
        case "block": return SwiftTermCursorStyle(shapeName: "block", blink: blink)
        case "bar": return SwiftTermCursorStyle(shapeName: "bar", blink: blink)
        case "underline": return SwiftTermCursorStyle(shapeName: "underline", blink: blink)
        default: return nil
        }
    }
}

/// A cursor shape independent of any terminal library, so the config parser can
/// stay free of SwiftTerm types.
struct SwiftTermCursorStyle: Equatable {
    var shapeName: String
    var blink: Bool

    static let block = SwiftTermCursorStyle(shapeName: "block", blink: false)
}
