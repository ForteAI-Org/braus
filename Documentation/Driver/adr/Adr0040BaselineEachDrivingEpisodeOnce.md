# ADR 0040: Take "already there" once per driving episode, and say why a move was not kept

Status: implemented for qualification, 2026-10-12. Offline tests only; the live
acceptance is pending an owner's go for input to Photoshop. Ticket "la Start Bar di
Photoshop blocca il trasferimento", phase 2. Path: the app (`BrokeredAutomationSession`
over a real `SeatBroker`) with Photoshop (PID 99986) on macOS 27.0.1, 12 October 2026.
It completes [ADR 0033](Adr0033ExplainWhatAPressedCommandCauses.md) and keeps the rule
that the window follower never transfers a window retroactively.

## Evidence

Place Embedded's Open panel (window 2775, layer 8, modal `AXDialog`) was born on the
virtual display 1356 ms after the menu press. 47 ms before that, the adoption of
window 2525 (a layer 3 palette) finished and the seat took the baseline of every
driven process again. The panel was recorded as "already there" and never became a
candidate; the menu result and the next observation failed with "selected surface is
not owned", and the panel stayed open.

The cause is older than the run: `AppWindowInventory.baseline` has recorded every
surface it did not know as `agreed: true` since the follower was written, and
`refreshWindowFollowing` called it for all driven processes after every adoption and
release. A window born between one reading of a pass and the end of another
transaction was furniture for good. The doc comment of the call ("the baseline for
whichever of them is new") said what the code did not do. The vulnerable window runs
from about 560 ms to about 4 s after a press, the time an application takes to
publish a window while the seat finishes something else.

Two timings of the same run are not changed here. The "Start Bar" (layer 8, 451 by
32) is a floating window Photoshop keeps at a constant offset from the document
(offset (261, 575) to 2311 in one run, and (747, 264) for window 2525 in another),
and its 3 s `moveRefused` of 7 October predates the delivery of web-page input, so
the cause stays undecided and re-anchoring is the working reading. And 507 ms
passed between the "detected" notice of window 2525 (19.425) and the seat leaving
`ready` for `starting` (19.932), with no Command in flight. The code between the two
makes only accessibility reads of Photoshop (`placing.frame`, then the fullscreen
read of `leaveFullScreenForAdoption`); no timestamp separates them, and the first
row of the Open panel appears 5 ms after the seat started. Photoshop was building
that panel, so the likely reading is that the reads waited on its main thread. It is
not proved: measuring it needs a live build with timings around each read.

## Decision

**"Already there" is taken once per process and per driving episode.**
`AppWindowInventory` keeps the `ProcessIdentity` values already baselined.
`baseline(surfaces:processes:)` works only for processes it has not seen, and takes
its reading lazily (the window server is read only when a process is new). A process
the seat no longer holds a window of is forgotten with its surfaces and its attempts
at the moment its last record goes, whichever path removes it (a release, a window
found destroyed, a target handed over after its destruction), and by any pass that no
longer reads it, so driving it again takes a fresh baseline: keeping the old records
would propose every window the person opened meanwhile, which is the retroactive
transfer the follower must not do. The key is `ProcessIdentity`, so a restarted
application starts over. A failed reading leaves the process unbaselined, and the
first reading that succeeds takes its baseline, whether it is the next call or the
next pass: until then no window of that process is a candidate, and a sighting during
an adoption ignores it too. A window that was hidden at the start stays a candidate
when it appears, because surfaces are read on screen only.

The limit that remains is the first adoption of a process. The baseline is taken when
the seat holds its first window, so a window the application opens between the start
of that adoption and its end is read as already there. "Already there" is defined only
at that moment, and no earlier moment knows which process will be driven.

**A reading taken during an adoption is recorded.** The follow pass still stands down
for the whole adoption, but it now takes the reading and `AppWindowInventory.sight`
notes it: an unknown window becomes a candidate waiting for its agreeing reading, a
waiting candidate takes the newest frame, and nothing else changes (no change is
reported, no held window is touched, no vanish is consumed). The first pass after the
adoption finds the candidate at the same frame and proposes it at once, and an
adoption that ends with a candidate pending asks for that pass itself instead of
leaving it to the heartbeat, so an observation that waits for the adoption finds the
window inside its own 5 s budget.
Observation still waits for an adoption in flight; it is not made to skip it.

**A move the application accepted and did not keep has its own reason.**
`WindowTransferRefusal` gains `placementNotConfirmed` (the write was accepted and the
window never settled at the origin it was sent to) and `seatNotReady` (the seat
refused to admit the window, or stopped being ready under the transaction). They stop reading as `moveRefused`, which
stays for a write the application refused, so a floating window anchored to a document
is told apart from one that cannot be moved. `SeatErrorMapper` words both.

**A move undone is refused early, on positive evidence only.** `confirmPlacement`
refuses at once when a window found outside the virtual display, that left its
pre-write origin, reads back at that origin in agreeing readings 500 ms apart. A window
found inside the display is never refused this way: one its application holds where it
was found is accepted there, as before. There is no time based refusal: Safari holds each
step of a move for 300 to 450 ms (ADR 0038), so a slow mover is accepted exactly as
before, and a window that never left its origin keeps waiting out the 2 s budget.

## Not decided

No window is excluded by evidence ("anchored to a held window") yet. The evidence
for it is two samples of a constant offset, and the follower still tries every visible
window of a driven process once, up to three attempts each. The Start Bar's cost per
attempt is now at most about 0.6 s when it snaps back, and 2 s when it only lags.

## Verification

Offline, over the fakes: `AppWindowInventoryTests` (a window born between two
baselines is a candidate, a forgotten process is baselined again, a joining process is
baselined alone, a process the passes stop reading is forgotten without a baseline
call, a forgotten process leaves its attempts, the reading is lazy, a failed reading is
retried by the next call or
taken by the next pass and proposes nothing, a sighting is proposed by the next pass
and changes nothing else), `CommandBornWindowTests` (a panel
born during the adoption of another window of the Command, and during a release, is
adopted with one extra handback; the settle-read row also asserts the adoption) and
`AppWindowFollowTests` (the mapping of the reasons, a move undone refused in under
1.5 s, a slow mover accepted whether it holds steps or waits before the first, a
window found inside the display and held there is still adopted, a process whose only
window was found destroyed is baselined afresh when it is driven again, a window born
during an adoption is adopted by the first pass after it, and that pass is asked for by
the adoption itself). No
live run was made, so the Photoshop sequence is not reproduced.

## Follow-up: a window born in the seat that its application moves out (Preview, 2026-10-14)

Proposed by Tommaso from the Brain/Memory canary, for Elio's review with the follow-up of
[ADR 0031](Adr0031ActuateRemotePanelContentThroughAccessibility.md).

Preview 11.0 on macOS 27.0: after Open was pressed in its standalone Open panel (window
112209), Preview created the document window 112290 beside the panel, on the virtual
display, while the panel still lived. The follower reported it as born inside and
`ownWindowBornInSeat` took it in place; Preview then put it where it remembers its
documents, (4, 37) on the person's display, and the confirmation ended with
`placementNotConfirmed` after about 3 s. The inventory had already agreed on the window,
so no pass proposed it again: it stayed on the person's display for about 10 s, the seat
read the assigned application as not contained, and only a new session took it in. In the
run before, the panel died first, and the window was taken in as its successor.

**A window born inside that the application moves out before it is confirmed is offered
again.** When the in-place adoption ends with `placementNotConfirmed`,
`ownWindowBornInSeat` calls `AppWindowInventory.offerAgain` for it, and logs it. The pass
that finds it settled at its new frame proposes it as `appeared`, and the ordinary
transfer brings it in under the attempt budget of three, so an application that keeps
putting it back is still given up on. Nothing else changes: a window born inside and
confirmed is still taken in place with no move and no attempt spent.

Verified offline by `AppWindowFollowTests` ("a window born in the seat that its
application moves out before it is confirmed is transferred in", which fails without the
re-offer). The live check is the next canary run.

**A missing operating target the window server proves destroyed is let go, not recovered.**
The fourth canary round (12:06:17, build `f76ac58`) closed the same panel the other way
round: Open pressed, the follow pass found the panel missing at 18.431 and reported
`windowUnavailable` (`absentFromReading`); the recovery began on an input already posted
with no confirmation and failed the seat with `ambiguousEffect`; 6 ms later the named
window-server request proved the panel destroyed. The seat stayed failed until the agent
closed and reopened its session. When the pass finds the operating target missing, it now
asks the window server for it by name first (`windowIsDestroyed`, the proof the containment
wait uses): destroyed, the target takes `dropDestroyedRecord`, which keeps following the
application for its next window; otherwise one missing reading is still not a destruction,
and the recovery runs as before. Verified offline by `AppWindowFollowTests` ("an operating
target missing from a pass is let go when the window server proves it destroyed, and
recovered otherwise", whose destroyed case fails without the change).
