# Pro Tools background controls

Pro Tools uses the Seat's accessibility click route for ordinary windows. `QtPlatform`
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
refuses; it does not fall back to a click that might activate PT. Each action consumes
its observation. `AXError.cannotComplete` is an attempted action with an uncertain
effect, never permission to press again. The consumer reads the effect and confirms it.

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

## Repository checks

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
