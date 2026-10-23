# Interactive background control

Status: agreed product direction, implementation in increments. The queue described below is the
first increment. The second adds explicit host suspension and lease retention. Round 3A adds
Driver authority for complete Commands. These endpoints are not yet composed or triggered by the
preview, which does not yet accept human input through them.

## Product contract

The person can interact with the target application through Braus's current-window preview and
expand it to the Agent Seat's entire display, including that application's dialogs and palettes.
Expanding or hovering does not interrupt the agent. The first click, scroll or keyboard input
addressed to the session starts the intervention. Clicking the application surface gives that
session keyboard ownership until the person selects another Braus control or another application.

Human input proceeds at natural speed. The engine retains input requests, coordinates, times,
surface identities, geometry and the frames actually presented in memory. Perception reconstructs
components and observed changes through an ordered producer/consumer pipeline while input continues.
It makes no model calls and asks no questions during the intervention. A shared effect of several
inputs and an uncertain effect remain expressible; a later scene is not proof of what a vanished
menu contained.

The agent's next actions are suspended, while an already admitted command may finish atomically.
The session and lease must remain held. The ordinary stop path, which may close the session, is not
this suspension. Common faults still block both human and agent input. Agent-only suspension must
not disable those faults or accidentally refuse all human input.

Display, cursor and window containment remain active. Intentional target activation is acceptable
during control, but its duration and delivery policy require qualification. The hardware pointer
need not leave Braus's physical display: forwarded coordinates can address the virtual surface.
Target changes and transfers must not redirect an event to a surface other than the one intended.

After input begins, movement inside the preview contributes to continued activity. Leaving the
preview favors completion after inactivity; keyboard input still directed to the session extends
the episode even with the pointer outside. The inactivity policy must account for held gestures.
The discussed 10–20 seconds are an example of human pacing, not a fixed timeout contract. A discreet
return-control action and reconstruction status explain waiting without rushing the person.

At the end of input, the pipeline completes reconstruction and observes the final state. Only then
does the agent receive a compact factual handoff, with input still suspended. It compares the
sequence and outcome with the existing goal, replans or recognizes completion, and asks for
clarification when the goal appears changed. A new input or renewed activity during reconstruction
or evaluation continues the same episode and invalidates the older decision.

## First increment: HumanIntervention

`Engine.HumanIntervention<Payload, Finding>` is an actor owning a bounded, temporary event sequence.
`Payload` is the future producer's immutable input/frame envelope; `Finding` is the future
Perception consumer's structured reconstruction. Neither requires a dependency on Brain, Memory,
SQLiteMemory, a provider, an input poster or an application framework. No persistent schema changes.

The lifecycle is:

1. Observing: movement and view expansion do not suspend anything.
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

The constructor requires event and accounted-byte limits. A producer calls `record` before
forwarding the input request. Refusal must prevent forwarding; otherwise the retained trace would
omit a real action. Overflow blocks the episode and preserves existing history. The byte cost is a
conservative caller-supplied charge for the retained payload, including its frame; it is not a
measurement of total process RSS. Findings and externally retained snapshots also occupy memory.
This increment retains payloads until successful resolution or explicit close, with no eviction or
silent coalescing. Shared-frame accounting and early pixel release belong to the later adapter.

`Status.allowsAgentInput` describes this episode only. It is not a Driver authorization and does not
replace the gate, target checks or lease. The UI and Driver must eventually coordinate the first
record with stopping agent admission. This actor alone does not stop a provider or an in-flight tool.

## Second increment: suspend execution and retain the lease

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

The future coordinator must retain the broker lease and suspend the host on MainActor without an
intervening await. If the host refuses because it is stopping, the coordinator must unwind its
new retention and must not forward the input. It must consume the suspension before `WorkerTurnRecorder` records a terminal
turn, retain the Engine episode, and allow a new route only after a current review. This composition,
the live preview trigger, and progressive Driver input remain unimplemented. The new Driver gate
can block subsequent Commands inside an admitted tool; the coordinator must connect that gate to
this host suspension before any preview input is forwarded.
An existing compaction interrupted by human input keeps its normal cancellation result; no new
compaction can start during the intervention. The later coordinator must handle this separately
from the typed suspension of `run`.
These tests prove local lifecycle behavior, not a live human takeover or background focus behavior.

## Round 3A: Driver authority for complete Commands

The Driver now provides gate-bound human episodes and versioned admission. AgentSeat exposes
`beginHumanInput`, `sendHumanInput` and `endHumanInput`; complete human Commands retain ordinary
observation and containment checks. Pending requests retain their original admission generation,
so an intervention that starts and ends while a request waits still invalidates that request.
The gate's common causes continue to block both sources. Ending invalidates the last observation.

The first-input coordinator must close Driver admission as well as retain the broker and suspend
the host, then wait for the old command/Turn and cleanup before sending human input. Opening a
preview must not call `beginHumanInput`. None of these endpoints automatically calls another.
A token does not authorize a window or replace the Turn's correlation marker.

Round 3 remains incomplete: progressive mouse events and deliberate activation need their own
held-input and focus lifecycle. The current adapter refuses split human key Commands and refuses
takeover during native composition, held agent keys, or a split key Command in flight. Those cases
must not forward the input or suspend the host after the Driver refuses. The existing focus checks
remain active, so intentional target activation is not yet permitted by this adapter.

## Alpha delivery rounds

1. Engine event queue and temporary history, complete.
2. Host suspension and session retention, implemented with controlled tests.
3. Driver human/agent admission, progressive gestures and deliberate activation.
4. Window/display preview input and keyboard ownership.
5. Historical Perception, inactivity and compact handoff for goal evaluation and replanning.
6. Integrated review, regression checks and a compiled application for the user's alpha trial.

The alpha is delivered after all six rounds. Round 4 alone is not the complete feature.

## Integration seams still to implement

- Driver: complete progressive gestures, held-input cleanup and deliberate activation on top of
  versioned admission; keep common fault causes, geometry validation and atomic-command cleanup.
- Compose the new host suspension and broker retention with `HumanIntervention`, intercept the typed
  suspension before terminal recording, and resume evaluation separately from input.
- Preview: window/display view, immutable presented-frame binding, coordinate conversion, keyboard
  ownership and complete down/up, repeat, modifier, drag and composition behavior.
- Perception: analyze historical frames, bind targets and effects, handle unknowns and obtain the
  final observation corresponding to the current input boundary.
- Handoff: compact evidence for model evaluation, inactivity policy, reconstruction/clarification UI,
  explicit cleanup and measurement of memory, latency and token costs.

The current Driver consumes an observation per complete command and accepts complete drag paths.
A streaming human gesture cannot simply call the existing complete-action loop for each event.
Likewise the existing passive Watcher does not provide the whole preview-and-keyboard history.

Activation and background forwarding remain two approaches to qualify. A synthetic event is not
proof of background behavior, and delivered shortcuts need independent effect checks. Never replay
an unconfirmed gesture through a second transport. Physical keys, text and native composition have
distinct semantics.

## Persistent learning

Temporary reconstruction does not teach a procedure automatically. Reliable reusable procedures or
verified improvements to existing ones are a separate integration with the owner of Brain and
Memory. Small interventions and uncertain sequences are not automatically persisted.

## Verification

Pure lifecycle tests exercise admission, consumer ordering, stale and foreign references, activity
during reconstruction/review, clarification, explicit failure, capacity limits and cleanup. They do
not establish live input, window containment, perception quality, application compatibility or
latency. Those require reviewed, coordinated host/live checks after their adapters exist.
