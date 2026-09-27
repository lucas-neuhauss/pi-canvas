# PiCanvas

A native macOS canvas for coding agents. Zoom around an infinite plane, drop
terminals and `pi` agents anywhere, resize them, delete them. That's it.

![PiCanvas](docs/screenshot.png)

Every node is a real PTY running a real program — no reimplemented chat UI, no
wrapper around the agent. A `pi` node is exactly `pi` in a terminal, so themes,
slash commands, extensions, key bindings and mouse reporting all behave the way
they do in your terminal.

## Build and run

```sh
make deps     # fetch vendored SwiftTerm (once)
make app      # build build/PiCanvas.app
make run      # build and run with logs on stdout
make open     # build and open as a normal app
```

Requirements: macOS 14+, Apple Command Line Tools. **Xcode is not required.**
There is no `.xcodeproj` and no `Package.swift`.

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘T` | New terminal on the canvas |
| `⌘P` | New `pi` agent on the canvas |
| `⌘W` | Close the focused node (falls back to closing the window) |
| `⌘O` | Choose the folder new nodes start in |
| `⌘+` / `⌘-` / `⌘0` | Zoom in / out / actual size |
| `⌘9` | Zoom to fit every node |
| `Delete` | Close the selected node (when the canvas, not a terminal, has focus) |
| `⌘C` / `⌘V` / `⌘A` | Copy / paste / select all, routed to the focused terminal |

Mouse: two-finger scroll pans, pinch zooms, `⌘`+scroll zooms, drag a title bar to
move a node, drag the bottom-right grip to resize, click `×` or a node's title
bar to focus it.

## How it works

```
Sources/PiCanvas/
  main.swift                    entry point, flag handling
  App/
    AppDelegate.swift           window, menus, launch arguments
    CanvasController.swift      node lifecycle: create/restore/close/persist
    MainView.swift              canvas + status bar
    SelfTest.swift              headless integration tests (--self-test)
    PreviewHarness.swift        offscreen render harness (--render-preview)
  Canvas/
    CanvasView.swift            infinite pan/zoom plane, world↔screen maths
    NodeFrameView.swift         node chrome: title bar, close, resize grip
  Agent/
    AgentContent.swift          the seam between canvas and terminal
    TerminalContent.swift       SwiftTerm PTY host (the only SwiftTerm importer)
    ProcessResolver.swift       what to launch, with what environment
    TerminalContentFactory.swift
  Model/
    AgentModel.swift            NodeSpec / LayoutFile
    LayoutStore.swift           debounced atomic JSON persistence
```

### Two design decisions worth knowing

**Zoom resizes the view; it never transforms it.** Nodes hold a world-space
frame and the canvas computes a screen frame from it
(`screen = world * zoom + pan`). A `CALayer` transform would be two lines of
code and would make terminal text blurry and its mouse coordinates lie. Instead
the terminal always renders at native 1:1 pixels, and zooming in means the node
occupies more pixels, which means more columns and rows. Node chrome (title bars,
buttons) is drawn in constant screen pixels so it stays legible at every zoom.

**The canvas never imports the terminal library.** `AgentContent` is the seam;
`TerminalContentFactory` is the only place that knows the terminal exists. That
keeps the canvas, persistence and interaction testable without a PTY, and makes
swapping the terminal implementation a one-file change.

### Why swiftc instead of SwiftPM

On a Command Line Tools-only install, this machine's `libPackageDescription.dylib`
exports no `Package` symbols, so *every* `swift build` fails with
`Invalid manifest ... Undefined symbols`. `scripts/build-app.sh` therefore drives
`swiftc` directly, and `scripts/build-swiftterm.sh` turns the vendored SwiftTerm
sources into `libSwiftTerm.a` plus a `SwiftTerm.swiftmodule` the app links
against — including running SwiftTerm's real build-info generator to produce the
files its build plugin normally emits. This is not a workaround we are waiting to
remove: it is faster to iterate on and has no external moving parts.

## Testing

```sh
# 54 checks: coordinate maths, zoom anchoring, drag, resize, delete,
# persistence round-trip, process launch, and two real-PTY tests
./build/PiCanvas.app/Contents/MacOS/PiCanvas --self-test

# Render a window with two nodes to PNG without a display server
./build/PiCanvas.app/Contents/MacOS/PiCanvas --render-preview /tmp/preview.png

# Screenshot just the app window (needs Screen Recording permission)
./scripts/window-shot.sh /tmp/window.png

# Launch with nodes already open
./build/PiCanvas.app/Contents/MacOS/PiCanvas --new-terminal --new-pi
```

The self-test synthesises real `NSEvent`s to drive the actual drag and resize
code paths, and spawns real PTYs to verify that input reaches the shell, output
comes back, resizing reflows the grid, and terminating reaps the process. It does
not need a human or a visible window.

`--self-test` output:

```
terminal round trip (real PTY)
  ok   a login shell starts and writes a prompt
  ok   PTY received a sane column count (102)
  ok   PTY received a sane row count (34)
  ok   typed input reaches the shell and output comes back
  ok   terminate() reaps the process

resize reflow (real PTY)
  ok   PTY starts with a grid (65x21)
  ok   growing the node gives the PTY a bigger grid (65x21 → 130x42)
  ok   shrinking the node reduces the grid (130 → 52)
```

## State

Canvas layout lives at
`~/Library/Application Support/PiCanvas/layout.json`: node positions, sizes,
kind, working directory and the exact argv needed to relaunch, plus viewport
zoom and pan. Writes are debounced and atomic. On launch every node is recreated
and its process restarted; scrollback is not yet restored.

`PI_*` environment variables are stripped before spawning, so a `pi` node started
from inside another `pi` session does not inherit that session's identity.

## Not built yet

- Scrollback restore across relaunch (`docs/SWIFTTERM_API.md` §4 documents the
  capture architecture; the high-level `LocalProcessTerminalView` has no
  overridable raw-byte hook, so this needs `TerminalView` + `LocalProcess`)
- Per-node agent status read from pi's session JSONL (`thinking`, `running bash`,
  **needs you**) with a native notification
- Node connections, drag-to-snap, minimap, multi-select
