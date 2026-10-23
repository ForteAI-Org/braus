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
