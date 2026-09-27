# PiCanvas

A native macOS canvas for coding agents. Zoom around an infinite plane, drop
terminals and `pi` agents anywhere, resize them, delete them.

![PiCanvas](docs/screenshot.png)

Every node is a real PTY running a real program — no reimplemented chat UI, no
wrapper around the agent. A `pi` node *is* `pi` in a terminal, so themes, slash
commands, extensions, key bindings and mouse reporting behave exactly as they do
in your terminal. What the canvas adds is the part a terminal grid cannot give
you: knowing which agent wants you, and not losing the conversation when the app
restarts.

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
| `⌘J` | Jump to the next agent that needs you (pans to it if off-screen) |
| `Delete` | Close the selected node (when the canvas, not a terminal, has focus) |
| `⌘C` / `⌘V` / `⌘A` | Copy / paste / select all, routed to the focused terminal |

Mouse: two-finger scroll pans (content follows your fingers, like any other
canvas app), pinch zooms, `⌘`+scroll zooms, drag a title bar to move a node,
drag **any border or corner** to resize (the cursor changes and the grabbed
border lights up), click `×` or anywhere in a node to focus it and raise it.

## Agent awareness

Each `pi` node is bound to its own session before it launches, by passing
`pi --session-id <uuid> --name canvas-<dir>-<uuid>`. Two consequences:

**Restarts do not lose conversations.** Relaunch PiCanvas and each node reopens
the session it owned, transcript and context intact. Two agents working in the
same directory stay separate, and `pi -r` lists them under recognisable names.
Nothing about this requires a wrapper around pi — it is a documented pi flag.

**A node can tell you what it is doing.** pi writes one JSON object per line to
its session file as work completes, so the last entry is a precise status
signal:

| Last transcript entry | Node shows |
| --- | --- |
| no transcript yet | `ready` (pi is at the prompt) |
| `user` message | `thinking` |
| `assistant` with `stopReason: toolUse` | the tool being run, e.g. `bash` |
| `toolResult` | still working, labelled with the tool |
| `assistant` with `stopReason: stop` | **`needs you`** |

![Agent status](docs/screenshot-agent-status.png)

When a node lands on `needs you` it is counted in the status bar (`1 agent needs
 you — ⌘J`) and, if PiCanvas is not the active app, the Dock icon bounces once.
`⌘J` cycles through the nodes that want a human, panning to bring them on screen.
That is the whole notification design: a busy canvas stays quiet, and a finished
one gets a nudge. Nothing is shown for `thinking` or tool states, because those
do not need a human.

## Scrollback

Shell nodes also survive a restart visually: on quit each node's terminal buffer
is snapshotted to `~/Library/Application Support/PiCanvas/scrollback/<node>.txt`
(capped at 256 KB, trailing blank rows trimmed) and painted back before the new
shell starts. The restored text is plain — no colours — because it comes from the
buffer rather than the raw byte stream; the live session below it is fully
coloured as usual. `pi` nodes are skipped on purpose: pi redraws its own
transcript from the session file, and injecting an old TUI frame would be noise.

A `kill` behaves like quitting: `SIGTERM` and `SIGINT` are turned into a normal
termination so the layout and snapshots are written rather than lost.

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
    NodeFrameView.swift         node chrome: title bar, close, resize, status pill
  Agent/
    AgentContent.swift          the seam between canvas and terminal
    TerminalContent.swift       SwiftTerm PTY host (the only SwiftTerm importer)
    ProcessResolver.swift       what to launch, with what environment
    PiSessionWatcher.swift      tails the transcript, derives agent status
    TerminalContentFactory.swift
  Model/
    AgentModel.swift            NodeSpec / LayoutFile
    LayoutStore.swift           debounced atomic JSON persistence
    ScrollbackStore.swift       per-node terminal snapshots between launches
```

### Three design decisions worth knowing

**Zoom scales glyphs; resizing changes content.** Canvas zoom multiplies the
terminal font size, so zooming out makes nodes smaller *and* their text smaller —
the whole canvas becomes a readable map instead of a grid of fixed-size text in
shrinking boxes. Node chrome scales with it, clamped so title bars stay usable.
Because the font and the node's pixel size scale together, the grid (columns ×
rows) stays essentially constant while zooming; changing how much content a node
shows is what resizing it is for.

The alternative — a `CALayer` transform — would be two lines of code and would
scale a bitmap, making text mushy. Scaling the *font* keeps every glyph rendered
natively at its true size, so it stays crisp at 20% and at 300%.

**The canvas never imports the terminal library.** `AgentContent` is the seam;
`TerminalContentFactory` is the only place that knows the terminal exists. That
keeps the canvas, the interaction model and persistence testable without a PTY.

**The transcript is the status API.** `PiSessionWatcher` only reads files pi
already writes, so node status needs no hooks, no RPC and no cooperation from
the agent. It reproduces pi's session-directory slug exactly, including
`realpath` resolution (pi turns `/tmp` into `--private-tmp--`).

### Why swiftc instead of SwiftPM

On a Command Line Tools-only install, this machine's `libPackageDescription.dylib`
exports no `Package` symbols, so *every* `swift build` fails with
`Invalid manifest ... Undefined symbols`. `scripts/build-app.sh` therefore drives
`swiftc` directly, and `scripts/build-swiftterm.sh` turns the vendored SwiftTerm
sources into `libSwiftTerm.a` plus a `SwiftTerm.swiftmodule` — including running
SwiftTerm's real build-info generator to produce the files its build plugin
normally emits. This is not a workaround we are waiting to remove: it is faster
to iterate on and has no external moving parts.

## Testing

```sh
# 128 checks: coordinate maths, zoom anchoring, drag, resize from every border,
# delete, persistence round-trip, process launch, session binding, the agent
# status state machine, the needs-you indicator and jump, scrollback
# snapshot/restore, zoom-vs-resize behaviour, and three real-PTY tests
./build/PiCanvas.app/Contents/MacOS/PiCanvas --self-test

# Render a window with two nodes to PNG without a display server
./build/PiCanvas.app/Contents/MacOS/PiCanvas --render-preview /tmp/preview.png

# Screenshot just the app window (needs Screen Recording permission)
./scripts/window-shot.sh /tmp/window.png

# Launch with nodes already open
./build/PiCanvas.app/Contents/MacOS/PiCanvas --new-terminal --new-pi
```

The self-test synthesises real `NSEvent`s to drive the actual drag and resize
code paths, spawns real PTYs to verify that input reaches the shell, output comes
back, resizing reflows the grid and terminating reaps the process, and tails a
synthetic pi transcript to verify every status transition. It needs no human and
no visible window.

Selected output:

```
terminal round trip (real PTY)
  ok   a login shell starts and writes a prompt
  ok   PTY received a sane column count (102)
  ok   typed input reaches the shell and output comes back
  ok   terminate() reaps the process

resize reflow (real PTY)
  ok   growing the node gives the PTY a bigger grid (69x21 → 138x42)
  ok   shrinking the node reduces the grid (138 → 56)
  ok   zooming out shrinks the glyphs (12.5pt → 6.25pt)
  ok   zooming out keeps roughly the same content (cols 138 → 130)

pi agent status watcher
  ok   session directory resolves symlinks the way pi does
  ok   a user message means the agent is working
  ok   a pending tool call names the tool (got bash)
  ok   a finished run means the agent needs you

agent attention and jump
  ok   only the finished agent asks for attention (got 1)
  ok   the running node names the tool it is using
  ok   jump pans to bring an off-screen node into view
  ok   the target node is on screen after the jump

scrollback persistence (real PTY)
  ok   capping starts at a line boundary
  ok   the snapshot holds the session output
  ok   restored lines start at column 0 (no staircase)
  ok   a restored terminal still runs a shell
```

## State

Canvas layout lives at
`~/Library/Application Support/PiCanvas/layout.json`: node positions, sizes,
kind, working directory, the exact argv to relaunch and the pi session id, plus
viewport zoom and pan. Terminal snapshots live beside it in `scrollback/`.
Writes are debounced and atomic. On launch every node is recreated with its
process restarted, its agent conversation resumed, and shell scrollback
restored.

`PI_*` environment variables are stripped before spawning, so a `pi` node started
from inside another `pi` session does not inherit that session's identity. If
PiCanvas is force-quit, the child processes die with the pty.

## Not built yet

- Cost and token history over time (the transcript already carries `usage`; only
  the current totals are shown)
- Node connections, drag-to-snap, minimap, multi-select, saved workspaces
- A first-run welcome state instead of an empty canvas
