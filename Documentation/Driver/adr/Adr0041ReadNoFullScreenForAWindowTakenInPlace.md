# ADR 0041: A window taken in place is not read for fullscreen

Status: implemented for qualification, 2026-10-12. Offline tests only; the live
acceptance is pending an owner's go for input to Photoshop. Ticket "~500 ms di letture
AX lente su Photoshop durante un'adozione (R4)", phase 2. Path: the app
(`BrokeredAutomationSession` over a real `SeatBroker`) with Photoshop 27.10.0 on
macOS 27.0.1. It closes the timing [ADR 0040](Adr0040BaselineEachDrivingEpisodeOnce.md)
left undecided and narrows [ADR 0017](Adr0017InPlaceWindowSettlement.md).

## Evidence

Phase 1 timed every accessibility read of an adoption in an instrumented scratch build.
In a Place Embedded run, the palette 4768 (born on the Virtual Display, so adopted by
`ownWindowBornInSeat` with `takenInPlace: true`) spent 719 ms between entering
`adoptionTransaction` and leaving `ready` for `starting`. 717 ms of it was one
`copy AXWindows`, the cold window-element resolution behind `placing.fullScreen`
in `leaveFullScreenForAdoption`, made with no messaging timeout while Photoshop's main
thread built the Open panel. On 12 October the same gap was 507 ms. Every other
fullscreen read of the four Place Embedded runs and of six plain Photoshop and TextEdit
adoptions took 0.2 to 14.3 ms.

For a window taken in place that read is the only unbounded accessibility read of the
transaction: nothing is written, physical origins are not read, and `confirmPlacement`
reads only the window server unless the two sources disagree on size.

## Decision

**`adoptionTransaction` does not call `leaveFullScreenForAdoption` for a window taken
in place.** It adopts it with `wasFullScreen: false`. The window is already where an
adoption would put it, so no fullscreen exit is needed to write anything. A window
born in native fullscreen on the Virtual Display is therefore owned where it stands
instead of being taken out of fullscreen or refused at adoption. Since `wasFullScreen`
is false, no fullscreen state is owed back to it. Its release reads `AXFullScreen` and
exits fullscreen before it writes only with `transfersFullScreenWindows` on, as in the
app (the existing step of `returnToUserSeat`). With the switch off the window stays in
fullscreen, and macOS migrates its Space when the Virtual Display goes.

There is no skip by window level: a level 0 window born in the seat takes the same path
as a palette or a panel, because the cost is the read, not the kind of window.

Unchanged: the fullscreen preparation of a window transferred from the User Seat, and
the fullscreen read of the follow pass before it spends an attempt on a candidate.
Short accessibility timeouts with an `offerAgain` retry were rejected: a read that times
out repeatedly would retry without bound on the main actor.

**The fallback of the surface reader says how long the native pass took.** The roughly
600 ms before the "detected" notice in the same run is read as the cross-checked native
pass failing (0.1 s attempt and 0.5 s recovery) and falling back to the on-screen list.
That is an inference from the timing, not a measurement: the new notice is what confirms
or refutes it. `SensingSurfaceReader.snapshot` now logs one notice with the failure and
the elapsed milliseconds, so the time is attributable in production logs. Nothing else
changes.

**The first move reads only the windows whose place is not held yet.** A window whose
origin the broker already noted is not read again by `recordPhysicalOrigins`: its body
would be a round trip to the application that `noteOrigins` discards. Recorded origins
are identical. This gains time on `open_session`, not on R4.

## Verification

Offline, over the fakes: `WindowAdoptionTests` (a level 3 and a level 8 surface born in
the seat make no fullscreen read and are owed their birth frame and server frame, no
desktop, a return and no fullscreen; a window born in the seat in writable fullscreen is
adopted without a fullscreen request and its release requests the exit) and
`WindowOriginTests` (with an origin held for one window of two, only the other's body is
read and the held origin is unchanged). All three failed on a scratch copy without the
change. `FullScreenTransferTests` are unchanged. No live run was made.
