# libghostty migration — status

The canvas was written against a content seam (`NodeContent`, with a
`ProcessContent` refinement for terminals), so swapping the terminal backend is
a contained change. This file records where that swap stands and what it is
waiting on.

## State

| Piece | Status |
| --- | --- |
| `NodeContent`/`ProcessContent` seam + backend-agnostic tests | done |
| libghostty host (`GhosttyApp`, `GhosttySurfaceView`, `GhosttySurfaceContent`) | written, typechecks with 0 errors against the real header |
| Build auto-detection (Ghostty when present, SwiftTerm otherwise) | done |
| Self-test suite (354 checks) | passing on both backends |
| **Building libghostty on this machine** | **blocked: needs Xcode** |

The app currently runs on the **SwiftTerm** backend because libghostty could not
be built here. Nothing else is missing: once `make ghostty` succeeds, the app
picks up the Ghostty backend automatically on the next `make app`.

## Why the build is blocked

libghostty compiles its Metal shaders **offline at build time** and embeds the
resulting `.metallib` into the static library:

```zig
// src/build/SharedDeps.zig
if (step.rootModuleTarget().os.tag.isDarwin()) {
    const metallib = self.metallib.?;
    metallib.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("ghostty_metallib", .{ ... });
}
```

Verified facts:

- That branch is **unconditional for macOS**, so it applies even with
  `-Drenderer=opengl`. Confirmed by running the build: it fails at
  `metallib Ghostty → metal Ghostty (Ghostty.ir) failure` with the OpenGL
  renderer selected.
- `metal` ships with **Xcode**, not with the Command Line Tools. Verified:
  `xcrun -sdk macosx metal --version` fails on this machine, and there is no
  `metal` binary anywhere under the CLT, `/Applications`, or Homebrew.
- Packaging as an xcframework additionally requires `xcodebuild` (also Xcode).

So on a CLT-only machine there is no supported path to a macOS build of
libghostty. Two ways forward:

1. **Install Xcode** (or Xcode plus its downloadable Metal toolchain component),
   then `make ghostty && make app`.
2. **Vendor a prebuilt `libghostty.a`** produced on a machine or CI image that
   has Xcode, from the matching Ghostty release tag. The static library is
   self-contained (the metallib is embedded), so the local build only links it:
   drop it in `build/ghostty/` next to `include/ghostty.h` and `module.modulemap`.

### A trap worth remembering

While investigating, a probe script was placed on `PATH` as a fake `metal` that
printed to stderr and wrote nothing. The build then reported success — the
embedded "metallib" was **10 bytes** and the resulting 272 MB static library
would have linked, launched, and rendered a black terminal. Verify build
artifacts, not build exit codes:

```sh
ls -l Vendor/ghostty/.zig-cache/o/*/Ghostty.metallib   # ~100 KB+, not 10 bytes
```

## What the host does

Implemented in `Sources/PiCanvas/Agent/Ghostty/`:

- `GhosttyApp` — process-wide `ghostty_init`, the user's real config
  (`ghostty_config_load_default_files`, so theme/palette/font/ligatures apply),
  `ghostty_app_new`, the wakeup tick, and routing of surface actions back to
  views via `ghostty_surface_userdata` (no side tables).
- `GhosttySurfaceView` — an `NSView` that owns one surface. libghostty creates
  and owns the Metal layer and renders on its own schedule, so there is no layer
  setup and no draw loop. The view sizes the surface in pixels, drives
  `set_content_scale`/`set_focus`/`set_occlusion`, forwards key/mouse/IME input
  (`NSTextInputClient` for marked text), maps mouse shapes to cursors, and
  reports title/pwd/exit/close through its delegate.
- `GhosttySurfaceContent` — the `ProcessContent` conformance: builds the surface
  command from `ProcessRequest`, stages scrollback, applies zoom.

Notable mappings:

| Canvas need | libghostty mechanism |
| --- | --- |
| Launch a process | `ghostty_surface_config_s.command` — **always run through a shell**, so argv is shell-quoted |
| Zoom scales text | `increase_font_size:<f32>` / `decrease_font_size:<f32>` binding actions, tracked exactly (there is no absolute setter) |
| Scrollback snapshot | `ghostty_surface_read_text` + `free_text`, over a `GHOSTTY_POINT_SCREEN` selection |
| Scrollback restore | libghostty has no feed API, so the saved buffer is written to a temp file and `cat`-ed by the child's shell before exec |
| Exit status | `GHOSTTY_ACTION_SHOW_CHILD_EXITED` / `GHOSTTY_ACTION_CLOSE_WINDOW` |
| Session env | surface config `env_vars`; `PI_*` is unset at startup since libghostty inherits our environment |
| Clipboard | `read_clipboard_cb` / `write_clipboard_cb`, plus `confirm_read_clipboard_cb` which denies program-initiated reads |

### Details worth not re-learning

- **The clipboard callbacks are mandatory.** Their fields are non-nullable in
  Zig; passing NULL crashes as soon as a terminal touches the clipboard. Only
  `close_surface_cb` may be NULL. All of them receive the *surface's* userdata
  (our view pointer), not the app's.
- **`ghostty_config_get` is not a general reader.** It returns false for
  `font-family` and `cursor-color`, and the destination width must match the
  field: `font-size` is a 32-bit `float`, so reading it into a `Double` yields
  garbage in half the value. `GhosttyTheme` parses the config files directly
  instead, which is also what the SwiftTerm fallback needs.
- **`GHOSTTY_POINT_SURFACE` is not "the surface".** It is internally `history`
  (scrollback only). Use `SCREEN` for a full snapshot, or it silently omits
  whatever is on screen.
- **libghostty owns the layer.** It installs its own `IOSurfaceLayer` on the view
  and renders on its own schedule: no `CAMetalLayer`, no `wantsLayer`, no
  `draw(_:)`, no `GHOSTTY_ACTION_RENDER` handling.
- **Free surfaces before the app.** `ghostty_app_free` deinitialises whatever is
  still registered, and a debug build asserts the font grid is empty.

## When Xcode is available

```sh
make deps            # if Vendor/ghostty is missing
make ghostty         # fails with instructions if `metal` is absent
make app             # auto-detects build/ghostty and switches backend
./build/PiCanvas.app/Contents/MacOS/PiCanvas --self-test   # same 129 checks
```

Then re-verify: a node opens, the theme/palette match the user's Ghostty, zoom
scales glyphs, resize reflows, scrollback restores, exit status shows, and
closing a node reaps its process.
