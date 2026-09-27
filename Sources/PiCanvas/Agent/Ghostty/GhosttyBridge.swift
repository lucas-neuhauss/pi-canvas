import AppKit
import GhosttyKit

/// Translation between AppKit modifier flags and ghostty's C enum.
enum GhosttyMods {

    static func toGhostty(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
        if flags.contains(.control) { mods |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
        if flags.contains(.option) { mods |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
        if flags.contains(.command) { mods |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
        if flags.contains(.capsLock) { mods |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
        if flags.contains(.numericPad) { mods |= UInt32(GHOSTTY_MODS_NUM.rawValue) }
        return ghostty_input_mods_e(rawValue: mods)
    }

    static func toAppKit(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        let raw = mods.rawValue
        if raw & UInt32(GHOSTTY_MODS_SHIFT.rawValue) != 0 { flags.insert(.shift) }
        if raw & UInt32(GHOSTTY_MODS_CTRL.rawValue) != 0 { flags.insert(.control) }
        if raw & UInt32(GHOSTTY_MODS_ALT.rawValue) != 0 { flags.insert(.option) }
        if raw & UInt32(GHOSTTY_MODS_SUPER.rawValue) != 0 { flags.insert(.command) }
        if raw & UInt32(GHOSTTY_MODS_CAPS.rawValue) != 0 { flags.insert(.capsLock) }
        return flags
    }
}

/// Building ghostty key events from AppKit events.
///
/// Adapted from Ghostty's own macOS host (MIT licensed), which is the reference
/// implementation for the translation heuristics — in particular the
/// consumed-modifier rule and the PUA/control-character filtering, both of which
/// took upstream years to settle.
extension NSEvent {

    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        // Ghostty takes the raw macOS key code and does its own translation.
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = GhosttyMods.toGhostty(modifierFlags)
        // Control and command never contribute to text translation; everything
        // else is assumed to have.
        keyEvent.consumed_mods = GhosttyMods.toGhostty(
            (translationMods ?? modifierFlags).subtracting([.control, .command])
        )
        keyEvent.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp,
           let characters = characters(byApplyingModifiers: []),
           let scalar = characters.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        return keyEvent
    }

    /// The text to hand to the PTY for this event.
    ///
    /// Control characters are dropped because Ghostty encodes those itself from
    /// the key code, and private-use scalars are how AppKit reports function
    /// keys — sending those would be wrong.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }
        return characters
    }

    /// AppKit event rebuilt with ghostty's translation modifiers, when they
    /// differ from the physical ones. Dead keys depend on this.
    func ghosttyTranslationEvent(_ translationMods: NSEvent.ModifierFlags) -> NSEvent {
        var translated = modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationMods.contains(flag) {
                translated.insert(flag)
            } else {
                translated.remove(flag)
            }
        }
        if translated == modifierFlags { return self }
        return NSEvent.keyEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: translated,
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            characters: characters(byApplyingModifiers: translated) ?? "",
            charactersIgnoringModifiers: charactersIgnoringModifiers ?? "",
            isARepeat: isARepeat,
            keyCode: keyCode
        ) ?? self
    }
}

/// Reads values out of a ghostty config.
///
/// The `len` argument of `ghostty_config_get` is the *key* length (verified
/// against Ghostty's own C API tests), and the destination pointer type depends
/// on the key's type.
enum GhosttyConfigReader {

    static func double(_ config: ghostty_config_t?, _ key: String, fallback: Double) -> Double {
        guard let config else { return fallback }
        var value: Double = fallback
        let ok = ghostty_config_get(config, &value, key, UInt(key.utf8.count))
        return ok ? value : fallback
    }

    static func string(_ config: ghostty_config_t?, _ key: String) -> String? {
        guard let config else { return nil }
        var value: UnsafePointer<CChar>?
        let ok = ghostty_config_get(config, &value, key, UInt(key.utf8.count))
        guard ok, let value else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }
}

/// The process-wide libghostty state.
///
/// libghostty has exactly one app per process; every canvas node is a *surface*
/// belonging to it. This owns initialisation, the user's real config (which is
/// why font, theme, palette and ligatures now come from Ghostty), and the action
/// callback that routes per-surface events back to the right view.
@MainActor
final class GhosttyApp {

    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    /// The user's configured `font-size`, which canvas zoom multiplies.
    private(set) var baseFontSize: CGFloat = 13

    private(set) var fontFamily: String?
    private(set) var diagnostics: [String] = []
    private(set) var startupError: String?

    private var didStart = false

    var isRunning: Bool { app != nil }

    private init() {}

    /// Initialises libghostty once. Safe to call repeatedly.
    @discardableResult
    func start() -> Bool {
        if didStart { return app != nil }
        didStart = true

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            startupError = "ghostty_init failed"
            return false
        }

        guard let config = Self.loadUserConfig() else {
            startupError = "could not create ghostty config"
            return false
        }
        self.config = config

        baseFontSize = CGFloat(GhosttyConfigReader.double(config, "font-size", fallback: 13))
        fontFamily = GhosttyConfigReader.string(config, "font-family")

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { _ in GhosttyApp.wakeup() },
            action_cb: { _, target, action in GhosttyApp.dispatch(target: target, action: action) },
            read_clipboard_cb: nil,
            confirm_read_clipboard_cb: nil,
            write_clipboard_cb: nil,
            close_surface_cb: nil
        )

        app = ghostty_app_new(&runtime, config)
        if app == nil {
            startupError = "ghostty_app_new failed"
            return false
        }
        return true
    }

    /// Loads the user's own Ghostty configuration, including themes and any
    /// `config-file` includes. This is the whole point of embedding libghostty:
    /// the terminals look like the user's Ghostty.
    private static func loadUserConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        let count = ghostty_config_diagnostics_count(config)
        if count > 0 {
            var messages: [String] = []
            for index in 0..<count {
                let diagnostic = ghostty_config_get_diagnostic(config, index)
                messages.append(String(cString: diagnostic.message))
            }
            GhosttyApp.shared.diagnostics = messages
        }
        return config
    }

    /// Called from libghostty on any thread; the app tick must run on main.
    static func wakeup() {
        DispatchQueue.main.async {
            guard let app = GhosttyApp.shared.app else { return }
            ghostty_app_tick(app)
        }
    }

    /// Routes a surface action to the view that owns it.
    ///
    /// The owning view is recovered from the surface's userdata, which is the
    /// pointer we hand libghostty when creating the surface — no side tables.
    static func dispatch(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        MainActor.assumeIsolated {
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            let surface = target.target.surface
            guard let raw = ghostty_surface_userdata(surface) else { return false }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(raw).takeUnretainedValue()
            return view.handle(action: action)
        }
    }

    /// A fresh config for a surface: the user's config with our overrides.
    /// Used for per-surface font sizing (canvas zoom).
    func makeSurfaceConfig(fontSize: CGFloat?) -> ghostty_config_t? {
        guard let config else { return nil }
        guard let clone = ghostty_config_clone(config) else { return nil }
        // There is no public setter for config values, so absolute font sizes are
        // applied after creation with the font-size binding action instead.
        _ = fontSize
        return clone
    }
}
