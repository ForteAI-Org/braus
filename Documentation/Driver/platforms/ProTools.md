# Pro Tools background controls

Pro Tools uses the Seat's accessibility click route for ordinary windows and attested dialogs. `QtPlatform`
remains its event policy; that choice does not establish which framework drew a control.
The input driver still sends coordinates and events. Accessibility actions belong to
`SeatSession`, inside the observation admission and command gate.

## Resolving a click

`SeatControls` declines the application-wide label shortcut for `com.avid.ProTools`.
Labels such as Mute repeat across tracks. The Seat resolves the command's point inside
the observed, attested window instead.

PT's Mix hit test can return an `AXScrollArea` whose descendants omit the track strips.
The strips are children of the window. The PT route therefore starts at the exact
`AXWindows` entry, descends through the smallest containing child frames, and verifies
the parent chain, PID and window number. Equal smallest frames, cycles, foreign owners,
an unreadable path or exhausted budgets refuse before acting. The descent is limited
to 64 levels, 512 examined children and the existing 300 ms path budget.

Supported roles use the existing accessibility action mapping. An unsupported control
refuses; it does not fall back to a click that might activate PT. A qualified dialog's text
field is the narrow exception: after its own window path and requested label match, a field
without writable `AXSelectedText` receives the pointer click that enters its editor. No AX
selection is written before that click. An uncertain AX write never grants a posted retry. Each action consumes
its observation. `AXError.cannotComplete` is an attempted action with an uncertain
effect, never permission to press again. The consumer reads the effect and confirms it.

## Text fields in dialogs

Bounce Mix exposes a name field with a writable selection range before its editor exists,
but its text and focus are not writable then. Selecting the range and writing text can return
without changing the name. A pointer click creates the editable text area. `type_text` uses a
triple click to replace PT text, avoiding selection shortcuts that can reach another control,
and verifies the resulting value. The field label accompanies the click; another named field
refuses before selection. The input sequence cannot follow a newly opened dialog.

Save Session As is a native file panel. Its logical window belongs to PT, while the field
belongs to the AppKit panel service. The remote route is tried before the own-window route.
When PT's hit test names a sibling, the resolver starts at the exact panel's AX entry and
requires a bounded, unambiguous descendant path, matching parents and the content window's
current identity and geometry. Remote actuation uses that same window-scoped path. Missing
or conflicting evidence refuses before writing; the host never receives a speculative click.

## Send navigation and held palettes

The Engine recognizes the native `Send selector A` and `Send Assignment A` controls through
slot J only inside PT's matching `Sends A-E` or `Sends F-J` AX group. Opening them is audio
routing navigation. The exact `no send` choice is also allowed by selection tools when that
native opener supplies the context. Generic Send buttons and unrelated destructive menu
items retain the existing policy. A label alone is insufficient to qualify a control.

The broker's `windows` list includes small floating windows already adopted by its Seat.
Each supplemental candidate must still have the same current WindowServer identity, a usable
body and a window layer; a reused ID, vanished window or menu is excluded. This covers the
89 by 533 point, layer-three Output palette without weakening the initial launch filter.
PT supplies no title for that palette, so its entry remains untitled. Exact-title switching
uses the same candidates and still refuses ambiguity.

## PT running without a window

When `SeatBroker.launch` finds PT already running without an adoptable window, it reads
the enabled state of File > Close Session. An open session selects Window > Edit;
a closed session selects File > Dashboard. The helper checks process identity, the
menu item's owner and AXPress support, and checks for a late window before pressing
once. The broker then waits for an actual window. It does not activate PT or replay
an uncertain request through `NSWorkspace`.

The measured menu paths are English. Missing, disabled or unreadable menu items refuse.
A window on another desktop retains the broker's existing refusal. This recovery runs
when opening the broker session; it is not a loop that reopens every window a user closes.
It does not create or choose a project.

## Virtual display placement

With uneven physical displays, the lower right corner of their bounding rectangle
can lie in empty space. The host check reproduced a 304-point correction by WindowServer
because the requested virtual display did not touch a physical display.

`TopologyBaseline.cornerAttachedOrigin` now chooses the lower right corner of the
rightmost physical display, breaking a shared right edge by the lowest bottom edge.
The origin stays one point above that corner. Regression tests cover the measured
arrangement in either enumeration order and stacked displays sharing the right edge;
both retain zero overlap and one point of contact.

## Live verification, 15 October 2026

Environment: Mac16,1, arm64, macOS 27.0.1 (26A434), Pro Tools Ultimate 2026.4.1
(26.4.1.179 / 26.4.1d179). Debug build of `elio/pt-driver`, based on public
`main` at `f8dc83bf`. The fixture was a disposable session with two empty
mono audio tracks and EQ3 1-Band on the first track. Playback remained stopped.
The click probes used `restoresUserFocus: false` and
`allowUnvalidatedFocusRecovery: true`; no focus restoration was enabled. These
observations do not promote the compatibility ledger.

| Path | Observed result |
| --- | --- |
| `SeatBroker.launch`, no session | Two Dashboard recoveries, each followed by Cancel and another windowless state; same PT process. The temporary session was reopened afterward. |
| `AgentSeat.send`, Edit | Slip then Grid, with the original mode restored. Both receipts used accessibility and posted zero mouse events. |
| `AgentSeat.send`, Mix | Mute, Solo, Record Enable and Input Monitor on/off on each of two tracks: 20 presses including the guard mutes. The peer track stayed unchanged; all states and the window frame were restored. |
| `AgentSeat.send`, EQ3 | Two open, bypass on/off and close cycles. New plugin windows were automatically adopted; both closed windows left the held set, and the Seat returned to Mix. The remaining windows were returned successfully. |

The successful runs observed no PT activation, unchanged foreground application and
cursor, no physical events in the click probes, and removal of the virtual display
and cursor fence. The Dashboard probe compared foreground and cursor and recorded
activation notifications; it did not install the Seat's HID fence.

All four paths were rerun after the physical-corner correction. A preliminary
Dashboard run with a six-second probe timeout ended with `noWindowShown`; the
session was restored and no action was replayed. Two subsequent runs, each with
two recoveries, passed with the application's default 20-second timeout. The final
run had no extra observer during launch and recovered both windows in under one
second. Those passes do not explain the earlier failure; intermittent Dashboard
recovery remains a qualification limit.

Closing the selected plugin can enter the existing five-second recovery period.
The caller must confirm the measured closure, release its turn and wait for a usable
Seat before another command. A read invalidated by the target transition needs a new
observation; that is not a repeated input. Early probes exposed these sequencing
requirements and were failures, not counted as completed cycles.

## Dialog and state verification, 16 October 2026

On the same macOS build and Pro Tools version, a broker-level probe changed Solo off/on/off
on one audio track and read `[on]` and `[off]` in both Mix and Edit. The native on values were
`Selected` in Mix and `on` in Edit; both off readings were empty strings.

With the pre-existing Output panel open, Bounce Mix accepted a temporary file name and its
original name again. Both `type_text` results verified the exact value. Sample Rate changed
48 → 44.1 → 48 kHz, with both selections verified. Captures stayed titled `Bounce Mix`, at
420 by 516 points, without Output controls mixed in. Cancel closed the dialog and the Seat
returned the windows. No export or session save was requested. The final repeated cycle
recorded no workspace activation notification, and the foreground application and cursor
were unchanged. This is a broker/driver check, not a model-driven end-to-end export.

A bare `MP3` target remains ambiguous between two dropdowns. Selecting an already-selected
menu row can also refuse when its checkmark is recognized as part of the label. Neither probe
changed the value; the opened menu was closed. The verified selection cycle chose different
values and restored the original.

## Save panel, Send and Output verification, 16 October 2026

A broker/tool-level run on Mac16,1, macOS 27.0.1 (26A434), PT 26.4.1.179, with changes over
`d306b854`, reproduced Save Session As refusing its name field while Output was open. The
application hit test returned Output's AX group; the field's own AX window number identified
the separate AppKit content window. The corrected route wrote a temporary name, read it back
exactly, restored the original name and read that back before Cancel. The inspected capture
also showed the temporary name in the Save As field. No session was saved or exported.

The Send selector on a visible audio track opened the routing menu and Escape closed it.
The inspected capture showed `no send`, `output` and `bus`. No routing value was changed.
The `no send` policy exception has controlled regression coverage; this run did not assign
and remove a bus. A preliminary probe targeted a scrolled-out track whose AX controls still
appeared in the scene and was refused; this change does not qualify scrolled-out controls.

Output appeared in `windows` while held, remained listed after Save As was cancelled, and
left the list after its close. A separate final cycle selected that untitled window with
`open_session(window: "")`, read its 89 by 533 point scene, then selected Mix again with the
same session ID. Foreground application and cursor stayed unchanged. The click receipt alone remained `acted_unverified` in the
parent Mix scene and reported the separate window's creation or closure; the window census
supplied the evidence. The final run recorded no workspace activations and unchanged
foreground application and cursor. The Seat returned the remaining windows and closed.
These checks use the same broker and tools as the app, without a model-driven workflow.

## Repository checks, 16 October 2026

- `swift build --product braus`: passed.
- `make native-test-runner SWIFT=swift`: passed.
- `TIER_BUNDLES=30 bash Tools/Driver/Scripts/run-tier.sh unit - bash Tools/Driver/Scripts/unit-test-command.sh swift`:
  passed, 3,741 executed, 120 environment-dependent tests skipped, 3,861 reported across
  30 runs. The final `TIER_RESULT` had `status: passed` and no problems.
- `make host-tests SWIFT=swift`: passed, one Seat cycle and 29 display tests, with no
  skips or tier problems.
- `git diff --check`: passed.
- `make test SWIFT=swift`: stopped at the product-name check because ten existing files
  still contain the former product name. The independent unit tier above passed;
  this does not make the aggregate command a pass.

## Repository checks, 15 October 2026

- `swift build --product braus`: passed.
- `swift test --filter 'RemoteContentActuationTests|ProToolsWindowRecoveryTests'`:
  28 driver tests and 5 broker tests passed, including the seven-case window-tree regression.
  The valid Mix case failed on `AXScrollArea` before the resolver correction.
- `make test SWIFT=swift`: passed, 3,446 executed, 118 opt-in tests skipped, 3,564
  reported across 29 runs; final `TIER_RESULT` had `status: passed` and no problems.
- `swift test --filter TopologyBaselineGeometryTests`: 13 tests passed. The uneven-display
  regression failed on the requested origin and absent contact before the correction.
- `git diff --check`: passed.
- `make host-tests SWIFT=swift`: passed, one Seat cycle and 29 display tests, with
  no skips or tier problems. This includes the previously failing origin assertion
  in `VirtualDisplayHostTests.fullLifecycle`; the assertion was not weakened.

No general Live fixture matrix or full Braus UI workflow was run for this change.

## Limits

These checks cover the named controls through the broker and driver APIs, not a full
Braus UI or model-driven workflow. The open-session Window > Edit recovery branch has
unit coverage but was not reproduced live with every session window absent. The new
route does not add AXIncrement/AXDecrement for faders or plugin parameters. Other
plugins, every Mix button, menu selections, localized menus, playback and recording
remain outside this qualification.

Window following is reactive: a newly created PT window can first appear on a physical
display before adoption. The earlier Send panel resize/return mismatch is also unchanged.
Neither limitation is solved by choosing an accessibility action for a click.
