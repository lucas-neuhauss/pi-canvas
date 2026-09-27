# SwiftTerm API Reference (vendored, exact)

Target: macOS 26 arm64, Swift 6.3.3, AppKit. Module: `SwiftTerm` (imported with `import SwiftTerm`).
Vendored source: `Vendor/SwiftTerm`, git HEAD `fe4fb45d5888ce33ff3788d6873870a73894a41b`
("Make TerminalView.currentMouseMode public on macOS (#715)").

Paths in citations are relative to the repository root. Line numbers are from the vendored files as read.

**Access-level legend**

- `open` — visible and subclassable/overridable from an external module.
- `public` — visible from an external module, but **not overridable** outside the defining module.
- `internal` (no modifier) — **invisible** to `import SwiftTerm`. Listed in §7.
- `private` — invisible.

The positive/negative/compile/runtime probes behind the access claims are in Appendix A. Every signature below
was copied from the cited source line; behavior statements cite the source line or a runtime probe result.

---

## 0. Module / build facts

- `TerminalView` (macOS) is declared in `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:105`:
  ```swift
  open class TerminalView: NSView, NSUserInterfaceValidations, TerminalDelegate {
  ```
  There is **no class named `MacTerminalView`**; the file name is historical.
- `LocalProcessTerminalView` is declared in `Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:241`:
  ```swift
  open class LocalProcessTerminalView: TerminalView, TerminalViewDelegate {
  ```
- Much of the shared public API (feed, scroll, buffer reads, search, send) lives in
  `extension TerminalView` in `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1227` and
  `Sources/SwiftTerm/TerminalViewSearch.swift`.
- Both view files are wrapped in `#if !SWIFTTERM_EMBEDDED` + `#if os(macOS)` (`MacLocalTerminalView.swift:9-11`,
  `MacTerminalView.swift:9-11`). The normal host build must **not** define `SWIFTTERM_EMBEDDED`.

### 0.1 Generated files are mandatory for a direct swiftc build

`Sources/SwiftTerm/Terminal.swift:5218` references `SwiftTermBuildInfo`, and
`Terminal.swift:1570` references `SwiftTermTerminfo.xtgettcapReplies`. These symbols are only defined by
`Sources/SwiftTerm/EmbeddedSupport.swift:96` / `:113` when `SWIFTTERM_EMBEDDED` is set. For a normal macOS
build they are produced by the SwiftPM build-tool plugin (`Plugins/SwiftTermBuildInfoPlugin/plugin.swift`)
running `Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift`, which emits
`SwiftTermBuildInfo.swift` and `SwiftTermTerminfo.swift`. A direct `swiftc` build must compile those two
generated files into the module too. This was verified by actually doing it (Appendix A.2).

### 0.2 Verified direct compile command

```
swiftc -emit-library -emit-module -module-name SwiftTerm -swift-version 6 \
  -target arm64-apple-macos26.0 \
  -o <out>/libSwiftTerm.dylib -emit-module-path <out>/SwiftTerm.swiftmodule \
  @sources.txt <gen>/SwiftTermBuildInfo.swift <gen>/SwiftTermTerminfo.swift
```
`sources.txt` = every `*.swift` under `Sources/SwiftTerm` (107 files at this commit). Compiles with only
`CVDisplayLink` deprecation warnings. See Appendix A.

---

## 1. `TerminalView` (NSView subclass)

### 1.1 Class and initializers

```swift
open class TerminalView: NSView, NSUserInterfaceValidations, TerminalDelegate
```
`Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:105`

```swift
public init(frame: CGRect, font: NSFont?)
```
`MacTerminalView.swift:550`

```swift
public init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions)
```
`MacTerminalView.swift:561` — doc comment on it: "the `cols` and `rows` in the options are used as-is for a
zero-sized frame, and are otherwise recomputed from the frame size" (`MacTerminalView.swift:558-560`).

```swift
public override init (frame: CGRect)
```
`MacTerminalView.swift:572`

```swift
public required init? (coder: NSCoder)
```
`MacTerminalView.swift:581`

All four are `public` (not `open`), so external code can call them but cannot override them. `LocalProcessTerminalView`
overrides the first, third, and fourth in-module.

### 1.2 Font and appearance

```swift
public var font: NSFont
```
`MacTerminalView.swift:539`. Setting it rebuilds a `FontSet` and calls the internal `resetFont()`, which recomputes
cell metrics and re-resizes the terminal (`MacTerminalView.swift:539-547`, `AppleTerminalView.swift:1509`).
There is **no public font-size or font-family property**; construct an `NSFont` at the desired size/family and assign it.

```swift
public func resetFontSize ()
```
`MacTerminalView.swift:4250` — resets to `FontSet.defaultFont` (monospaced system font at `NSFont.systemFontSize`,
`MacTerminalView.swift:228-235`), keeping the selection.

```swift
@objc open var fontSmoothing: Bool
```
`AppleTerminalView.swift:1480` (macOS-only, `#if os(macOS)` at `:1479`).

```swift
@objc open var lineSpacing: CGFloat
```
`AppleTerminalView.swift:1492` — setter calls internal `resetFont()`.

```swift
public var caretFrame: CGRect
```
`AppleTerminalView.swift:1540` (read-only).

```swift
public var nativeForegroundColor: NSColor
```
`MacTerminalView.swift:1228`

```swift
public var nativeBackgroundColor: NSColor
```
`MacTerminalView.swift:1246`

```swift
public var backgroundOpacity: CGFloat
```
`MacTerminalView.swift:1273` (clamped 0...1; carried in `nativeBackgroundColor`'s alpha).

```swift
public var caretColor: NSColor
```
`MacTerminalView.swift:1323`

```swift
public var caretTextColor: NSColor?
```
`MacTerminalView.swift:1333`

```swift
public var selectedTextBackgroundColor: NSColor
```
`MacTerminalView.swift:1343`

```swift
public var selectedTextForegroundColor: NSColor
```
`MacTerminalView.swift:1356`

```swift
public func configureNativeColors ()
```
`MacTerminalView.swift:1484` — sets the two native colors to `NSColor.textColor` / `NSColor.textBackgroundColor`.

```swift
public func installColors (_ colors: [Color])
```
`AppleTerminalView.swift:2303` — requires exactly 16 `Color` values; derives 16–255. Public palette constants:
`Color.defaultInstalledColors`, `Color.paleColors`, `Color.vgaColors`, `Color.terminalAppColors`, `Color.xtermColors`
(`Sources/SwiftTerm/Colors.swift:52-136`); constructors `public init(red8:green8:blue8:)` (`Colors.swift:336`) and
`public init(red:green:blue:)` (`Colors.swift:355`). Note `Color.defaultForeground`/`defaultBackground` are internal
(the negative probe failed on them; use `Color.defaultInstalledColors`).

Other appearance/behavior properties (all verified `public`/`open`):

| Property | Declaration | Cite |
| --- | --- | --- |
| `public var useBrightColors: Bool = true` | bool | `MacTerminalView.swift:1285` |
| `public var bidiHostPolicy: BidiHostPolicy` | `.respectTerminal` default | `MacTerminalView.swift:1288` |
| `public var customBlockGlyphs: Bool = true` | bool | `MacTerminalView.swift:1297` |
| `public var glyphFallbackProvider: (any TerminalGlyphFallbackProvider)?` | nil default | `MacTerminalView.swift:1307` |
| `public var antiAliasCustomBlockGlyphs: Bool = false` | bool | `MacTerminalView.swift:1315` |
| `public var scrollerStyle: NSScroller.Style = .overlay` | scroller style | `MacTerminalView.swift:1399` |
| `public var linkReporting: LinkReporting = .implicit` | `.none/.explicit/.implicit` | `MacTerminalView.swift:1546` |
| `public var linkHighlightMode: LinkHighlightMode = .hoverWithModifier` | `.hover/.hoverWithModifier/.always/.alwaysWithModifier` | `MacTerminalView.swift:1549`, enum at `AppleTerminalView.swift:69-90` |
| `public var notifyUpdateChanges = false` | drives `rangeChanged` | `MacTerminalView.swift:1564` |
| `public var caretViewTracksFocus: Bool` | bool | `MacTerminalView.swift:266` |
| `public var cursorBlinkResetsOnInput = true` | bool | `MacTerminalView.swift:280` |
| `public var suspendsRenderingWhenNotVisible: Bool` | get/set | `MacTerminalView.swift:285` |
| `public var bellStyle: BellStyle = .sound` | bell behavior | `MacTerminalView.swift:4343` |
| `public var backspaceSendsControlH: Bool = false` | `^?` vs `^H` | `MacTerminalView.swift:1162` |
| `public var optionAsMetaKey: Bool = true` | ESC prefix | `MacTerminalView.swift:2000` |
| `public var scrollSensitivity: CGFloat = 1.0` | wheel multiplier | `MacTerminalView.swift:4103` |
| `public var ansi256PaletteStrategy: Ansi256PaletteStrategy` | get/set | `AppleTerminalView.swift:1717` |
| `public var maximumBidiParagraphRows: Int` | get/set | `AppleTerminalView.swift:1726` |
| `public var disableFullRedrawOnAnyChanges = false` | redraw policy | `MacTerminalView.swift:531` |

### 1.3 First responder / focus / keyboard input

```swift
public override func becomeFirstResponder() -> Bool
```
`MacTerminalView.swift:1766` — sets `hasFocus = true` and calls internal `updateTerminalFocus()`.

```swift
public override func resignFirstResponder() -> Bool
```
`MacTerminalView.swift:1775`

```swift
public override var acceptsFirstResponder: Bool
```
`MacTerminalView.swift:1785` — always returns `true`.

```swift
open var hasFocus : Bool
```
`MacTerminalView.swift:1749` — settable; getter returns `_hasFocus && (window?.isKeyWindow ?? true)`.

How to make it first responder: there is **no public `focus()`/`makeFirstResponder()` method on the view** — the
internal `func makeFirstResponder ()` at `MacTerminalView.swift:1700-1703` is inaccessible (negative probe).
Use the AppKit call: `window?.makeFirstResponder(terminalView)` (verified in the working example, §5).
The view also installs `NSWindow.didBecomeKeyNotification` / `didResignKeyNotification` observers (internal
`setupFocusNotification()`, `MacTerminalView.swift:1033`) so focus state follows window key status.

```swift
public override func keyDown(with event: NSEvent)
```
`MacTerminalView.swift:2039`

```swift
public override func keyUp(with event: NSEvent)
```
`MacTerminalView.swift:2293`

```swift
public override func flagsChanged(with event: NSEvent)
```
`MacTerminalView.swift:1938`

```swift
public var shouldSendCommandKeyToTerminal: ((NSEvent) -> Bool)?
```
`MacTerminalView.swift:4651`

The view conforms to `NSTextInputClient` (`MacTerminalView.swift:4657: extension TerminalView: @MainActor NSTextInputClient {}`),
so it participates in the normal AppKit text input system. `keyDown` is `public override`, not `open`
(comment at `AppleTerminalView.swift:1631-1636` explains that a host that rebinds a chord does it in an event monitor
ahead of the view; `keyboardEnhancementFlags` tells the monitor when to stand down).

### 1.4 Injecting bytes / text

```swift
public nonisolated func feed (byteArray: ArraySlice<UInt8>)
```
`AppleTerminalView.swift:4411`

```swift
public nonisolated func feed (text: String)
```
`AppleTerminalView.swift:4417`

Both are `nonisolated` (callable from any thread; doc comment: "this can be invoked from a background thread").
There is **no `feed(data:)`** in the vendored source (grep: NOT FOUND).

```swift
public nonisolated let feedSender = TerminalFeedSender()
```
`MacTerminalView.swift:308`; `TerminalFeedSender` is a `public final class: Sendable` (`AppleTerminalView.swift:1174`):

```swift
public func feed(byteArray: ArraySlice<UInt8>)
```
`AppleTerminalView.swift:1193`

```swift
public func feed(text: String)
```
`AppleTerminalView.swift:1198`

Input (toward the "host", for a PTY the child process):

```swift
public nonisolated let inputSender = TerminalInputSender()
```
`MacTerminalView.swift:307`; `TerminalInputSender` is `public final class: Sendable` (`AppleTerminalView.swift:1114`):

```swift
public func send(data: ArraySlice<UInt8>)
```
`AppleTerminalView.swift:1152` — doc: "Serial calls preserve their delivery order. Calls from concurrent threads need
external ordering…"

```swift
public nonisolated func send(data: ArraySlice<UInt8>)
```
`AppleTerminalView.swift:4485`

```swift
public func send (txt: String)
```
`AppleTerminalView.swift:4494`

```swift
public func send (_ bytes: [UInt8])
```
`AppleTerminalView.swift:4509`

```swift
@MainActor
public func pasteText(_ text: String)
```
`Sources/SwiftTerm/Apple/AppleKittyClipboard.swift:135-136` — applies bracketed paste and the paste safety policy;
"a host can feed the terminal content that did not come from the pasteboard … without it being seen as typed input"
(`AppleKittyClipboard.swift:128-134`).

Ordering/lock rule (documented and source-relevant): do not call `feed`/`send` from inside a terminal delegate
callback; those run with the terminal lock held and these take it
(`Documentation.docc/Embedding.md`, "Feeding and sending from other threads";
`AppleTerminalView.swift:4481-4487` comment).

### 1.5 Reading terminal content back

`TerminalView` does **not** expose its `Terminal`. The stored property is internal:

```swift
var terminal: Terminal!
```
`MacTerminalView.swift:487` — internal (negative probe: `'terminal' is inaccessible due to 'internal' protection level`).

**`getTerminal()` does not exist.** It existed in SwiftTerm 1.x and was removed in 2.0; the vendored docs say so
explicitly (`Documentation.docc/MigratingFrom1To2.md`: "SwiftTerm 1.0 exposed the underlying terminal through
`TerminalView/getTerminal()` … SwiftTerm 2.0 does not expose a `Terminal` from `TerminalView`."). A grep for
`func getTerminal` across `Sources/` returns nothing, and a compile probe confirms
`value of type 'LocalProcessTerminalView' has no member 'getTerminal'`.

The public copied-read APIs are:

```swift
public nonisolated var terminalDimensions: TerminalDimensions
```
`AppleTerminalView.swift:1624`

```swift
public struct TerminalDimensions: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int)
}
```
`AppleTerminalView.swift:1012-1018`

```swift
public nonisolated func terminalStateSnapshot() -> TerminalViewStateSnapshot
```
`AppleTerminalView.swift:1643`

```swift
public struct TerminalViewStateSnapshot: Sendable {
    public let dimensions: TerminalDimensions
    public let cursor: Position
    public let viewportRow: Int
    public let bracketedPasteMode: Bool
    public let currentBidiState: BidiPresentationState
    public let bidiArrowKeySwap: Bool
    public let cursorStyle: CursorStyle
    public let ansi256PaletteStrategy: Ansi256PaletteStrategy
    public let visibleRows: [TerminalVisibleRowSnapshot]
}
```
`AppleTerminalView.swift:1043-1054`. `TerminalVisibleRowSnapshot` is at `:1023-1032`:
`row: Int`, `text: String`, `isWrapped: Bool`, `bidiState: BidiPresentationState`, `cellWidths: [Int]`
("The display width of each copied cell. Wide cells use `2` for the leading cell and `0` for the trailing cell.").
Only the visible viewport is included — there is no copied scrollback-row API.

```swift
public nonisolated func getBufferAsData(
    kind: Terminal.BufferKind = .active,
    encoding: String.Encoding = .utf8
) -> Data
```
`AppleTerminalView.swift:1648-1651`. `kind` is `Terminal.BufferKind` (`Terminal.swift:8866-8874`):
`.active` (current buffer), `.normal`, `.alt`. The data is each buffer line run through
`translateToString(trimRight: true)` plus a `\n` per line (`Terminal.swift:8930-8944`). This includes normal-buffer
scrollback lines (the loop runs over `b.lines.count`, `Terminal.swift:8935`).

`Terminal` itself is `open class Terminal` (`Terminal.swift:386`) and has public
`getBufferAsData(kind:encoding:)` (`Terminal.swift:8930`), `getText(start:end:)` (`Terminal.swift:8950`),
`cols`/`rows` (`:414`/`:418`), `resize(cols:rows:)` (`:8210`), `terminalLock` (`:411`), `changeScrollback`
(`:8332`), `clearScrollback` (`:8325`), `refresh(startRow:endRow:)` (`:8499`), but **a view-owned instance is
not reachable from the view**. `getBufferAsString` does **not exist** (grep: NOT FOUND).

```swift
public func getSelection () -> String?
```
`AppleTerminalView.swift:4745`

```swift
public var selectionActive: Bool
```
`AppleTerminalView.swift:4735`

OSC observation (passive, no terminal access):

```swift
@MainActor
public func observeOscEvents(
    _ handler: @escaping @Sendable (TerminalOscEvent) -> Void
) -> TerminalOscObservation
```
`AppleTerminalView.swift:1664-1667`; `TerminalOscEvent` at `Sources/SwiftTerm/EscapeSequenceParser.swift:147-169`
(`code: Int`, `payload: [UInt8]`, `cursor: Position`), `TerminalOscObservation` at `:174-196` (retain token;
`cancel()`; async delivery on a private serial queue).

### 1.6 Resize / reflow / cols-rows computation

```swift
open override func setFrameSize(_ newSize: NSSize)
```
`MacTerminalView.swift:1706` — public API for the host is simply setting the view frame. Behavior:
if `cellDimension != nil`, then during a live drag it calls internal `queueSizeChange(newSize:)` (coalesced to one
resize per frame, `AppleTerminalView.swift:1791-1795`), otherwise it calls internal
`processSizeChange(newSize:)` synchronously (`MacTerminalView.swift:1706-1738`).

`processSizeChange` (`AppleTerminalView.swift:1809`) computes (`:1813-1814`):
```swift
let newRows = Int (newSize.height / cellDimension.height)
let newCols = Int (getEffectiveWidth (size: newSize) / cellDimension.width)
```
`getEffectiveWidth` subtracts the reserved legacy scroller width (`MacTerminalView.swift:1534-1537`). It then calls
`terminal.resize(cols:rows:cellWidth:cellHeight:)`, invalidates search, and notifies
`terminalDelegate?.sizeChanged(source:newCols:newRows:)` (`AppleTerminalView.swift:1822-1836`). Cell size comes from
the font metrics (`computeFontDimensions`, `AppleTerminalView.swift:1916`).

```swift
public func resize (cols: Int, rows: Int)
```
`AppleTerminalView.swift:4425` — programmatic resize. **Note: it calls `terminal.softReset()` after resizing**
(`AppleTerminalView.swift:4431-4434`), then notifies the delegate and updates the scroller.

```swift
open func getOptimalFrameSize () -> NSRect
```
`MacTerminalView.swift:1526` — frame that would host the current cols/rows at the current cell size.

Current cols/rows: `terminalDimensions.cols` / `.rows` (`AppleTerminalView.swift:1624`) or
`terminalStateSnapshot().dimensions` (`:1643`).

`queueSizeChange`/`processSizeChange`/`getEffectiveWidth` are **internal** (negative probe) — a host cannot call or
override them; use `setFrameSize`, `resize(cols:rows:)`, and the `sizeChanged` delegate callback.

### 1.7 Scrolling and scrollback

```swift
public var scrollThumbsize: CGFloat
```
`AppleTerminalView.swift:4208` — 0 in the alternate buffer.

```swift
public var scrollPosition: Double
```
`AppleTerminalView.swift:4229` — 0...1 relative viewport position.

```swift
public var canScroll: Bool
```
`AppleTerminalView.swift:4255`

```swift
public func scroll (toPosition: Double)
```
`AppleTerminalView.swift:4271`

```swift
public func scrollTo (row: Int, notifyAccessibility: Bool = true)
```
`AppleTerminalView.swift:4297`

```swift
public func pageUp()
```
`AppleTerminalView.swift:4334` — sends `EscapeSequences.cmdPageUp` in the alternate buffer, otherwise scrolls.

```swift
public func pageDown ()
```
`AppleTerminalView.swift:4347`

```swift
public func scrollUp (lines: Int)
```
`AppleTerminalView.swift:4360`

```swift
public func scrollDown (lines: Int)
```
`AppleTerminalView.swift:4369`

There is **no `scroll(to:)`** method (grep: NOT FOUND); the relative API is `scroll(toPosition:)`.

Scrollback capacity is configured through `TerminalOptions.scrollback` (declared `TerminalOptions.swift:158`,
default **500** at `:220`) at construction, or at runtime:

```swift
public func changeScrollback (_ newScrollback: Int?)
```
`AppleTerminalView.swift:4445` — `nil` disables scrollback. Only the normal buffer has scrollback.

```swift
public func clearScrollback ()
```
`AppleTerminalView.swift:4459` — discards history without clearing the visible screen.

`maxScrollingHistory` does **not exist** (grep: NOT FOUND). The `Terminal` equivalents
`changeScrollback(_:)` / `clearScrollback()` are at `Terminal.swift:8332` / `:8325`.

### 1.8 Mouse

```swift
public var allowMouseReporting: Bool = true
```
`MacTerminalView.swift:1542`

```swift
public var currentMouseMode: Terminal.MouseMode
```
`MacTerminalView.swift:4367` — get-only; read from a lock-free mirror, "Reading it does not take the terminal lock"
(`MacTerminalView.swift:4360-4366`). `Terminal.MouseMode` is public (`Terminal.swift:987`) with cases
`.off`, `.x10`, `.vt200`, `.buttonEventTracking`, `.anyEvent` (`Terminal.swift:988-1000`). The commit under test
(fe4fb45) is the one that made this property public.

The mouse mode is driven by the terminal application. The view observes changes in
`public nonisolated func mouseModeChanged(source: Terminal)` (`MacTerminalView.swift:4447`); there is no public
setter for the mode.

Clicks/selection/copy:
```swift
open override func mouseDown(with event: NSEvent)          // MacTerminalView.swift:3629
open override func mouseUp(with event: NSEvent)            // MacTerminalView.swift:3699
open override func mouseDragged(with event: NSEvent)       // MacTerminalView.swift:3776
public override func mouseMoved(with event: NSEvent)       // MacTerminalView.swift:3988
public override func scrollWheel(with event: NSEvent)      // MacTerminalView.swift:4110
```
Selection is internal (`var selection: SelectionService!`, `MacTerminalView.swift:504`), but public entry points
exist:
```swift
public override func selectAll(_ sender: Any?)   // MacTerminalView.swift:3446 (NSResponder)
public func selectAll ()                         // AppleTerminalView.swift:4756
public func selectNone ()                        // AppleTerminalView.swift:4763
public func getSelection () -> String?           // AppleTerminalView.swift:4745
public var selectionActive: Bool                 // AppleTerminalView.swift:4735
@objc open func copy(_ sender: Any)              // MacTerminalView.swift:3434 (writes NSPasteboard.general)
@objc open func paste(_ sender: Any)             // MacTerminalView.swift:3415
public func pastePrimarySelection()              // MacTerminalView.swift:3421
```
When `allowMouseReporting` is on and the application enabled tracking, mouse events are encoded and sent to the
application; Shift bypasses reporting (`MacTerminalView.swift:3647`, `:3719-3723`). `linkHighlightMode` decides
whether a click opens a link and the view then calls
`terminalDelegate?.requestOpenLink(source:link:params:)` (`MacTerminalView.swift:3742`).

### 1.9 Search

All in `extension TerminalView` in `Sources/SwiftTerm/TerminalViewSearch.swift`:

```swift
@discardableResult
public func findNext (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool
```
`TerminalViewSearch.swift:21-22`

```swift
@discardableResult
public func findPrevious (_ term: String, options: SearchOptions = SearchOptions(), scrollToResult: Bool = true) -> Bool
```
`TerminalViewSearch.swift:51-52`

```swift
public func searchMatchSummary (_ term: String, options: SearchOptions = SearchOptions(), limit: Int = 1000) -> (index: Int, total: Int)
```
`TerminalViewSearch.swift:79`

```swift
public func clearSearch ()
```
`TerminalViewSearch.swift:94`

```swift
public struct SearchOptions: Equatable {
    public var caseSensitive: Bool
    public var regex: Bool
    public var wholeWord: Bool
    public init (caseSensitive: Bool = false, regex: Bool = false, wholeWord: Bool = false)
}
```
`Sources/SwiftTerm/SearchOptions.swift:12-23`

The macOS find bar is wired through `@objc open func performFindPanelAction(_ sender: Any?)`
(`MacTerminalView.swift:3255`) and `open override func performTextFinderAction(_ sender: Any?)` (`:3274`).

### 1.10 Other public view API

```swift
public weak var terminalDelegate: TerminalViewDelegate?
```
`MacTerminalView.swift:259` — do not repoint this on `LocalProcessTerminalView`; its own class comment warns that it
captures the delegate and that replacing it breaks internals (`MacLocalTerminalView.swift:215-232`).

```swift
@MainActor @discardableResult
public func updateUiClosed() -> Bool
```
`MacTerminalView.swift:1129-1131` — owner must call this when permanently releasing the view; returns `false` if
committed GPU work is still active and the owner must retry.

```swift
public func setUseMetal(_ enabled: Bool) throws          // MacTerminalView.swift:641
public var isUsingMetalRenderer: Bool                    // MacTerminalView.swift:398
public var isUsingRenderLoop: Bool                       // MacTerminalView.swift:439
public var metalBufferingMode: MetalBufferingMode        // MacTerminalView.swift:375
public var metalScaleFactorOverride: CGFloat?            // MacTerminalView.swift:382
public func drawMetalFrameNow()                          // MacTerminalView.swift:407
public static func openDefaultLink (_ link: String)      // MacTerminalView.swift:4662
public nonisolated static var onFramePresented: (@Sendable () -> Void)?  // AppleTerminalView.swift:1372
public func refreshKittyClipboardCapabilities()          // AppleTerminalView.swift:1234
public func updateColorScheme(_ colorScheme: TerminalColorScheme, notify: Bool = true) // AppleTerminalView.swift:1677
public nonisolated func notifyColorScheme()              // AppleTerminalView.swift:1686
public nonisolated func softReset()                      // AppleTerminalView.swift:1701 (DECSTR)
public nonisolated func resetToInitialState()            // AppleTerminalView.swift:1706 (RIS)
public func setCursorStyle(_ style: CursorStyle)         // AppleTerminalView.swift:1711
public nonisolated func previousSemanticPromptRow() -> Int? // AppleTerminalView.swift:1691
public nonisolated func nextSemanticPromptRow() -> Int?     // AppleTerminalView.swift:1696
public nonisolated var keyboardEnhancementFlags: KittyKeyboardFlags // AppleTerminalView.swift:1638
public func requestRedraw ()                             // AppleTerminalView.swift:3964
```

---

## 2. `LocalProcessTerminalView` (PTY host)

### 2.1 Class and initializers

```swift
open class LocalProcessTerminalView: TerminalView, TerminalViewDelegate
```
`Vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift:241`

```swift
public override init (frame: CGRect)
```
`MacLocalTerminalView.swift:247`

```swift
public override init (frame: CGRect, font: NSFont? = nil, options: TerminalOptions)
```
`MacLocalTerminalView.swift:254`

```swift
public required init? (coder: NSCoder)
```
`MacLocalTerminalView.swift:260`

All three call internal `setup()`, which sets `terminalDelegate = self`, builds a private
`LocalProcessTerminalViewProcessAdapter`, and creates the `LocalProcess` with
`dispatchQueue: .main, directDelivery: true` (`MacLocalTerminalView.swift:266-292`).

```swift
public weak var processDelegate: LocalProcessTerminalViewDelegate?
```
`MacLocalTerminalView.swift:308`

### 2.2 Process handle, PID, terminate

```swift
public internal(set) var process: LocalProcess!
```
`MacLocalTerminalView.swift:243` — public getter, **setter is internal** (cannot be replaced from our module).

`LocalProcess` is `public class LocalProcess` (`Sources/SwiftTerm/LocalProcess.swift:208`) with:

```swift
public var childfd: Int32
```
`LocalProcess.swift:215` — primary PTY descriptor, `-1` when inactive.

```swift
public var shellPid: pid_t
```
`LocalProcess.swift:222` — child PID, 0 when inactive. Doc warns: during teardown it becomes 0 while `running` is
still true, so check for a positive value before `kill` (`LocalProcess.swift:218-221`).

```swift
public var running: Bool
```
`LocalProcess.swift:371` — true while running/terminating/exited (i.e., during the final drain).

```swift
public var windingDown: Bool
```
`LocalProcess.swift:379` — true while an exit/launch-failure callback awaits delivery.

```swift
public var drainTimeout: TimeInterval        // LocalProcess.swift:228
public var killEscalationDelay: TimeInterval // LocalProcess.swift:234
public func terminalControlBytesForPaste() -> Set<UInt8>? // LocalProcess.swift:244
public func updateWindowSize(_ size: inout winsize) -> Bool // LocalProcess.swift:747
```

Terminate / kill:
```swift
public func terminate()
```
`MacLocalTerminalView.swift:446` (view) and `LocalProcess.swift:711` (process). It sends **SIGTERM**; the session
stays occupied until the child actually exits — `running` remains true, `startProcess` is refused, and
`processTerminated` fires after reap + final drain (`LocalProcess.swift:703-729`). A child that ignores SIGTERM keeps
the session occupied indefinitely; use `kill(process.shellPid, SIGKILL)` for force-kill, or release the instance,
whose deinitializer escalates after `killEscalationDelay` (`LocalProcess.swift:706-711`, `:437-445`).
There is no `kill()`/`SIGKILL` method on the library.

### 2.3 `startProcess` — exact signature, cwd, env, args, execName

```swift
public func startProcess(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil)
```
`MacLocalTerminalView.swift:434` (view) and `LocalProcess.swift:542` (process).

```swift
@discardableResult
public func startProcessChecked(executable: String = "/bin/bash", args: [String] = [], environment: [String]? = nil, execName: String? = nil, currentDirectory: String? = nil) -> Result<Void, LocalProcessError>
```
`LocalProcess.swift:551` — reports busy/fork/input-channel failure as a typed `LocalProcessError`
(`LocalProcess.swift:133-139`: `.alreadyRunning`, `.notRunning`, `.forkFailed(Int32)`,
`.writeChannelFailed(Int32)`, `.writeFailed(code:bytesWritten:)`). The unchecked `startProcess` reports launch
failure through `processFailedToStart` instead, and is **silently ignored while a previous session is active**
(including the `windingDown` window) (`LocalProcess.swift:534-541`).

Parameter semantics (source: `LocalProcess.swift:542-601`):
- `args` — the child arguments; the library inserts `execName` or `executable` at index 0
  (`LocalProcess.swift:588-593`).
- `environment` — **if non-nil it replaces the environment entirely; it is NOT merged with the parent**
  (`LocalProcess.swift:595-600`). If nil, `Terminal.getEnvironmentVariables(termName: "xterm-256color")` is used.
- `execName` — `argv[0]`.
- `currentDirectory` — child `chdir` target (`Pty.swift:133-135`).
- The child is launched with `forkpty` then `execve` (`Pty.swift:60-138`); `_exit(127)` if exec fails
  (`Pty.swift:137-138`), which surfaces as exit code 127 through `processTerminated`.

`TERM` and environment defaults (source-verified):
- Default env (only when `environment == nil`) is `Terminal.getEnvironmentVariables(termName: "xterm-256color")`
  (`LocalProcess.swift:597`), which produces `TERM=xterm-256color`, `COLORTERM=truecolor` (unless
  `trueColor: false`), `LANG=en_US.UTF-8`, and mirrors `LOGNAME`, `USER`, `DISPLAY`, `LC_TYPE`, `USER`, `HOME`
  from the parent (`Terminal.swift:8843-8864`). **`PATH` is deliberately not copied** — it is commented out in the
  source list (`Terminal.swift:8856`). If you pass your own `environment`, no `TERM` is added by the library.
- `TerminalOptions.termName` (declared `TerminalOptions.swift:152`, default `"xterm-256color"` at `:217`) is the
  terminal's own reported name (DA/XTGETTCAP), not the child's env. The view's `startProcess` comment says so:
  "hosts that want `options.termName` in the child's environment pass `Terminal.getEnvironmentVariables(termName:)`
  explicitly" (`MacLocalTerminalView.swift:436-438`).

Terminfo: the vendored `swifterm-terminfo` file (repo root) is not installed on disk and does not set `TERM`.
The build plugin converts it into `SwiftTermTerminfo.xtgettcapReplies` (generated `SwiftTermTerminfo.swift`,
from `Sources/SwiftTermBuildInfoGenerator/XtgettcapTableGenerator.swift`), which is an internal table consulted only
when answering in-band `XTGETTCAP` queries (`Terminal.swift:1570`; also `SwiftTermTerminfo` only appears at
`EmbeddedSupport.swift:113` and `Terminal.swift:1570`). `XTGETTCAP TN` is answered from
`terminal.options.termName` (`Terminal.swift:1606-1618`).

### 2.4 Writing input to the PTY

```swift
open func send(source: TerminalView, data: ArraySlice<UInt8>)
```
`MacLocalTerminalView.swift:404` — declaration only; see §4: the runtime path does not call it.

```swift
public func send (data: ArraySlice<UInt8>)
```
`LocalProcess.swift:309` — fire-and-forget, prints on write failure.

```swift
public func send(data: ArraySlice<UInt8>,
                 completion: @escaping @Sendable (Result<Int, LocalProcessError>) -> Void)
```
`LocalProcess.swift:322-323` — "Writes owned bytes to the PTY and completes exactly once. Success is the number of
bytes written, not the number consumed by the child… Await each completion before sending the next block to bound
queued input memory."

Reachable write paths from outside: `terminalView.send(data:)` / `send(txt:)` / `send([UInt8])` / `pasteText(_:)`,
`terminalView.inputSender.send(data:)`, and `terminalView.process.send(data:)`.

### 2.5 Output hook / host logging

```swift
public func setProcessOutputHandler(_ handler: (@Sendable () -> Void)?)
```
`MacLocalTerminalView.swift:299` — "Installs a notification that runs on the process parse thread after an output
batch is applied. The handler receives no mutable terminal state and must return quickly." It fires after each batch
(runtime-verified, Appendix A.4) but receives **no bytes**.

```swift
public func setHostLogging (directory: String?)
```
`MacLocalTerminalView.swift:412` (view) and `LocalProcess.swift:736` (process) — when set, each received batch is
written to `directory + "/log-<counter>"` (`LocalProcess.swift:766-787`). This is the only public raw-byte capture
the PTY host offers.

---

## 3. Delegates

### 3.1 `LocalProcessTerminalViewDelegate`

```swift
@MainActor
public protocol LocalProcessTerminalViewDelegate: AnyObject {
```
`MacLocalTerminalView.swift:19-20`. Every method below is `@MainActor` because the protocol is annotated.
All process-delegate callbacks are delivered on the main actor (view methods are main-actor via `NSView`; the private
adapter hops termination/failure with `Task { @MainActor in … }`, `MacLocalTerminalView.swift:174-182`, and
title/directory/size go through `onMain`, `MacTerminalView.swift:4454-4470`).

Required (no default implementation — a conforming type must implement these four):

```swift
func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int)
```
`MacLocalTerminalView.swift:28`

```swift
func setTerminalTitle(source: LocalProcessTerminalView, title: String)
```
`MacLocalTerminalView.swift:35`

```swift
func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?)
```
`MacLocalTerminalView.swift:42` — note `source` is `TerminalView`, not `LocalProcessTerminalView`.

```swift
func processTerminated (source: TerminalView, exitCode: Int32?)
```
`MacLocalTerminalView.swift:50` — "the normalized exit status from 0 through 255, or nil when the process ended
because of a signal or the wait failed". `source` is `TerminalView`.

Optional (default implementations in `public extension LocalProcessTerminalViewDelegate`,
`MacLocalTerminalView.swift:96-135`):

```swift
func processFailedToStart(source: TerminalView, error: LocalProcessError)
```
`MacLocalTerminalView.swift:53`; default at `:97`. "Reports a launch failure, separate from child exit."

```swift
func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities
func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]?
func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult?
func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult
func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult
```
`MacLocalTerminalView.swift:63-92`; defaults at `:99-135` (deny everything / `.unsupported`). The protocol compiles
with only the four required methods (conformance probe, Appendix A.3).

`Sendable`: the protocol is `AnyObject` and `@MainActor`; it is **not** declared `Sendable`. Conforming classes are
main-actor isolated by the protocol annotation.

### 3.2 `TerminalViewDelegate` (implemented by `LocalProcessTerminalView`, relevant to `TerminalView` hosts)

```swift
@MainActor
public protocol TerminalViewDelegate: AnyObject {
```
`Sources/SwiftTerm/Apple/TerminalViewDelegate.swift:13-14`.

Required on macOS (no default implementation):
```swift
func sizeChanged (source: TerminalView, newCols: Int, newRows: Int)   // :57
func setTerminalTitle(source: TerminalView, title: String)            // :62
func hostCurrentDirectoryUpdate (source: TerminalView, directory: String?) // :67
func send (source: TerminalView, data: ArraySlice<UInt8>)             // :73
func scrolled (source: TerminalView, position: Double)                // :79
func rangeChanged (source: TerminalView, startY: Int, endY: Int)      // :180
```
The conformance probe failed with exactly `scrolled` and `rangeChanged` missing when only the other four were
implemented (Appendix A.3).

Optional on macOS (defaults in `extension TerminalViewDelegate`, `MacTerminalView.swift:4702-4730` and
`AppleTerminalView.swift:4886-4922`):
```swift
func requestOpenLink (source: TerminalView, link: String, params: [String:String]) // :95, default :4711
func bell (source: TerminalView)                                   // :100, default :4716
func clipboardCopy(source: TerminalView, content: Data)            // :111, default :4724
func clipboardRead(source: TerminalView) -> Data?                  // :126, default :4727 (returns nil = deny)
func iTermContent (source: TerminalView, content: ArraySlice<UInt8>) // :174, default :4721
func kittyClipboard*                                               // :129-170, defaults AppleTerminalView.swift:4886+
```

### 3.3 `LocalProcessDelegate` — the public raw-bytes delegate (capture path, see §4)

```swift
public protocol LocalProcessDelegate: AnyObject {
    func processTerminated (_ source: LocalProcess, exitCode: Int32?)
    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError)
    func dataReceived (slice: ArraySlice<UInt8>)
    func getWindowSize () -> winsize
}
```
`Sources/SwiftTerm/LocalProcess.swift:143-159`. Not `@MainActor`. `processFailedToStart` has a default
(`:162-166`), so the other three are required. `winsize` is available with `import AppKit`/Foundation on macOS
(compile-verified without `import Darwin`, Appendix A.3).

```swift
public convenience init (delegate: LocalProcessDelegate, dispatchQueue: DispatchQueue? = nil, directDelivery: Bool = false)
```
`LocalProcess.swift:280`. With `directDelivery: false`, `dataReceived(slice:)` runs on `dispatchQueue`
(or a private serial queue if nil); with `true` it runs on the IO parse thread
(`MigratingFrom1To2.md`; `LocalProcess.swift:792-815`).

---

## 4. Capture hooks for scrollback persistence (ring buffer)

Question: can we intercept everything the PTY outputs while still feeding the terminal normally?

### 4.1 `LocalProcessTerminalView.dataReceived(slice:)` is dead as a capture hook

Declaration (overridable, `open`):
```swift
open func dataReceived(slice: ArraySlice<UInt8>)
```
`MacLocalTerminalView.swift:465`.

But `setup()` installs a **private** `LocalProcessTerminalViewProcessAdapter` as the `LocalProcess` delegate
(`MacLocalTerminalView.swift:266-292`), and that adapter feeds the terminal directly:

```swift
func dataReceived(slice: ArraySlice<UInt8>) {
    frameSignal.markDirty()
    _ = renderOwner.feed(bytes: slice)
    …
    outputHandler.call()
    frameSignal.markDirty()
}
```
`MacLocalTerminalView.swift:186-197` (and `dataReceivedBorrowed` at `:199-209`). It never calls
`self.dataReceived(slice:)` on the view.

Runtime evidence (Appendix A.4, `echo` through a real PTY in a `LocalProcessTerminalView` subclass):
```
CASE1 subclass dataReceived override calls: 0
CASE1 subclass captured bytes: 0
CASE1 buffer contains hello: true
```
So the override is **not** called; the terminal still receives output. The same is true of the input direction:
overriding `send(source:data:)` (`MacLocalTerminalView.swift:404`) never fires, because `setup()` replaces the
`inputSender` delivery closure with one that writes straight to the adapter (`MacLocalTerminalView.swift:290-292`,
`AppleTerminalView.swift:1140-1147`). Runtime evidence:
```
send(source:data:) override calls: 0, bytes: 0
cat echoed typed-line through pty: true
```
`setProcessOutputHandler` does fire after each batch (runtime-verified: `output handler fired`) but is handed no bytes
(`MacLocalTerminalView.swift:299-301`).

**Conclusion: from an external module there is no overridable hook on `LocalProcessTerminalView` that both sees the
raw PTY bytes and keeps the view's internal adapter feeding. Do not build the ring buffer on a
`dataReceived(slice:)` override.**

### 4.2 The supported capture architecture

Use `TerminalView` + `LocalProcess` directly. Both are public, and `LocalProcessDelegate` is a public protocol whose
`dataReceived(slice:)` receives every byte on your chosen queue. Feed the same slice into the view. This was
compile-verified and runtime-verified (Appendix A.4, CASE2):

```swift
final class Capture: LocalProcessDelegate {
    let view: TerminalView
    let process: LocalProcess
    init(view: TerminalView, queue: DispatchQueue) {
        self.view = view
        self.process = LocalProcess(delegate: self, dispatchQueue: queue, directDelivery: false)
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        ring.append(slice)                 // your persistence buffer
        view.feed(byteArray: slice)        // normal terminal feed
    }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) { … }
    func getWindowSize() -> winsize { … }  // from terminalDimensions / cell metrics
}
```
Observed: `CASE2 direct delegate dataReceived bytes: 22`, `CASE2 buffer contains direct-capture: true`,
`terminated: true exit=Optional(0)`.

Trade-offs to be aware of:
- You must implement `send(source:data:)` on the view's `TerminalViewDelegate` and forward to
  `process.send(data:)` yourself; the `LocalProcessTerminalView` conveniences (clipboard handling, title/directory
  forwarding, input coalescing, `setProcessOutputHandler`) are not present.
- `LocalProcess.init` with `directDelivery: false` delivers on the queue you pass; use a serial queue and be
  mindful that `dataReceived` must copy before returning if you hand the slice to another thread.
- `LocalProcessBorrowedDataDelegate`/`dataReceivedBorrowed` (`LocalProcess.swift:170-175`) is **internal** and cannot
  be adopted externally (negative probe), so you cannot use the zero-copy borrowed path; use `directDelivery: false`.

Alternative if you must stay on `LocalProcessTerminalView`: `setHostLogging(directory:)` writes each raw batch to a
file (`LocalProcess.swift:766-787`) and `setProcessOutputHandler` tells you when a batch landed, after which you can
copy `getBufferAsData()` for the visible content. This is file I/O plus snapshotting, not a byte hook.

---

## 5. Minimal working example

Compile-verified and launched successfully against the directly-built module (Appendix A.5). Uses only public API.

```swift
import AppKit
import SwiftTerm

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, LocalProcessTerminalViewDelegate {
    var window: NSWindow!
    var terminal: LocalProcessTerminalView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 560)
        terminal = LocalProcessTerminalView(frame: frame,
                                            font: NSFont(name: "Menlo", size: 13),
                                            options: TerminalOptions(scrollback: 10_000))
        terminal.processDelegate = self
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white
        terminal.caretColor = .green
        terminal.selectedTextBackgroundColor = .systemBlue
        terminal.autoresizingMask = [.width, .height]

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = terminal
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        terminal.startProcess(executable: "/bin/zsh",
                              args: ["-l"],
                              environment: env,
                              execName: "zsh",
                              currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { window.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { window.close() }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
```

Build flags used for verification (must also compile the generated files, §0.1):
```
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos26.0 \
  -I <module-dir> -L <module-dir> -lSwiftTerm \
  -Xlinker -rpath -Xlinker <module-dir> -o example example.swift
```
Runtime smoke test: process stayed alive with a zsh PTY for 6 s, then was terminated (Appendix A.5).

---

## 6. Gotchas / embedding contract

From `Documentation.docc/Embedding.md`, `GettingStarted.md`, `Mac/README.md`, `MigratingFrom1To2.md`, and the
source comments:

1. **Do not animate a window resize from `sizeChanged`.** `setFrame(_:display:animate: true)` emits intermediate
   frames, each resizing the terminal and calling back; measured main-thread stall p99 14–35 ms animated vs
   6–17 ms not (`Embedding.md`, `TerminalViewDelegate.swift:16-56`). Guard by **comparing frames**, not with a
   re-entrancy flag: during a live drag the notification is coalesced to one per display frame and arrives after the
   flag is cleared (`Embedding.md`, "Guard by comparing, not with a flag";
   `TerminalViewDelegate.swift:31-56`).
2. **`feed` and `send` are thread-safe, but not re-entrant.** They are callable from any thread
   (`AppleTerminalView.swift:4411`, `:4485-4487`), but must not be called from inside a terminal delegate callback:
   those run with the terminal lock held, and these take it; a precondition catches it rather than deadlocking
   (`Embedding.md`; `AppleTerminalView.swift:4481-4487`). Ordering between concurrent senders is the caller's
   problem.
3. **Delegate callbacks can run on the parse thread with the terminal lock held.** Keep them short, marshal UI to the
   main thread yourself; reading terminal state inside the callback is fine, calling back into SwiftTerm APIs that
   take the lock is not (`Embedding.md`, "Delegate callbacks and the terminal lock").
4. **Terminal ownership.** `TerminalView` owns its mutable `Terminal` and does not expose it; use the copied reads
   (`terminalDimensions`, `terminalStateSnapshot()`, `getBufferAsData(kind:encoding:)`) and the command entry points
   (`MacTerminalView.swift:97-103`; `MigratingFrom1To2.md`). `getTerminal()` is gone in 2.0.
5. **No SwiftPM needed for the sources, but the generated files are.** See §0.1.
6. **`LocalProcessTerminalView` captures its own `terminalDelegate`.** Its class comment: "instances … will set the
   `TerminalView`'s `delegate` property and capture and consume the messages… If you override the `delegate`
   directly, you might inadvertently break the internal working" (`MacLocalTerminalView.swift:215-232`).
7. **`LocalProcess` relaunch window.** `startProcess` is silently ignored while a previous session is active,
   including after `running` turns false during `windingDown`; relaunch from inside `processTerminated` or wait for
   both flags to clear (`LocalProcess.swift:534-541`). Use `startProcessChecked` for a typed error.
8. **Termination is asynchronous.** `terminate()` sends SIGTERM; `running` stays true and the session stays occupied
   until the child exits and output is drained (`LocalProcess.swift:703-729`). Exit-code normalization:
   0–255, nil on signal/wait failure (`LocalProcess.swift:463-466`).
9. **`resize(cols:rows:)` soft-resets the terminal** (`AppleTerminalView.swift:4431-4434`).
10. **Live-resize coalescing is intentionally only for live drags**; programmatic frame changes stay synchronous, and
    the library cannot safely coalesce everything because that disarms host re-entrancy guards
    (`Embedding.md`, "Why the library cannot simply fix this for you").
11. **Teardown:** call `updateUiClosed()` when permanently releasing the view (`MacTerminalView.swift:1124-1131`);
    a temporary `window == nil` is not teardown.
12. **`Mac/README.md`** is only a two-sentence description of the directory (AppKit front end; `MacTerminalView`
    file contains `TerminalView`, plus `LocalProcessTerminalView`) — `Sources/SwiftTerm/Mac/README.md`.
13. **Direct `LocalProcess` usage** requires implementing `TerminalViewDelegate.send` yourself and forwarding to
    `process.send(data:)`; `HeadlessTerminal` is the alternative when no view is wanted
    (`GettingStarted.md`, "Headless: Scripting and Testing"; `MigratingFrom1To2.md`).

---

## 7. Access-level blockers (not usable from an external module)

Verified by negative compile probes (Appendix A.3). "Suggested alternative" is public API only.

| Blocked API | Cite | Level | Suggested public alternative |
| --- | --- | --- | --- |
| `TerminalView.terminal` (`var terminal: Terminal!`) | `MacTerminalView.swift:487` | internal | `terminalDimensions`, `terminalStateSnapshot()`, `getBufferAsData(kind:encoding:)`, `observeOscEvents` |
| `TerminalView.getTerminal()` | — | does not exist (removed in 2.0) | same as above |
| `TerminalView.selection` (`SelectionService`) | `MacTerminalView.swift:504` | internal | `getSelection()`, `selectionActive`, `selectAll()`, `selectNone()` |
| `TerminalView.search` (`SearchService`) | `MacTerminalView.swift:294` | internal | `findNext`, `findPrevious`, `searchMatchSummary`, `clearSearch` |
| `TerminalView.caretView` | `MacTerminalView.swift:484` | internal | `caretColor`, `caretTextColor`, `caretFrame`, `setCursorStyle` |
| `TerminalView.cellDimension` | `MacTerminalView.swift:483` | internal | `getOptimalFrameSize()`, `terminalDimensions` |
| `TerminalView.startupOptions` | `MacTerminalView.swift:536` | internal | pass `TerminalOptions` to `init(frame:font:options:)` |
| `TerminalView.withTerminal(_:)` | `AppleTerminalView.swift:1613` | internal | copied reads (see above) |
| `TerminalView.processSizeChange(newSize:)` | `AppleTerminalView.swift:1809` | internal | `setFrameSize(_:)`, `resize(cols:rows:)` |
| `TerminalView.queueSizeChange(newSize:)` | `AppleTerminalView.swift:1791` | internal | `setFrameSize(_:)` |
| `TerminalView.resetFont()` | `AppleTerminalView.swift:1509` | internal | assign `font` (setter triggers it) or `resetFontSize()` |
| `TerminalView.setupOptions()` | `MacTerminalView.swift:1155` | internal | construct with `init(frame:font:options:)` |
| `TerminalView.makeFirstResponder()` | `MacTerminalView.swift:1701` | internal | `window?.makeFirstResponder(view)` |
| `FontSet` (struct + `init(font:fontSize:)`) | `MacTerminalView.swift:222`, `:236` | internal | `font` property, `resetFontSize()`; `fontSize:` is ignored anyway (`:236-242`) |
| `LocalProcessTerminalView.process` setter | `MacLocalTerminalView.swift:243` | `internal(set)` | create a `LocalProcess` yourself (§4.2) |
| `LocalProcessTerminalView.sizeChanged/setTerminalTitle/hostCurrentDirectoryUpdate/clipboardCopy/clipboardRead` | `MacLocalTerminalView.swift:319,345,349,327,335` | `public` but **not `open`** — cannot override in a subclass | implement `processDelegate` (title/dir); subclass `TerminalView` for clipboard overrides |
| `LocalProcessBorrowedDataDelegate` / `dataReceivedBorrowed(_:)` | `LocalProcess.swift:170-171` | internal protocol | `LocalProcessDelegate.dataReceived(slice:)` with `directDelivery: false` |
| `LocalProcess.init(delegate:dispatchQueue:directDelivery:duplicateDescriptor:)` | `LocalProcess.swift:287-289` | internal | public convenience `init(delegate:dispatchQueue:directDelivery:)` (`:280`) |
| `LocalProcess.debugIO`, `sendCount`, `total`, `dispatchQueue`, `directDelivery` | `LocalProcess.swift:253-263` | internal | `send(data:completion:)` for write results |
| `Color.defaultForeground` / `Color.defaultBackground` | `Colors.swift` (unmarked statics) | internal | `Color.defaultInstalledColors`, public `Color` initializers |
| `SwiftTermTerminfo.xtgettcapReplies` | `Terminal.swift:1570` | internal | none (internal XTGETTCAP table; no host API) |

**Dead-but-open hooks** (compile-visible, never invoked by the vendored implementation — do not rely on them):
`LocalProcessTerminalView.dataReceived(slice:)` (`MacLocalTerminalView.swift:465`) and
`LocalProcessTerminalView.send(source:data:)` (`MacLocalTerminalView.swift:404`). Runtime evidence in §4.1.

**Open hooks that do fire:** `processTerminated(_:exitCode:)`, `processFailedToStart(_:error:)`,
`getWindowSize()` (view overrides are consulted when `startProcess`/`sizeChanged` snapshot the size),
`scrolled(source:position:)`, `rangeChanged(source:startY:endY:)`, `requestOpenLink(source:link:params:)`,
and the `kittyClipboard*` methods. Runtime-verified for `processTerminated`, `getWindowSize`, `scrolled`
(Appendix A.4).

---

## 8. APIs requested but NOT FOUND

- `TerminalView.getTerminal()` — removed in 2.0 (`MigratingFrom1To2.md`), no source declaration, compile probe fails.
- `Terminal.getBufferAsString` / `TerminalView.getBufferAsString` — no occurrence anywhere in the vendored tree
  (`grep -rn getBufferAsString` over `*.swift`/`*.md` → empty).
- `maxScrollingHistory` — no occurrence anywhere (`grep -rn maxScrollingHistory` → empty).
- `scroll(to:)` — no such method; use `scroll(toPosition:)` / `scrollTo(row:)`.
- `feed(data:)` — no such method; use `feed(byteArray:)` / `feed(text:)`.
- Public font-size / font-family property — none; set an `NSFont` on `font`.
- Public `Terminal` accessor on the view — none.
- Public line-level buffer/scrollback accessor — none; `getBufferAsData(kind:encoding:)` (whole buffer incl.
  scrollback as text) and `terminalStateSnapshot().visibleRows` are the only copied reads.
- Public SIGKILL / kill API — none; `terminate()` is SIGTERM only, `shellPid` + `kill(2)` otherwise.
- Public API to set the terminal mouse mode — none (read-only `currentMouseMode`).

---

## Appendix A — Verification commands and observed output

Environment: `swiftc --version` → `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`,
target `arm64-apple-macosx26.0`; `sw_vers` → macOS 26.6.2 (25G83). All probes used the vendored source at
`fe4fb45`.

### A.1 Module build

```
swiftc -emit-library -emit-module -module-name SwiftTerm -swift-version 6 \
  -target arm64-apple-macos26.0 \
  -o /tmp/stbuild/module/libSwiftTerm.dylib \
  -emit-module-path /tmp/stbuild/module/SwiftTerm.swiftmodule \
  @/tmp/stbuild/sources.txt /tmp/stbuild/gen/SwiftTermBuildInfo.swift /tmp/stbuild/gen/SwiftTermTerminfo.swift
```
Observed: exit 0, `libSwiftTerm.dylib` + `SwiftTerm.swiftmodule` produced; only `CVDisplayLink*` deprecation
warnings. `sources.txt` contained all 107 `*.swift` files under `Sources/SwiftTerm`.
The two generated files were produced by compiling and running `Sources/SwiftTermBuildInfoGenerator/*.swift`;
`SwiftTermBuildInfo.swift` contains `commit = "fe4fb45d5888ce33ff3788d6873870a73894a41b"`.

### A.2 Positive API probe

A single Swift file importing only `SwiftTerm`/`AppKit` referenced every API documented in §1–§3, including
subclass overrides, protocol conformances, and the full `startProcess` parameter list:
```
swiftc -typecheck -swift-version 6 -target arm64-apple-macos26.0 -I /tmp/stbuild/module probe/probe.swift
EXIT: 0
```
This probe is what established that `sizeChanged/setTerminalTitle/hostCurrentDirectoryUpdate/clipboardCopy/clipboardRead`
on `LocalProcessTerminalView` are `public` but not overridable (compile errors "overriding non-open instance method
outside of its defining module"), while `dataReceived`, `send`, `processTerminated`, `processFailedToStart`,
`getWindowSize`, `scrolled`, `rangeChanged`, `requestOpenLink`, `kittyClipboard*`, and `getOptimalFrameSize` are
overridable.

### A.3 Negative access probe

One snippet per candidate compiled separately; result classified as ACCESSIBLE / INACCESSIBLE with the compiler's
first error. Blocked (representative output):
```
INACCESSIBLE | v.terminal :: 'terminal' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.getTerminal() :: value of type 'LocalProcessTerminalView' has no member 'getTerminal'
INACCESSIBLE | v.selection :: 'selection' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.withTerminal { } :: 'withTerminal' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.processSizeChange(newSize:) :: 'processSizeChange' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.queueSizeChange(newSize:) :: 'queueSizeChange' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.resetFont() :: 'resetFont' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.setupOptions() :: 'setupOptions' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.makeFirstResponder() :: 'makeFirstResponder' is inaccessible due to 'internal' protection level
INACCESSIBLE | FontSet(font:) :: cannot find 'FontSet' in scope
INACCESSIBLE | v.search :: 'search' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.caretView :: 'caretView' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.cellDimension :: 'cellDimension' is inaccessible due to 'internal' protection level
INACCESSIBLE | v.processAdapter :: 'processAdapter' is inaccessible due to 'private' protection level
INACCESSIBLE | v.startupOptions :: 'startupOptions' is inaccessible due to 'internal' protection level
INACCESSIBLE | LocalProcessBorrowedDataDelegate :: cannot find type 'LocalProcessBorrowedDataDelegate' in scope
INACCESSIBLE | Color.defaultForeground :: 'defaultForeground' is inaccessible due to 'internal' protection level
```
Everything else in §1–§3 compiled: `terminalDimensions`, `currentMouseMode`, `getBufferAsData`,
`feedSender`, `updateUiClosed`, `setProcessOutputHandler`, `changeScrollback`, `scroll(toPosition:)`,
`findNext`, `pasteText`, `Terminal.getEnvironmentVariables`, `Terminal(delegate:options:)`, `installColors`,
`setUseMetal`, `observeOscEvents`, `resetFontSize`, `getOptimalFrameSize`, `scrollerStyle`, `hasFocus`,
`optionAsMetaKey`, `suspendsRenderingWhenNotVisible`, `bidiHostPolicy`, `fontSmoothing`, `lineSpacing`,
`bellStyle`, `linkReporting`, `linkHighlightMode`, `ansi256PaletteStrategy`, `maximumBidiParagraphRows`,
`scrollSensitivity`, `metalBufferingMode`, `isUsingRenderLoop`, `drawMetalFrameNow`,
`TerminalView.onFramePresented`, `TerminalView.openDefaultLink`, and the properties in the §1.2 table.

Protocol conformance probes:
- `TerminalViewDelegate` with only `sizeChanged/setTerminalTitle/hostCurrentDirectoryUpdate/send` failed with
  "protocol requires function 'scrolled(source:position:)'" and "'rangeChanged(source:startY:endY:)'".
- `LocalProcessTerminalViewDelegate` with only the four required methods compiled (exit 0).
- `LocalProcessDelegate` conformance (with `winsize` and no `import Darwin`) compiled (exit 0).

### A.4 Runtime probes

Built as executables linked against the module, run with a main run loop.

PTY capture probe (`/bin/echo`, real forkpty):
```
CASE1 subclass dataReceived override calls: 0
CASE1 subclass captured bytes: 0
CASE1 subclass terminated: true
CASE1 subclass getWindowSize override calls: 2
CASE1 buffer contains hello: true
CASE2 direct delegate dataReceived bytes: 22
CASE2 direct delegate terminated: true exit=Optional(0)
CASE2 direct delegate getWindowSize calls: 1
CASE2 buffer contains direct-capture: true
```
Input-direction probe (`/bin/cat`):
```
send(source:data:) override calls: 0, bytes: 0
cat echoed typed-line through pty: true
terminated: true
```
Output-handler / scroll probe:
```
output handler fired
scrolled override calls: 1
canScroll: true scrollPosition: 0.9646643109540636
```

### A.5 Minimal example

Built with the flags in §5; exit 0. Runtime smoke test: launched, kept a `/bin/zsh -l` PTY alive, then terminated
by the test harness:
```
EXAMPLE BUILD EXIT: 0
RUNNING OK (pid 49469)
```

### A.6 Grep-based NOT FOUND checks

```
grep -rn "getBufferAsString" --include="*.swift" --include="*.md" .   # empty
grep -rn "maxScrollingHistory" --include="*.swift" --include="*.md" . # empty
grep -rn "func scroll(to\b" --include="*.swift" .                     # empty
grep -rn "func feed(data\|func feed (data" --include="*.swift" .      # empty
grep -rn "func getTerminal\b" Sources/                                # empty
```
