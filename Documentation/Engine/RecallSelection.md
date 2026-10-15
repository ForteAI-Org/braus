# Recall selection

How the Recall goes from a task's request to the few steps it proposes, which data each decision rests on, what that
data proves, and what it leaves unknown. Selector `recall-selector-4` (2026-10-12, after the third review), in
[RecallSelector.swift](../../Sources/Engine/Memory/Recall/RecallSelector.swift). The rest of the Recall (index,
lifecycle, delivery, use) is in [MemoryRecall.md](MemoryRecall.md). Since 2026-10-13 the product's path is the agent's
choice ([RecallAgentChoice.md](RecallAgentChoice.md)), which validates the agent's tracts with these same rules
(exclusions, conditions, bindings, coverage) and shows this selector's selection as a suggestion. The automatic
selection is no longer an answer of the product: it is the control of the comparisons and the regression tests
(`RecallSelectionControl`).

The rule of the design: **facts decide what they can; the request's words decide the extent only where they name the
work unambiguously; similarity says whether a version is about the need, never how much of it to select or that the
need is covered.** Where none of these decides, the selector states the uncertainty or proposes nothing.

## 1. Data, proof, conclusion, unknown

| Data (contract) | What it proves | What the selector may conclude | What stays unknown |
| --- | --- | --- | --- |
| Request revision: goal, `remaining`, `needs[].text`, constraints ([TaskContext.swift](../../Sources/Engine/Memory/Tasks/TaskContext.swift)) | What the agent states the work is | The need's words; constraints to check against steps | Whether a word describes work to do, work done, or context ("the photo already rotated") |
| `needs[].app` | The application the need is bound to | Parts of other applications are excluded before any cut | — |
| Task inputs: value, kind, role, source, `source_ref` | The values the task holds and where they came from, as stated | Bindings to parameters by name and role ([RecallBinding.swift](../../Sources/Engine/Memory/Recall/RecallBinding.swift)); a value the need mentions | Whether the agent assigned a value to the semantically right role |
| Version steps: one operation each, label, tool, literal or parameter arguments (D2) | The method's operations in order and what each reads | Contiguous tracts; which parameters a tract reads | A step's purpose beyond its label; data dependencies between steps (a send that needs the recipient typed before) |
| Parts: procedure, subprocedures (one per application block), steps; qualification A; part states | Which parts are admissible now | Only offered steps are delivered; a step out of the catalogue inside a tract is a gap | — |
| Declared outputs (`producedBy`) | Which part produced an output in the source | That part is skipped when the task holds the output (`output_ready`) | Who consumes it |
| Per-attempt bindings: value, source, `source_ref` (`memory_parameter_bindings`) | Where each input's value came from, as the agent stated it | An input fed by an output of an earlier part, when its reference names that output ([RecallSource.feed(of:)](../../Sources/Engine/Memory/Recall/RecallSource.swift)) | Any relation not stated; equal values are no relation |
| Entry and exit states of steps' calls (structural scenes) | The UI state each step started from and left | Episodes: the atomic UI units (a dialog from its opening to its closing) | The data state (whether a document was edited) |
| Latest observation of the session (within 15 min) | The UI state now | Steps that reached it inside its episode are done (`observed_state`) | Which document it is for; whether earlier episodes' work is done |
| Index relevance (lexical, semantic, hybrid) | Similarity of texts | The version is about the need (≥ `absolute`) | Extent, coverage, compatibility |

## 2. From the request to the steps

1. **Request.** `memory_task begin`/`recall` gives the revision's values, constraints, `remaining` and `needs`
   ([MemoryTaskTool.swift](../../Sources/Integration/AutomationMCP/MemoryTaskTool.swift)).
2. **Observed state.** The service flushes the derived queue for 1 s and reads the latest observation of the task's
   stream within 15 minutes ([RecallService.recall](../../Sources/Integration/AutomationRuntime/RecallService.swift)).
3. **Retrieval.** Each need is searched with the task's values masked; parts of another application are left out first
   when the need names one; the 48 best parts per need, and of them up to 12 versions, are read (`limited`, with a note,
   when more were relevant) ([RecallService.prepare](../../Sources/Integration/AutomationRuntime/RecallService.swift)).
4. **Sources.** Each version is read from the authoritative tables, never from the index: steps, parts, offer,
   parameters with their per-attempt origins, element keys, entry and exit states
   ([SQLiteRecallRows.source](../../Sources/Engine/SQLiteMemory/SQLiteRecallRows.swift)).
5. **One version for one need** (`RecallSelector.Reading`), in this order:
   exclusions (certain conflict, constraint) → episodes, cut at the observed state unless the need names earlier work →
   episodes the need names → tract from the first named to the last → producers (`output_ready`, `input_produced`) →
   prerequisites (`entry_state` or `observed_state`, `prepared_before`, `application_switch`, gaps) → bindings and
   compatibilities → constraints not checked → coverage.
6. **Ranking** of the versions within `adequacy` of the best relevance: coverage, fewer preparations, evidence,
   relevance; then, between equal proposals, the version with fewer steps outside the proposal, its label and its id
   (learning gives random ids, so the content decides); variants of one method decided by the need's words or named
   as alternatives.
7. **Last check.** Every selected step is read again as offered, or the versions are read again and selected again.
8. **Record and delivery.** Query, needs, selections (version, ordered interval, whole part), requirements, then the
   delivery: version id, steps numbered as in the source with their operations, parameters bound (value, from, match),
   conditions in words, evidence ([RecallDelivery.swift](../../Sources/Integration/AutomationRuntime/RecallDelivery.swift)).
9. **Use.** After the attempt, calls are linked to the delivered steps from facts only
   ([RecallUseLinking.swift](../../Sources/Engine/Memory/Recall/RecallUseLinking.swift)).

## 3. Requested, done, prerequisite, additional

| Kind of work | Decided by | Rule | Example |
| --- | --- | --- | --- |
| **Requested** | The need's words and the values it mentions | An episode is named when, in one clause of the need, it alone holds the most words no other episode of the version holds (a tie names none); a word every episode holds says what the version works on, an application's name says where. A value the need mentions (three characters or more, or a number of any length, held by no other value) names the episode that alone reads it, but only when the version recognizes the need's work: a word one episode alone holds, or a word the procedure's or a part's label gives the work and no step spells | "Add Marco Rossi to Contacts with the phone number …": the phone names the card's episode; first and last name are read by the card and by the sharing and name neither. "Create the event Pranzo on 2026-11-03": "create" is only in the label, so the date names the creation's episode. "Move the event … to 2026-10-21": no word names any work, nothing is proposed |
| **Done** | Facts only | Observed state (steps before it inside its episode); an output the task holds (`output_ready`); an input bound to a held output it was stated to be (`produced`). Never a word ("already"), never the mere presence of a previous output | "Email the invoice already downloaded" with the invoice file held: the download part is skipped because the file is held, not because of "already" |
| **Necessary prerequisite** | Structure and stated origins | The episode's own steps (a dialog is opened and confirmed); episodes between named ones, unless they form a block of another application none of whose episodes the need names; the producer of an input the task lacks when an origin names it, included only when nothing else lies between them or what lies between belongs to an episode of either (`input_produced`); otherwise the input stays missing and the delivery names its producer; the entry state as a condition | Attaching a file the source downloaded right before, as its attempt stated: the download is included. The report exported from Pages with an unrelated download between it and the email: the email alone, its attachment missing, the export named as its producer (review F10) |
| **Additional** | Absence of naming | Episodes after the last named one are left out; episodes before the first named one, in its block, are stated (`prepared_before`) and never planned | Creating a contact without sharing it: the sharing is left out. Adding a song to a playlist that exists: the creation is stated, not repeated |

Why work before the selection is stated rather than planned: whether it is done or still needed is not in the
contracts. Planning it may repeat work that changes data (a second playlist, a second rotation); stating it costs the
agent one check. The condition names those steps, the last label and the data they read that the task does not give.

## 4. Coverage

`complete` means: the selection holds every episode the need names, none of them excluded, no gap, every parameter it
reads bound; its conditions are stated beside it. It is a proposal of the remaining work within those conditions
(R51), not a proof that the goal will be reached.

Not evidence of coverage: a similarity above a threshold, the number of the task's values a method reads, bound inputs
alone, the presence of any previous output, a procedure label that matches the request (a label summarizes all its
parts, so it matches a request about any of them).

`ambiguous`: an input missing or ambiguous, a value lacking about a fixed choice, two variants the words do not tell
apart. `partial`: a gap; a clause whose work (its first word, the verb of an imperative request) the version knows
nowhere, named in the answer (review F11: "Turn the open picture clockwise and export it" is partial, never complete
with the export alone); named work left out behind a block of another application the need does not ask for. `absent`:
no version names the work, or a named episode is excluded, by the need's words or by a
value it alone reads (the exclusion is named). An excluded episode takes along the uncertain episodes next to it in its
block (steps whose start was not recorded in a known state), so a dialog is never delivered without the choice that
defines it.

## 5. Not decidable without new information

| Case | What the selector does | Consequence |
| --- | --- | --- |
| A request in another language than the labels | No word recognized: nothing from the version | Safe; multilingual positives are lost (a semantic channel finds the version but cannot delimit it) |
| Done work stated only in words ("the downloaded invoice", "già selezionata", "the dialog already open") | The words name the episode as work | May plan done work; the remedy is a fact: the ready output as an input bound to the declared output |
| Context words that are also an episode's words ("In the Export dialog…, choose PNG"; the Italian "calendario" cut to the stem of "calendar") | The context names the confirming step, or the episode that adds an event for a request to delete it | A step more than asked, or work of another kind answered `ambiguous` |
| A need that shares only the object with the version ("Move the event …") | No work recognized: nothing from the version | Safe; a need worded only with synonyms of the labels is lost the same way |
| Steps whose entry state was not recorded (a window the learning did not recognize as a scene) | Each is an uncertain episode; the selection has a gap | `partial` with `unknown_entry_state`; the corpus check lists such versions before a final |
| Work before the selection, not named (creating the note a title is typed in) | `prepared_before` | When it was needed, the agent must do it from the condition |
| Synonyms and derivations ("resize"/"size", "write"/"create", "turn … clockwise"/"rotate … right") | Not named; a clause whose verb the version knows nowhere leaves the need partial, the verb named | The episode is missed or the version answers absent or partial, never complete; the agent's choice (A, the product's path) can read the synonym |
| Unrelated work inside a tract inside one application (an edit between two named steps of one app) | Kept: the rule cannot tell it from a needed step | A step more than asked; across applications the tract is cut instead |
| An object word one episode alone holds ("image" in "Save the exported image") | It names that episode | A wrong episode may join the tract |
| Near methods in other applications (a Pages export for "export the document in Preview") | Ranked by preparations | A simpler method of another application may come first |
| A data dependency between episodes (send needs the recipient typed before) | Not known | The earlier episode is stated, not included |

## 6. Measured effect, development only

The second comparison's corpus (`recall-corpus-v2`, all 90 queries; its final split is development since its result)
diagnosed through `RecallEvaluationV2Tests` in mode `diagnose2`, at each configuration's frozen thresholds (only
`absolute`, `adequacy` and `tie` are still read). Correct / unsafe / wrong queries, full archive; "before" is selector 2
with the corrections F07–F09 already applied.

| Configuration | Split | Before | After |
| --- | --- | --- | --- |
| lexical, uniform | regression (46) | 26 / 3 / 17 | 23 / 7 / 16 |
| | development (23) | 9 / 0 / 14 | 10 / 1 / 12 |
| | former final (21) | 7 / 6 / 8 | 14 / 0 / 7 |
| hybrid Granite 0.2, uniform | regression | 39 / 4 / 3 | 31 / 6 / 9 |
| | development | 16 / 0 / 7 | 12 / 1 / 10 |
| | former final | 6 / 10 / 5 | 14 / 0 / 7 |
| semantic Granite | regression | 31 / 3 / 12 | 27 / 5 / 14 |
| | development | 14 / 0 / 9 | 12 / 1 / 10 |
| | former final | 7 / 7 / 7 | 14 / 0 / 7 |

After the change no configuration delivers an incompatible step or a false complete on a critical need, in any split
or condition (full and minimal archives); the unsafe answers left are non-critical false completes (work before the
selection that was needed, near methods, context words, one expectation that ignores an equivalent method added in
v2). Positives move from the regression split to the cases the change targets; Italian and mixed requests answered by
the semantic channel's relevance are now absent. The rule was written while reading these cases: the numbers say what
it does on them, not how it generalizes. A new final on unseen families is required for that.

### The third comparison and what followed

A new final on families not seen (Calendar, Photos, a Keynote slide sent with Messages; corpus v3, three
configurations, criteria fixed before the run; [MemoryRecall](MemoryRecall.md#the-third-comparison)) failed: no
configuration met K1–K6, each delivered one incompatible step and two critical false completes. Its cases are
development since. They showed a defect of the fixtures (two windows not recognized as scenes) and three of the rules,
fixed after it with the further changes they led to, each with a test in `RecallScopeGuideTests`:

| Change | Case that showed it | Test |
| --- | --- | --- |
| An excluded episode takes along the uncertain episodes next to it | A JPEG asked of a PNG export whose dialog states were unknown: the rest of the dialog was delivered | `exclusionOverUncertainEpisodes` |
| Values name an episode only when the need's work is recognized | "Move the event …" answered with the creation | `objectWordsAndValuesNameNoWork` |
| A number of any length is a mention | "Export slide 2 …" left the slide's selection out (critical false complete) | `shortNumbersAreMentions` |
| Words of a label that no step spells are recognized | "Create the event … without inviting anyone" lost by the previous change | `labelWordsRecognizeTheWork` |
| A value naming an excluded episode makes the version absent | With the label's "named" recognized, "slide 2" named the selection of the slide whose export is excluded | `exclusionOverUncertainEpisodes` (failed after the previous change, passes with this one) |
| Equal proposals ordered by content before the id | Two lexical answers flipped between runs on random ids | `equalProposalsByContent` |

After these changes, on the same (now seen) cases at the frozen thresholds, no configuration delivers an incompatible
step or a critical false complete in any split or condition; the final split's positives are 7–9 of 16 (full) and
9–11 of 16 (minimal), still under the frozen criteria, and every positive the hybrid configuration still misses is on
a version with unknown entry states. These numbers describe rules read against those cases, not a generalization.

### Selector 4, after the third review

- **F10.** A producer is joined to the selection only with what its dependency needs. When unrelated work lies between,
  the input stays missing and the delivery names the producer.
- **F10, across applications.** Named work across a block of another application that the need does not name is cut
  at that block. The later work is delivered, and the earlier work is said left out.
- **F11.** A clause whose verb the version knows nowhere leaves the need partial, the verb named.

Tests: `RecallThirdReviewTests` (the review's counterexamples, expectations unchanged), `RecallScopeDependencyTests` and
`RecallUnaccountedWorkTests`. Two expectations of earlier tests changed, each with its reason in the test:
- the coverage of "Write a note titled Budget …", the false complete the second round reported;
- the coverage of a need whose clause "edited as …" the rule cannot read.

`twoProducersOfEqualValues` keeps its proof of the stated producer, and its expected scope follows F10.

## 7. Decisions for review

The extent of the work is an interpretation of the request; the deterministic rule above interprets only exclusive
words, and the classes of section 5 remain. Closing them needs one of the following, none introduced without review
(D3 plan: experiment, benefit and cost, contract review).

**Status, 2026-10-12.** The user approved an experiment of A, as an experiment and not as the default. It is
implemented as the agent's choice among shortlisted sources, Engine validating it with this page's rules, in
[RecallAgentChoice.md](RecallAgentChoice.md). It is broader than the outline below: several tracts, several sources, a
shortlist that keeps versions the rule names nothing in. Schema 7 holds proposals, choices, declarations and tract
links. C's provenance is fixed at the typed boundary (`TaskOutputReference`, review F12). Measured on development cases
with a real agent, A finds the right tract far more often than this page's rules but fails the safety and negative
criteria ([RecallAgentChoice](RecallAgentChoice.md#measured-development-2026-10-12)); it stayed an experiment. **Status, 2026-10-13.** The product owner chose A as the product's one Recall path; this
page's rules are now its control in the comparisons and the regression tests (`RecallSelectionControl`). The text
below is the proposal as it was written.

**A. Extent confirmed by the agent (contract change, recommended to try first).** When the selection's extent rests on
words, the answer carries the version's episode outline (step ranges and labels, the proposed range marked) with a
new reason `extent_unconfirmed`; the agent confirms or narrows with `recall` `keep: {need, first, last}`, and the use is
linked to the confirmed range.

- Example: "Write a note titled Budget and email it to sara@example.com" proposes steps 2–5 and outlines step 1
  "Create a new note"; the agent, which knows no note is open, answers `keep 1–5`.
- Cost: the outline is the labels of one version, about 80–200 tokens per need; one more call when the agent narrows.
- Contract: a new coverage reason, a new `keep` field, a confirmed range in the record (schema 7, with a migration).
- Requirements: it departs from the guide's decision not to add a mandatory preview of all labels (A8), so it needs
  that review.
- Evidence that would refute it: on a corpus replayed by an agent, no reduction of false completes, or a token cost
  above the reuse it saves.

**B. A semantic judgement of the extent (second component).** A cross-encoder or the agent's model labels each episode
as asked, done or not asked.

- Cost: a second model or a model call per recall.
- Evidence that would refute it: its errors on the close negatives (rename, delete) are not below the rule's.

**C. Same-attempt provenance (clarification, no schema change).** An input taken from an output of an earlier part of
the same attempt states `source: previous_output` and `source_ref` naming that output. The selector already reads the
output's name, or `<task id>/<output name>`, through `RecallSource.feed(of:)`; the tool's instructions would say so.

- D1 finding: a `source_ref` of the form `<task UUID>/<output name>` is replaced by `[withheld]` in the archive. The
  credential heuristic `ValueMinimization.looksGenerated` treats a token of 32 or more characters with upper case,
  lower case and digits as a generated key. D1's documented reference format for previous outputs is therefore lost
  whenever task ids are UUIDs.
- Proposed fix (D1 owner): check the token on each side of the `/`, or exempt a prefix that is a task id of this
  archive.
- Until then, the output's name alone survives.

**D. Need and done work stated apart (guidance).** `remaining` holds only the work to do; what is done goes into
inputs as ready outputs. This makes "already X" a fact instead of a word. It needs no schema change, but it is a
change of the agent-facing instructions.
