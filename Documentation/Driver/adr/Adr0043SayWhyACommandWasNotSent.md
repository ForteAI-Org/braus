# Say why a Command was not sent

Status: candidate, 2026-10-14. Proposed by Tommaso from the Brain/Memory canary, to be
reviewed by Elio with [ADR 0042](Adr0042PreparePreviewMenuCommands.md) and the
follow-ups of ADR 0031 and ADR 0040.

## Evidence

Canary of 14 October 2026, Preview 11.0 on macOS 27.0, build `e300fc0`.

- Preview's Save As sheet (window 112340) shrank from 347 to 321 pt when its format
  became PNG, and the seat logged that it "settled … and the coordinates taken before it
  are refused". The agent's next input, `set_toggle` on "Mantieni le modifiche nel
  documento originale", was stopped by `preflight` before any event, but it reached the
  agent as `acted_unverified` with "delivery failed: SeatInterruption(issues:
  [SeatCore.SeatIssue.geometryChanged])". The agent read an input of unknown effect,
  gave up the box, and so gave up the route that keeps the original file as it was. The
  Export sheet of the second part did the same after it expanded.
- A moment in front for "File > Esporta…" ended with "in front for 822.2 ms, not ready,
  and the front is with process 83997, where it was left": the person had brought
  ChatGPT forward, and the seat left it there, as ADR 0013 says. The agent was told only
  "The admitted menu command was not dispatched."

A `SeatInterruption` is thrown before an event by `preflight`, and after events by the
recovery (`ambiguousEffect`, `recoveryExhausted`, a critical Issue), so its type does not
say whether anything went out. `notReady` covered both an item that stayed disabled and a
front another application took.

## Decision

**The preflight's stop says it came before any event.** `SeatInterruption` gains
`beforeAnyEvent`, false by default; the two throws of `preflight` (a stashed window, the
Issues of the guard) set it. `SeatActuator` answers such a stop as `GestureNotSent`
(reason `seat_preflight`, the Issues in words and "Observe again and act on the new
scene"), so the engine reports `refused`, nothing sent. Any other `SeatInterruption`
stays a delivery of unknown effect, now in words (`GestureInterrupted`: "the seat stopped
it: …; it may have taken effect, so observe before any retry"). `SeatIssue` keeps no
prose; the words are the actuator's, as `SeatErrorMapper` and `SeatAdmission` keep theirs.

**A moment that ends with the front elsewhere says so.** `BriefActivationOutcome` gains
`frontElsewhere(afterMilliseconds:)`: the condition did not hold and the front is with a
process that is neither the target nor the person's own. A front still with the person's
process stays `notReady`, since the target never came forward. The broker words it ("another
application came to the front meanwhile and was left there, so nothing was pressed"),
and a plain `notReady` in a menu command now says the item did not read enabled before the
moment ended. After a moment that dispatched nothing, the menu path is read again, and an
item that is gone answers with the menu's current items: Preview read "Esporta come…" in
the background and "Esporta…" once active.

## Verification

Offline: `ObservationAdmissionTests` (a stashed window refuses with `beforeAnyEvent`),
`OperationalGeometryTests` (an Issue the preflight reads is marked and nothing is posted),
`RemoteContentActuationTests` (the mapping, both ways), `UserFocusRecoveryTests` (a front the
person takes is `frontElsewhere`; one that stays with the person is `notReady`),
`BrokeredAutomationSessionTests` and `MenuBarCommandTests` (the sentences, and a renamed
item listing the current menu). The live check is the next canary run.
