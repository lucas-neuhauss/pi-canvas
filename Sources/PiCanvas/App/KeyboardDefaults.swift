import AppKit
import Foundation

/// Keyboard defaults that a terminal has to override.
///
/// AppKit's "press and hold" feature replaces key repeat with an accent picker
/// (é, è, ê…) in anything that participates in text input, which terminal views
/// do. That is wrong for a terminal: holding `j` in nvim has to move the cursor,
/// not offer an accent. Registering the default — the same thing Ghostty's macOS
/// app does — makes AppKit send key-repeat events instead.
///
/// Registered defaults sit at the bottom of the search order, so an explicit
/// setting in the app's own domain or in `NSGlobalDomain` still wins. That is the
/// right precedence: we provide the terminal-appropriate default, and the user's
/// deliberate choice beats it.
enum KeyboardDefaults {

    static let pressAndHoldKey = "ApplePressAndHoldEnabled"

    /// Call before AppKit starts processing key events.
    static func apply() {
        UserDefaults.standard.register(defaults: [pressAndHoldKey: false])
    }

    /// True when held keys will repeat, which is what we ask for.
    static var repeatsHeldKeys: Bool {
        !UserDefaults.standard.bool(forKey: pressAndHoldKey)
    }

    /// The user's own explicit setting, when there is one.
    ///
    /// `persistentDomain` deliberately excludes registered defaults, so this
    /// returns a value only when something the user wrote outranks ours.
    static func explicitOverride() -> Bool? {
        let domains = [Bundle.main.bundleIdentifier, "NSGlobalDomain"].compactMap { $0 }
        for domain in domains {
            if let value = UserDefaults.standard.persistentDomain(forName: domain)?[pressAndHoldKey] as? Bool {
                return value
            }
        }
        return nil
    }

    /// A note for the log when something overrides us, so a still-accented
    /// terminal is explainable rather than mysterious.
    static func overrideWarning() -> String? {
        guard let override = explicitOverride() else { return nil }
        if override {
            return "press-and-hold is explicitly enabled for this app or globally, so held keys will show accents. "
                + "Override with: defaults write com.neuhaus.picanvas \(pressAndHoldKey) -bool false"
        }
        return nil
    }
}
