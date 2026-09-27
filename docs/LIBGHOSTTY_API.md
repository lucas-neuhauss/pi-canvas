# libghostty (`GhosttyKit`) API Reference for a Hand-Written AppKit Host

Target: embed Ghostty's terminal in a hand-written AppKit `NSView` subclass in a
Swift app built with raw `swiftc` (no Xcode project, no SwiftPM), macOS 14+, arm64.
This document is an exact reference for the C API in `Vendor/ghostty/include/ghostty.h`
and for how Ghostty's own macOS host (`Vendor/ghostty/macos/Sources/`) uses it.

Source revision: `b40acce58dcf77df52231c3798ea58e924647c89` (`git -C Vendor/ghostty log -1`).

> **Read this first.** `include/ghostty.h:1-8` says, verbatim:
>
> ```
> // Ghostty's internal embedder API, a.k.a. "libghostty-internal".
> //
> // The only consumer of this API is the macOS app, and while it is fairly
> // comprehensive, it is tailored to the needs of the macOS app and not designed
> // for external use, hence why most functions are undocumented and some are
> // macOS-specific (e.g. ones dealing with the Metal graphics API).
> //
> // External embedders should instead use `libghostty-vt` or other related
> // packages, which are extensively documented and designed from the ground up
> // to be used in other software.
> ```
>
> The official embedding path is `libghostty-vt` (`include/ghostty/vt.h`,
> `include/ghostty/vt/*.h`), a *standalone* terminal emulator you render yourself;
> it has no NSView/Metal integration and no PTY/child-process management. There is
> **no official example of embedding the full GUI libghostty in a custom host**.
> See §9. Everything below is what the macOS app actually does.

---

## Verification method (what is proven and how)

- **Signatures** are copied verbatim from `include/ghostty.h` with `file:line`.
- **Behavior** is read from the Zig core (`src/...`) and Swift host (`macos/Sources/...`),
  cited per claim. Where behavior is subtle it is quoted.
- **Runtime-verified** facts are marked `[runtime]`. I built Ghostty's own test
  binary and ran a custom probe against a byte-identical copy of `src/`:
  `cp -R Vendor/ghostty/src /tmp/ghostty-probe/src_copy`, then reused the exact
  `zig test` command emitted by `zig build test -Dtest-filter=... --verbose`
  (root swapped to the probe). Because this machine has only Command Line Tools
  (`xcode-select -p` → `/Library/Developer/CommandLineTools`) and no Metal
  compiler, the build was made to complete with a shim `metal`/`metallib` on
  `PATH`; the probe exercises `src/config/c_get.zig` only, never the renderer.
  Probe output is quoted inline where relevant.
- **NOT FOUND** is used deliberately where an API you asked about does not exist.
- Everything else is marked `[source]`.

---

## 0. Minimal host: the required set

A host that boots, shows a terminal, types into it, resizes it, and shuts down
cleanly must implement exactly this:

| # | API | Why |
|---|-----|-----|
| 1 | `ghostty_init(argc, argv)` | global state, once per process, before anything |
| 2 | `ghostty_config_new` + `load_default_files` + `load_recursive_files` + `finalize` | user's real config |
| 3 | `ghostty_app_new(runtime_cfg, config)` | app + runtime callbacks |
| 4 | `wakeup_cb` (must dispatch a `ghostty_app_tick` to the main thread) | the only notification channel into the core's event loop |
| 5 | `action_cb` (must at least handle `RING_BELL`, `SET_TITLE`, `PWD`, `CLOSE_WINDOW`, `CLOSE_TAB`, `NEW_TAB`, `NEW_WINDOW`, `MOUSE_SHAPE`, `MOUSE_VISIBILITY`, `SHOW_CHILD_EXITED`, `PROGRESS_REPORT`, `SET_TAB_TITLE`, `RELOAD_CONFIG`/`CONFIG_CHANGE`, `OPEN_URL`, `SIZE_LIMIT`, `CELL_SIZE`) | everything the terminal asks the UI to do |
| 6 | `read_clipboard_cb` / `confirm_read_clipboard_cb` / `write_clipboard_cb` | **not optional** (Zig fields are non-nullable, see §1.4) |
| 7 | `ghostty_app_tick(app)` on the main thread whenever `wakeup_cb` fires | delivers actions/mailbox messages |
| 8 | `ghostty_surface_new(app, &cfg)` with a plain `NSView` in `cfg.platform.macos.nsview` | creates the terminal |
| 9 | `ghostty_surface_set_size` (backing pixels) and `ghostty_surface_set_content_scale` | resize/DPI |
| 10 | `ghostty_surface_set_focus`, `ghostty_surface_set_occlusion` | cursor blink, rendering pause, focus events |
| 11 | `ghostty_surface_key` + `NSTextInputClient` + `ghostty_surface_text`/`preedit`/`ime_point` | keyboard/IME |
| 12 | `ghostty_surface_mouse_pos`/`mouse_button`/`mouse_scroll`/`mouse_pressure` | mouse |
| 13 | `ghostty_surface_free` for every surface, then `ghostty_app_free`, then `ghostty_config_free` | teardown |

`close_surface_cb` may be NULL (`embedded.zig:87`: `close_surface: ?*const fn ... = null`).
Every other callback field is non-optional in Zig and will be called; pass NULL at
your own risk (crash).

---

## 1. Bootstrap and lifetime

### 1.1 `ghostty_init`

Declaration (`include/ghostty.h:1139`), verbatim:

```c
GHOSTTY_API int ghostty_init(uintptr_t, char**);
```

Implementation (`src/main_c.zig:110-137`):

```zig
pub export fn ghostty_init(argc: usize, argv: [*][*:0]u8) c_int {
    assert(builtin.link_libc);

    global.init(.{
        .c = .{
            .argc = argc,
            .argv = argv,
            .environ = ...
        },
    }) catch |err| {
        std.log.err("failed to initialize ghostty error={}", .{err});
        return 1;
    };

    return 0;
}
```

- Returns `0` (`GHOSTTY_SUCCESS`, `include/ghostty.h:33`) on success, `1` on failure.
- **Must be called once per process, before every other libghostty call.** Ghostty's
  own host calls it at the very top of `main` (`macos/Sources/App/main.swift:8-10`):

  ```swift
  if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
      Ghostty.logger.critical("ghostty_init failed")
  ```

- `argv` must be the **real process argv** (`CommandLine.argc`/`CommandLine.unsafeArgv`).
  It is stored in global state and later read by `ghostty_config_load_cli_args`
  (`src/config/Config.zig:4258`, via `global.args()`), and used for the I/O runtime
  (`src/global.zig:118-121`). Passing `argc = 0`/`NULL` is not done anywhere in the
  source; there is no validation, so pass the real values.
- There is no guard against calling it twice (no "already initialized" check in
  `src/global.zig:55-...`); call it exactly once.
- `ghostty_cli_try_action()` (`include/ghostty.h:1140`) is the optional next call. It
  runs a `+action` from argv and **exits the process** if one is present
  (`src/main_c.zig:139-149`: `posix.system.exit(...)`). A GUI host that does not want
  CLI actions should not call it.

### 1.2 Config lifecycle

Declarations (`include/ghostty.h:1145-1160`), verbatim:

```c
GHOSTTY_API ghostty_config_t ghostty_config_new();
GHOSTTY_API void ghostty_config_free(ghostty_config_t);
GHOSTTY_API ghostty_config_t ghostty_config_clone(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_cli_args(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_file(ghostty_config_t, const char*);
GHOSTTY_API void ghostty_config_load_default_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_load_recursive_files(ghostty_config_t);
GHOSTTY_API void ghostty_config_finalize(ghostty_config_t);
GHOSTTY_API bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);
GHOSTTY_API ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t,
                                                              const char*,
                                                              uintptr_t);
GHOSTTY_API bool ghostty_config_key_is_binding(ghostty_config_t, ghostty_input_key_s);
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t);
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t, uint32_t);
GHOSTTY_API ghostty_string_s ghostty_config_open_path(void);
```

Ordering that the macOS host uses (`macos/Sources/Ghostty/Ghostty.Config.swift:60-108`):

```swift
guard let cfg = ghostty_config_new() else { ... }      // 62
if let path {
    ghostty_config_load_file(cfg, path)                // 69
} else {
    ghostty_config_load_default_files(cfg)             // 71
}
if !isRunningInXcode() {
    ghostty_config_load_cli_args(cfg)                  // 77
}
ghostty_config_load_recursive_files(cfg)               // 80
if finalize { ghostty_config_finalize(cfg) }           // 88
let diagsCount = ghostty_config_diagnostics_count(cfg) // 92
for i in 0..<diagsCount {                              // 94
    let diag = ghostty_config_get_diagnostic(cfg, UInt32(i))
    let message = String(cString: diag.message)
}
```

Rules, all `[source]`:

- `ghostty_config_new()` returns defaults and never fails to parse; it returns `NULL`
  only on allocation failure (`src/config/CApi.zig:15-28`).
- `load_default_files` loads, on macOS, the XDG paths
  (`~/.config/ghostty/config.ghostty`, legacy `~/.config/ghostty/config`) **and** the
  App Support paths (`~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`,
  legacy `.../config`), and creates a template file if neither exists
  (`src/config/Config.zig:4185-4250`, paths in `src/config/file_load.zig:12-75`).
- `load_cli_args` parses **this process's argv** (`src/config/Config.zig:4258`). If your
  app has its own flags, they may be interpreted as Ghostty config. Ghostty's host
  skips this under Xcode (`Ghostty.Config.swift:74-77`). For a host app, either skip
  it or make sure your argv is clean.
- `load_recursive_files` loads `config-file` references found by the previous loads
  (`src/config/CApi.zig:81-86`, `Config.zig` `loadRecursiveFiles`).
- `finalize` populates derived/default values. Call it after all loads and before
  `ghostty_app_new`. It is idempotent enough to call again after a later
  `load_file` (`[runtime]` probe: `after finalize font-size=21.5` preserved the value).
- `ghostty_config_free(NULL)` is safe (`src/config/CApi.zig:30-36`).
- `ghostty_config_clone` deep-clones (`src/config/CApi.zig:38-52`). This is what you
  use when a callback hands you a borrowed config (see `CONFIG_CHANGE` in §5).
- Diagnostics are strings owned by the config; valid while it lives
  (`src/config/CApi.zig:124-134`). `ghostty_diagnostic_s` is `{ const char* message; }`
  (`include/ghostty.h:439-441`).
- `ghostty_config_open_path()` returns a `ghostty_string_s` that **must be freed with
  `ghostty_string_free`** (see §7.2).

### 1.3 `ghostty_config_get`: exact per-type ABI (runtime-verified)

`ghostty_config_get(config, ptr, key, len)` copies the value of the config field
named by `key` (exact field name, e.g. `"font-size"`; `len` is the **byte length
without NUL**) into `*ptr`. It returns `false` if the key does not exist **or if the
field's Zig type is not representable** in the C API (`src/config/CApi.zig:93-102`,
`src/config/c_get.zig:12-101`).

The dispatch in `src/config/c_get.zig:26-101` is the whole contract:

| Zig type of the field | C storage you must pass | Example keys |
|---|---|---|
| `?[:0]const u8` | `const char*` (nullable; borrowed) | `title`, `shell-integration-features`? |
| `bool` | `bool` | `focus-follows-mouse`, `maximize` |
| `u8`, `u32` | `unsigned int` (`c_uint`, **4 bytes**) | `scrollback-limit` |
| `i16` | `short` (`c_short`, 2 bytes) | `background-blur` |
| `f32`, `f64` | `float` / `double` matching the field | `font-size` (f32), `background-opacity` (f64) |
| optional without value | — returns `false` | `unfocused-split-fill = null` |
| enum | `const char*` → `@tagName(value)` (borrowed, NUL-terminated) | `window-theme` → `"dark"` |
| struct with `cval()` | the matching `extern` C struct | `background`/`foreground` → `ghostty_config_color_s`, `palette` → `ghostty_config_palette_s`, `command-palette-entry` → `ghostty_config_command_list_s` |
| packed struct ≤ 32 bits | `unsigned int` bit pattern | `split-preserve-zoom`, `bell-features` |
| **struct without `cval()`, not packed** | — returns `false` | **`font-family` (`RepeatableString`)** |
| **union without `cval()`** | — returns `false` | **`cursor-color` (`?TerminalColor`)** |

Exact C patterns for the keys you named:

```c
// f32 — font-size. NOTE: float, not double.
float font_size = 0;
bool ok = ghostty_config_get(cfg, &font_size, "font-size", 9);

// Color — background / foreground.
ghostty_config_color_s bg = {0};
ok = ghostty_config_get(cfg, &bg, "background", 10);
// bg.r, bg.g, bg.b are uint8_t 0-255.

// Palette — 256 colors, fixed-size array.
ghostty_config_palette_s pal;
ok = ghostty_config_get(cfg, &pal, "palette", 7);
// pal.colors[i].r/g/b for i in 0..255.

// font-family — DOES NOT WORK (verified). Use the core's font handling;
// the family list is not exposed through ghostty_config_get.
const char *font_family = NULL;
ok = ghostty_config_get(cfg, &font_family, "font-family", 11); // -> false

// cursor-color — DOES NOT WORK (verified). TerminalColor is a union with
// color/cell-foreground/cell-background and has no cval().
ghostty_config_color_s cursor = {0};
ok = ghostty_config_get(cfg, &cursor, "cursor-color", 12); // -> false
```

`[runtime]` probe output (exact, from `/tmp/ghostty-probe/root_probe.zig`):

```
RESULT font-size ok=true value=14.5
RESULT background ok=true rgb=1,2,3
RESULT foreground ok=true rgb=4,5,6
RESULT palette ok=true p0=7,8,9 p255=238,238,238
RESULT font-family ok=false
RESULT cursor-color ok=false
RESULT window-theme ok=true value=auto
RESULT title ok=true is_null=true
RESULT background-opacity ok=true value=0.42
```

and after loading a file with `font-size = 21.5`, `font-family = My Font`,
`font-family = My Fallback`, `cursor-color = #112233`, `background = #010203`:

```
RESULT cfg.font-size=21.5
RESULT cfg.font-family count=2 first=My Font second=My Fallback
RESULT cfg.cursor-color rgb=17,34,51
RESULT cfg.background rgb=1,2,3
RESULT c_get background ok=true rgb=1,2,3
RESULT c_get font-size ok=true value=21.5
RESULT c_get font-family ok=false
RESULT c_get cursor-color ok=false
RESULT after finalize font-size=21.5
```

That last block also proves the **override mechanism**: loading a file into a config
overwrites earlier values (later wins), and `finalize` afterwards is safe. For
per-node overrides beyond the surface config fields, see §6.2.

### 1.4 `ghostty_app_new` and `ghostty_runtime_config_s`

Declarations (`include/ghostty.h:1070-1102`, `1162-1174`), verbatim:

```c
typedef void (*ghostty_runtime_wakeup_cb)(void*);
typedef ghostty_clipboard_read_result_e (*ghostty_runtime_read_clipboard_cb)(
    void*,
    ghostty_clipboard_e,
    void*,
    const char* const*,
    size_t,
    bool);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(
    void*,
    const ghostty_clipboard_confirm_s*,
    void*,
    ghostty_clipboard_request_e);
typedef void (*ghostty_runtime_write_clipboard_cb)(void*,
                                                   ghostty_clipboard_e,
                                                   const ghostty_clipboard_content_s*,
                                                   size_t,
                                                   bool);
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef bool (*ghostty_runtime_action_cb)(ghostty_app_t,
                                          ghostty_target_s,
                                          ghostty_action_s);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;
  ghostty_runtime_action_cb action_cb;
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;
} ghostty_runtime_config_s;

GHOSTTY_API ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*,
                                             ghostty_config_t);
GHOSTTY_API void ghostty_app_free(ghostty_app_t);
GHOSTTY_API void ghostty_app_tick(ghostty_app_t);
GHOSTTY_API void* ghostty_app_userdata(ghostty_app_t);
```

Field-by-field contract (`src/apprt/embedded.zig:32-112`; comments there are the
authoritative docs for the clipboard callbacks):

- **`userdata`** — `AppUD = ?*anyopaque`; passed to every callback. Not owned by
  the library. Ghostty's host uses `Unmanaged.passUnretained(self).toOpaque()`
  (`Ghostty.App.swift:59`), i.e. the host must outlive the app.
- **`supports_selection_clipboard`** — if `false`, `GHOSTTY_CLIPBOARD_SELECTION`
  requests return `GHOSTTY_CLIPBOARD_READ_UNSUPPORTED`
  (`src/apprt/embedded.zig:700-715`). The primary selection is never supported by
  the embedded API (`embedded.zig:706-714`).
- **`wakeup_cb`** — non-nullable. Called from **any thread** by
  `apprt.App.Mailbox.push` (`src/App.zig:583-593`) and by `App.wakeup`
  (`src/apprt/embedded.zig:269-271`). The callback is *not* the tick; it must
  schedule `ghostty_app_tick`. Ghostty's host
  (`Ghostty.App.swift:540-548`):
  ```swift
  static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
      let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()
      // Wakeup can be called from any thread so we schedule the app tick
      // from the main thread.
      DispatchQueue.main.async { state.appTick() }
  }
  ```
- **`action_cb`** — non-nullable. Returns `bool` = "handled". Called synchronously
  from `App.performAction` (`src/apprt/embedded.zig:303-323`). Delivery thread:
  terminal-driven actions are wrapped into the app mailbox and run inside
  `ghostty_app_tick` (`src/apprt/surface.zig:187-207` → `src/App.zig:265-298` →
  `src/Surface.zig:983` `handleMessage`); host-initiated calls (key events,
  `binding_action`, `update_config`) fire it on the caller's thread. **Tick on the
  main thread and treat the callback as main-thread; any other caller must dispatch.**
  Full payload handling in §5.
- **`read_clipboard_cb`** — non-nullable. Signature meaning
  (`src/apprt/embedded.zig:44-59`): `(surface_userdata, ghostty_clipboard_e,
  request_state_ptr, mimes, mimes_len, list)`. `mimes` is the exact list of
  representations to read (text-like always normalized to `"text/plain"`,
  `embedded.zig:744-770`); `list` asks for the full available-MIME listing in the
  completion. Return one of `ghostty_clipboard_read_result_e`
  (`include/ghostty.h:122-126`):
  ```c
  typedef enum {
    GHOSTTY_CLIPBOARD_READ_STARTED,
    GHOSTTY_CLIPBOARD_READ_UNAVAILABLE,
    GHOSTTY_CLIPBOARD_READ_UNSUPPORTED,
  } ghostty_clipboard_read_result_e;
  ```
  If you return `STARTED`, you **must** eventually call
  `ghostty_surface_complete_clipboard_request` or
  `ghostty_surface_deny_clipboard_request` with the `state` pointer. The state
  pointer is owned by libghostty and is freed immediately for any non-`STARTED`
  result (`embedded.zig:783-796`). All memory in the completion call is borrowed
  for the duration of the call (`embedded.zig:2258-2262`).
- **`confirm_read_clipboard_cb`** — non-nullable. Called when a read requires
  confirmation (OSC 52 / Kitty policy). Receives
  `const ghostty_clipboard_confirm_s*` (`include/ghostty.h:103-110`) whose
  `contents` are borrowed for this call only; `name` is the requesting program,
  `can_remember` is whether a session grant may be remembered. You must eventually
  complete or deny with the same `state`.
- **`write_clipboard_cb`** — non-nullable. `(userdata, location, contents, len,
  confirm)`. `contents` is an array of `ghostty_clipboard_content_s`
  (`include/ghostty.h:83-87`: `mime`, binary-safe `data`, `len`). If `confirm` is
  true the host must prompt; the host owns nothing.
- **`close_surface_cb`** — **may be NULL** (`embedded.zig:87`). Called when the
  core wants the surface closed; the host must then free the surface itself. The
  `bool` argument is `surface.needsConfirmQuit()`
  (`src/Surface.zig:849-851`), **not** "process alive" despite the parameter name
  `process_alive` in `src/apprt/embedded.zig:678-685`. Ghostty's host treats it as
  `withConfirmation:` (`BaseTerminalController.swift:659-664`). See gotcha #7.

Creation (`src/apprt/embedded.zig:1664-1690`): `ghostty_app_new` clones the config
(`App.init`, `embedded.zig:145-161`), so **you still own your `ghostty_config_t`
and may free it after the call**. Returns `NULL` on failure.

`ghostty_app_userdata(app)` returns exactly the `userdata` you passed
(`src/apprt/embedded.zig:1699-1701`).

### 1.5 App tick / update / free

- `ghostty_app_tick(app)` drains the app mailbox (`src/apprt/embedded.zig:1692-1697`
  → `src/App.zig:156-159`). Call it on the **main thread** on every wakeup.
- `ghostty_app_update_config(app, config)` — main thread only, and the caller
  owns the config: "The caller owns the config memory. The memory can be freed
  immediately when this returns." (`src/App.zig:161-163`). It propagates to all
  surfaces and emits `GHOSTTY_ACTION_CONFIG_CHANGE` for the app
  (`src/App.zig:164-189`).
- `ghostty_app_free(app)` frees the app and **deinitializes any surfaces still
  registered** (`src/App.zig:132-151`); a debug build asserts the font grid set is
  empty (`App.zig:141`). Free your surfaces first. See §7.3.
- `ghostty_app_needs_confirm_quit` / `ghostty_app_has_global_keybinds` /
  `ghostty_app_set_focus` / `ghostty_app_set_color_scheme` / `ghostty_app_key`
  exist (`include/ghostty.h:1167-1174`) and behave as named; `ghostty_app_key` is
  for app-global keybinds and returns true if captured
  (`src/apprt/embedded.zig:1721-1733`).

---

## 2. Surfaces and rendering

### 2.1 `ghostty_surface_config_s` field by field

Declaration (`include/ghostty.h:489-521`), verbatim:

```c
typedef struct {
  void* nsview;
} ghostty_platform_macos_s;

typedef struct {
  void* uiview;
} ghostty_platform_ios_s;

typedef union {
  ghostty_platform_macos_s macos;
  ghostty_platform_ios_s ios;
} ghostty_platform_u;

typedef enum {
  GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
  GHOSTTY_SURFACE_CONTEXT_TAB = 1,
  GHOSTTY_SURFACE_CONTEXT_SPLIT = 2,
} ghostty_surface_context_e;

typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
  ghostty_env_var_s* env_vars;
  size_t env_var_count;
  const char* initial_input;
  bool wait_after_command;
  ghostty_surface_context_e context;
} ghostty_surface_config_s;

GHOSTTY_API ghostty_surface_config_s ghostty_surface_config_new();
```

The macOS union arm is **`ghostty_platform_macos_s`** and it expects an
**`NSView*`** (opaque `void*`). `platform_tag` must be `GHOSTTY_PLATFORM_MACOS`
(`include/ghostty.h:69-73`: `INVALID=0, MACOS=1, IOS=2`). If the tag is `INVALID`
or the view is `NULL`, surface creation fails
(`src/apprt/embedded.zig:409-430`: `NSViewMustBeSet` / `InvalidEnumTag`).

`ghostty_surface_config_new()` returns zero/default values
(`src/apprt/embedded.zig:1797-1799`: `return .{}`), i.e.
`platform_tag = 0`, `scale_factor = 1`, `font_size = 0`, all pointers NULL,
`wait_after_command = false`, `context = window`
(`src/apprt/embedded.zig:431-511`).

How Ghostty's host fills it (`macos/Sources/Ghostty/Surface View/SurfaceView.swift:628-697`):

```swift
var config = ghostty_surface_config_new()
config.userdata = Unmanaged.passUnretained(view).toOpaque()
config.platform_tag = GHOSTTY_PLATFORM_MACOS
config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
    nsview: Unmanaged.passUnretained(view).toOpaque()
))
config.scale_factor = NSScreen.main!.backingScaleFactor
config.font_size = fontSize ?? 0        // 0 = inherit default font size
config.wait_after_command = waitAfterCommand
config.context = context
// all strings inside withCString closures:
config.working_directory = cWorkingDir
config.command = cCommand
config.initial_input = cInput
config.env_vars = buffer.baseAddress
config.env_var_count = environmentVariables.count
```

Field semantics (from the Zig `Options` docs, `src/apprt/embedded.zig:431-511`):

| field | type | semantics |
|---|---|---|
| `platform_tag` | `ghostty_platform_e` | must be `GHOSTTY_PLATFORM_MACOS` |
| `platform.macos.nsview` | `NSView*` | the view libghostty will render into. **It assigns the layer to this view** (§2.3). Must outlive the surface. |
| `userdata` | `void*` | returned by `ghostty_surface_userdata`; passed to clipboard/close callbacks |
| `scale_factor` | `double` | initial content scale; `1` = default. Ghostty's host uses the **main screen's** `backingScaleFactor` and corrects later via `set_content_scale` |
| `font_size` | `float` | points; `0` means "inherit config/default" (`embedded.zig:437-439`, host comment `SurfaceView.swift:637`) |
| `working_directory` | `const char*` (NUL-terminated) | validated to exist and be a directory; silently ignored otherwise (`embedded.zig:519-565`) |
| `command` | `const char*` | **run in a shell (`/bin/sh -c`), not argv**; setting it forces `wait_after_command = true` (`embedded.zig:470-482`, `566-572`) |
| `env_vars`/`env_var_count` | array of `{const char* key; const char* value;}` (`include/ghostty.h:484-487`) | extra env for the child; copied during `ghostty_surface_new` |
| `initial_input` | `const char*` | text queued to the **child's stdin after start**, not fed to the emulator (`embedded.zig:486-489`, `src/termio/Termio.zig:86-115`, `347-405`) |
| `wait_after_command` | `bool` | keep the surface open after the child exits |
| `context` | `ghostty_surface_context_e` | affects working-dir/font-size inheritance only (`src/apprt/surface.zig:210-249`) |

All pointers only need to stay alive **for the duration of `ghostty_surface_new`**;
the Zig code copies strings and env vars into the surface config arena
(`embedded.zig:515-600`). `ghostty_surface_config_new()` also returns a struct with
`platform` uninitialized (`undefined`), so you must set both `platform_tag` and
`platform`.

`context` values: `GHOSTTY_SURFACE_CONTEXT_WINDOW=0`, `TAB=1`, `SPLIT=2`
(`include/ghostty.h:502-506`; `[runtime]` probe: `WINDOW=0 TAB=1 SPLIT=2`).

### 2.2 Creating/freeing surfaces

Declarations (`include/ghostty.h:1178-1200`, `1221`, `1236-1241`), verbatim:

```c
GHOSTTY_API ghostty_surface_t ghostty_surface_new(ghostty_app_t,
                                                     const ghostty_surface_config_s*);
GHOSTTY_API void ghostty_surface_free(ghostty_surface_t);
GHOSTTY_API void* ghostty_surface_userdata(ghostty_surface_t);
GHOSTTY_API ghostty_app_t ghostty_surface_app(ghostty_surface_t);
GHOSTTY_API ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t, ghostty_surface_context_e);
GHOSTTY_API void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);
GHOSTTY_API bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_refresh(ghostty_surface_t);
GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t);
```

- `ghostty_surface_new` **must be called from the main thread**
  (`src/Surface.zig:472-473`: "Create a new surface. This must be called from the
  main thread."). Returns `NULL` on failure.
- `ghostty_surface_free` is immediate destruction: `app.closeSurface(ptr)` →
  `surface.deinit()` → stop renderer thread, stop IO thread, free resources
  (`src/apprt/embedded.zig:1819-1821`, `291-295`, `634-650`, `src/Surface.zig:800-847`).
  It does **not** call `close_surface_cb`. Ghostty's host frees on the main thread,
  and if `deinit` runs off-main it hops to main
  (`Ghostty.Surface.swift:22-39`).
- `ghostty_surface_userdata` returns the config's `userdata` unchanged
  (`src/apprt/embedded.zig:1824-1827`).
- `ghostty_surface_inherited_config(surface, context)` returns a fresh
  `ghostty_surface_config_s` with `font_size` (if `window-inherit-font-size`),
  `working_directory` (if the context inherits it), and `context` filled in
  (`src/apprt/embedded.zig:1161-1179`). **Gotcha:** when a working directory is
  inherited it is heap-allocated by the library and there is **no free API** for
  the returned struct; Ghostty's own host never frees it (`Ghostty.App.swift:943`,
  `979`, `1007` → `SurfaceConfiguration(from:)` copies and drops the pointer).
  Treat it as a small per-surface leak or avoid it.
- `ghostty_surface_update_config` applies a surface-only config. The surface
  derives a copy; the caller keeps ownership (`src/Surface.zig:1770-1797`).
- `ghostty_surface_needs_confirm_quit` → `confirm_close_surface` config plus
  read-only/child-exited logic (`src/Surface.zig:961-979`).
- `ghostty_surface_process_exited` → `child_exited` (`embedded.zig:1858-1861`).
- `ghostty_surface_refresh` schedules a render (`src/Surface.zig:3514-3521`);
  `ghostty_surface_draw` forces a synchronous frame (`src/Surface.zig:891-895`).
  The macOS host calls **neither** (see §2.3).

### 2.3 The render loop contract — who draws, and when

This is the most important section for a custom host, and the answer is unusual:

**libghostty owns the view's layer and drives drawing itself. Your host creates no
`CAMetalLayer`, sets no `wantsLayer`, implements no `draw(_:)`, and does not need
to call `ghostty_surface_draw` or handle `GHOSTTY_ACTION_RENDER`.**

Evidence, in order:

1. On the Metal backend, libghostty creates its own `IOSurfaceLayer` (a
   `CALayer` subclass) and installs it on the view you passed. The comments and
   code (`src/renderer/Metal.zig:107-149`) are explicit:

   ```zig
   // Add our layer to the view.
   //
   // On macOS we do this by making the view "layer-hosting"
   // by assigning it to the view's `layer` property BEFORE
   // setting `wantsLayer` to `true`.
   switch (comptime builtin.os.tag) {
       .macos => {
           info.view.setProperty("layer", layer.layer.value);
           info.view.setProperty("wantsLayer", true);
       },
       ...
   }
   info.view.setProperty("clipsToBounds", true);
   layer.layer.setProperty("contentsScale", info.scaleFactor);
   // This makes it so that our display callback will actually be called.
   layer.layer.setProperty("needsDisplayOnBoundsChange", true);
   ```

   The view is obtained from `platform.macos.nsview`
   (`src/renderer/Metal.zig:96-105`).

2. That layer's `display` is overridden to call back into the renderer
   (`src/renderer/metal/IOSurfaceLayer.zig:150-172`):

   ```zig
   subclass.replaceMethod("display", struct {
       fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
           const self = objc.Object.fromId(target);
           const display_cb: DisplayCallback = @ptrFromInt(...);
           if (display_cb) |cb| cb(@ptrCast(self.getInstanceVariable("display_ctx").value));
       }
   }.display);
   ```

   and the Metal backend registers `displayCallback` on render-thread entry
   (`src/renderer/Metal.zig:163-175`), which calls
   `renderer.drawFrame(true)` (`Metal.zig:171-175`).

3. Frames are presented by setting the layer's `contents` to the rendered
   `IOSurface`; this hops to the main thread unless already there
   (`src/renderer/Metal.zig:253-258` → `IOSurfaceLayer.zig:53-80`). There is an
   explicit size check that discards stale-sized surfaces
   (`IOSurfaceLayer.zig:96-126`).

4. Therefore the host's `NSView` is a *plain* view. Ghostty's own host never
   touches `wantsLayer`/`layer` for terminal surfaces (only unrelated chrome
   views do; `grep -rn "CAMetalLayer\|wantsLayer" macos/Sources/Ghostty` returns
   nothing). It does not override `draw(_:)`.

**`GHOSTTY_ACTION_RENDER`.** The action exists (`include/ghostty.h:976`) and the
core emits it when the renderer pushes a `.redraw` message to the surface
(`src/Surface.zig:1743-1753` → `src/Surface.zig:1120` `.redraw => self.redraw()`).
On the Metal backend nothing ever pushes `.redraw` — the only producer in the
tree is the OpenGL frame (`src/renderer/opengl/Frame.zig:85`). Consistent with
that, **Ghostty's macOS host has no `case GHOSTTY_ACTION_RENDER`**; it falls into
`default:` which logs and returns false (`macos/Sources/Ghostty/Ghostty.App.swift:786-789`).
If you want to be defensive, handling it by calling `ghostty_surface_draw` is
harmless, but on macOS/Metal it will not fire.

**Threading of drawing.** The renderer runs on its own thread (`src/renderer/Thread.zig:201-240`).
`drawFrame(true)` is explicitly supported from the main thread so resize can update
contents (`src/Surface.zig:891-895`: "Renderers are required to support `drawFrame`
being called from the main thread, so that they can update contents during resize.").
Your host must never call `ghostty_surface_draw` from a background thread.

**When to call what:**

- `ghostty_surface_set_size(surface, w, h)` — `w`/`h` are **backing pixels**
  (framebuffer pixels). Ghostty's host does
  `let scaledSize = self.convertToBacking(size)` then passes `UInt32(scaledSize.width/height)`
  (`SurfaceView_AppKit.swift:482-490`, `493-506`). It is called from the view's
  size-change path, using the *target* size rather than the current frame:
  ```swift
  // Ghostty wants to know the actual framebuffer size... It is very important
  // here that we use "size" and NOT the view frame. If we're in the middle of
  // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
  override func sizeDidChange(_ size: CGSize) {
      let scaledSize = self.convertToBacking(size)
      setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
      contentSize = size
  }
  ```
  The core ignores duplicate sizes (`src/apprt/embedded.zig:1018-1036`), then
  recalculates the grid and notifies the pty/renderer (`src/Surface.zig:2560-2605`).
- `ghostty_surface_set_content_scale(surface, x, y)` — **scale factors** (not
  sizes), clamped to `>= 1`; triggers font-size recalculation for the DPI and a
  resize (`src/apprt/embedded.zig:1005-1016`, `src/Surface.zig:3725-3758`).
  Ghostty's host calls it from `viewDidChangeBackingProperties`, after computing
  `xScale = fbFrame.width / frame.width` and `yScale = fbFrame.height / frame.height`,
  and also updates `layer?.contentsScale` itself to the window's
  `backingScaleFactor` with implicit animations disabled
  (`SurfaceView_AppKit.swift:866-903`). For a custom host, calling
  `set_content_scale` when the window's backing scale changes is the important
  part; the `layer.contentsScale` line is defensive compositing hygiene.
- Window resize: just update the view frame and call `set_size`. The layer has
  `needsDisplayOnBoundsChange = true`, so CoreAnimation calls the display callback
  during the resize; the renderer also gets a resize message
  (`src/Surface.zig:2600-2605`).
- Occlusion: call `ghostty_surface_set_occlusion(surface, visible)` from
  `windowDidChangeOcclusionState` using
  `window.occlusionState.contains(.visible)`. Ghostty's host does exactly this and
  caches the last value per surface
  (`BaseTerminalController.swift:1281-1291`). The core avoids duplicate reports,
  pauses rendering when not visible, notifies the renderer, and emits mode 2033
  visibility reports if enabled (`src/Surface.zig:3397-3424`).
- Focus: `ghostty_surface_set_focus(surface, focused)` on first-responder change
  (`SurfaceView_AppKit.swift:445-470`, call at `458`). App-level focus is
  `ghostty_app_set_focus(app, active)` (`Ghostty.App.swift:280-288`).
- Screen changes: on Darwin, call `ghostty_surface_set_display_id(surface, displayID)`
  so the display link uses the right refresh rate
  (`SurfaceView_AppKit.swift:809-826`; `include/ghostty.h:1244`,
  `src/apprt/embedded.zig:2408-2416`).
- Appearance: `ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_DARK|LIGHT)`
  (`BaseTerminalController.swift:1514-1537`).

**Minimum initial frame.** Give the view a non-zero frame before/at surface
creation. Ghostty's host comments
(`SurfaceView_AppKit.swift:261-265`): "Initialize with some default frame size.
The important thing is that this is non-zero so that our layer bounds are non-zero
so that our renderer can do SOMETHING."

### 2.4 Other surface APIs (declarations)

```c
GHOSTTY_API void ghostty_surface_set_content_scale(ghostty_surface_t, double, double); // :1189
GHOSTTY_API void ghostty_surface_set_focus(ghostty_surface_t, bool);                   // :1190
GHOSTTY_API void ghostty_surface_set_occlusion(ghostty_surface_t, bool);               // :1191
GHOSTTY_API void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);      // :1192
GHOSTTY_API ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);            // :1193
GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);                // :1194
GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);              // :1195
GHOSTTY_API void ghostty_surface_set_color_scheme(ghostty_surface_t,
                                                     ghostty_color_scheme_e);          // :1196
GHOSTTY_API void ghostty_surface_request_close(ghostty_surface_t);                     // :1221
```

`ghostty_surface_size_s` (`include/ghostty.h:523-530`):

```c
typedef struct {
  uint16_t columns;
  uint16_t rows;
  uint32_t width_px;
  uint32_t height_px;
  uint32_t cell_width_px;
  uint32_t cell_height_px;
} ghostty_surface_size_s;
```

Filled from the core (`src/apprt/embedded.zig:1961-1972`): `width_px`/`height_px`
are the framebuffer size; `cell_*` are the pixel cell metrics. Host use: convert
window resizes into whole-cell steps, and drive scrollbar geometry.

- `ghostty_surface_foreground_pid` returns `0` when unavailable
  (`src/apprt/embedded.zig:1974-1976`).
- `ghostty_surface_tty_name` returns a `ghostty_string_s` that **must be freed
  with `ghostty_string_free`** (`src/apprt/embedded.zig:1978-1989`).
- `ghostty_surface_request_close` prefers the `close_surface` binding path and
  falls back to a raw close; either way the host is notified via
  `close_surface_cb` if implemented (`src/apprt/embedded.zig:2166-2175`).

---

## 3. Input

### 3.1 Keys

`ghostty_input_key_s` (`include/ghostty.h:391-399`), verbatim:

```c
typedef struct {
  ghostty_input_action_e action;
  ghostty_input_mods_e mods;
  ghostty_input_mods_e consumed_mods;
  uint32_t keycode;
  const char* text;
  uint32_t unshifted_codepoint;
  bool composing;
} ghostty_input_key_s;
```

- **There is no `code` field.** NOT FOUND. The physical key is identified solely by
  the native `keycode` (macOS `NSEvent.keyCode`), which the core maps to its
  W3C-style key enum (`src/apprt/embedded.zig:113-146`).
- **There is no type named `ghostty_input_key_action_e`.** NOT FOUND. The action
  enum is `ghostty_input_action_e` (`include/ghostty.h:189-193`):
  ```c
  typedef enum {
    GHOSTTY_ACTION_RELEASE,
    GHOSTTY_ACTION_PRESS,
    GHOSTTY_ACTION_REPEAT,
  } ghostty_input_action_e;
  ```
  (RELEASE=0, PRESS=1, REPEAT=2. Note this collides in name with the
  `ghostty_action_tag_e` prefix `GHOSTTY_ACTION_*` — different enum, be careful.)
- `ghostty_input_mods_e` (`include/ghostty.h:168-180`), verbatim:
  ```c
  typedef enum {
    GHOSTTY_MODS_NONE = 0,
    GHOSTTY_MODS_SHIFT = 1 << 0,
    GHOSTTY_MODS_CTRL = 1 << 1,
    GHOSTTY_MODS_ALT = 1 << 2,
    GHOSTTY_MODS_SUPER = 1 << 3,
    GHOSTTY_MODS_CAPS = 1 << 4,
    GHOSTTY_MODS_NUM = 1 << 5,
    GHOSTTY_MODS_SHIFT_RIGHT = 1 << 6,
    GHOSTTY_MODS_CTRL_RIGHT = 1 << 7,
    GHOSTTY_MODS_ALT_RIGHT = 1 << 8,
    GHOSTTY_MODS_SUPER_RIGHT = 1 << 9,
  } ghostty_input_mods_e;
  ```
- `ghostty_surface_key` (`include/ghostty.h:1200`):
  ```c
  GHOSTTY_API bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
  ```
  Returns `true` if consumed/closed, `false` if ignored
  (`src/apprt/embedded.zig:202-228`, `2033-2048`).

How Ghostty's host builds the struct (`macos/Sources/Ghostty/NSEvent+Extension.swift:12-46`):

```swift
func ghosttyKeyEvent(_ action: ghostty_input_action_e,
                     translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
    var key_ev: ghostty_input_key_s = .init()
    key_ev.action = action
    key_ev.keycode = UInt32(keyCode)
    key_ev.text = nil
    key_ev.composing = false
    // macOS provides no easy way to determine the consumed modifiers...
    // control and command never contribute to the translation of text.
    key_ev.mods = Ghostty.ghosttyMods(modifierFlags)
    key_ev.consumed_mods = Ghostty.ghosttyMods(
        (translationMods ?? modifierFlags).subtracting([.control, .command]))
    key_ev.unshifted_codepoint = 0
    if type == .keyDown || type == .keyUp {
        if let chars = characters(byApplyingModifiers: []),
           let codepoint = chars.unicodeScalars.first {
            key_ev.unshifted_codepoint = codepoint.value
        }
    }
    return key_ev
}
```

and the text field is attached with a `withCString` so the pointer is valid only
during the call (`SurfaceView_AppKit.swift:1475-1496`):

```swift
private func keyAction(_ action: ghostty_input_action_e, event: NSEvent,
                       translationEvent: NSEvent? = nil, text: String? = nil,
                       composing: Bool = false) -> Bool {
    var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
    key_ev.composing = composing
    if let text = text?.keyEventText {
        return text.withCString { ptr in
            key_ev.text = ptr
            return ghostty_surface_key(surface, key_ev)
        }
    } else {
        return ghostty_surface_key(surface, key_ev)
    }
}
```

**Plain press/release:** `action = GHOSTTY_ACTION_PRESS|RELEASE`, `keycode =
event.keyCode`, `mods = current modifier flags`, `consumed_mods = translation mods
minus ctrl+command`, `text = NULL`, `unshifted_codepoint = characters(byApplyingModifiers:
[])`, `composing = false`. Release events go through `keyUp` with
`GHOSTTY_ACTION_RELEASE` (`SurfaceView_AppKit.swift:1272-1274`). Modifier keys
themselves are synthesized in `flagsChanged` (`SurfaceView_AppKit.swift:1428-1473`)
using the side-specific mod bits.

**With text:** same, plus `text` = committed UTF-8 (`withCString`). The host
strips control characters and PUA function-key codepoints before sending
(`NSEvent+Extension.swift:54-75`).

`ghostty_surface_key_translation_mods` (`include/ghostty.h:1198-1199`):

```c
GHOSTTY_API ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                                         ghostty_input_mods_e);
```

Filters mods per `macos-option-as-alt`; use the result **only** for key
translation and still send the original `mods` to `ghostty_surface_key`
(`src/apprt/embedded.zig:2015-2031`). Ghostty's host calls it at the top of
`keyDown` and rebuilds the `NSEvent` with the translated flags, but reuses the
original event when flags are unchanged because Korean IME requires object
identity (`SurfaceView_AppKit.swift:1110-1148`).

`ghostty_surface_key_is_binding(surface, event, ghostty_binding_flags_e*)`
(`include/ghostty.h:1201-1203`) reports whether a binding would trigger and its
flags (`CONSUMED/ALL/GLOBAL/PERFORMABLE`, `include/ghostty.h:182-187`). Ghostty's
host uses it in `performKeyEquivalent` to route bindings to the menu
(`SurfaceView_AppKit.swift:1305-1380`).

`ghostty_app_key(app, event)` (`include/ghostty.h:1168`) is the app-global variant.

### 3.2 IME / `NSTextInputClient`

Declarations (`include/ghostty.h:1204-1205`, `1220`):

```c
GHOSTTY_API void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);
GHOSTTY_API void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*);
```

- `ghostty_surface_text` — "Send raw text to the terminal. This is treated like a
  paste so this isn't useful for sending escape sequences. For that, individual
  key input should be used." (`src/apprt/embedded.zig:2063-2074`; implementation
  `src/Surface.zig:3386-3392` → `completeClipboardPaste`). Length is bytes, no NUL.
- `ghostty_surface_preedit` — sets the IME composition string; `len == 0` clears it
  (`src/apprt/embedded.zig:2076-2087`).
- `ghostty_surface_ime_point` — returns the IME anchor in **points, top-left
  origin**: `x` is the cursor midpoint, `y` is the bottom of the cursor cell,
  `width` reflects the preedit width, `height` the cell height
  (`src/Surface.zig:2181-2220`). Ghostty's host converts to AppKit bottom-left with
  `frame.size.height - y` (`SurfaceView_AppKit.swift:2012-2055`).

Required `NSTextInputClient` methods and their C mapping (all in
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1918-2120`):

| `NSTextInputClient` | Implementation | C call |
|---|---|---|
| `hasMarkedText()` | `markedText.length > 0` | — |
| `markedRange()` | range of the local marked string | — |
| `selectedRange()` | reads the terminal selection | `ghostty_surface_read_selection` (`:1929-1940`) |
| `setMarkedText(_:selectedRange:replacementRange:)` | stores marked text; if not inside `keyDown`, sync preedit | `ghostty_surface_preedit` via `syncPreedit()` (`:1942-1961`, `:2130-2150`) |
| `unmarkText()` | clears marked text | `ghostty_surface_preedit(surface, nil, 0)` (`:1963-1968`) |
| `validAttributesForMarkedText()` | `[]` | — |
| `attributedSubstring(forProposedRange:actualRange:)` | returns selection as attributed string | `ghostty_surface_read_selection` (`:1974-2010`) |
| `firstRect(forCharacterRange:actualRange:)` | IME candidate window anchor | `ghostty_surface_ime_point` (and `read_selection` for QuickLook) (`:2012-2055`) |
| `insertText(_:replacementRange:)` | committed text | `committedTextAction` → `ghostty_surface_key` with `text`, `keycode=0`, `mods=NONE` (`:2070-2107`, `:1511-1530`) |
| `doCommand(by:)` | swallows unhandled selectors (prevents beep) and re-sends command-key events | `NSApp.sendEvent` (`:2109-2118`) |

The `keyDown` flow (`SurfaceView_AppKit.swift:1101-1271`) is the subtle part:

1. Compute translation mods via `ghostty_surface_key_translation_mods`, rebuild the
   event if changed (reuse if identical).
2. `keyTextAccumulator = []`, then `interpretKeyEvents([translationEvent])`.
3. `syncPreedit(clearIfNeeded:)` pushes `markedText` to `ghostty_surface_preedit`.
4. `composing = markedText.length > 0 || markedTextBefore`.
5. If `interpretKeyEvents` produced committed text (`insertText` appended to the
   accumulator), send each string through `keyAction(..., text:)`; otherwise send
   the raw key with `translationEvent.ghosttyCharacters`.

If you don't need IME you can skip `NSTextInputClient` and send
`ghostty_surface_key` directly, but then dead keys, dictation, and CJK input break.

### 3.3 Mouse

Declarations (`include/ghostty.h:1206-1219`), verbatim:

```c
GHOSTTY_API bool ghostty_surface_mouse_captured(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_mouse_button(ghostty_surface_t,
                                                 ghostty_input_mouse_state_e,
                                                 ghostty_input_mouse_button_e,
                                                 ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_pos(ghostty_surface_t,
                                              double,
                                              double,
                                              ghostty_input_mods_e);
GHOSTTY_API void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                                 double,
                                                 double,
                                                 ghostty_input_scroll_mods_t);
GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);
```

Enums (`include/ghostty.h:128-156`):

```c
typedef enum {
  GHOSTTY_MOUSE_RELEASE,
  GHOSTTY_MOUSE_PRESS,
} ghostty_input_mouse_state_e;

typedef enum {
  GHOSTTY_MOUSE_UNKNOWN,
  GHOSTTY_MOUSE_LEFT,
  GHOSTTY_MOUSE_RIGHT,
  GHOSTTY_MOUSE_MIDDLE,
  GHOSTTY_MOUSE_FOUR,
  ... GHOSTTY_MOUSE_ELEVEN,
} ghostty_input_mouse_button_e;

typedef enum {
  GHOSTTY_MOUSE_MOMENTUM_NONE,
  GHOSTTY_MOUSE_MOMENTUM_BEGAN,
  GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
  GHOSTTY_MOUSE_MOMENTUM_CHANGED,
  GHOSTTY_MOUSE_MOMENTUM_ENDED,
  GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
  GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
} ghostty_input_mouse_momentum_e;
```

- `ghostty_surface_mouse_captured` — true when the program enabled mouse
  reporting (`src/apprt/embedded.zig:2088-2091`). Host use: suppress the context
  menu (`SurfaceView_AppKit.swift:1561-1590`) and override cursor handling.
- `ghostty_surface_mouse_button` — returns true if consumed. Use
  `GHOSTTY_MOUSE_PRESS`/`RELEASE` and the button enum. Ghostty's host maps
  `NSEvent.buttonNumber` as `0=left, 1=right, 2=middle, 3=eight(back),
  4=nine(forward), ...` (`Ghostty.Input.swift:480-492`). Right-click checks the
  return value before showing the menu (`SurfaceView_AppKit.swift:970-1000`).
- `ghostty_surface_mouse_pos(surface, x, y, mods)` — **points, top-left origin**
  (`(0,0)` = top-left of the view). Ghostty's host sends
  `(pos.x, frame.height - pos.y)`; on exit it sends `(-1, -1)` to mark "outside
  the viewport" (`SurfaceView_AppKit.swift:902-1057`). The core multiplies by the
  content scale and ignores sub-pixel no-op moves
  (`src/apprt/embedded.zig:1085-1120`).
- `ghostty_surface_mouse_scroll(surface, x, y, scroll_mods)` — `x`/`y` units
  (`src/Surface.zig:3559-3630`):
  - If the packed `scroll_mods` has `precision = 1`, `y` is **pixels to scroll**.
  - If `precision = 0`, `y` is **wheel ticks** (fractional allowed); on macOS the
    core clamps the magnitude to at least `1` and multiplies by cell height, then
    by `mouse-scroll-multiplier` (`src/Surface.zig:3568-3588`).
  - `x` is used the same way but only for precise scrolls; non-precise `x` is
    rounded directly to a cell delta (`src/Surface.zig:3612-3630`).
  - `ghostty_input_scroll_mods_t` is a packed `u8`
    (`include/ghostty.h:166`); bit 0 = precision, bits 1-3 = momentum, bits
    4-7 padding (`src/input/mouse.zig:88-99`). Ghostty's host builds it with
    `precision` from `event.hasPreciseScrollingDeltas` and momentum from
    `event.momentumPhase`, and doubles `scrollingDeltaX/Y` for precise scrolls
    (`SurfaceView_AppKit.swift:1058-1079`, `Ghostty.Input.swift:523-553`).
- `ghostty_surface_mouse_pressure(surface, stage, pressure)` — `stage` is
  `0=none, 1=normal, 2=deep` (`src/input/mouse.zig:75-86`). Deep press while the
  left button is down selects the word (`src/Surface.zig:4556-4600`). Ghostty's
  host forwards `event.stage`/`event.pressure` and uses stage 2 for QuickLook
  (`SurfaceView_AppKit.swift:1081-1099`).

**`MOUSE_SHAPE` → `NSCursor`.** `ghostty_action_mouse_shape_e` is at
`include/ghostty.h:739-774`. Ghostty's host maps it in `setCursorShape`
(`SurfaceView_AppKit.swift:509-556`) to a `CursorStyle`, whose `NSCursor` mapping
is the function you want (`macos/Sources/Helpers/Cursor.swift:59-117`):

```swift
extension CursorStyle {
    var cursor: NSCursor {
        switch self {
        case .default: return .arrow
        case .grabIdle: return .openHand
        case .grabActive: return .closedHand
        case .horizontalText: return .iBeam
        case .verticalText: return .iBeamCursorForVerticalLayout
        case .link: return .pointingHand
        case .resizeLeft:  // macOS 15+: .columnResize(directions: .left), else .resizeLeft
        case .resizeRight: // macOS 15+: .columnResize(directions: .right)
        case .resizeUp:    // macOS 15+: .rowResize(directions: .up)
        case .resizeDown:  // macOS 15+: .rowResize(directions: .down)
        case .resizeUpDown: // macOS 15+: .rowResize
        case .resizeLeftRight: // macOS 15+: .columnResize
        case .contextMenu: return .contextualMenu
        case .crosshair: return .crosshair
        case .operationNotAllowed: return .operationNotAllowed
        }
    }
}
```

`setCursorShape` handles only: DEFAULT, TEXT, GRAB, GRABBING, POINTER, W/E/N/S/NS/EW
RESIZE, VERTICAL_TEXT, CONTEXT_MENU, CROSSHAIR, NOT_ALLOWED; everything else is
ignored (`SurfaceView_AppKit.swift:509-556`). `MOUSE_VISIBILITY` maps to
`NSCursor.setHiddenUntilMouseMoves(!visible)` (`SurfaceView_AppKit.swift:562-568`).
For a plain AppKit host, apply the cursor in `cursorUpdate`/`mouseMoved` with
`cursor.set()`, or override `resetCursorRects`.

### 3.4 Selection and clipboard

Declarations (`include/ghostty.h:1230-1241`), verbatim:

```c
GHOSTTY_API void ghostty_surface_complete_clipboard_request(
    ghostty_surface_t,
    const ghostty_clipboard_complete_s*,
    void*);
GHOSTTY_API void ghostty_surface_deny_clipboard_request(ghostty_surface_t,
                                                           void*);
GHOSTTY_API bool ghostty_surface_has_selection(ghostty_surface_t);
GHOSTTY_API bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);
GHOSTTY_API bool ghostty_surface_read_text(ghostty_surface_t,
                                              ghostty_selection_s,
                                              ghostty_text_s*);
GHOSTTY_API void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);
```

Payload structs (`include/ghostty.h:83-119`):

```c
typedef struct {
  const char *mime;
  const char *data;
  size_t len;
} ghostty_clipboard_content_s;

typedef struct {
  const ghostty_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  bool confirmed;
  bool remember;
} ghostty_clipboard_complete_s;

typedef struct {
  const ghostty_clipboard_content_s *contents;
  size_t contents_len;
  const char *const *available;
  size_t available_len;
  const char *name;
  bool can_remember;
} ghostty_clipboard_confirm_s;

typedef enum {
  GHOSTTY_CLIPBOARD_REQUEST_PASTE,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
  GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
  GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE,
  GHOSTTY_CLIPBOARD_REQUEST_LIST,
} ghostty_clipboard_request_e;
```

Flow:

1. The core asks for a read via `read_clipboard_cb` (§1.4). The host reads only
   the requested MIME types (`mimes`/`mimesLen`).
2. If the request is allowed by policy, the host completes it immediately:
   `ghostty_surface_complete_clipboard_request(surface, &complete, state)` with
   `confirmed=false`. Ghostty's host does exactly this
   (`Ghostty.App.swift:326-348`).
3. If confirmation is needed, the core calls `confirm_read_clipboard_cb`. The host
   must later call complete with `confirmed=true` / `remember`, or
   `ghostty_surface_deny_clipboard_request(surface, state)`
   (`Ghostty.App.swift:350-483`). The `state` pointer is invalid after either
   call (`src/apprt/embedded.zig:2258-2270`).
4. Writes arrive via `write_clipboard_cb`; if `confirm` is true, prompt first
   (`Ghostty.App.swift:484-539`).
5. Selection: `ghostty_surface_read_selection(surface, &text)` returns the current
   user selection; `ghostty_surface_has_selection` reports whether one exists.
   Copy is host-side: read selection, put `text.text` on the pasteboard, then
   `ghostty_surface_free_text`. Paste is host-side: put pasteboard text into
   `ghostty_surface_text` (paste semantics, bracketed paste honored), or trigger
   the `paste_from_clipboard` binding via `ghostty_surface_binding_action`
   (`src/Surface.zig:5181-5184`). Ghostty's context menu uses the binding-action
   route (`SurfaceView_AppKit.swift:1561-1760`).

---

## 4. Reading terminal content back (snapshot/restore)

### 4.1 `ghostty_text_s` and `ghostty_surface_read_text`

`ghostty_text_s` (`include/ghostty.h:449-456`), verbatim:

```c
typedef struct {
  double tl_px_x;
  double tl_px_y;
  uint32_t offset_start;
  uint32_t offset_len;
  const char* text;
  uintptr_t text_len;
} ghostty_text_s;
```

Field semantics from `src/Surface.zig:1958-1992` and `2008-2118`:

| field | meaning |
|---|---|
| `text` | allocated, **NUL-terminated UTF-8** (`[:0]const u8`). **Plain text only — no colors/styles.** |
| `text_len` | byte length excluding the NUL |
| `tl_px_x`, `tl_px_y` | top-left of the selection in **points, top-left origin**, only when visible in the viewport; otherwise the viewport block is null and these are `-1` |
| `offset_start`, `offset_len` | **cell offsets in the flattened viewport** (`y * cols + x`), not bytes/codepoints; documented as possibly wrong for partially-visible selections (`Surface.zig:1971-1982`) |

`ghostty_selection_s` / `ghostty_point_s` (`include/ghostty.h:458-482`), verbatim:

```c
typedef enum {
  GHOSTTY_POINT_ACTIVE,
  GHOSTTY_POINT_VIEWPORT,
  GHOSTTY_POINT_SCREEN,
  GHOSTTY_POINT_SURFACE,
} ghostty_point_tag_e;

typedef enum {
  GHOSTTY_POINT_COORD_EXACT,
  GHOSTTY_POINT_COORD_TOP_LEFT,
  GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
} ghostty_point_coord_e;

typedef struct {
  ghostty_point_tag_e tag;
  ghostty_point_coord_e coord;
  uint32_t x;
  uint32_t y;
} ghostty_point_s;

typedef struct {
  ghostty_point_s top_left;
  ghostty_point_s bottom_right;
  bool rectangle;
} ghostty_selection_s;
```

**The `kind` argument you asked about does not exist.** NOT FOUND. The closest
thing is `ghostty_point_s.tag`, which selects the coordinate space
(`src/terminal/point.zig:10-46`):

- `ACTIVE` — the editable area (cursor-addressable region).
- `VIEWPORT` — the currently visible rows.
- `SCREEN` — **the whole written screen including scrollback** (from the furthest
  back history to the last written row).
- `SURFACE` — internally named **`history`**; the scrollback region only, i.e.
  everything before the active area.

`[runtime]` probe confirmed the name/value mismatch:

```
RESULT point tag: GHOSTTY_POINT_ACTIVE=0 active=0 VIEWPORT=1 viewport=1 SCREEN=2 screen=2 SURFACE=3 history=3
```

So `GHOSTTY_POINT_SURFACE` is *not* "the surface", it is the history/scrollback
region. For a full snapshot (scrollback + screen), use `SCREEN` + `TOP_LEFT` to
`SCREEN` + `BOTTOM_RIGHT`, exactly as Ghostty's host does
(`SurfaceView_AppKit.swift:254-273`):

```swift
var text = ghostty_text_s()
let sel = ghostty_selection_s(
    top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN,
                              coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
    bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN,
                                  coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
    rectangle: false)
guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
defer { ghostty_surface_free_text(surface, &text) }
return String(cString: text.text)
```

Freeing: `ghostty_surface_free_text(surface, &text)` calls the Zig `Text.deinit`,
which frees `text[0..text_len :0]` (`src/apprt/embedded.zig:1939-1941`,
`src/apprt/embedded.zig:1558-1569`). **Never `free()` the pointer yourself.**

Encoding: the text is the terminal's UTF-8 selection string with
`trim = false` (`src/Surface.zig:2014-2017`). It is linearized from the selection
rectangle; cells are concatenated row-major, so cursor-position data is lost.

### 4.2 Styled cells, and writing text back — what is and is not possible

**Can `ghostty_text_s` give styled cells (colors)?** **No.** NOT POSSIBLE with
this API. `dumpTextLocked` calls `selectionString(alloc, .{ .sel = sel, .trim = false })`
and returns one UTF-8 buffer (`src/Surface.zig:2008-2018`). There is no style
side-channel in `ghostty_text_s`. `[source]`

**Is there a feed/input API that does not go through the child's stdin?** In
`include/ghostty.h`: **no.** NOT FOUND. The closest functions and what they
actually do:

- `initial_input` (surface config) — queued to the **child's stdin** after it
  starts (`src/apprt/embedded.zig:583-600`, `src/termio/Termio.zig:347-405`).
- `ghostty_surface_text` — paste into the running program (PTY), not the emulator
  (`src/Surface.zig:3386-3392`).
- `ghostty_surface_key` — encodes key events to the PTY.
- There is no `ghostty_surface_feed`, no `ghostty_surface_vt_write`, and no way to
  hand a surface a stream of escape sequences. `grep -n "feed" include/ghostty.h`
  returns nothing.

So a faithful "restore scrollback" is **not possible through the surface API**:
you can save plain text with `ghostty_surface_read_text` and later write it back
only as paste/input to a fresh shell, which re-executes nothing but also preserves
no styles, cursor, or screen state.

**What does exist:** the separate `libghostty-vt` library
(`include/ghostty/vt.h`, `include/ghostty/vt/*.h`) has a real terminal model with
`ghostty_terminal_vt_write` (`include/ghostty/vt/terminal.h:2240`) and snapshot
encode/decode (`ghostty_snapshot_encode`, `ghostty_snapshot_decoder_*`,
`include/ghostty/vt/snapshot.h:284-556`), plus styled export via the formatter
(`ghostty_formatter_*`, `include/ghostty/vt/formatter.h:135-226`). **But it is a
different artifact and a different terminal instance.** The internal
`src/main_c.zig` does not export the vt API (`src/main_c.zig:31-47` force-references
only the config/apprt/benchmark C APIs), and there is no function anywhere in
`include/ghostty.h` to obtain a `GhosttyTerminal` from a `ghostty_surface_t`. So
you cannot snapshot a live surface's styled state, and you cannot attach a vt
terminal to a surface. If you need styled persistence, the realistic options are
(1) plain text + re-render yourself, (2) parse the VT stream yourself while
piping the child, or (3) use `libghostty-vt` standalone instead of the surface
API.

---

## 5. Action callback

`ghostty_action_s` (`include/ghostty.h:1065-1068`):

```c
typedef struct {
  ghostty_action_tag_e tag;
  ghostty_action_u action;
} ghostty_action_s;
```

`ghostty_action_u` (`include/ghostty.h:1021-1063`) is the payload union; in C you
read members directly, e.g. `action.action.set_title.title`. In Swift (as the
host does) it imports as a struct with properties. **Payloads with no member in
the union are payload-less** (the union is not zeroed; do not read `action` for
those tags): `QUIT`, `NEW_WINDOW`, `NEW_TAB`, `CLOSE_TAB` (uses
`close_tab_mode`), `CLOSE_ALL_WINDOWS`, `TOGGLE_*`, `EQUALIZE_SPLITS`,
`RESET_WINDOW_SIZE`, `RENDER`, `INSPECTOR` (uses payload), `RENDER_INSPECTOR`,
`OPEN_CONFIG` (uses payload), `CLOSE_WINDOW`, `RING_BELL`, `SELECTION_CHANGED`,
`UNDO`, `REDO`, `CHECK_FOR_UPDATES`, `SHOW_ON_SCREEN_KEYBOARD`, `END_SEARCH`,
`COPY_TITLE_TO_CLIPBOARD`, `MOVE_TAB_TO_NEW_WINDOW`.

Full tag list (`include/ghostty.h:948-1019`), verbatim values and line numbers:

```c
GHOSTTY_ACTION_QUIT,                    // 949
GHOSTTY_ACTION_NEW_WINDOW,              // 950
GHOSTTY_ACTION_NEW_TAB,                 // 951
GHOSTTY_ACTION_CLOSE_TAB,               // 952
GHOSTTY_ACTION_NEW_SPLIT,               // 953
GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,       // 954
GHOSTTY_ACTION_TOGGLE_MAXIMIZE,         // 955
GHOSTTY_ACTION_TOGGLE_FULLSCREEN,       // 956
GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,     // 957
GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,// 958
GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,   // 959
GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,  // 960
GHOSTTY_ACTION_TOGGLE_VISIBILITY,       // 961
GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,// 962
GHOSTTY_ACTION_MOVE_TAB,                // 963
GHOSTTY_ACTION_GOTO_TAB,                // 964
GHOSTTY_ACTION_GOTO_SPLIT,              // 965
GHOSTTY_ACTION_GOTO_WINDOW,             // 966
GHOSTTY_ACTION_RESIZE_SPLIT,            // 967
GHOSTTY_ACTION_EQUALIZE_SPLITS,         // 968
GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,       // 969
GHOSTTY_ACTION_PRESENT_TERMINAL,        // 970
GHOSTTY_ACTION_SIZE_LIMIT,              // 971
GHOSTTY_ACTION_RESET_WINDOW_SIZE,       // 972
GHOSTTY_ACTION_INITIAL_SIZE,            // 973
GHOSTTY_ACTION_CELL_SIZE,               // 974
GHOSTTY_ACTION_SCROLLBAR,               // 975
GHOSTTY_ACTION_RENDER,                  // 976
GHOSTTY_ACTION_INSPECTOR,               // 977
GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,      // 978
GHOSTTY_ACTION_RENDER_INSPECTOR,        // 979
GHOSTTY_ACTION_EXPORT_TERMINAL_IO,      // 980
GHOSTTY_ACTION_DESKTOP_NOTIFICATION,    // 981
GHOSTTY_ACTION_SET_TITLE,               // 982
GHOSTTY_ACTION_SET_TAB_TITLE,           // 983
GHOSTTY_ACTION_SET_WINDOW_TITLE,        // 984
GHOSTTY_ACTION_PROMPT_TITLE,            // 985
GHOSTTY_ACTION_PWD,                     // 986
GHOSTTY_ACTION_MOUSE_SHAPE,             // 987
GHOSTTY_ACTION_MOUSE_VISIBILITY,        // 988
GHOSTTY_ACTION_MOUSE_OVER_LINK,         // 989
GHOSTTY_ACTION_RENDERER_HEALTH,         // 990
GHOSTTY_ACTION_OPEN_CONFIG,             // 991
GHOSTTY_ACTION_QUIT_TIMER,              // 992
GHOSTTY_ACTION_FLOAT_WINDOW,            // 993
GHOSTTY_ACTION_SECURE_INPUT,            // 994
GHOSTTY_ACTION_KEY_SEQUENCE,            // 995
GHOSTTY_ACTION_KEY_TABLE,               // 996
GHOSTTY_ACTION_COLOR_CHANGE,            // 997
GHOSTTY_ACTION_RELOAD_CONFIG,           // 998
GHOSTTY_ACTION_CONFIG_CHANGE,           // 999
GHOSTTY_ACTION_CLOSE_WINDOW,            // 1000
GHOSTTY_ACTION_RING_BELL,               // 1001
GHOSTTY_ACTION_SELECTION_CHANGED,       // 1002
GHOSTTY_ACTION_UNDO,                    // 1003
GHOSTTY_ACTION_REDO,                    // 1004
GHOSTTY_ACTION_CHECK_FOR_UPDATES,       // 1005
GHOSTTY_ACTION_OPEN_URL,                // 1006
GHOSTTY_ACTION_SHOW_CHILD_EXITED,       // 1007
GHOSTTY_ACTION_PROGRESS_REPORT,         // 1008
GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD, // 1009
GHOSTTY_ACTION_COMMAND_FINISHED,        // 1010
GHOSTTY_ACTION_START_SEARCH,            // 1011
GHOSTTY_ACTION_END_SEARCH,              // 1012
GHOSTTY_ACTION_SEARCH_TOTAL,            // 1013
GHOSTTY_ACTION_SEARCH_SELECTED,         // 1014
GHOSTTY_ACTION_READONLY,                // 1015
GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD, // 1016
GHOSTTY_ACTION_MOVE_TAB_TO_NEW_WINDOW,  // 1017
GHOSTTY_ACTION_RESIZE_WINDOW,           // 1018
```

`[runtime]` probe: `action count zig=70`, last tag `GHOSTTY_ACTION_RESIZE_WINDOW=69`,
i.e. the header and the core's `apprt.Action.Key` are 1:1.

Targets (`include/ghostty.h:596-608`):

```c
typedef enum {
  GHOSTTY_TARGET_APP,
  GHOSTTY_TARGET_SURFACE,
} ghostty_target_tag_e;

typedef union {
  ghostty_surface_t surface;
} ghostty_target_u;

typedef struct {
  ghostty_target_tag_e tag;
  ghostty_target_u target;
} ghostty_target_s;
```

For `GHOSTTY_TARGET_SURFACE`, `target.target.surface` is the surface; the host
resolves its own view via `ghostty_surface_userdata(surface)`
(`Ghostty.App.swift:580-585`). Return `true` if handled; returning `false` is
logged by the core for some actions and may trigger fallbacks (e.g. OSC 8 URLs,
`Ghostty.App.swift:855-858`).

### 5.1 Required/expected payloads, with exact accessor patterns

All host-side accessors below are quoted from Ghostty's own dispatcher
(`macos/Sources/Ghostty/Ghostty.App.swift:587-794`); use the same pattern.

**Title — `SET_TITLE`, `SET_TAB_TITLE`, `SET_WINDOW_TITLE`** (`ghostty_action_set_title_s`,
`include/ghostty.h:714-716`: `const char* title;`). Borrowed NUL-terminated
string, copy it (`Ghostty.App.swift:1811-1830`):

```swift
case GHOSTTY_ACTION_SET_TITLE:
    setTitle(app, target: target, v: action.action.set_title)
...
guard let title = String(cString: v.title!, encoding: .utf8) else { return }
surfaceView.setTitle(title)
```

**PWD** (`ghostty_action_pwd_s`, `include/ghostty.h:726-728`: `const char* pwd;`)
— `action.action.pwd.pwd`, copied (`Ghostty.App.swift:1945-1964`). Used for
working-directory inheritance on new surfaces.

**RENDER** (`include/ghostty.h:976`) — no payload. Not handled by Ghostty's host
(§2.3). Optionally call `ghostty_surface_draw(target.target.surface)`.

**MOUSE_SHAPE** (`include/ghostty.h:987`, payload
`ghostty_action_mouse_shape_e`) — `action.action.mouse_shape`; see §3.3
(`Ghostty.App.swift:1965-1983`).

**CLOSE_WINDOW** (`include/ghostty.h:1000`) / **CLOSE_TAB** (payload
`ghostty_action_close_tab_mode_e`, `include/ghostty.h:888-892`) — close the
window/tab; CLOSE_TAB mode is THIS/OTHER/RIGHT
(`Ghostty.App.swift:1040-1100`).

**There is no `GHOSTTY_ACTION_CLOSE_SURFACE`.** NOT FOUND. A single surface is
closed through the runtime `close_surface_cb` (optional, §1.4) — and the host
must then call `ghostty_surface_free` itself. `CLOSE_WINDOW`/`CLOSE_TAB` are the
host-level window/tab actions.

**Child exited — `SHOW_CHILD_EXITED`** (payload `ghostty_surface_message_childexited_s`,
`include/ghostty.h:895-898`):

```c
typedef struct {
  uint32_t exit_code;
  uint64_t timetime_ms;
} ghostty_surface_message_childexited_s;
```

Access `action.action.child_exited.exit_code` and `.timetime_ms`. `timetime_ms`
is the child runtime in milliseconds. Ghostty's host ignores it when
`timetime_ms == 0` (launch failures) and shows a message otherwise
(`Ghostty.App.swift:1858-1875`). Note the misspelled field name `timetime_ms` is
what is actually in the header.

**Cell size — `CELL_SIZE`** (`ghostty_action_cell_size_s`,
`include/ghostty.h:809-812`): `action.action.cell_size.width/height`, in **pixels**
(`src/Surface.zig` `setCellSize`). Ghostty's host converts to points with
`convertFromBacking` and stores it for window resize stepping
(`Ghostty.App.swift:2101-2120`).

**Size limits — `SIZE_LIMIT`** (`ghostty_action_size_limit_s`,
`include/ghostty.h:789-794`): `min_width`, `min_height`, `max_width`,
`max_height` in pixels (0 = no limit). Use for `NSWindow.contentMinSize` etc.

**Initial size — `INITIAL_SIZE`** (`ghostty_action_initial_size_s`,
`include/ghostty.h:797-800`): `width`, `height` in pixels
(`Ghostty.App.swift:2037-2050`).

**Bell — `RING_BELL`** (`include/ghostty.h:1001`) — no payload. The core
rate-limits bells to 100 ms (`src/Surface.zig:1130-1145`). The macOS host posts a
notification and flashes state (`Ghostty.App.swift:1186-1207`). "Needs attention"
is host-defined; combine this with `DESKTOP_NOTIFICATION`
(`ghostty_action_desktop_notification_s`, `include/ghostty.h:708-711`:
`title`/`body`, both NUL-terminated) and `COMMAND_FINISHED`
(`include/ghostty.h:918-923`: `exit_code` = `-1` if unknown, `duration` in ns)
(`Ghostty.App.swift:1634-1700`).

**Open URL — `OPEN_URL`** (`ghostty_action_open_url_s`,
`include/ghostty.h:881-885`): `kind` (`UNKNOWN/TEXT/HTML/OSC8`,
`include/ghostty.h:873-878`), `url` + `len` (NOT necessarily NUL-terminated).
Ghostty's host copies `Data(bytes: url, count: len)` and opens it, with a separate
untrusted policy for `OSC8` (`Ghostty.App.swift:809-870`).

**Config change — `CONFIG_CHANGE`** (`ghostty_action_config_change_s`,
`include/ghostty.h:863-865`: `ghostty_config_t config;`). The config is
**borrowed**; clone it if you need it after the callback
(`Ghostty.App.swift:2414-2430`):

```swift
// Clone the config so we own the memory. It'd be nicer to not have to do
// this but since we async send the config out below we have to own the lifetime.
let config = Config(clone: v.config)
```

**Reload config — `RELOAD_CONFIG`** (`ghostty_action_reload_config_s`,
`include/ghostty.h:868-870`: `bool soft;`). Soft = re-apply the existing config;
hard = re-read from disk, then `ghostty_app_update_config` /
`ghostty_surface_update_config` (`Ghostty.App.swift:2391-2414`).

**Progress — `PROGRESS_REPORT`** (`ghostty_action_progress_report_s`,
`include/ghostty.h:910-915`): `state` (REMOVE/SET/ERROR/INDETERMINATE/PAUSE,
`include/ghostty.h:901-907`) and `progress` (`-1` = unknown, else 0-100). The
macOS host gates it on `progress-style` and auto-clears after 15 s
(`Ghostty.App.swift:2229-2264`, `SurfaceView_AppKit.swift:34-49`).

**Also worth handling:** `SCROLLBAR` (`total/offset/len`, `include/ghostty.h:941-945`),
`COLOR_CHANGE` (`kind` foreground/background/cursor/palette + rgb,
`include/ghostty.h:848-860`), `READONLY` (`include/ghostty.h:702-705`),
`DESKTOP_NOTIFICATION`, `MOUSE_VISIBILITY`, `MOUSE_OVER_LINK` (`url` + `len`),
`KEY_SEQUENCE`/`KEY_TABLE` (keybind UX), `RENDERER_HEALTH`
(`HEALTHY`/`UNHEALTHY`), `UNDO`/`REDO`, `QUIT`.

---

## 6. Config-driven behaviour

### 6.1 Loading the user's real config

Use `ghostty_config_load_default_files` (and `ghostty_config_load_recursive_files`)
exactly as in §1.2. Fonts, themes, palette, ligatures, keybinds, scrollback, and
rendering behavior are all applied by the core from the finalized config; the host
does not need to read them. Ghostty's host only reads a handful of values for its
own chrome (background color/opacity, scrollbar style, progress style, etc. —
`Ghostty.Config.swift:130-732`), all via `ghostty_config_get`.

For your app, the important `ghostty_config_get` keys and their C storage are in
§1.3. Do **not** try to read `font-family` or `cursor-color`; both return false
(runtime-verified).

### 6.2 Per-node overrides

There is **no `ghostty_config_set`**. NOT FOUND. Two mechanisms exist:

1. **Surface-config fields** (best for working directory, command, env, initial
   font size): `ghostty_surface_config_s.working_directory`, `.command`,
   `.env_vars`, `.font_size`, `.initial_input` (§2.1). These are per surface and
   do not mutate the shared config.
2. **A per-node config object**: clone the app config, load a small override file,
   finalize, and hand it to `ghostty_surface_update_config` (or pass it to
   `ghostty_app_update_config` for global changes). Later `load_file` wins over
   earlier values — `[runtime]`-verified (§1.3). Pattern:

   ```c
   ghostty_config_t node = ghostty_config_clone(app_config);
   ghostty_config_load_file(node, "/tmp/pi-canvas-node-42.conf"); // "font-size = 18"
   ghostty_config_finalize(node);
   ghostty_surface_update_config(surface, node);   // surface copies; main thread
   ghostty_config_free(node);
   ```

   The surface derives its own copy, so freeing `node` after the call is safe
   (`src/Surface.zig:1770-1797`).

If you need the node's working directory / command / font size, prefer mechanism 1;
use 2 only for values with no surface-config field (e.g. `font-family`,
`background-opacity`, `cursor-style`).

### 6.3 Changing font size at runtime (canvas zoom)

Ghostty's host uses **binding actions** (`Ghostty.App.swift:234-251`):

```swift
enum FontSizeModification { case increase(Int), decrease(Int), reset }

func changeFontSize(surface: ghostty_surface_t, _ change: FontSizeModification) {
    let action: String
    switch change {
    case .increase(let amount): action = "increase_font_size:\(amount)"
    case .decrease(let amount): action = "decrease_font_size:\(amount)"
    case .reset:                action = "reset_font_size"
    }
    if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
        logger.warning("action failed action=\(action, privacy: .public)")
    }
}
```

For canvas zoom you want an exact size, which is also supported even though the
macOS host does not use it: `set_font_size:<points>` (e.g. `"set_font_size:13.5"`).
Parsing is in `src/input/Binding.zig:403-407`; the core clamps points to
`[1, 255]` and marks the size as manually adjusted (`src/Surface.zig:5231-5243`).
Increase/decrease clamp the same way (`src/Surface.zig:5191-5218`), and
`reset_font_size` restores `config.original_font_size` (`src/Surface.zig:5220-5229`).

```c
const char *action = "set_font_size:13.5";
ghostty_surface_binding_action(surface, action, strlen(action)); // main thread
```

`ghostty_surface_binding_action` returns `false` for an unparseable action
(`src/apprt/embedded.zig:2249-2263`). Manual font sizes survive config reloads:
`setFontSize` sets `font_size_adjusted = true`, and `Surface.zig:1820-1833` keeps
the adjusted size on reload. So if the canvas zoom uses `set_font_size`, a later
`ghostty_app_update_config` will not stomp it.

Alternative for exact sizes that also reflows correctly: recreate the surface with
`font_size` set in the surface config. Do **not** mutate the shared config's
`font-size` for one node.

### 6.4 Rendering behaviour the host must respect

- `background-opacity < 1` requires the host to make the window/layer background
  transparent for the effect to show. Ghostty's macOS host reads
  `background-opacity` (`Ghostty.Config.swift:474-483`) and does its own window
  transparency. The core also exposes `ghostty_set_window_background_blur(app,
  ns_window)` (`include/ghostty.h:1277`, Darwin-only, uses private CGS APIs,
  `src/apprt/embedded.zig:2388-2404`).
- `background-blur` is read via `ghostty_config_get` as an `int16_t`
  (0 disabled, >0 radius, -1/-2 macOS 26 glass; `Ghostty.Config.swift:753-800`).
- `vsync` controls the CVDisplayLink; you do not need to manage it.
- `macos-option-as-alt` changes key translation — use
  `ghostty_surface_key_translation_mods`.
- `mouse-hide-while-typing` produces `MOUSE_VISIBILITY` actions.
- `confirm-close-surface` changes the `close_surface_cb` bool (see §1.4).
- `window-inherit-font-size` / `*-inherit-working-directory` change what
  `ghostty_surface_inherited_config` returns (§2.2).
- `macos-titlebar-style`, `window-theme`, etc. are macOS-app chrome; a custom host
  can ignore them or read them for its own chrome.

---

## 7. Gotchas

### Top 10, ranked by likelihood of biting this host

1. **You must not create the layer.** libghostty installs its own
   `IOSurfaceLayer` on the NSView you pass and sets `wantsLayer = true` itself
   (`src/renderer/Metal.zig:107-149`). A host `CAMetalLayer`, `wantsLayer = true`,
   or a `draw(_:)` override fights the renderer. Pass a plain `NSView`.
2. **Building libghostty needs Xcode's Metal toolchain.** CLT-only fails with
   `xcrun: error: unable to find utility "metal"`; shaders are compiled at build
   time and embedded (`src/build/MetallibStep.zig:38-60`,
   `src/build/SharedDeps.zig:503-507`). Get Xcode 26+ or a prebuilt framework.
3. **Threading.** `wakeup_cb` arrives on any thread; tick on main; treat
   `action_cb` as main-thread; surface create/free and font-size changes are
   main-thread-only (`src/Surface.zig:472`, `2495`; `src/App.zig:161-163`).
4. **Teardown order and unretained userdata.** `ghostty_surface_free` every
   surface before `ghostty_app_free`; the NSView/userdata must outlive the
   surface; `close_surface_cb` does not free anything.
5. **`ghostty_config_get` type widths and gaps.** `font-family` and
   `cursor-color` return `false`; `u8`/`u32` need a 4-byte `unsigned int`; `i16`
   needs `short`; `font-size` is `float` (runtime-verified).
6. **Borrowed pointers in callbacks.** Title/pwd/open-url/clipboard/`CONFIG_CHANGE`
   data is only valid during the callback; copy immediately and clone configs.
7. **`close_surface_cb`'s bool means `needsConfirmQuit`**, not "process alive"
   (`src/Surface.zig:849-851`), and the host must free the surface afterwards.
8. **`command` is a `/bin/sh -c` string, not argv; `initial_input` goes to the
   child's stdin, not the emulator; there is no feed API** (`src/apprt/embedded.zig:470-489`).
9. **`GHOSTTY_POINT_SURFACE` is internal `history` (scrollback only), and
   `read_text` is plain text with cell offsets** (runtime-verified;
   `src/Surface.zig:1971-1982`).
10. **Units:** `set_size` is backing pixels, `mouse_pos`/`ime_point` are points
    with top-left origin, `set_content_scale` is a scale factor clamped to `>= 1`.

### 7.1 Threading

- `wakeup_cb` is called from **any thread** (`src/App.zig:583-593`); schedule
  `ghostty_app_tick` on the main thread. `Ghostty.App.swift:540-548` is the
  canonical implementation.
- `ghostty_app_tick` runs `action_cb` and the surface message handlers. Call it on
  main so UI mutation in `action_cb` is safe (`src/apprt/surface.zig:187-207`,
  `src/App.zig:265-298`, `src/Surface.zig:983`).
- Host-initiated calls (`ghostty_surface_key`, `ghostty_surface_binding_action`,
  `ghostty_surface_request_close`, `ghostty_app_update_config`, mouse, clipboard
  completion) fire `action_cb` synchronously on the caller's thread. Keep those
  calls on main.
- `ghostty_surface_new` and `Surface.setFontSize` are documented main-thread only
  (`src/Surface.zig:472`, `2495`).
- `ghostty_app_update_config` is main-thread only (`src/App.zig:161-163`).
- `ghostty_surface_free` must be on main; Ghostty's wrapper hops to main if it is
  not (`Ghostty.Surface.swift:22-39`).
- Clipboard callbacks run on the tick thread (or the caller for paste bindings).
  Confirmation may complete asynchronously from the main thread later
  (`Ghostty.App.swift:350-483`).

### 7.2 Ownership/freeing

- The library owns and frees: all `ghostty_config_t` internals, `ghostty_app_t`,
  `ghostty_surface_t` (after `ghostty_surface_free`), `ghostty_string_s` returned
  from `ghostty_surface_tty_name`/`ghostty_config_open_path` (free with
  `ghostty_string_free`), and `ghostty_text_s.text` (free with
  `ghostty_surface_free_text`).
- The host owns: its `ghostty_config_t` (free with `ghostty_config_free`), its
  `ghostty_runtime_config_s` (a stack temporary is fine), its userdata, and every
  C string it passes in.
- Callback pointers are **borrowed for the duration of the callback** unless
  stated otherwise: `set_title.title`, `pwd.pwd`, `open_url.url` (+len),
  `mouse_over_link.url` (+len), `desktop_notification.title/body`,
  `key_table` names, and all clipboard contents in `confirm_read_clipboard_cb`.
  Copy immediately.
- `CONFIG_CHANGE.config` is borrowed; clone it (`Ghostty.App.swift:2417-2421`).
- The `state` pointer from `read_clipboard_cb` is library-owned; it is freed after
  the callback unless you returned `STARTED`, and is invalid after complete/deny
  (`src/apprt/embedded.zig:783-796`, `2258-2270`).
- `ghostty_surface_config_s` string/env pointers are only read during
  `ghostty_surface_new`.
- `ghostty_surface_inherited_config` leaks an allocated `working_directory` (no
  free API); see §2.2.

### 7.3 Teardown order

1. Stop producing input; remove your view from the window if you like.
2. `ghostty_surface_free(surface)` for **every** surface, on main. This
   synchronously joins the IO and renderer threads
   (`src/Surface.zig:800-847`). Do not free the NSView before this returns.
3. `ghostty_app_free(app)` — deinitializes any leftover surfaces and asserts the
   font grid set is empty in debug builds (`src/App.zig:132-151`).
4. `ghostty_config_free(config)`.
5. Never call any API with a freed `app`/`surface`/`config`. The runtime
   `userdata` must outlive the app (it is unretained:
   `Unmanaged.passUnretained`, `Ghostty.App.swift:59`), and the surface `userdata`
   must outlive the surface.

`ghostty_surface_request_close` / `ghostty_surface_binding_action("close_surface")`
do **not** free the surface; they notify `close_surface_cb`, and the host must
call `ghostty_surface_free` (`src/apprt/embedded.zig:2166-2175`).

### 7.4 Building without Xcode / Metal / deployment target

- **The build needs Xcode's Metal toolchain.** Verified on this machine:
  ```
  $ zig build test -Dtest-filter=ghostty_config_get
  +- metal Ghostty (Ghostty.IR) failure
  xcrun: error: unable to find utility "metal", not a developer tool or in PATH
  ```
  `src/build/MetallibStep.zig:38-60` runs `/usr/bin/xcrun -sdk macosx metal` and
  `... metallib`, and the result is embedded into the library as an anonymous
  import (`src/build/SharedDeps.zig:503-507`). There is no precompiled
  `.metallib` in the repo and no runtime shader compilation fallback. CLT-only
  (`xcode-select -p` → `/Library/Developer/CommandLineTools`) is not enough.
  Either install Xcode (HACKING.md:52-68: main-branch development requires Xcode
  26 + macOS 26 SDK; you can still build on macOS 15) or obtain a prebuilt
  `libghostty`/`GhosttyKit` xcframework.
- The default build target observed in the verbose compile line was
  `aarch64-macos.13.0`, and the Xcode project's app targets use
  `MACOSX_DEPLOYMENT_TARGET = 13.0` (`macos/Ghostty.xcodeproj/project.pbxproj:579`).
  A macOS 14 host is fine.
- `GhosttyKit` is a Clang module wrapping `include/ghostty.h`
  (`include/module.modulemap`):
  ```
  module GhosttyKit {
      umbrella header "ghostty.h"
      export *
  }
  ```
  With raw `swiftc` you need the module map discoverable (`-I <dir containing
  module.modulemap>`) and the static/shared library on `-L`/`-l`.
- `ghostty_init` must be the first call even before `NSApplicationMain`; Ghostty's
  `main.swift` does it at file scope.
- There is **no** `macos/README.md` and **no** `docs/` directory in this repo
  (`ls Vendor/ghostty` → no such files). The only build guidance is `HACKING.md`
  and `macos/AGENTS.md`; the only embedding guidance is `README.md:145-169`
  ("External embedders should use libghostty-vt" — header comment — plus the
  examples directory) and `example/README.md`. NOT FOUND: an official
  full-libghostty GUI embedding guide.

### 7.5 Other traps found in source

- `close_surface_cb`'s bool is `needsConfirmQuit()`, not process-alive
  (`src/Surface.zig:849-851`). Naming in `src/apprt/embedded.zig:678` is misleading.
- `GHOSTTY_POINT_SURFACE == internal history` (scrollback only), runtime-verified.
- `ghostty_surface_set_size` is **pixels**; `mouse_pos` and `ime_point` are
  **points** (top-left origin); `set_content_scale` takes scale factors.
- `command` is a shell string (`/bin/sh -c`), not argv.
- `initial_input` goes to the child's stdin, not the emulator.
- `ghostty_config_get` type widths: `u8`/`u32` → `unsigned int` (4 bytes),
  `i16` → `short`, `font-size` → `float`, `background-opacity` → `double`.
- `font-family` and `cursor-color` are not readable via `ghostty_config_get`
  (runtime-verified).
- `ghostty_surface_read_text` returns plain text only; `offset_start/len` are cell
  offsets, not bytes.
- The `close_surface_cb` is optional, but `wakeup`/`action`/`read`/`confirm`/
  `write` are non-nullable in Zig and will be invoked.
- `ghostty_app_update_config`/`ghostty_surface_update_config` take ownership
  **from the caller** (caller may free after return).
- `ghostty_config_load_cli_args` parses your process argv.
- `supports_selection_clipboard = false` makes selection-clipboard requests
  `UNSUPPORTED`; primary selection is never supported.
- The surface `userdata` is unretained; a freed view/userdata that a live surface
  still points at will crash callbacks. Free the surface before the view.
- `ghostty_surface_inherited_config`'s returned `working_directory` has no free
  API.

---

## 8. Minimal AppKit host skeleton

This is a shape, not a compiled artifact (no libghostty is available in this
repo). Every call is cited above. It assumes `import GhosttyKit`.

```swift
import AppKit
import GhosttyKit

final class TerminalView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    var cellSize = CGSize(width: 1, height: 1)

    // Plain NSView: libghostty installs its own IOSurfaceLayer (Metal.zig:107-149).
    override var acceptsFirstResponder: Bool { true }

    init(app: ghostty_app_t) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var cfg = ghostty_surface_config_new()
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = window?.backingScaleFactor ?? 1
        cfg.font_size = 0 // inherit
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        self.surface = ghostty_surface_new(app, &cfg) // main thread only
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        if let screen = window?.screen {
            ghostty_surface_set_display_id(surface, screen.displayID ?? 0)
        }
        updateSizeAndScale()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSizeAndScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSizeAndScale()
    }

    private func updateSizeAndScale() {
        guard let surface else { return }
        let fb = convertToBacking(bounds)
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
        if bounds.width > 0, bounds.height > 0 {
            ghostty_surface_set_content_scale(
                surface, fb.width / bounds.width, fb.height / bounds.height)
        }
        let s = ghostty_surface_size(surface)
        cellSize = CGSize(width: Double(s.cell_width_px), height: Double(s.cell_height_px))
    }

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r, let surface { ghostty_surface_set_focus(surface, true) }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r, let surface { ghostty_surface_set_focus(surface, false) }
        return r
    }

    // MARK: keyboard (see §3.1/§3.2 for the full IME path)

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }
        var key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        interpretKeyEvents([event]) // fills markedText via setMarkedText/insertText
        syncPreedit()
        if markedText.length == 0 {
            _ = ghostty_surface_key(surface, key)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_key(surface, event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE))
    }

    private func syncPreedit() {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: mouse (top-left origin, points)

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y,
                                  GhosttyMods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT,
                                         GhosttyMods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT,
                                         GhosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        // momentum: bits 1..3 (see ScrollMods)
        _ = ghostty_surface_mouse_scroll(
            surface, event.scrollingDeltaX, event.scrollingDeltaY, mods)
    }

    // MARK: NSTextInputClient stubs (implement fully per §3.2)
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(0...(markedText.length-1)) : NSRange() }
    func selectedRange() -> NSRange { NSRange() }
    func setMarkedText(_ s: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = NSMutableAttributedString(string: (s as? String) ?? "")
        syncPreedit()
    }
    func unmarkText() { markedText.setAttributedString(NSAttributedString()); syncPreedit() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange r: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for p: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange r: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        return window?.convertToScreen(convert(
            NSRect(x: x, y: bounds.height - y, width: w, height: max(h, cellSize.height)), to: nil)) ?? .zero
    }
    func insertText(_ s: Any, replacementRange: NSRange) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = 0
        key.mods = GHOSTTY_MODS_NONE
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        (s as? String ?? "").withCString { ptr in
            key.text = ptr
            _ = ghostty_surface_key(surface, key)
        }
    }
    override func doCommand(by selector: Selector) {}

    deinit { if let surface { ghostty_surface_free(surface) } } // main thread
}
```

App bootstrap (mirrors `Ghostty.App.swift:56-95` and `main.swift:8`):

```swift
// main.swift
ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

let cfg = ghostty_config_new()!
ghostty_config_load_default_files(cfg)
ghostty_config_load_recursive_files(cfg)
ghostty_config_finalize(cfg)

var rt = ghostty_runtime_config_s(
    userdata: Unmanaged.passUnretained(appState).toOpaque(),
    supports_selection_clipboard: true,
    wakeup_cb: { _ in DispatchQueue.main.async { ghostty_app_tick(appState.app) } },
    action_cb: { app, target, action in handleAction(app!, target, action) },
    read_clipboard_cb: { ud, loc, state, mimes, n, list in /* §3.4 */ },
    confirm_read_clipboard_cb: { ud, confirm, state, req in /* §3.4 */ },
    write_clipboard_cb: { ud, loc, contents, n, confirm in /* §3.4 */ },
    close_surface_cb: { ud, needsConfirm in /* ask user, then free surface */ })
let app = ghostty_app_new(&rt, cfg)!
```

---

## 9. Official embedding path (what the project actually recommends)

- `include/ghostty.h:1-8` (quoted at the top): the header you are targeting is
  explicitly **not designed for external use**; external embedders should use
  `libghostty-vt`.
- `README.md:145-169`: "we're breaking libghostty down into separate libraries,
  starting with `libghostty-vt`... `libghostty-vt` is already available and usable
  today for Zig and C... `libghostty` is already heavily in use. See `examples`...
  or the [Ghostling](https://github.com/ghostty-org/ghostling) project for a
  complete example."
- `example/` contains ~30 `libghostty-vt` C/Zig examples (render state, snapshot,
  selection, input encoding, formatter, etc.) and `example/swift-vt-xcframework/`
  for Swift. **None** of them embed the GUI apprt or an `NSView`.
- `HACKING.md:50-68`: building the macOS app requires Xcode, the macOS SDK, and
  the **Metal Toolchain**; main requires Xcode 26 / macOS 26 SDK.
- **NOT FOUND:** `macos/README.md`, a `docs/` directory, a `libghostty` embedding
  guide, a `ghostty_config_set`, a surface feed API, styled surface reads, or an
  official custom-GUI-host example.

If your goal is a canvas of many terminals with per-node zoom, the pragmatic
options are: (a) this internal API with the caveats above (it is what the real
macOS app does), or (b) `libghostty-vt` standalone, where you own rendering,
PTY, and input encoding entirely, and where snapshot/restore and styled export
actually exist.

---

## Appendix A — API index (verbatim declarations, `include/ghostty.h`)

```c
GHOSTTY_API int ghostty_init(uintptr_t, char**);                                        // :1139
GHOSTTY_API void ghostty_cli_try_action(void);                                          // :1140
GHOSTTY_API ghostty_info_s ghostty_info(void);                                          // :1141
GHOSTTY_API const char* ghostty_translate(const char*);                                 // :1142
GHOSTTY_API void ghostty_string_free(ghostty_string_s);                                 // :1143
GHOSTTY_API ghostty_config_t ghostty_config_new();                                      // :1145
GHOSTTY_API void ghostty_config_free(ghostty_config_t);                                 // :1146
GHOSTTY_API ghostty_config_t ghostty_config_clone(ghostty_config_t);                    // :1147
GHOSTTY_API void ghostty_config_load_cli_args(ghostty_config_t);                        // :1148
GHOSTTY_API void ghostty_config_load_file(ghostty_config_t, const char*);               // :1149
GHOSTTY_API void ghostty_config_load_default_files(ghostty_config_t);                   // :1150
GHOSTTY_API void ghostty_config_load_recursive_files(ghostty_config_t);                 // :1151
GHOSTTY_API void ghostty_config_finalize(ghostty_config_t);                             // :1152
GHOSTTY_API bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);   // :1153
GHOSTTY_API ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t,
                                                              const char*,
                                                              uintptr_t);                // :1154
GHOSTTY_API bool ghostty_config_key_is_binding(ghostty_config_t, ghostty_input_key_s);  // :1157
GHOSTTY_API uint32_t ghostty_config_diagnostics_count(ghostty_config_t);                // :1158
GHOSTTY_API ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t, uint32_t); // :1159
GHOSTTY_API ghostty_string_s ghostty_config_open_path(void);                            // :1160
GHOSTTY_API ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*,
                                             ghostty_config_t);                         // :1162
GHOSTTY_API void ghostty_app_free(ghostty_app_t);                                       // :1164
GHOSTTY_API void ghostty_app_tick(ghostty_app_t);                                       // :1165
GHOSTTY_API void* ghostty_app_userdata(ghostty_app_t);                                  // :1166
GHOSTTY_API void ghostty_app_set_focus(ghostty_app_t, bool);                            // :1167
GHOSTTY_API bool ghostty_app_key(ghostty_app_t, ghostty_input_key_s);                   // :1168
GHOSTTY_API void ghostty_app_keyboard_changed(ghostty_app_t);                           // :1169
GHOSTTY_API void ghostty_app_open_config(ghostty_app_t);                                // :1170
GHOSTTY_API void ghostty_app_update_config(ghostty_app_t, ghostty_config_t);            // :1171
GHOSTTY_API bool ghostty_app_needs_confirm_quit(ghostty_app_t);                         // :1172
GHOSTTY_API bool ghostty_app_has_global_keybinds(ghostty_app_t);                        // :1173
GHOSTTY_API void ghostty_app_set_color_scheme(ghostty_app_t, ghostty_color_scheme_e);   // :1174
GHOSTTY_API ghostty_surface_config_s ghostty_surface_config_new();                      // :1176
GHOSTTY_API ghostty_surface_t ghostty_surface_new(ghostty_app_t,
                                                     const ghostty_surface_config_s*);  // :1178
GHOSTTY_API void ghostty_surface_free(ghostty_surface_t);                               // :1180
GHOSTTY_API void* ghostty_surface_userdata(ghostty_surface_t);                          // :1181
GHOSTTY_API ghostty_app_t ghostty_surface_app(ghostty_surface_t);                       // :1182
GHOSTTY_API ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t, ghostty_surface_context_e); // :1183
GHOSTTY_API void ghostty_surface_update_config(ghostty_surface_t, ghostty_config_t);    // :1184
GHOSTTY_API bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);                 // :1185
GHOSTTY_API bool ghostty_surface_process_exited(ghostty_surface_t);                     // :1186
GHOSTTY_API void ghostty_surface_refresh(ghostty_surface_t);                            // :1187
GHOSTTY_API void ghostty_surface_draw(ghostty_surface_t);                               // :1188
GHOSTTY_API void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);  // :1189
GHOSTTY_API void ghostty_surface_set_focus(ghostty_surface_t, bool);                    // :1190
GHOSTTY_API void ghostty_surface_set_occlusion(ghostty_surface_t, bool);                // :1191
GHOSTTY_API void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);       // :1192
GHOSTTY_API ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t);             // :1193
GHOSTTY_API uint64_t ghostty_surface_foreground_pid(ghostty_surface_t);                 // :1194
GHOSTTY_API ghostty_string_s ghostty_surface_tty_name(ghostty_surface_t);               // :1195
GHOSTTY_API void ghostty_surface_set_color_scheme(ghostty_surface_t,
                                                     ghostty_color_scheme_e);           // :1196
GHOSTTY_API ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                                         ghostty_input_mods_e); // :1198
GHOSTTY_API bool ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);           // :1200
GHOSTTY_API bool ghostty_surface_key_is_binding(ghostty_surface_t,
                                                   ghostty_input_key_s,
                                                   ghostty_binding_flags_e*);           // :1201
GHOSTTY_API void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);       // :1204
GHOSTTY_API void ghostty_surface_preedit(ghostty_surface_t, const char*, uintptr_t);    // :1205
GHOSTTY_API bool ghostty_surface_mouse_captured(ghostty_surface_t);                     // :1206
GHOSTTY_API bool ghostty_surface_mouse_button(ghostty_surface_t,
                                                 ghostty_input_mouse_state_e,
                                                 ghostty_input_mouse_button_e,
                                                 ghostty_input_mods_e);                 // :1207
GHOSTTY_API void ghostty_surface_mouse_pos(ghostty_surface_t,
                                              double, double, ghostty_input_mods_e);    // :1211
GHOSTTY_API void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                                 double, double, ghostty_input_scroll_mods_t); // :1215
GHOSTTY_API void ghostty_surface_mouse_pressure(ghostty_surface_t, uint32_t, double);   // :1219
GHOSTTY_API void ghostty_surface_ime_point(ghostty_surface_t, double*, double*, double*, double*); // :1220
GHOSTTY_API void ghostty_surface_request_close(ghostty_surface_t);                      // :1221
GHOSTTY_API bool ghostty_surface_binding_action(ghostty_surface_t, const char*, uintptr_t); // :1229
GHOSTTY_API void ghostty_surface_complete_clipboard_request(
    ghostty_surface_t, const ghostty_clipboard_complete_s*, void*);                     // :1230
GHOSTTY_API void ghostty_surface_deny_clipboard_request(ghostty_surface_t, void*);      // :1234
GHOSTTY_API bool ghostty_surface_has_selection(ghostty_surface_t);                      // :1236
GHOSTTY_API bool ghostty_surface_read_selection(ghostty_surface_t, ghostty_text_s*);    // :1237
GHOSTTY_API bool ghostty_surface_read_text(ghostty_surface_t,
                                              ghostty_selection_s,
                                              ghostty_text_s*);                         // :1238
GHOSTTY_API void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*);         // :1241
#ifdef __APPLE__
GHOSTTY_API void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);           // :1244
GHOSTTY_API void* ghostty_surface_quicklook_font(ghostty_surface_t);                    // :1245
GHOSTTY_API bool ghostty_surface_quicklook_word(ghostty_surface_t, ghostty_text_s*);    // :1246
#endif
GHOSTTY_API void ghostty_set_window_background_blur(ghostty_app_t, void*);              // :1277
```
