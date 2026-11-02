# Retire a clean worker lease's display

Status: amended 2026-10-26: a clean lease keeps its display for an idle
period and retires it then (below). Candidate 2026-10-05; application
qualification is recorded in [the stabilization rounds](../reports/StabilizationRounds.md).

## Amended 2026-10-26: keep a clean lease's display for an idle period

### Cost of retiring at every lease

Measured system-wide on 2026-10-26 with a bystander AppKit application (its
own main-thread stalls and `CGDisplayRegisterReconfigurationCallback`) and
Instruments Animation Hitches across all processes. Each display creation and
each removal is one CoreGraphics reconfiguration
(`add,moved,setMode,enabled,desktopShape` and `remove,disabled,desktopShape`),
followed by AppKit's own second `didChangeScreenParameters` with identical
screens, and sometimes a third about 5 s later. At each notification every
application on the Mac lays out again: the bystander stalled 64-449 ms,
simultaneous hitches of 190-313 ms appeared in Safari, Music, Notion, Finder,
NotificationCenter and Pro Tools, and WindowServer CPU rose from about 40% to
82-119%. Retiring at every lease therefore cost the person two system-wide
freezes when a worker took the seat and two when it gave it back.

### Reproduction of the reason for retiring

The refusals below were looked for again with the display kept across leases
(retirement skipped), Stage Manager globally enabled, in one process:

| Application | How it entered the seat | Result | Window size |
| --- | --- | --- | --- |
| QuickTime Player | launched by each lease, its Open panel adopted, quit at the end | 3/3 adopted | 891x448, full size |
| Pro Tools | already running, its Edit window adopted and returned | 3/3 adopted | 1112x827, full size |
| Prism Launcher | launched by each lease, quit at the end | 3/3 adopted | 800x603, full size |
| DaVinci Resolve | launched by each lease, its Project Manager adopted, quit at the end | 3/3 adopted | 910x640, full size |
| Google Chrome | launched by each lease with the default profile, quit at the end | 3/3 adopted | 1293x922, full size |
| Adobe Photoshop 2026 | launched by the first lease, already running for the other two | 2/3 adopted | 1280x878, full size |

No adoption in the 18 leases was refused as a Stage Manager thumbnail. The
one failure was Photoshop's first lease, on a freshly created display: an
untitled launch dialog blocked the adopted window, so it is not an effect of
reuse. The baseline commits named below (Release0468ac57, Release8f22792c) no
longer exist in the repository, and several stash, thumbnail and adoption
fixes landed after ca834d04.

### Decision

A clean lease (the finish warning rule and the restitution predicate below,
`canRetireHost`) keeps its host and display for
`AgentSession.idleRetirementDelay`, two minutes. That covers the gaps between
a worker's turns after `BrokeredAutomationSession.idleWindow` (30 s) has given
the lease back, and bounds how long an unused display stays. When the delay
passes with no new lease and the session still open, the same
`SeatDriver.stop` the immediate path ran takes the host down; there is no
lease to hand its sentence to, so it is logged. The queue hands the parked
session to the next lease through `AgentSession.beginLease`, which cancels a
pending retirement before anything is prepared or adopted, and waits for one
already taking the host down. A generation counter makes a retirement that
wakes after a new lease or a close do nothing, even when its cancel raced.

`AgentSession.close`, which an explicit close and the queue's shutdown at
quit both reach, still takes the host down at once, after cancelling a
pending retirement; it stops nothing more when a retirement already did. An
unclean lease keeps its host exactly as before, and a failed seat is still
remade by the next adoption. The gated `cleanLeasesKeepTheirSeat` test,
formerly `cleanLeasesRetireTheirSeat`, now expects the same Seat across its
three queue reacquisitions.

### Limits

- The cause of the October refusals is not pinned: they did not recur, and
  which change since ca834d04 removed them, if any, is not known.
- Photoshop's launch dialog on a fresh display is a separate failure and is
  not addressed here.
- An idle display costs its preview stream at rest, and it stays in the
  person's display list for up to two minutes after the last lease.

## Original decision (2026-10-05)

The record below is unchanged. Where it says a clean lease stops the host,
the amendment above replaces that with the idle retirement.

## Evidence

The queue reuses an AgentSession across worker leases. With Release0468ac57,
repeated QuickTime and Prism workflows complete only the first of three
cycles; later native windows are refused as Stage Manager thumbnails.
Resolve likewise refuses full-size adoption on that reused host. Restarting
the unchanged executable permits three full-size Resolve adoptions. Those
input-free comparisons change the process as well as the host, so they do not
prove that display reuse alone is the native cause.

## Decision

After finishUsingApp successfully returns the held application and its
provenance permits any required quit, a lease with no outstanding restitution
calls the existing SeatDriver.stop. The queue's AgentSession stays open and
reusable. Its next adoption starts a host and creates a new Seat.

An unrestored window retains the host. A finish warning alone does not
(amended 2026-10-14): an application left running after the quit request
is not a window left on the display. A refused or left-behind answer, and an
obligation of the last release, is settled only on positive evidence: a
window server row that lists the window off the display, or a destruction
the window server proves for the identity the obligation named. A missing
row (a window ordered out or hidden, which still exists) and a refused or
failed reading keep the host. Settled answers are pruned before the check,
so they cannot keep later leases' displays up.

The quit of an application the agent opened waits only on the rollbacks
owed by the instance of the assignment being finished, as the release
report names it. A pending adoption with no attested identity, and any
pending adoption met by a release that answers nothingAssigned, no longer
block that quit: the process is the agent's and its windows go with it, so
nothing of the person's is lost. Such a pending adoption still retains the
host. The change does
not erase deferred returns, replay input, choose another window, relax geometry
or identity guards, or extend application activation. Handover within a lease
keeps its existing lifecycle; explicit lease completion is the new boundary.

The retirement precondition covers the seat's entire lifetime, including
refused returns and failed-adoption restorations from previous assignments.
It is separate from the current application's provenance check: an unrelated
earlier refusal must not prevent quitting an application whose own windows
were returned. Accepted hidden-window returns remain with their independent
ledger and do not require retaining this display.

## Cost and limits

Each clean lease pays for display removal and the next host startup. This
comparison makes no latency percentile claim. Outstanding restitution may
still retain a host; focus and modal adoption remain separate obligations.

## Verification

Release8f22792c completes three independent QuickTime launches, panel Cancel,
scoped empty-window readings, clean session closes and actual process exits,
without restarting Braus. Prism also completes three Unicode/control/Cancel
cycles with its actual raw values; standalone-observation repeats remain
separately tracked. Earlier failures are preserved.

Resolve adopts at full size on the first candidate trials but refuses Search
input with targetActivated. Later opening attempts encounter the still-open
owned timeline modal. An externally cancelled modal is not a successful
Native workflow and does not qualify timeline creation or undo/redo.

The candidate's offline baseline, full app tests, Release build/signature
and host checks pass before the additional lifecycle regression. The gated
cleanLeasesRetireTheirSeat test then adds three queue reacquisitions: it checks
that the AgentSession identity survives, each ready Seat identity is new,
application cleanup has no warning and the process started by the lease exits.
The gated test actually passes with the previously closed Prism Launcher:
one test, three lease acquisitions, no skips, 15.779 seconds. This exercises
the broker lifecycle; it does not replace Native app workflow qualification.

The subsequent broad 8f22792c cohort stops at Electron cleanup: teardown
reports two Chrome windows refused, although the current Electron overlay
had closed. That explicit session teardown still reports its complete ledger.
A fake-window regression then reproduces the separate automatic-retirement
hazard: the first app refuses return, the second returns to its original
frame, and an empty pending-adoption register alone incorrectly permits host
retirement. The new whole-seat predicate retains the host in that case.
This regression goes red and then passes within the 17-test assignment suite.
The final f0ab94d6 Release build and signature pass. Its Native Prism workflow
also completes three independent cycles with standalone text, toggle, parent
and closure observations. That result qualifies the owned Prism row only;
Photoshop and Resolve adoption, Chrome drag and CEF's composite row do not
complete in the same cohort. The whole-host refusal guard has an offline
regression, not a live reproduction of the earlier refused Chrome return.
