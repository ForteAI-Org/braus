# Driving Mac apps in the background: what other projects do

For Braus developers working on [the MacDriver](2026-10-14-mac-driver-design.md). Read on 14 October
2026 from the source of four open projects, at the commits below. It records what each one does,
what the MacDriver takes and what it leaves, with the files to read before writing the code. None
of their code has been run here; every claim below is from reading it, and the ones about app
behaviour are theirs, to confirm on our probes.

| Project | Commit | Language, licence | In one line |
| --- | --- | --- | --- |
| [actuallyepic/background-computer-use](https://github.com/actuallyepic/background-computer-use) | `52116ac` | Swift, MIT | the most complete: AX state pipeline, per-route fallbacks with typed reasons, SkyLight clicks |
| [opensymph/open-computer-use](https://github.com/opensymph/open-computer-use) | `5b433b9` | Swift (+ Go for Windows/Linux), MIT | the cleanest SkyLight click (`sky_click`), fail-closed, a safety denylist |
| [hyprcat/mac-cua](https://github.com/hyprcat/mac-cua) | `362393e` (`release`) | Python, Apache-2.0 | user-interruption detection, event-driven settling, tree pruning |
| [Panchangam18/background-computer-use](https://github.com/Panchangam18/background-computer-use) | `c8ce895` | Python, MIT | an app-by-app matrix of what works in the background, a background-safe scroll ladder |

Licences are compatible with Braus's Apache-2.0. We take ideas and recipes and write our own code;
if a function is copied, its file keeps the original copyright line and `THIRD_PARTY_NOTICES` gets
an entry.

## 1. Clicking a window that is not in front

The public `CGEvent.postToPid` reaches AppKit apps but Chromium and Electron drop its clicks. Both
Swift projects use the same recipe, taken from Cua Driver:

1. Resolve the window's owner connection and PSN (`CGSGetWindowOwner`, `CGSGetConnectionPSN`, or
   `GetProcessForPID`) and its window-server bounds (`CGWindowListCopyWindowInfo`).
2. Check the window is still on screen and owned by the pid; refuse otherwise ("stale target, read
   the state again").
3. Focus without raise: `SLPSPostEventRecordTo` with an activation record for the target window, so
   the app becomes AppKit-active for routing while its window keeps its place in the stack.
4. Post through `SLEventPostToPid`: one `mouseMoved` at the target, a primer down/up at (-1, -1)
   (advances Chromium's user-activation gate), then the real down/up pairs, about 1 ms within a pair
   and 80 ms between pairs.
5. Stamp every event: target pid (field 40), window number (51, 91, 92), owner connection (52, 85 in
   actuallyepic), subtype 3, click state, a click group id (58), window-local point via
   `CGEventSetWindowLocation`.
6. Keep the synthetic focus about 100 ms after the last up (Chromium's renderer hop), then deactivate
   only the target.

open-computer-use posts each event through both SkyLight and `postToPid` as one policy. Both refuse
when a symbol is missing instead of falling back silently. open-computer-use's live regression
checks, besides the click's effect, that the person's front app kept AppKit active, its key window,
its first responder, and counts key-loss events.

Read: actuallyepic `Actions/Click/NativeBackgroundClickTransport.swift`; open-computer-use
`packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{SkyClickSimulation,SkyLightSPI}.swift`,
`docs/RELIABILITY.md`.

**MacDriver takes:** the recipe as mode 2's click, behind the build ledger and `PrivateSymbols`,
fail-closed; the live check on the person's front app as a required test.

## 2. Accessibility actions first, and which ones are safe

actuallyepic presses only roles where the press means the click (`AXButton`, `AXLink`, `AXCheckBox`,
`AXRadioButton`, `AXPopUpButton`, `AXDisclosureTriangle`, `AXSlider`, `AXSwitch`), uses `AXPick` for
pop-up and menu buttons, selects table and outline rows with `AXSelectedRows` on the container or
`AXSelected` on the row, retargets a click on a group or row to its one actionable descendant with a
matching label, and otherwise returns `coordinate_required` rather than guessing. Every fallback has
a typed reason (`ax_coordinate_required`, `missing_stable_ax_coordinate`, `stale_coordinate_guard`,
...). A `stateToken` from the last read makes a click refuse when the live state no longer matches.

Panchangam refuses `AXShowMenu`, `AXShowAlternateUI` and `AXRaise` by default: they bring the app to
the front.

Panchangam's matrix: sidebars built on `NSOutlineView`/`NSTableView` in Finder, System Settings, Mail
and Music accept `AXPress` and report success, but the app commits the selection only when the
window is key. The AX call succeeds; nothing changes.

Read: actuallyepic `Actions/Click/ClickRouteService.swift` (`exactPrimaryAction`,
`safeUniqueDescendantRetarget`), `Contracts/ClickActionContracts.swift`; Panchangam
`server/cua_server.py` (`_FOREGROUND_STEALING_ACTIONS`), `docs/APPS.md`.

**MacDriver takes:** the press-role list, `AXPick`, row selection, the unique-descendant retarget,
typed fallback reasons, the stale-state refusal. `AXShowMenu` and `AXRaise` leave rung 1. A
focus-dependent selection is caught by the read-back and climbs to mode 2.

## 3. Typing

Keys go by `CGEvent.postToPid` with `keyboardSetUnicodeString`, one character (actuallyepic) or a
chunk (open-computer-use) per event; key combos as one event with flags (mac-cua: discrete
`flagsChanged` events leak into the global modifier state). Keys sent to a pid land in the app's key
window, not necessarily the window aimed at; actuallyepic writes `AXValue` partly for that reason.
Panchangam focuses the element with `AXFocused` before a key.

actuallyepic and open-computer-use write `AXValue` when the field is settable, then restore the caret
with `AXSelectedTextRange`, and fall back to keys.

**MacDriver takes:** keys by pid, modifiers as flags, `AXFocused` on the field first, and the target
window made main (`AXMain`) before typing. **Leaves:** the `AXValue` write. Braus's L10 rule stands:
SwiftUI and web fields can show a value they never commit.

## 4. Scrolling without focus

Panchangam's ladder, all background-safe: the element's or its scroll bar's `AXScroll…ByPage`
action; the scroll bar's `AXValue`; wheel events to the pid, and for a view inside a `WKWebView` to
the `com.apple.WebKit.WebContent` helper that owns it. Chromium drops synthetic wheel events when its
window is not key. If the scroll bar did not move, it says so instead of pressing PageDown. mac-cua
sends pixel deltas both as integer and fixed-point for Chromium and Cocoa.

Read: Panchangam `server/cua_server.py` (`scroll`); actuallyepic `Actions/Scroll/ScrollRouteService.swift`
(surface classes `native_transparent`, `opaque_web`, `opaque_window_only`).

**MacDriver takes:** the ladder and the WebContent pid routing. A scroll bar is not a text field, so
its `AXValue` write is allowed.

## 5. Noticing the person

mac-cua runs a listen-only session event tap for mouse-down and key-down. A real event whose target
pid is the controlled app marks it interrupted; the next tool call fails with "the user changed
the app, read its state again". Events posted to a pid do not pass that tap, so the agent's own input
is not mistaken for the person's. A frontmost-app tracker logs focus theft without fighting it.

Read: mac-cua `app/_lib/focus.py` (`UserInteractionMonitor`, `FrontmostAppTracker`).

**MacDriver takes:** this instead of a timer: the session stops and asks for a fresh read when the
person touched the target app. Braus's `InteractionListener` may already give the events; check it
before writing a new tap.

## 6. Settling and the tree

mac-cua: one `AXObserver` per pid on a dedicated run-loop thread; settle on 150 ms without a
notification, capped at 2 s; no notification within the first quiet period means no change, which is
itself a result. Its experimental branch dropped "no observed effect" errors built on notifications:
AX notifications lag and gave false negatives; it reads the tree again instead.

actuallyepic: `AXUIElementSetMessagingTimeout` of 1 s on the app and window discovery, 0.25 s per
element during the walk, 0.05 s for frames in dense collections. `AXManualAccessibility` only for
apps whose bundle has the Electron or Chromium Embedded framework; `AXEnhancedUserInterface` only for
Catalyst/UIKit. Panchangam: in Electron only the key window has a rich tree; others show about ten
elements.

mac-cua's pruning passes (merge labels into controls, unwrap single-child groups, collapse wrappers,
merge adjacent text) and its re-find of a stale element by role, label and position are close to
what `MacSceneBuilder` needs.

Read: mac-cua `app/_lib/{observer,pruning,refetchable_tree}.py`; actuallyepic
`StatePipeline/AXPipelineV2/Capture/AXRawCaptureService.swift`, `Platform/AXPlatformProfileService.swift`.

**MacDriver takes:** the settle values, the timeouts, the framework-based enablement, notifications as
a settle signal only (never as proof), the pruning passes as a checklist for the scene builder.

## 7. Safety

open-computer-use never launches or drives password managers (1Password, Bitwarden, Dashlane,
LastPass, NordPass, Proton Pass) and refuses terminals and security apps at launch. Foreground input
and global pointer fallbacks sit behind explicit switches.

**MacDriver takes:** a denylist by bundle id in the engine, refused at `open_session` with a sentence.

## 8. Not taken

- `AXValue` writes into text fields (L10).
- Software cursors and their animation, the HTTP or Python servers, separately signed helper apps:
  Braus has its own host, tools and permissions.
- Per-app hint files ("skills"): in Braus that knowledge is the living memory's.
- Chrome scrolling through AppleScript JavaScript: pages belong to the WebDriver.
