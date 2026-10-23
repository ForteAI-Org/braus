# Interactive background control

Status: agreed product direction, implementation in increments. The queue described below is the
first increment; the preview does not yet accept human input through it.

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

## Integration seams still to implement

- `InputCommandGate`, `InputEngine` and `AgentSeat`: distinguish authority and deliberate activation;
  keep common fault causes, geometry validation and atomic-command cleanup.
- `WorkerAgentHost`, `ModelToolLoop`, `MCPRouter` and `BrokeredAutomationSession`: pause without
  teardown, retain lease, invalidate pending agent actions, and resume evaluation separately from input.
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
