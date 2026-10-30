# Human control and watch-only preview

Status: B4. The live preview shows frames only. A person uses the lent
application through real mouse and keyboard input. A passive listener records temporary action
metadata and optional window pictures. A background consumer reconstructs temporary scene findings;
Yes hands the reviewed state back to a new worker turn.

## Episode lifecycle

Opening, expanding or switching the preview between window and display mode does not interrupt
the worker. **Take Control** calls `HumanPreviewControl.begin()`: it closes Driver agent admission
with `.humanIntervention`, retains the lease and suspends the worker before awaiting its current
action. The worker drains its admitted call and makes no further provider calls during control.
The preview remains for watching throughout the episode.

`begin()` lends the application after the worker drains. **End Control** calls `finish()`, stops
the interrupted turn and closes the retained session, leaving the application where the person
put it. It does not resume the agent automatically.
The ordinary agent click, dropdown, accessibility and per-Command preparation paths are unchanged.

End Control, lease end and session close abandon any open Driver episode. Lease startup also
clears a stale episode on a parked host, so the next worker cannot inherit `.humanIntervention`.
Abandonment invalidates observations, leaves other pause causes intact and neither confirms nor
replays uncertain Commands. Ordinary `endHumanInput` keeps its matching-token, command-boundary
and focus-verification checks for a future handback that resumes the agent.

## Passive intervention recording

Lending creates one `HumanInterventionRecorder` and its
`HumanIntervention<HumanRecordedInteraction, HumanSceneFinding>`. `PassiveInteractionListener` supplies the
real events. Only the lent process is admitted; gaps are always retained, including gaps whose
lost events cannot be attributed. Every event, hovers included, first reaches the activity policy
(`ObservedInteractionSource`, below); hovers never reach the recorder and focus is dropped here.
Finish, block and session closure await listener stop, including its final typing/scroll flush,
and drain admitted actions before closing the queue. A block leaves End Control available.

A fast intake task filters events into a 64-event inbox. One task resolves metadata and records
immutable payloads in listener order. Both inbox pressure and the intervention's 4,096-event or
256 MiB limit report through `HumanPreviewControl.block`, with no successful partial-history claim.
The source stream's existing unbounded hop is drained without AX or capture work by this intake.
The byte charge is 1,024 bytes per entry plus four bytes per UTF-8 metadata byte and the actual HEIC
length. This covers retained payloads and indexes conservatively, not total process RSS or the
single native capture in flight.

| Input | Retained action facts |
| --- | --- |
| Click / right click | Point, click count, attributed window number/title/frame, AX role/subrole/label, optional hit-window picture |
| Drag | Press and release points, attributed window, AX metadata at both points, optional release picture |
| Scroll | One gesture, deltas, start point, attributed window and AX metadata |
| Shortcut | Key code, modifiers, layout-derived command name, focused AX metadata, window identity/geometry |
| Typing | One span, focused AX role/label, window identity/geometry; no text, key, modifiers, click count or window title |
| Gap | Lost sequence range and critical/coalescible counts |

Metadata is read after delivery, so it is not proof of the control or state at the exact input
instant. `InteractionSceneReader.metadata` runs on the concurrent executor with 20 ms AX messaging
timeouts and a 150 ms read deadline. Its attribute closure requests only role, subrole, title,
description and help, never AXValue, editable content or descendants. `InteractionAXLabel` selects
the human label. Secure roles/subroles and labels reserved by `ValueMinimization.namesSecret` or its
credential-shape rules retain only the role and a protected-field marker. An unreadable editable
subrole is also protected until classified. This path stores no input
text or keystroke count. Optional screenshots remain visual evidence and are not field-redacted.

Clicks, right clicks and drag releases attempt `StillCapturer.captureWindow` for the event window
when its owner is the lent process, falling back to the lent window,
off the main thread, checking its owner PID in the shareable-content snapshot before capture.
The existing HEIC encoder scales down to fit 1920 by 1080 without upscaling,
at quality 0.8. Capture races the AX read with a 600 ms deadline: only a picture ready when that entry is recorded is kept.
A late, failed or busy capture leaves that entry without pixels; it never attaches to a later event
or delays recording. At most one capture is in flight, even when cancellation is ignored. Closing
cancels optional capture without waiting for it, and discards any later result. The new capture hit
rate and latency need a live trial; previous encoding-only measurements do not establish them.

Before closure releases history, the `dev.forte.AgentSeatKit` / `Preview` logger prints each entry
in order and a summary of entries, charged bytes, pictures, discarded other-app events and incomplete
recording. These requested diagnostic lines expose metadata publicly; they never print AX values
or typing content. The adapter writes no screenshot or input-content files and does not promote
anything into persistent Memory.

## Temporary Perception reconstruction

`HumanInterventionConsumer` runs one task on its actor, off the main actor. Its first queue is
one latest-pending state request, identified by the intervention sequence. Recording never waits
for a scene read. A new request supersedes older pending requests; each still leases and completes
its own `HumanIntervention.next()` item with a `skipped (superseded)` finding. A read already in
flight completes before the newest pending state is read. The second queue is the actor's ordered
findings, so every admitted action has exactly one result and original ordering is preserved.

The listener publishes left-button edges separately from completed gestures. Reads wait while a
press belongs to the lent process. A read that spans a button-state change is discarded and retried
after release, or superseded by newer pending work. This cannot interrupt native AX IPC already in
flight. After listener shutdown, the native button state checks physical release so a held gesture
cannot be stranded waiting for a stopped tap. Other-process presses do not pause admission.

Each action reads its attributed window when owned by the lent process, otherwise the lent window.
`InteractionSceneReader` validates capture ownership and uses `ProductionPerception.pipeline()`.
The first successful retained scene for a window is a full compact keyframe. Later readings use
`SceneChanges.text`, relative to the last retained scene of that window, including an explicit
unchanged result. Failed and superseded readings never replace that baseline. The consumer keeps
one transient baseline per observed window until it finishes; these scenes and native work in flight
are separate from the retained-findings byte budget. No canvas crops are produced; issue #16 owns
that extension, and the existing per-click picture remains available.

Findings retain UTF-8 text as LZFSE bytes, with raw and compressed sizes and read duration.
`complete` and `beginReview` charge compressed bytes to the same intervention budget as payloads.
An oversized finding is replaced by an explicit byte-budget failure without blocking review.
Ordinary read failures are findings too; cancellation or a broken consumer fails its leased work.
Payload or event-count overflow still reports incomplete recording and cannot produce a review.

After `stop()` joins listener intake and metadata recording, `finish()` drains reconstruction,
calls `endInput()`, and obtains a new full scene of the application's largest normal-level window and
dialogs/panels above it. Final inventory includes offscreen windows, because take-back can order out
the document during staging. Surfaces under 120 by 60 points are excluded. The selected window
numbers, sizes, levels and minimized titles are logged. This happens even for an empty episode or when intermediate reads were
skipped. Missing or failed final surfaces remain explicit failures, never inferred success.
`beginReview` requires all action findings and that final finding and enters `.evaluating`.
The recorder retains this Review until the handoff consumes its revision. Reconstruction itself starts
no model and authorizes no agent action.

Secure roles/subroles, unreadable editable subroles and fields with reserved labels refuse AXValue
before the value read. An explicitly unsupported subrole remains distinguishable from a messaging
failure. The adapter supplies the existing `ValueMinimization` reserved-name and credential policy;
scene text is minimized before compression and before becoming a baseline. Diagnostic difference
lines also withhold both old and new field values, including duplicates in OCR text. The Preview
logger emits action outcomes, raw/compressed sizes, read times, the first three minimized difference
lines and totals. Error diagnostics use fixed reasons, never arbitrary error text from the application.

Controlled tests cover ordering, pending-state replacement, drag suspension and read invalidation,
per-window keyframes, compression, byte-budget refusal, final review, privacy and dialog-picture
routing. These tests read no live screen or AX tree. Read latency in a large application (Pro Tools),
real popup attribution, drag timing, capture success and final-window coverage need a live trial.

## Temporary intervention history

`Engine.HumanIntervention<Payload, Finding>` is an actor owning a bounded, temporary event sequence.
`Payload` is the producer's immutable input/frame envelope; `Finding` is the
Perception consumer's structured reconstruction. Neither requires a dependency on Brain, Memory,
SQLiteMemory, a provider, an input poster or an application framework. No persistent schema changes.

The lifecycle is:

1. Observing: no event is being recorded.
2. Collecting: `record` starts the intervention; `next` leases at most one event to a consumer.
   Producers can append while the consumer works. `complete` preserves original ordering.
3. Reconstructing: `endInput` records an opaque boundary. An empty queue alone is insufficient.
4. Evaluating: `beginReview` requires that boundary, all findings and an explicit final-state finding.
5. Awaiting clarification: the agent may ask a question, but may not act.
6. Resumed or task completed: explicit resolution releases owned payloads. Completion does not
   authorize new actions. Closed and blocked states never authorize actions.

Input or activity reopens collection and changes the opaque revision. An older final-state result
or agent decision refuses. Work items belong to one actor and can complete only once. A failed
consumer blocks the episode rather than returning a partial reconstruction as complete.

The constructor requires event and accounted-byte limits. The passive producer reports missing
pictures and input loss explicitly. Overflow blocks the episode and preserves existing history. The byte cost is a
conservative caller-supplied charge for the retained payload, including its frame; it is not a
measurement of total process RSS. Callers charge findings and the final state separately;
externally retained snapshots and transient scene baselines also occupy memory.
This increment retains payloads until successful resolution or explicit close, with no eviction or
silent coalescing. The passive adapter retains only immutable encoded pictures.

`Status.allowsAgentInput` describes this episode only. It is not a Driver authorization and does not
replace the gate, target checks or lease. `HumanPreviewControl` coordinates passive recording with
the episode that pauses agent admission. This actor alone does not stop a provider or an in-flight tool.

## Suspend execution and retain the lease

`BrokeredAutomationSession.retainForHumanIntervention()` pins the current native lease, cancelling
idle release and preventing queue pressure from releasing it when the old provider turn ends.
Repeated calls return the same episode token. Explicit `close` invalidates the token and still
performs normal cleanup. `endHumanIntervention` accepts only the current token and restores idle
release. Call it inside the new desktop turn when that continuation must retain the same lease.

`WorkerAgentHost.suspendForHumanIntervention()` closes agent admission, cancels generation and
lets the admitted tool finish. The old run then throws `HumanInterventionSuspended` rather than
closing its session on intentional cancellation. Pending tool calls are discarded. New turns and
compaction refuse while suspended. Only the matching token, after the old turn drains, can end
suspension; ending never starts a provider. Normal stop, close and actual failures retain cleanup.
Stopping after the suspended run has already ended starts tracked session cleanup; new runs, compaction and suspension refuse until it completes.
The owner can await `waitForHumanInterventionCleanup()` before ending its control UI.

`MCPRouter.suspendForHumanIntervention()` differs from `pause()`: it preserves the admitted call,
including against cancellation notifications from the departing provider. An ordinary stop overrides
it. The native model loop checks cancellation between its tool calls and stops its stream. Human-specific
interruption preserves a real failure already reported by either the native transport or CLI provider,
so an error is not incorrectly translated into a retained human suspension.

The inactivity policy is below; invalidation during evaluation remains to be done. Review revision
checks remain active.
Temporary reconstruction does not automatically teach a persistent procedure or authorize agent
Commands. Controlled lifecycle tests do not establish live input, lending, focus behavior or
application compatibility; those require coordinated host/live qualification.

## Preview shape and interrupted provider diagnostics

The displayed capture supplies its size in screen points directly to the view containers. Floating
windows update their content aspect ratio and fit inside the visible desktop; the enlarged view
updates its native size from the same delivery. Neither depends on another agent observation, which
may never arrive during human control. Switching back to a window follows the newly delivered shape.

CLI cancellation snapshots whether a provider failure had already been observed before interruption.
A failure reported only after intentional cancellation cannot turn human suspension into a failed
turn that tears down the retained session. A failure observed before cancellation still propagates.

## Observation and stopped tasks

The native assigned-window inventory used by observation and the watcher's reconciliation runs on
one background queue per reader. Only the native read leaves the caller; transition filtering and
the Seat fold return to the caller's executor. A newer input-gate reading supersedes an older
background result. Lifecycle, selection and observation barriers are checked again before folding.
Destruction evidence is retained for the same assignment even if its selection changed meanwhile.
Synchronous input gates, adoption and restitution still take their existing fresh readings; this
change does not establish that every Accessibility operation is off the main thread.

An explicit worker Stop marks its task for an abandoned end after the admitted call drains. The
next turn also finishes a pending end before sending anything to a provider. For End Control after
the provider already drained, that next-turn boundary closes the task. A temporary human suspension
preserves the task, and stopping context compaction does not abandon it. The compact next-turn notice
names the old task and requires a new task scoped to the current request, including remaining work
on the same goal: the Memory contract does not reopen an abandoned task.
No uncertain action is replayed, and the stopped task is not automatically interpreted as a success.

Completed task answers include `completion_evidence`: the verdicts and scope of their checks,
separate from the agent's declared outcome. A window-presence check explicitly cannot establish an
applied value. `goal_match` remains `not_assessed`: the agent must compare the observed result with
the requested goal. This strengthens the evidence contract and instructions, not a semantic proof
of goal satisfaction. Brain, Memory schema and procedure admission policies are unchanged.

Unit evidence covers native execution off the main thread, superseded inventory reads, teardown
while a read returns, Stop followed by a new task, and preservation during temporary human control.
It does not establish real-app latency, Pro Tools tempo correctness or native window-drag safety.

## Lending the application to the person

Physical control replaces preview input: the preview is for watching only.
R2 provides `BrokeredAutomationSession.lendApplication(on:)` and
`takeBackApplication()`, through `AgentSession` and `SeatDriver`. The caller retains
the human episode, suspends the worker and awaits its current action before lending.
The lease remains held and `.humanIntervention` keeps agent Commands paused.

The Seat translates all held windows of the application's attested process lifetime
as one group, centred in the chosen physical display's visible frame. The Take Control
caller captures `NSEvent.mouseLocation` before starting asynchronous work and passes it
to the shared `PersonScreen.current(pointer:)`. That helper chooses the screen under
the pointer, then Braus' key-window screen, then the first physical screen in menu-bar
order. Seat displays (vendor `0xF0A7`, model `0xA617`) are excluded from every choice.
The chosen `NSScreen` is an explicit input through the lending APIs. The Driver converts
its visible frame from AppKit to WindowServer
coordinates using the menu-bar screen's height; it never substitutes the menu-bar
screen as the destination. A disconnected or Seat-owned target refuses lending. Oversized groups align their oversized
axes to the visible frame's top/left edge and report a clamp; lending never resizes.
Before any move, the Seat checks every held window's identity and captures its full
body. If a window vanished or changed identity after the worker drained, it refreshes
the application's WindowServer inventory once and repeats preflight for the surviving
held identities. It never substitutes a reused window ID or a different process lifetime.
An empty inventory or a failed refresh refuses without moving anything; the preview
reports that refusal without blocking human control.

After translation, the existing focus restorer activates the application and requests
the largest successfully lent window as key. AXRaise brings that window out of the
Stage Manager strip. Success requires foreground-process and focused-window identity,
plus two WindowServer readings showing the moved frame at full size and no other
application's layer-0 window ahead of it anywhere on the full destination screen,
including outside the visible placement area. Same-application
windows may remain ahead. The Seat retries activation once after a short settle if
verification fails. AX body geometry alone cannot establish activation: it stays full
size even when the server shows a thumbnail. A still-stashed or obscured window is a
failure in `ApplicationLendingReport`; the report reaches the preview and the person
retains control. The existing lend log includes the selected window, attempt count and
verification outcome. This uses the existing display and does not change ADR 0030's
idle retirement policy. A move the application refuses is tried once more after 150 ms:
an application can refuse the first write right after the window's preactivation and
accept the same move later (Safari).

While lent, the application's windows, including newly opened dialogs, are expected
outside the virtual display. Observation and containment folding stop for that
assignment, its window follower stands down, and focus recovery accepts that process's
activation. Agent input remains closed. Display/fence checks and other process identities
keep their normal rules. A lending request refuses during an unfinished transfer or
recovery rather than racing it.

Take-back returns surviving held windows to their recorded virtual frames, including the
recorded sizes if the person resized them. It uses the same two-reading placement
confirmation and thumbnail staging as adoption. Stage Manager also runs on the virtual
display: returning windows can sit in its strip as thumbnails (about 95 by 108 points at
its left edge) that AXRaise leaves there for seconds. When staging is
refused that way, take-back activates the application once on that window, as a click on
the thumbnail would, and confirms it again with the same two readings; the handback below
then restores the person's focus. A hidden application has ordered its windows out, so
take-back first shows it, without activating it, and waits up to a second for them. New
windows pass the ordinary follower's visibility and level filter and are adopted
normally. Take-back refreshes attachment evidence before adopting a new sheet: it follows
its host and is owned in place, with no independent position write or return obligation.
Windows already open but unheld before lending stay the person's. Closed windows are
forgotten only on destruction proof; an unreadable window is a named failure. A vanished
process ends the lease. After placement, the existing human handback restores the
previous user focus, including when every held window was closed but the process remains
running, before normal admission can resume. Ending the broker episode does not itself
start an agent.

That explicit restoration carries `applicationLendingHandback` attribution. While its
bounded verification is pending, activation of the same process lifetime is expected:
the seat stays ready without a `targetActivated` issue, and the focus-recovery gate keeps
agent input closed. This activation exemption ends on verified handback, refusal,
cancellation or expiry of the verification window. A later activation is checked normally;
geometry, identity, display and fence checks remain active throughout handback.

Every take-back exit clears the lending exemptions. Placement or focus failure remains
reported and paused; another End Control cannot silently turn that failure into success.
Stop, session close and teardown instead abandon lending, drain any in-flight lending
operation and leave physical windows where the person put them. This leave-open decision
survives preview cleanup, so lease cleanup neither closes a session-created browser
window nor quits the lent application. No display is destroyed/recreated for lending;
the idle-retirement policy in [ADR 0030](../Driver/adr/Adr0030RetireCleanWorkerDisplays.md)
continues to apply.

Each lend/take-back logs a notice with verified before/after frames, clamp and failures.
Stage Manager thumbnails never supply a missing full-size body. Take-back stages a
thumbnail through the existing adoption confirmation. Native fullscreen selected by the
person, app-specific AX refusals and Stage Manager rearrangements can still refuse a
placement; there is no unverified fallback. Multiwindow physical behavior, especially
Pro Tools with Stage Manager enabled, requires live qualification on the approved host.

The Take Control action calls the control adapter's `lendApplication(on:)`: it begins the
episode, suspends and drains the worker, then calls the broker lending API. The preview
input queue is stopped for that episode. End
Control closes the session, so it skips take-back like Stop/close and the lease end abandons
lending, leaving the windows where the person has them (`HumanControlEnd`): taking back
first and then returning them was a visible double move. The
resume path keeps take-back. R1 removes the remaining preview input machinery; its
integration should retain these broker calls and preserve that distinction.

While lent, `HumanPreviewControl.lentWindow` names the largest moved window selected
for activation and its frame. An unverified activation keeps that placement available
to the preview while its status reports the failure and keeps End Control available.
Braus' `LendingCompanion` follows it: the control border follows the app's largest window
through the app's accessibility move and resize notifications, and the worker waits in the
corner; Yes resumes the worker through the reviewed handoff below. Nothing stands behind the app:
the application simply comes to the front on the person's own desktop, at its own size. A
black backdrop of Braus's own is not used: under Stage Manager it takes the centre stage and
leaves the lent application in the strip, and a black screen reads as strange.

## Reviewed handoff and worker resume (B4)

**Yes** calls `HumanPreviewControl.finish(.resumingWorker)`. `HumanControlCompletion` orders:

1. `BrokeredAutomationSession.takeBackApplication()` takes the app back. A vanished application or
   failed placement becomes an explicit handoff note; it cannot strand the episode.
2. `HumanInterventionRecorder.stop()` stops and joins the listener, intake and metadata queue.
   `HumanInterventionConsumer` drains action findings, calls `endInput`, captures the final surfaces
   and calls `beginReview` for that revision.
3. `HumanInterventionSummary.prepare` and `render` run on the concurrent executor. The handoff
   awaits both; only the host's actor-bound withholding callback runs on the main actor. Each
   retained scene is decoded once. The digest uses indexed semantic identity matching instead of
   the general `SceneChanges` geometric matcher, whose duplicate candidates can grow quadratically.
   Readout values, geometry-only changes, OCR fragments and reverted effects are excluded. Read
   evidence and window-scoped label indexes link actions to net changes; optional embeddings retain
   their 150 ms deadline. Explicit read links rank first, with at most 64 inline candidates per window.
   Changes have one window heading, list additions share one line, and unlinked effects appear only
   as a count. `start:` and `end:` survive the 1,000-byte UTF-8 budget. Repeated strings are interned
   after filtering, with consecutive IDs; `human_step` retains access to the episode's details.
4. `WorkerAgentHost.waitForHumanInterventionCleanup()` joins the old provider run and admitted tool.
   `TeamModel` also joins the old turn's recorder and terminal writes, without waiting for the control
   UI to close. The matching host token ends suspension only after this drain.
5. `TeamModel.resumeHumanIntervention` appends one user-side summary in the interrupted conversation
   and schedules a new turn on its existing host/provider conversation. Inside `desktop.turn`, the
   revision is resolved and the broker episode ends without a second take-back. The retained lease
   cannot idle or yield to another worker between these turns. Startup is acknowledged only after
   this preparation; a failed prelude closes the retained session.
6. The worker receives `WorkerAgentHost.humanInterventionInstructions`: judge whether the person
   helped, finished, or changed the goal; then continue from current state, close the task, or clarify.
   Old pending actions are never replayed and the intervention does not automatically teach Memory.

A failed take-back keeps the Driver's placement/focus guards intact. Its session is closed inside
that new turn before evaluation continues, so the worker can inspect/reopen what remains. This
failure path cannot promise the old lease remains usable. Missing final surfaces are explicit
read failures, not success. **End Control** still stops and closes without take-back or resume,
leaving windows with the person; it also overrides an unfinished Yes handoff.

Diagnostics include each handoff stage with elapsed time, selected final windows, summary byte count
and its first three withheld lines. Unit fixtures do not establish real-app behavior. A live
trial of B4 must check document and dialog coverage after staging (Pro Tools), Yes through the same CLI
conversation with a held lease, app/window closure and take-back failure, End Control/Stop, and
protection of secure values. App build and hosted tests require an environment where Xcode can open
the workspace and access its services.

### Debug handoff replay

Debug handoffs save `review.json` and numbered LZFSE finding blobs under
`~/Library/Application Support/Braus/Runs/handoff-<timestamp>-<uuid>/`. The versioned manifest
contains action metadata. The blobs retain minimized findings and the final state, including initial
scenes and read coverage; they contain no event payloads or pictures. The JSON inside each blob uses
`HumanSceneFinding`'s Codable representation, including its original compressed scene/text fields.
The directory is private to the user. These local files persist until removed manually. A write failure
is logged and does not prevent the handoff. The writer, reader and call site are excluded from Release.

Replay a captured folder in Debug without touching the desktop:

```sh
BRAUS_HANDOFF_REPLAY='/path/to/handoff-folder' CLANG_MODULE_CACHE_PATH=/tmp/braus-module-cache \
  /usr/bin/swift test --disable-sandbox --filter 'HumanInterventionSummaryTests/replaySavedHandoff'
```

`HumanInterventionSummaryTests/largeNoisyReview` measures five concurrent prepare/render runs on
35 actions and about 2.6 MB of retained raw findings, including about 700 noisy changes. Release
requires each run to finish within 300 ms; Debug allows 1 s for instrumentation and concurrent tests.
The timing includes the concurrent preparation, withholding, deterministic embedding fallback and rendering.
Fixture creation, replay I/O and installed-model inference are outside those timings.
These synthetic checks do not establish Pro Tools live latency or reconstruction accuracy.

## Activity policy: taking the application back by itself

Braus takes the lent application back when the person stops using it, inferred from what the passive
listener sees rather than from a bare timer. `LendActivity` (SeatBroker) is a pure model: it takes
timestamped evidence and returns a state and a decision, reads no clock, and exposes one `deadline`.
`LendActivityWatch` (Braus) feeds it and wakes a single task at that deadline, so a still Mac costs
no wakeups. Per listener event the main actor does only bookkeeping: map, compare, store.

Evidence and states:

| State | Evidence |
| --- | --- |
| working | clicks, keys, typing, drags and scrolls routed to the lent process |
| reading | the pointer resting on the lent app (`HoverDwell`), one of its menus open (AX menu notices), the app back in front without input yet |
| elsewhere | another app came to the front (listener focus), or the lent app hidden or every window minimized |
| away | no listener event of any kind on the Mac |
| locked | `com.apple.screenIsLocked`/`Unlocked`, `NSWorkspace` sleep and wake |
| closed | the app's accessibility window list empty, or `didTerminateApplication` for the lent process |

The listener now runs with hover on. `ObservedInteractionSource` hands each event to
`HumanPreviewControl.onActivity` with its age (`systemUptime - endedAt`), then passes everything but
hovers on, so the recorder's history and diagnostics are unchanged. A typing burst is reported once it
pauses, up to two seconds late; its age places it when it ended.

Triggers, all delays in `LendActivity`:

- Elsewhere asks "Are you done?" after `elsewhereDelay` (2 min), but only once the person works
  elsewhere: input routed to another app during the span. A look elsewhere with no input there is left to
  the away delay. The lent app hidden or fully minimized is stronger evidence: `tuckedDelay` (30 s,
  chosen for this policy) from the later of leaving and tucking, without work elsewhere. The lent app in front
  again, input to it, the pointer resting on it or one of its menus opening ends the span; evidence that
  ended before leaving does not.
- Away asks after `awayDelay` (5 min) since the last event anywhere. An open menu of the lent app holds
  both delays until it closes; another app coming to the front closes it in the model.
- Locked or asleep takes back without asking after `lockedDelay` (1 min) from the first of them; a
  question never appears meanwhile. Unlocking or waking earlier changes nothing and restarts an elsewhere
  span, so nothing is asked the moment the person returns. Waking past the minute, when the timer could
  not run, takes back at once.
- Every window closed asks at once, once per closing. The census reads `kAXWindowsAttribute` off the main
  actor after the companion's window notices settle (500 ms), with a `censusReadLimit` of 0.25 s; hidden
  counts as tucked, all minimized as tucked, an unreadable list as no evidence. Accessibility lists only
  the current Space, so a window notice while the person is on another Space can read as closed.
- The application quitting takes back at once, even over an open question: the take-back reports the
  vanished app and the worker resumes knowing it.

The question uses the companion's existing bubble with a `countdown` of 10 s. Yes or the countdown
running out is the same path as the worker's Yes (`LendingCompanion.finishRequested`). No, or input
reaching the lent app while it is open, closes it and doubles that trigger's delay; work in the app that
ends after the answer resets every delay. The bubble's answer is final: a withdrawal that reaches it after
Yes or the timeout changes nothing. While a question is open a global key monitor withdraws it on a key
press with the lent app in front, since the listener's typing span would arrive too late. ⌃⌥Tab during the
countdown hands back at once. Nothing is asked while the lend is landing (the model starts held until the
still lands), once any hand-back was asked, or while Braus reads what the person did: the watch stops
with the hand-back.

An automatic take-back passes its reason to `HumanPreviewControl.finish(_:automatically:)`.
`HumanControlCompletion` puts `Ended automatically: <reason>.` as the summary's first line, so the new
turn and the transcript's hand-back row carry it, for example "the person worked in another application
for 2 min; nobody answered within 10 s".

The `dev.forte.Braus` / `HumanControl` log prints, with a `take-back:` prefix, state changes, each question
and its reason, the answer with the next delays, withdrawals, take-backs and the watch's start and stop;
never one line per event. `LendActivityTests` drive every trigger, reset, back-off and never-ask rule on
a hand clock. Lock notifications, Stage Manager, Spaces, activation without a click after the countdown,
and real menus need a live trial.
