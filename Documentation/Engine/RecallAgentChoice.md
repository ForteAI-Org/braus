# Recall by the agent's choice (experiment A)

An experimental path of the Recall, approved on 2026-10-12 as an experiment, not as the default. Engine retrieves a few
relevant sources. The agent that runs the task chooses the tracts it needs, using what it knows of the conversation.
Engine checks the choice against the facts and delivers the details. The automatic selector
([RecallSelection](RecallSelection.md)) stays the default and the control the experiment is compared with.

## Activation

The path exists only in a process started with `BRAUS_RECALL_AGENT_CHOICE=1`. In that process `memory_task` accepts
`recall_mode: "propose"` on `begin` and `recall`, and the operation `choose`; its description and instructions say
so. Without the variable those arguments are unknown and refused, and nothing changes for any client. Even when the
path is enabled, a `begin` without `recall_mode` answers the automatic selection.

## Contract

```text
begin|recall {recall_mode: "propose", remaining, needs, inputs, constraints}
        └─▶ proposal {proposal, needs[{need, sources[s1..]}], sources[{source, version, procedure, apps,
                     relevance, steps[{step, app, operation, label, entry}], parameters, outputs, feeds,
                     excluded, not_offered, suggested}], search, guidance}
choose {proposal, plan[{need, tracts[{source, from, to}], covered: all|part|none|ambiguous, uncovered,
                        alternatives[{source, from, to}], settled_by}]}
        ├─▶ refused {code, problems[]}            nothing recorded, nothing delivered, no UI
        ├─▶ choice_not_recorded                   the archive refused the record: nothing recorded or delivered
        └─▶ delivered {query, needs[{need, coverage, reason, declared, uncovered, tracts[selection], alternatives,
                                     settledBy}]}
```

- **Proposal.** Engine searches each need as the automatic path does: values masked, filters, the local index. For
  each need it shortlists up to `RecallChoice.sourcesPerNeed` (3) versions by relevance, and at most
  `RecallChoice.sourceLimit` (6) for the query. A version stays shortlisted even when the automatic selector names no
  tract in it. That keeps synonyms and other languages within reach of the agent.
  - Each step of a shortlisted version is one line: its number, application and recorded operation (tool and its fixed
    arguments, for example `press "Send"` or `menu File > Export…`), the agent's label, and whether its entry state
    is known.
  - Labels are data written by an earlier agent, not instructions.
  - The proposal also states the parameters with how they bind to the task's values, declared outputs and the inputs
    they fed, the steps certainly excluded and why, the steps the catalogue no longer offers, and the automatic
    selector's suggestion, marked as such.
- **Choice.** The agent orders tracts per need. A tract is a contiguous interval of one shortlisted version, in that
  version's numbering. A need may take several tracts, from one version or several, or none.
  - `covered` is the agent's declaration of how much of the need the tracts cover. `uncovered` says in its words what
    remains.
  - `covered: ambiguous` answers a need whose result is the person's choice (a format, which pages) that nothing
    settles. It names the options as `alternatives`, at least two, never as tracts, with the question for the person in
    `uncovered`. Nothing of it runs.
  - `settled_by` is the agent's quotation of the person's words that, in its reading, settle a fixed choice another
    shortlisted version makes otherwise ("soltanto la pagina che sto leggendo"). It is the agent's interpretation, not a
    verified choice: Engine checks only that the words are the request's.
  - A tract keeps its origin and order. The choice never rewrites a procedure or makes a composite step.
  - The instructions ask for a tract that does part of the work asked, on the object asked, from what is at hand. A
    generic step of a procedure of another action (Save in a creation, for a rename) is no method. A preparation the
    request needs (selecting the very item) may be chosen as `part`, with the action left uncovered.
- **Validation (Engine).** All-or-nothing; a refusal lists every problem, so the agent can choose again or propose
  again.
  - The proposal must belong to this producer, task, attempt and current revision, and be at most 30 minutes old.
  - Each source is in the proposal, and its version is still current (not superseded) when re-read from SQLite.
  - Each range is within the version and in order, without overlap inside one version.
  - Every step is still offered. None is excluded by a certain conflict or a constraint, and none belongs to the
    episode such a step belongs to: leaving the conflicting step out does not make the rest of its work compatible
    (the selector's own exclusion of the episode). The version's other episodes stay selectable, so an independent
    compatible part (making a chart whose learned export has the wrong format) is still reused.
  - **Variants.** A tract whose steps another shortlisted version of the need does with a different fixed choice (a
    select's item, a toggle's value, a menu path's last item) needs that choice settled. The evidence follows the choice
    and its role, never the person's data (review F14):
    - a task value concerning the choice that names this option. A value concerns a choice when its name, the
      identifier the task gives it, shares a content word with what the choice is made on: the select's control, the
      toggle's element, or the menu path before its last item. A value either version binds to a parameter is that
      version's data and concerns no choice: a file named Word is no format. A value's role is free text written by
      the agent and is not read for this;
    - the request's own words naming this option and not the other, read with every task value masked out, as the
      selector reads a need;
    - or `settled_by`, a quotation Engine finds in the request and that is not the request as a whole. Engine checks
      that the words are the request's, not that they mean the choice; that reading is the agent's, recorded beside the
      choice as its own.

    A value concerning the choice that names the other option refuses the tract. A value not shown to concern it settles
    nothing and contradicts nothing: the choice stays open, the plan is refused with both options, and the agent answers
    `ambiguous` or quotes the person.
    - *Limit.* A value whose name does not share a word with the menu (`output_format` for "File > Export To > PDF…")
      is not shown to concern it, so the agent quotes the person instead. The automatic selector's own certain
      conflicts still read a value's name and role together, unchanged here.
  - `covered: none` comes with no tract; `all` and `part` with tracts; `ambiguous` with no tract, two alternatives or
    more and the question.
- **Conditions, not refusals.** These are computed per tract with the automatic selector's own rules:
  - entry state, observed state, steps before in the block, application switches, gaps;
  - bindings, ambiguities and missing inputs (a missing parameter stays missing whatever the agent says);
  - inputs produced by a declared output. The producer may be an earlier tract of the same need, otherwise the input
    is missing and its producer is named.
- **Coverage.** Coverage is structural, never the agent's word alone.
  - `ambiguous` (`alternatives`): an ambiguous answer, its options recorded as alternatives.
  - `absent`: no tract.
  - `partial` (`gaps`): a gap, or `covered: part` with what is uncovered.
  - `ambiguous` (`unresolved_input`): an unresolved input.
  - `complete`: none of these.

  The agent's declaration is kept beside it, attributed to the agent. It is not a qualification or a verification of
  the goal.
- **Delivery.** Each tract is delivered as the automatic path delivers its selection: steps with operations,
  parameters bound or missing, conditions and evidence. The proposal is what was proposed; the delivery is what was
  admitted. Proposed or rejected material is never delivered as a plan.
- **Use.** Calls after the delivery are linked to the delivered tracts in their order. Each call links to at most
  one step of one tract (`memory_recall_choice_links`, keyed by query and call). A version's confirmed reuses count a
  tract only when all its steps were carried out by confirmed calls. Perception, action, verification and progressive
  recording are unchanged; a new query is made for a reason, not after each call.

## Transitions of a proposal

```text
proposed ──choose (valid)──▶ chosen (one query)      choose again, same plan, same revision: the recorded receipt, nothing new
    │                                                  choose again after a revision, past 30 minutes, a step retired or a
    │                                                  version superseded: refused like a new choice (stale or invalid)
    │                                                  choose again, another plan: refused (already chosen)
    ├──choose (invalid)──▶ proposed (refusal listed, nothing recorded)
    ├──task revised / attempt resumed / 30 minutes ──▶ expired (stale_proposal: propose again)
    └──process restart ──▶ the producer's open task is gone; a resumed attempt makes it expired (stale_proposal)

A proposal of another producer or of another task is unknown (`unknown_proposal`).
```

**Retries (review F13).** A choice given again is checked as a new one: against the task's current revision, the
proposal's age and the versions read now.
- After a revision of the task it is stale. A new Recall is needed, and the recorded query keeps its own revision's
  values.
- In the same revision it is answered under the recorded query only when what it would deliver now equals what was
  recorded: needs, selections and requirements with the task values they took, by name
  (`SQLiteRecallRepository.facts(ofQuery:)`). Otherwise it is stale too.
- A retry never records anything. A receipt is never re-bound to other values under the same query.

**A choice that cannot be recorded (review R2).** The archive refusing the choice's record answers
`choice_not_recorded`:
- nothing is delivered or recorded;
- the answer says the call ran no app action, so none is to be repeated;
- the memory is not suspended.

The memory being unusable, or an essential write failing, stays `memory_unavailable`, with D1's suspension.

## Persistence: schema 7

Schema 6 already allows several `selected` rows per need. It has no place for three things the experiment needs:
- a proposal that is not a delivery;
- the agent's declaration of coverage, kept apart from Engine's;
- a link that names which of several tracts of one need a call carried out.

`memory_recall_links` keys a link by need and step only, so the same step position in two versions of one need would
be confused. Using `delivery = 'not_delivered'`, an `alternative` role or the need's coverage for these would give
existing columns another meaning. Schema 7 (`brain-living-memory-schema-7.sql`, since 2026-10-13 part 7 of the one schema text,
[One schema text](MemorySchema.md#one-schema-text)) therefore only adds tables, immutable
as the other recall facts are:

| Table | Holds |
| --- | --- |
| `memory_recall_proposals` | One proposal: task, attempt, revision, producer, reason, remaining work, generation, channel, search status and note, parts considered, its size in bytes, format version, instant, duration |
| `memory_recall_proposal_needs` | The needs it was made for |
| `memory_recall_proposal_sources` | The versions it shortlisted per need, with their local id (`s1`…), relevance and the automatic suggestion |
| `memory_recall_choices` | A delivered query that answers a proposal (one per proposal) |
| `memory_recall_choice_needs` | Per need, the agent's declared coverage (`all`, `part`, `none`, `ambiguous`), what it says remains or asks, and the request's words it quoted to settle a choice (`settled_by`) |
| `memory_recall_choice_links` | Links of a choice's calls to the tract (selection position) and step they carried out |

The chosen tracts are rows of `memory_recall_queries`, `memory_recall_needs`, `memory_recall_selections` and
`memory_recall_requirements`, with `selector_version = 'recall-agent-choice-2'` (`-1` before the review's corrections).
Their meaning is unchanged. An ambiguous need's options are `alternative` rows of the need, whose coverage is
`ambiguous` with the reason `alternatives`, as the automatic selector records alternatives; a trigger checks that such
a need has no selected row and two alternatives at least.
`input_produced` states a producer the need's plan includes, in an earlier tract of the same need. Schema 6's check
of a requirement's step admitted only steps of the requirement's own tract, so schema 7 writes that trigger again with
this one case admitted (an earlier selected tract of the same version and need). The one schema text writes that
trigger once, as schema 7 did; an archive of version 1 gets it in its migration with every other part 7 object.

## Ownership, invalidation, cost, compatibility

- **Ownership.** Memory holds the values and rules (`RecallChoice`: the plan, its validation and the rendering of a
  proposal's steps). SQLiteMemory holds the rows and transactions. AutomationRuntime (`RecallService.propose`,
  `choose`) orchestrates search, validation, record and delivery. AutomationMCP decodes the tool.
- **Invalidation.** Everything is read again when the agent chooses: the versions, what is offered, the task's current
  revision and values. A proposal's own text is never trusted. A version superseded, or a step retired between the
  proposal and the choice, refuses the tracts concerned.
- **Cost.** The experiment adds one tool exchange before the first operation, plus the proposal's text. The proposal's
  size is recorded with it, and the comparison measures tokens and time. No budget is assumed: the earlier estimate of
  80–200 tokens per need is not a measure, and a shortlisted version is sent whole (all its steps, one line each)
  within the channel's limit.
- **Compatibility.** The automatic path, its records and its comparisons are unchanged.

## Measured (development, 2026-10-12)

A development measure, by a protocol fixed before any result (`.scratch/brain-memory-recall/experiment-a/protocol.md`
and its three amendments). The cases are development, and the author wrote some of them: this is not an independent
final.

**Setup.**
- Corpus v4 (`70b7e096…`): 27 versions and 119 queries, judged on the full archive, plus 27 cases on minimal archives.
- One index: hybrid, Granite 107m, weight 0.2.
- Control: the automatic selector 4 on the same search.
- Agent: the Claude CLI as Braus invokes it, tools off. `claude-sonnet-5-5` with effort `max` is the primary arm;
  `claude-haiku-5-5` is informative.
- The agent receives Braus's instructions, its begin call and the proposal, nothing of the expectations. `RecallJudge`
  judges; the model never does.

| | A, Sonnet | A, Haiku | Control |
| --- | --- | --- | --- |
| Positives exact, full archive | 83/89 | 83/89 | 60/89 |
| Italian or mixed positives exact, full archive | 29/32 | 30/32 | 15/32 |
| Positives exact, minimal archives | 19/21 | 18/21 | 16/21 |
| Negatives right, full / minimal | 15/26, 1/6 | 16/26, 2/6 | 22/26, 5/6 |
| Incompatible deliveries, full + minimal | 4 + 1 | 3 + 2 | 1 + 1 |
| False complete, critical | 0 | 1 | 0 |

**Reading.**
- A finds the right tract far more often, in English and in Italian. The automatic selector misses the same cases it
  missed in the third comparison: synonyms, another language, producer and consumer apart.
- A meets K3–K5 and fails K1 and K6 (Haiku also fails K2). By the protocol's rule A does not improve on the control:
  its positives are 25.8 points above, but its negatives fall well below and it delivers incompatible tracts. The
  control fails K1, K3, K4 and K6.
- **Cost.**
  - Per model call, Sonnet: input p50 7,597 tokens, output p50 635 (p95 3,719); 7.9 s p50, 33 s p95.
  - Haiku: input 8,365, output 356; 5.0 s p50, 6.8 s p95.
  - Engine adds 19 ms for the proposal and 14 ms for the choice (p50). The proposal is 4.5 KB p50, 7.6 KB at most.
  - A version the corpus accepts is in the shortlist for 109 of 110 positives.

**What the measure found.**
- **A defect, fixed after the measure.** A plan whose second tract consumes what the first produced was admitted but
  not recorded: schema 6's trigger refused the requirement naming a step outside its tract.
  - The four a-relay cases failed this way in both arms of the agent.
  - The fix is the trigger above; `RecallChoiceToolTests.producerInAnEarlierTract` proves it end to end on the corpus.
  - After it, the same four cases re-run with Sonnet are all right. That is a development check, not part of the
    measure.
- **A misleading answer.** The recording fault reached the agent as `memory_unavailable` ("did not record the task").
  A choice that cannot be recorded should be told apart. Not changed.
- **A certain conflict circumvented.** For "sort ascending" against a descending sort, the agent took the steps around
  the conflicting one, and Engine admitted them because it refuses steps, not versions. The same happened for a chart to
  PDF and a slide to JPEG.
  - Proposed: a version with a step in certain conflict with the need gives no tract to it, as the automatic selector
    excludes it.
  - The cost: a version loses its non-conflicting part too.
- **Near negatives filled with a generic step.** For delete, move and rename requests that nothing learned does, the
  agent delivered one generic step of a creating procedure as partial (Save, New Playlist, Rotate Right for a left
  rotation).
  - This is most of the gap on negatives.
  - Proposed: the experiment's instructions say that a step which only opens, selects or confirms inside a procedure of
    another action covers nothing, and the answer is no tract.
  - Engine cannot check it. The rule is written on development cases, so only a holdout can tell whether it holds.
- **Variants chosen without a word for them.** "Print the open PDF" and "Export … as relazione_x" were delivered
  complete with one variant where the corpus expects ambiguity. Structural coverage does not see an ambiguity between
  versions.
- **The model matters for safety.** Haiku delivered a whole album creation for "add the photo to the album"
  (recreating it), complete. Sonnet chose the two right steps. No Engine check covers a tract too wide within a
  compatible version.

**Status.** A stays an experiment behind `BRAUS_RECALL_AGENT_CHOICE=1`; the automatic selector is the default. The two
proposed corrections are not applied. Whether A is corrected, adopted or postponed is a decision for review, and an
independent holdout must follow any correction.
