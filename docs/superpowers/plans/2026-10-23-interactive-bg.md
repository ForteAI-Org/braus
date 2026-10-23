# Interactive background control implementation plan

**Goal:** Start the agreed feature with a tested, memory-only intervention lifecycle in Engine.

**Architecture:** The preview will produce events with historical frames. A single consumer will reconstruct them without calling an agent. The engine owns ordering and versioned handoff; the agent evaluates task meaning only after collection and reconstruction. Driver integrity remains separate from agent admission.

**Spec:** `Documentation/Engine/InteractiveBackground.md`; the Italian product brief is also in the requested Downloads folder.

## Constraints

- Work only on `elio/interactive-bg` in the isolated worktree based on `4c5b4456`.
- Leave the original checkout's uncommitted changes alone.
- No Brain, Memory or SQLiteMemory changes. No provider calls, input posting or global event taps in this increment.
- No UI or live-control claim until integration is complete and qualified.
- Commit imperative English subjects, actual configured author, no coauthor trailers; no push.
- The user explicitly authorized starting implementation after the document. Execute inline without another approval loop.

## First increment: ordered intervention lifecycle

Create `Sources/Engine/Engine/Intervention/HumanIntervention.swift` and `Tests/Engine/EngineTests/HumanInterventionTests.swift`.

Use an actor `HumanIntervention<Payload: Sendable, Finding: Sendable>`: the future preview adapter supplies immutable event/frame payloads and conservative retained-byte costs, and the Perception consumer supplies reconstruction findings. This core does not invent another event or scene vocabulary before those adapters exist.

The actor starts observing without suspending input. Recording the first event enters collecting. `noteActivity()` cannot start an episode but reopens an existing one. `endInput()` returns an opaque revision and enters reconstruction; completion of the queue does not itself authorize agent input. `beginReview` requires that revision, complete ordered analysis and a final-state finding explicitly supplied by the consumer. `resolve` can resume, finish the task or await clarification. New input/activity invalidates an older review. Closing or analysis failure blocks, clears on explicit closure, and never grants input accidentally.

Interfaces:
- `record(_:retainedBytes:) throws -> UInt64`
- `next() -> WorkItem?` and `complete(_:with:) throws`
- `noteActivity()`, `endInput() throws -> Revision`
- `beginReview(_:finalState:) throws -> Review`
- `resolve(_:as:) throws` with resume, taskCompleted, needsClarification
- `fail(_:) throws`, `close()`, `status() -> Status`

The queue has one leased consumer item at a time. Repeated or foreign completions refuse. Limits apply to both total event metadata count and explicitly accounted retained payload bytes. Overflow refuses before admission and blocks review; it never silently drops events. All frames remain retained for this initial increment, bounded by supplied limits, until successful resolution or close. Later adapters can optimize shared-frame retention without changing the episode contract.

Review focus and tests:
1. Hover does not start an episode; the first recorded input blocks agent admission.
2. A consumer awaits analysis while producers append: order and historical payload survive.
3. New input or activity invalidates reconstruction/review references, including equal event counts.
4. Full queues and invalid costs do not silently produce a complete review; foreign/duplicate tokens refuse.
5. Clarification retains the block; resume/completion/close release payloads with distinct admission outcomes.

- [x] Write behavior tests and observe the missing implementation failure.
- [x] Implement the actor and run focused tests to green.
- [x] Update `Documentation/Engine/README.md` with current capability and missing adapters.
- [x] Run `swift build --product braus`, `make test SWIFT=swift`, and `git diff --check`.
- [x] Have a fresh reviewer inspect this increment and fix material findings.
- [x] Inspect staged diff and commit `Add an in-memory human intervention queue`.

## Subsequent increments, not implemented by the first increment

1. Wire agent suspension and session/lease retention. Inspect WorkerAgentHost, ModelToolLoop, MCPRouter and BrokeredAutomationSession; distinguish temporary suspension from teardown and ignore stale pending actions.
2. Extend Driver admission to distinguish human and agent authority while preserving common faults; qualify deliberate activation, gesture boundaries and native keyboard behavior.
3. Add preview window/display input, frame/coordinate binding and keyboard ownership. Preserve down/up, drag, repeat, modifiers and composition.
4. Connect historical-frame Perception to the queue, inactivity policy and bounded final-state observation. Surface incomplete reconstruction explicitly.
5. Build a compact factual handoff for agent evaluation with input still blocked; show progress/clarification UI and replan only from the current state.
6. Measure latency, frame retention and token costs; perform reviewed host/live qualification on named apps. Do not infer live compatibility from pure tests.

These integrations require concrete adapter contracts from their owning source; the first increment deliberately does not install a partial live input path.

## Execution record

- Ruling: implement the first isolated Engine increment before installing any live input path. The
  existing checkout contains unrelated worker-loop changes; the cost is that preview control is not
  available in this commit and the documented adapters remain necessary.
- Ruling: retain payloads for the whole episode with explicit event and byte limits. This preserves
  reconstruction evidence; shared-frame deduplication and early release remain adapter work.
- Red: `swift test --filter HumanInterventionTests` failed because `HumanIntervention` did not exist.
- Green: the same command passed all 17 lifecycle tests after implementation.
- `swift build --product braus` passed both before and after the change.
- `make test SWIFT=swift` was attempted with host/live opt-ins unset. It stopped before the unit
  runner because the product-name check rejects historical paths in
  `Documentation/App/House/Integration.md` and `Documentation/App/House/Testing.md`. Both files are
  unchanged from the base commit. This required check is not passing and was not disabled.
- An independent read-only review found no actionable issues. No implementation fixes were needed.
- No host, live-input, GUI, provider, perception-quality or performance qualification was run.

- After the final style adjustments, `swift test --filter HumanInterventionTests` passed all 17 tests again.
- The separate complete unit tier passed: 4,587 executed, 197 skipped, 4,784 reported across 39 runs;
  `TIER_RESULT` reported `status: passed` and no problems. This does not replace the failed `make test` gate.
  Exact command (with host/live opt-ins unset):

  ```sh
  env -u BRAUS_LIVE_TESTS -u AGENTSEAT_HOST_TESTS -u AGENTSEAT_LIVE_TESTS \
    -u AGENTSEAT_TYPING_SWEEP -u AGENTSEAT_TEXT_DELIVERY \
    TIER_BUNDLES=39 bash Tools/Driver/Scripts/run-tier.sh unit - \
    bash Tools/Driver/Scripts/unit-test-command.sh swift
  ```

- `git diff --check` and `git diff --cached --check` passed. The local commit contains only this
  increment and its documentation; the original checkout's unrelated changes remain excluded.


## Six implementation rounds to an alpha

1. Temporary Engine history and ordered reconstruction lifecycle: complete, `112b0811`.
2. Human suspension of worker execution and explicit retention of the native session: complete.
3. Driver admission for human input, gesture delivery and deliberate activation with containment intact.
4. Interactive window/display preview, coordinates and keyboard ownership, composed with rounds 2–3.
5. Historical Perception, inactivity, compact handoff, goal evaluation and a fresh route for the agent.
6. Integrated review, regression/alpha checks and an application build for the user's manual trial.

The alpha requires all six rounds. This is a work breakdown, not a compatibility or calendar promise.
Round 6 produces an app, not just the command-line product; unqualified app/input combinations are listed.

### Round 2 contract

- A host can suspend for a human episode: block admission synchronously, cancel model generation,
  let an admitted tool finish, discard pending tool calls and keep its session on intentional cancellation.
- Suspension has an opaque token. Another turn or compaction is refused until the old turn drains and
  the matching token is ended. Ending does not replay old calls or automatically start a provider.
- Ordinary stop, retirement, close and actual provider failures retain their cleanup behavior.
- The broker pins the existing lease during human intervention, including between turns and when other
  workers wait. Explicit close always wins; stale hold tokens cannot release a newer lease.
- MCP distinguishes human suspension from stop, including late client cancellation notifications.
- The future preview coordinator must retain the broker lease before suspending the host, on MainActor
  without an intervening await. Driver event admission and the episode-to-handoff adapter remain rounds 3–5.
- Ruling: do not wire a partial pause to the current TeamModel recorder yet. Its stopped-turn semantics
  would expose an intervention as a completed cancellation; the complete handoff belongs to round 5.
  Cost: these APIs are exercised by integration tests but have no user-visible trigger in this round.

Tests: broker idle/waiter retention, stale tokens and explicit close; router draining without cancellation;
worker model-stream cancellation, admitted-call completion with no later call, refusal during suspension,
matching-token release and ordinary stop/close precedence. Run focused tests, build and required checks.


### Round 2 verification and review ledger

- RED: package tests rejected the missing router and broker methods; native app tests rejected the
  missing host API. GREEN: 43 broker tests and 5 router tests passed; initial host/loop/bridge run passed.
- A completion-boundary test then demonstrated that human input in the final event callback could
  return success; a post-await stop check corrected it and the app suites passed again.
- Fresh whole-branch review found two P2 issues: stopping after the suspended run drained did not
  release its session, and lower-layer cancellation could erase an already-observed provider error.
  Both were reproduced by three failing app tests, then corrected. The app suites passed 34 tests
  after these fixes, with the real-provider test gated off.
- Ruling: a human interruption of an already-running compaction retains its existing cancellation
  outcome; only `run` promises the typed suspension. No new compaction is admitted while suspended.
  The future coordinator must distinguish that case. No persistent recorder schema is changed here.
- Ruling on review exclusions: live input, Driver action boundaries, preview ownership and recorder
  composition remain rounds 3–5. Their absence prevents an alpha claim, but does not block committing
  the tested round 2 endpoints.
- `make test SWIFT=swift` still fails the same preexisting product-name check in the two unchanged
  House documents. This is not treated as a passing required check. Separate unit verification follows.

- The stop-precedence regression also failed when another human input followed an explicit stop
  before the old turn drained. Suspension now refuses in that interval; the final app suite passed.
- Final `swift build --product braus`: passed. Final `make test SWIFT=swift`: same document-gate failure.
- Full separate unit tier: 4,592 executed, 197 skipped, 4,789 reported in 39 runs, `status: passed`,
  `problems: []`. This run began before the final provider-failure fixes. After those fixes,
  `swift test --filter 'ChatTests|BrokeredAutomationSessionTests|HumanInterventionTests'` passed
  158 Chat tests, 43 broker tests and 17 Engine tests. The unaffected native Seat tier was not repeated.
- Final app verification passed 34 tests in three suites; the real-provider test was skipped:

  ```sh
  xcodebuild -workspace BrausApp/AgentEnvironment.xcworkspace -scheme Braus \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath .scratch/interactive-bg-dd \
    -only-testing:BrausTests/ModelToolLoopTests \
    -only-testing:BrausTests/WorkerAgentHostTests \
    -only-testing:BrausTests/ToolBridgeTests test
  ```

- Both review findings are fixed with failing-then-passing regression tests. No minor findings were
  deferred. Compaction and the live composition exclusions are recorded above as explicit rulings.
- No live target input, provider account, perception-quality or performance qualification was run.
  The compiled test app is not an alpha of the interactive feature. Round 6 delivers that build.

### Round 3A: authority at existing command boundaries

Round 3 is in progress, not complete. This substep wires synchronous human/agent admission into
AgentSeat and InputDriver's existing complete-command paths. A gate-scoped opaque episode token
exempts human input only from the agent pause; all common causes and target/geometry checks remain.
A request captures its gate generation before waiting, and a completed intervention cannot revive it.
Ending an episode invalidates its last observation and does not start a provider.

- Ruling: qualify the existing complete-command admission first, before progressive mouse events
  and intentional activation. The Driver consumes an observation per Command and its current drag
  carries the whole path; silently reusing it for mouse-down/move/up would change cleanup semantics.
  Cost: round 3 remains open and these APIs must not be presented as interactive preview support.
- Ruling: refuse takeover during native composition or a split key gesture, and refuse split human
  key Commands in this adapter. There is no release-only ownership transfer yet. Cost: those cases
  cannot be controlled until round 3B supplies explicit held-input cleanup; no input is forwarded.
- RED: new InputCommandGateTests failed to compile for missing episode/admission APIs. The first
  implementation exposed exhaustive InputPauseReason consumers; their wording is updated explicitly.
- RED: HumanInputAdmissionTests failed to compile for missing AgentSeat entry points. They exercise
  the real observation/command path with controlled native collaborators, not just a separate gate.

Tests: agent requests waiting across begin/end, foreign/stale tokens, common faults and terminal stop,
preparation revalidation, complete human command and consumed observation, handback invalidation.
Round 3A complete: focused tests, final product build, required-gate attempt and fresh review recorded below.
The complete round 3 still requires progressive input and activation.

### Round 3A verification and review ledger

- GREEN: 9 InputCommandGate tests and the initial 3 AgentSeat integration tests passed. Expanded
  AgentSeat coverage initially failed before the intended boundary because its fixture supplied no
  keyboard recipient. After supplying controlled identity/geometry/focus evidence, all 5 passed.
- The focused run also passed all 29 ObservationAdmission tests and 23 SeatErrorMapper tests.
- `swift build --product braus` passed. `make test SWIFT=swift` still fails the preexisting product-name
  check in the two unchanged House documents; it is not counted as passing.
- Fresh read-only review found no P1/P2 issues. Final: minor (deferred): InputDriver's new outer
  admission can refuse before its existing TraceHandler paths, omitting diagnostic traces for those
  refused submissions. The error still reaches the caller and nothing is posted. Restore exactly-once
  refusal traces in a subsequent increment; this is not claimed as complete trace coverage.
- Final: Ruling: progressive gestures, held-input transfer and intentional activation remain 3B,
  because they require explicit release/focus lifecycle rather than an exemption in this gate.
  Cost: this increment cannot expose natural-speed live preview control.
- Final: Ruling: native popup callbacks and broader tool admission remain coordinator work. The
  present adapter controls complete Driver Commands, not every side effect a tool can perform.
  Cost: do not expose takeover until the host and these boundaries are composed and verified.
- Final: Ruling: preview, keyboard ownership, Perception and handoff remain rounds 4–5; synthetic
  event attribution still uses the Turn marker until the coordinator associates it with the episode.
  Cost: this increment alone cannot reconstruct or attribute a live intervention.
- Final: Ruling: live focus/containment, app compatibility and latency were not qualified. Pure
  tests do not prove native behavior; the app alpha remains round 6.
- The broad `swift test --filter 'SeatInputTests|SeatSessionTests|SeatErrorMapperTests'` invocation
  was incorrect for this repository: concurrent AppKit tests exhausted observation/follow deadlines
  (for example, frame ages of 266–288 seconds against a 120-second bound). It failed and its remaining
  process was terminated. No source or deadline was changed in response. The prescribed native
  SeatSession runner with `--no-parallel`, plus serial Input/mapper tests, is the corrective check.

- Final serial Input and mapper verification passed 155 and 23 tests respectively:
  `swift test --no-parallel --filter 'SeatInputTests|SeatErrorMapperTests'`.
- Final native SeatSession verification passed all 1,023 tests in 73 suites; `TIER_RESULT` reported
  `status: passed`, `problems: []`, 1,023 executed and none skipped. Exact command, with host/live
  opt-ins unset:

  ```sh
  TIER_BUNDLES=1 bash Tools/Driver/Scripts/run-tier.sh unit - \
    .build/native-driver-test-main \
    .build/out/Products/Debug/SeatSessionTests.xctest/Contents/MacOS/SeatSessionTests \
    --no-parallel
  ```

- Final `swift build --product braus`, `git diff --check` and `git diff --cached --check` passed.
  No app alpha, host/live target input or performance qualification was produced. The original
  checkout's eight unrelated modified paths were verified and are excluded from this commit.


### Round 3B execution and rulings

- Ruling: use the preview's actual input as the producer of immediately forwarded native
  fragments. Do not accumulate and replay a completed path, and do not run Perception before
  delivery. The target still receives process-directed reconstructed events, not the original
  Braus-window event unchanged; coordinate and identity attestation remain necessary.
- Ruling: reuse the complete Command admission and Preparation scope for one progressive
  left-button gesture, with a separate stream vocabulary. Keep per-process exclusion until up
  or cleanup. The cost is a distinct optional sender capability; unsupported senders refuse.
- Ruling: initially qualify only ordinary directly routed windows. Modal/remote/accessibility-only
  surfaces and split keys/composition remain refused, including takeover with an inherited held
  agent key. This is a deliberate alpha limitation, not completion of every input mode in round 3.
- Ruling: use a 30-second maximum held gesture and a bounded 256-sample default queue. A 20-ms
  gate monitor requests cleanup even without a new event. These are proposed safety bounds, not
  measured latency or the future human-inactivity policy. Overflow never silently loses events.
- Ruling: release-only cleanup retains identity/coordinate checks; if it cannot attest the
  recipient, stop the seat instead of sending elsewhere. Cost: a native button may remain held
  in an app whose identity/geometry became unavailable, requiring explicit recovery.
- Ruling: intentional activation is allowed only for the episode's pinned contained process.
  A host without a qualified restorer cannot hand back while that target remains active.
  Focus activation is permitted, not forced; no global event posting or cursor warp is added.
- RED: pointer tests failed to compile for the missing stream and event builder. GREEN: the
  initial six lifecycle/event-construction tests passed after implementation. Expanded coverage
  adds expiry, cleanup refusal and composed AgentSeat boundaries.
- RED: focus recovery tests failed to compile for the missing scoped activation callback.
  GREEN: 70 focused native SeatSession tests passed before adding the two gesture integration
  tests. An integration build then exposed an optional identity in the test fixture; that was
  corrected. A native run accidentally used the previously built bundle after this failed build;
  it is excluded from final validation and must be rerun after successful compilation.
- The existing round 3A minor about early admission refusal traces remains deferred.
- No live/host input, GUI trial, Perception quality, token-cost or latency qualification yet.
  Round 4 connects this input path to the preview; round 5 supplies reconstruction and handoff.


### Round 3B final review and verification ledger

- Initial full serial SeatSession regression passed 1,028 tests in 73 suites, none skipped.
- Fresh read-only whole-branch review found three P2 issues. The fix pass preserved native
  multi-click counts, refreshed expired user-destination evidence before handback, and guarded
  delayed command handback against human ownership. No second reviewer was dispatched.
- RED: native multi-click regression failed to compile for the missing count; after adding it,
  it failed six assertions because the common marker reset the field to one. Setting the native
  click count after marking corrected the actual defect. GREEN: 164 Input tests and 23 mapper
  tests passed, including parameterized single/double/triple click event inspection (no posting).
- RED: the delayed command-window regression observed a third restore request and target focus
  lost during human ownership. GREEN: the scoped guard prevents that restore; the same callback
  still restores after human ownership ends.
- RED: the fresh-handback regression required the missing preparation endpoint. GREEN: the
  injected clock can advance 20 seconds, the previously attested destination is freshly prepared,
  and the gate stays closed until two matching focus readings. An invalidated destination refuses.
- Added composed Seat coverage for new human input arriving during handback preparation: the
  stale end request refuses with inputAuthorityExpired and does not restore or release authority.
- Final focused native verification: 12 tests in 3 suites passed, no skips, TIER_RESULT passed
  with problems: []. Filter: HumanInputAdmissionTests|freshHumanHandback|delayedHandbackDuringHumanInput.
- Ruling: endHumanInput now awaits fresh evidence while retaining human authority. A local input
  revision rejects intervening events. It never extends the lifetime of stale focus evidence.
  Cost: callers must await handback and handle refusal; the UI coordinator is still round 4.
- Final: Ruling on review exclusions: preview/host composition remains round 4; Perception,
  inactivity and agent handoff remain round 5. No user-visible interactivity is claimed yet.
- Final: Ruling on review exclusions: remote/modal/accessibility-only recipients, split keys,
  composition and inherited holds stay explicitly refused. The future preview must communicate
  those limits and must not bypass admission. Geometry-invalid release remains fail-closed as
  documented; the cost is explicit recovery rather than sending an up to an unverified target.
- Final: Ruling on review recommendations: controlled stream/Seat tests and native event building
  do not qualify actual Driver preparation/exclusion timing or live input compatibility. Add
  that controlled orchestration coverage and reviewed live qualification with the preview; no
  latency, containment-on-real-app or focus-restoration-on-real-app claim is made in this commit.
- Final: minor (deferred): early admission refusal can still omit a TraceHandler callback, inherited
  from 3A. Documentation contradictions were corrected during the implementation documentation
  pass; they are not a remaining behavioral finding. No other minors remain open from this review.


- Final full native SeatSession regression after the three review fixes: 1,031 tests in 73 suites,
  no skips, TIER_RESULT status passed, problems []. Exact command (live/host opt-ins unset):

  ```sh
  env -u BRAUS_LIVE_TESTS -u AGENTSEAT_HOST_TESTS -u AGENTSEAT_LIVE_TESTS \
    -u AGENTSEAT_TYPING_SWEEP -u AGENTSEAT_TEXT_DELIVERY TIER_BUNDLES=1 \
    bash Tools/Driver/Scripts/run-tier.sh unit - .build/native-driver-test-main \
    .build/out/Products/Debug/SeatSessionTests.xctest/Contents/MacOS/SeatSessionTests --no-parallel
  ```

- The handback fix had added a focus read before closing the first-input gate. A regression
  observed an empty gate during that read (RED); moving the read after synchronous human admission
  made it GREEN. This was the final behavior change after the full run. The final affected native
  suites were rerun with the same command plus
  `--filter 'HumanInputAdmissionTests|UserFocusRecoveryTests|CommandBornWindowTests'`: all 88 tests
  passed, none skipped, TIER_RESULT passed and problems []. The unaffected full tier was not repeated.
- Final `swift test --no-parallel --filter 'SeatInputTests|SeatErrorMapperTests'`: 164 Input and 23
  mapper tests passed. Final `swift build --product braus`: passed. Final `make test SWIFT=swift`:
  still failed only at the existing product-name gate for the unchanged House Integration/Testing
  documents; this is not counted as passing or disabled.
- Final diff checks passed. The original checkout retains its eight unrelated modified paths.
  This commit completes the round 3B base path with the explicit unsupported-input limits above.
  No app alpha, preview UI, live target input, benchmark or persistent-learning change is included.
