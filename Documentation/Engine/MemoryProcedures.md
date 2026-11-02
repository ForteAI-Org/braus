# Memory procedures and the functional Brain

What the living memory learns from the facts of a task since G76 plan D2 (October 2026): the candidate
procedure the system segments from an attempt's calls, the agent's interpretation of it, the versions
built from it with their parts, parameters and contracts, the operational qualification A of every part,
and the functional Brain's states and relations, learned from verified operations. Status on 2026-10-11,
branch `tommaso/brain-memory-learning` on D1 `6320e9c`, uncommitted until reviewed, with the corrections
of the three independent reviews of the same day ([below](#corrections-after-the-independent-reviews)).

The facts this page reads (tasks, attempts, calls, effects, verifications, withheld values) are described
in [MemoryFacts](MemoryFacts.md); the tables of schemas 1 and 2 in [MemorySchema](MemorySchema.md). D3
(Recall) reads what this page builds and is not built here.

```text
calls of an attempt ──segmentation──▶ candidate ──agent's interpretation──▶ version (parts, parameters,
 (D1 facts)            app-blocks-2    steps, blocks    memory_task interpret     contracts, bindings,
     │                                                                          variant prefix)
     │                                                                              │
     │                                                                   qualification A per part
     │                                                                              │
     └──verification──▶ evaluation of a call ──▶ relation of a functional    catalogue (D3)
                         brain-relations-3         state ──▶ expectation,
                         (history, recovery)                 scene a model reads
```

## Schema 3 and its migration

Since 2026-10-13 schemas 3, 4 and 5 are parts 3, 4 and 5 of the one schema text, at version 7
([One schema text](MemorySchema.md#one-schema-text)). The three sections below record them as they were added.
Of their migrations only the one from version 1 remains: it fills the shapes of the structural scenes and the
anchors' label keys as described here. The migrations from versions 2, 3 and 4 were removed with those versions,
never released, and with them the data statements of schemas 4 and 5 and the second check of the prefixes schema 4
stated verified (`checkVerifiedPrefixesAgain`): an archive of version 1 holds no procedure and no prefix.

`brain-living-memory-schema-3.sql` follows schema 2 and only adds: 20 tables, 47 triggers, 11 indexes (86,
122 and 52 in all). Its sha256 is `ec26cef5ab5323ebbd898b3ff4bc46ad00a9105d4bba0de45846fd68654b9a88`;
the schema 1 and 2 resources are unchanged. No table is altered and no column takes another meaning: the
procedures reuse the Route tables of schema 1 (`memory_routes`, `memory_route_steps`, the operations and
their arguments, the parameters, `memory_step_occurrences`, `memory_step_events`) and add what they lack.

| Table | What it keeps |
| --- | --- |
| `memory_procedure_candidates`, `memory_candidate_steps` | A candidate: its attempt, segmentation version, structure digest, checkpoint, and each step's position, occurrence, call and block |
| `memory_procedure_interpretations`, `memory_interpretation_findings` | Each revision of the agent's interpretation of a candidate with its content digest and the attempt's state when it was given; each use the calls could not confirm |
| `memory_procedure_versions` | A version: the Route it is, its interpretation, candidate, task, attempt, contract version, the version it is a variant of and where it diverges |
| `memory_procedure_parts` | The parts: procedure, subprocedures (blocks), steps, with their parent, interval of steps, application, label and declared outcome |
| `memory_part_contract_items` | Per part: inputs, outputs, application, entry state (a structural scene, or stated unknown) |
| `memory_parameter_details`, `memory_operation_argument_segments` | A parameter's role, kind, unit, sensitivity and producing part; the segments of a templated argument |
| `memory_parameter_bindings` | The value a parameter had in one attempt with its source (episodic; a secret's is `withheld`) |
| `memory_procedure_step_occurrences` | The occurrence each definition step stands for |
| `memory_qualification_policies`, `memory_part_qualifications`, `…_reasons`, `…_evidence` | The policies (active or quarantined), each appended evaluation of a part with its reasons or its verifications |
| `memory_part_states` | A part's appended operational states (`usable`, `to_reevaluate`, `retired`) with reason and author |
| `brain_relations` | The relations, by identity |
| `brain_relation_proofs`, `brain_relation_applications` | What each call taught under `brain-relations-1`, the first policy: kept as written, read for diagnosis, written no more since schema 4 |
| `brain_scene_shapes` | Each structural scene's role key, for a targeted lookup of a capture's state |

The triggers keep the rows coherent where a writer could be wrong: a candidate step must be a started
operation of the candidate's attempt with that occurrence's call, in order and in blocks of one
application; a part is contained, by kind, in its parent's interval; a templated argument has segments and
no plain value; a secret binding has no text; reasons exist only on a refusal and evidence names the
step's own call; states are appended and `retired` is final; a relation's identity never changes and never
names the application scope; a proof names its relation's own application. Indexes serve the reads named
below; `brain_relations_identity` is unique over the whole key.

- The migration fills `brain_scene_shapes` for every structural scene already stored, so states observed
  before D2 are found by the new lookup. It derives no relation itself: the relations of the calls an
  archive already holds are evaluated by the recovery (below). No Route of schema 1 becomes a version.
- The Routes of earlier builds stay as they were: a Route with no `memory_procedure_versions` row is
  legacy, counted apart and never offered by the catalogue.
- D1's unification transfers only archives of builds before G76: an origin holding tasks, candidates,
  relations, evaluations or variant prefixes is refused whole and left where it is
  (`SQLiteArchiveTransfer.untransferred`), since a build that wrote them already shared the one archive.
  Candidates and relations are derived, so an index or a rebuild in the destination comes from its own
  facts.

## Schema 4 and its migration

`brain-living-memory-schema-4.sql` follows schema 3 and only adds: 4 tables, 10 triggers and 8 indexes (90,
132 and 60 in all). Its sha256 is `82e98112f406466ad8f47a2701ec3a1bda2fb86f6d8b445dd49efed2be20a29b`;
the resources of schemas 1, 2 and 3 are unchanged. It was added after the independent review of D2 rather
than by editing schema 3, because archives of schema 3 had already been written by the first delivery.

| Table | What it keeps |
| --- | --- |
| `brain_relation_evaluations` | Every evaluation of a call, appended in sequence: the policy, its cause (`acquisition`, `recovery`, `evidence`, `policy`), the outcome (`supported`, `contradicted`, `excluded` with its reason), whether the exclusion is recoverable, and for a failure that found nothing to contradict the group and outcome it waits for |
| `brain_relation_evidence` | The relations one evaluation supports or contradicts, with the call's own verification; a relation's counts are the evidence of each call's latest evaluation only |
| `brain_anchor_label_keys` | Each active anchor's normalized label and aliases, derived and rewritten with the anchor, so a scene's labels find their anchors by an index |
| `memory_variant_prefixes` | For a variant, whether its declared common prefix was verified on the operations or kept as suggested, the steps compared and why it is only suggested |

Triggers: an evaluation follows the call's last one by one, names the call's application, is immutable
and kept; evidence names the verification of its own call, of the relation's application, and belongs to
an evaluation with the same outcome; it is immutable and kept; a label key names its anchor's application;
a prefix exists only for a variant, compares at most the steps before the divergence, and is immutable and
kept. Indexes serve the recovery (recoverable exclusions, a group's waiting failures, evaluations by
policy, evidence by call) and the part of the projection a scene reads (label keys, the anchors a model
named, the unlabeled anchors, a group's members by anchor).

- A new archive runs the four texts at once. A producer's open of an archive at exactly schema 3, 2 or 1
  takes the verified copy D1 introduced, then runs the texts it lacks in one transaction
  (`SQLiteMemorySchema.migrations`); readers refuse it until then (`migrationRequired`). A failure rolls back
  to the version the file had, and the copy stays.
- The one data statement of the text states every variant built before schema 4 as `suggested`
  (`declared_before_verification`): its prefix was declared and never checked. The store fills the label
  keys of every active anchor in the same transaction (`SQLiteBrainRows.fillLabelKeys`), since the text
  cannot normalize labels as the matcher does. Nothing else is derived and no row of an earlier schema is
  changed or deleted.
- Schema 3's register (`brain_relation_applications`, `brain_relation_proofs`) stays as written: the history
  of `brain-relations-1`. The recovery evaluates every call it names again under the current policy, with
  the cause `policy`, and the diagnosis still shows the first policy's word for a call evaluated by
  nothing since. The relations the first policy keyed otherwise stay in `brain_relations`, with their
  proofs, and count nothing in the current reads (no current evidence).

`verify-memory-schema.py` runs schema 2's, schema 3's and schema 4's texts on its populated file and checks
them (390 checks, 324 negative, on 2026-10-11): schema 4 runs on the populated schema 3 file, keeps its
register, states an existing variant's prefix suggested, and refuses an evaluation out of order or of
another application, an update or a delete of an evaluation, evidence or a prefix, evidence of an
evaluation that excluded or decided otherwise, evidence by another call's verification, a label key of
another application, a prefix with a reason when verified, past the divergence, or of a version that
varies none.

## Schema 5 and its migration

`brain-living-memory-schema-5.sql` follows schema 4 and only adds: 1 table and 3 triggers (91, 135 and 60
in all). It was added after the second independent review, because a prefix whose parameters do not
correspond needed a reason schema 4's `memory_variant_prefixes` does not accept, and schema 4 had been
delivered. Its table, `memory_variant_prefix_checks`, has the same columns and rules (a prefix only for a
variant, at most the steps before the divergence, immutable and kept) and one more reason,
`parameter_correspondence`. Every check is written there from now on; `memory_variant_prefixes` stays as
written, the record of the first check, and is written no more.

- An archive at exactly schema 4, 3, 2 or 1 is migrated by a producer's open after the verified copy, in one
  transaction, as before. The text copies schema 4's `suggested` prefixes as they are: a check that could
  not prove a prefix proves no more now.
- A prefix schema 4 stated `verified` was checked without its parameters' correspondence. In the same
  transaction the store checks it again from the two versions' stored definitions and parameter details
  (`SQLiteProcedureRows.checkVerifiedPrefixesAgain`), which the text cannot compare, and writes the result
  in the new table: `verified` again, or `suggested` with its reason; a version that cannot be read again
  is kept `suggested` (`unreadable_step`), never dropped. Schema 4's row is not touched.
- No archive outside temporary test directories was written by the schema 4 build: it was never committed
  or run live.

`verify-memory-schema.py` runs schema 5's text after schema 4's on its populated file (401 checks, 332
negative, on 2026-10-11): it copies the suggested prefix, leaves the verified one to the store, keeps schema
4's rows, and refuses a second check of a variant, an update or a delete, a check of a version that varies
none, a verified prefix with a reason, a suggested one without, a reason no check gives, and a prefix past
the divergence.

## Segmentation: the candidate

**Problem.** A procedure must be cut from what happened, not from what the agent says happened; the agent
cannot be trusted to list its own steps, and a split by time or focus breaks on a passing change of window.

The candidate's id is `candidate-<attempt>-<digest>`, the FNV-1a 64 digest of the segmentation version
and the ordered calls: built again over the same calls it is the same candidate (`alreadyApplied`), and its
occurrences are brought up to date with calls that concluded since. A later checkpoint with more calls is
a new candidate; only the latest of an attempt can be interpreted (`stale_candidate`).

**Alternatives.** Steps by agent statement (refused: the agent's account is no fact); blocks by window or
by time gap (refused: a focus change or a pause would cut a method in two); a batch as one step (refused:
a partial batch would be one opaque step).

**Limit.** A step is an operation, not an intention: two clicks the agent thinks of as one action are two
steps, and the interpretation can only label them.

## The interpretation

**Problem.** Labels, parameters and outcomes are meaning the system cannot infer, and a replace of every
equal text would turn a file named Export and the Export command into one parameter (scenario S23).

**Choice.** The agent states them in its ordinary turn with `memory_task interpret`, from the candidate a
checkpoint or an end answered (`memory_task candidate` gives it again). Contract version 1
(`ProcedureInterpretationContract`):

| Field | Meaning |
| --- | --- |
| `candidate` | The candidate it is about; it must be the latest of the attempt and one of the producer's tasks |
| `revision` | The revision it means, or none for the next |
| `procedure`, `parts` (`b1`…), `steps` (1…) | A label (at most 512 bytes, refused rather than cut) and a declared outcome (`completed`, `failed`, `not_completed`) per part |
| `parameters` | Name, role, kind, direction, unit, secret, and the value in this attempt with its source; no value takes the task input of the same name with its source |
| `uses` | Step, argument and position, and a template over the argument's recorded text: `{name}` is a parameter, `{{` and `}}` literal braces |
| `phases` | Since 14 October 2026: the task's own stages, each a run of consecutive steps (`from`, `to`) with a label and an outcome; they become the subprocedures ([The method, phases, result and repeated runs](#the-method-phases-result-and-repeated-runs)) |
| `variant_of`, `divergence_step` | The version this one varies and the first step that differs, both or neither; the system checks the version exists, the step is within it, and the steps before it are the same operations ([Variant prefixes](#variant-prefixes)); a variant supersedes nothing |

The system checks every reference against the candidate and its calls and refuses what does not exist
with nothing written (`unknown_reference`); it renders every use with the bound values and compares it
with the argument as recorded. A use the call contradicts is kept as a finding (`use_mismatch`), a use
whose value is unknown as `unverifiable_use`; the argument stays as recorded. Only stated uses become
parameters: no other text is replaced because it is equal. Every text is minimized as D1's task texts
are, with the declared secrets of the task and of the interpretation; a secret parameter's binding is
`withheld`, and a step that keeps a withheld literal no secret parameter took is refused
(`withheld_literal`).

**Idempotency.** An interpretation is recognized by its digest, `<bytes>-<FNV-1a 64>` of its canonical
form (`ProcedureInterpretation.digest`): the same digest again is the stored interpretation
(`alreadyApplied`); another digest under a stored revision is `interpretation_conflict`; a revision that
skips one is `revision_out_of_order`. Only the digest is compared, not the statements themselves: two
different interpretations of the same length with the same 64-bit digest would be taken as one. No such
collision was produced or observed; it is a limit of the comparison, stated here because an earlier
version of this page said the statements were compared too.

**Alternatives.** A second model or a person compiling the procedure (refused: cost and a second
account of the same turn); inferred parameters by equal texts (refused by S23).

**Limit.** The system does not decide whether the agent understood the intent: a coherent label of the
wrong goal is admitted. Templates match whole argument texts; a parameter inside a list argument is
stated per position.

## Versions and parts

Each interpretation revision builds a version (`ProcedureAssembly`, pure: the same inputs give the same
rows) over the Route tables: one definition step per candidate step of the method (every step when the
procedure is not taken to be completed, [below](#the-method-phases-result-and-repeated-runs)), one
operation each, whose arguments are the call's as recorded, or a parameter, or a template where a use was
confirmed. The parts are the procedure; the phases the agent named, else one subprocedure per block when
there are several (a procedure of one block is that block); and one part per step. Each part's contract lists the parameters its steps read (propagated to the parts
that contain them), the outputs it or a contained part produces, its application, and the structural
state its first step started from (the scene the call's `before` sample was confirmed in, or stated
unknown). A new version of an attempt supersedes the previous one (`memory_routes.supersedes_route_id`);
the superseded one stays readable and leaves the catalogue.

**An entry state known later.** A contract is kept as it was built. When the first step's `before`
sample was placed in a state only after the version was built (its derived write came late, or the
recovery placed it), the version read says the state known since beside the contract
(`StoredProcedureVersion.lateEntryStates`, computed at read from the sample's association), and the
diagnosis prints `state unknown when built; known since: state …`. Nothing rewrites the contract; a new
interpretation builds a version whose contract has it.

**Prerequisites a contract does not state.** Application, functional state and parameters are what a
contract can say. The document open, the focus, a selection, the application's version or locale are
unknown unless a check recorded them; a part admitted alone is a step whose other prerequisites are
unknown, not one known to have none. D3 must treat them as unknown.

### Variant prefixes

**Problem.** A variant declared that its steps before the divergence were those of the version it varies,
and the system only checked that the version and the step existed: a double click could be declared the
same step as a click (review F04).

**Choice.** `VariantPrefix.check` compares every step before the divergence on the generalized
definitions, never on labels or positions alone: the same application, the same tool and, argument by
argument, the same literal, the same anchor or menu path, or a parameter of the same type in the same
place (a template of the same shape). New values of a parameter leave a prefix the same. The first step
that differs refuses the interpretation with nothing written (`contradicted_prefix`, with the step and
why). A step that cannot be decided (a value withheld on either side, a literal against a parameter, a
step that cannot be read) leaves the prefix `suggested` with its reason; otherwise it is `verified`.
`memory_variant_prefix_checks` keeps the result; `braus memory --task` prints it on the version line
(`prefix verified over 3 steps`, `prefix suggested over 3 steps (unreadable_step)`). A variant's own
qualification never rests on its origin's, whatever its prefix.

**Parameters correspond one to one (review F04b).** Comparing each argument alone took a parameter of the
same type for the same parameter: an origin typing `<file>` in two fields was declared the same as a
variant typing `<input>` in one and `<output>` in the other, though the first binds the two fields to one
value and the second lets them differ. The check now keeps, across the whole prefix and in arguments and
templates alike, one correspondence between the variant's parameters and the origin's: a parameter matched
to another is matched to it everywhere, so a renamed parameter stays the same parameter, and one parameter
against two (split), two against one (merged), or a match that crosses leaves the prefix `suggested`
(`parameter_correspondence`). The matched parameters must also have the same contract: type (another type is
another operation, refused), direction, whether required, and the kind, unit and sensitivity of their
details when both versions state them. Names and the free description of a role are never compared: they
are the agent's words, and comparing them would merge or split methods by wording.

**Alternatives.** Comparing the version ids of the steps (refused: two versions never share ids);
comparing labels (refused: a label is a statement); merging the two versions' common steps (refused: a
variant references its origin, it does not rewrite it).

**Limit.** A prefix with a parameter on one side and the same literal on the other stays suggested even
when the literal is the parameter's value in that attempt: values are episodic, not definitions. The
correspondence covers the prefix only: a parameter the origin shares between a prefix step and a later one
is not compared past the divergence, where the steps differ anyway.

## Qualification A

**Problem.** A label and a declared completion are statements; reuse needs proof that each operation did
what was asked, within what the method could see.

**Choice.** `QualificationPolicy` (`qualification-a-1`) admits a part when it is labelled, taken to be
completed, its trace complete, its interpretation coherent with its calls, and every operation of it
positively verified; it refuses it with every reason found otherwise. Positive conditions: the requested
state already present (with no gesture), the state after the gesture, the value read back, a structural
effect attributed to the gesture, a submenu opened, the window set changed, the contextual item chosen. A
pop-up that closed after a choice, a recovery gesture instead of the request, a path with no oracle, a
substitute or uncertain delivery verify nothing. Reasons: `missing_label`, `completion_not_declared`,
`declared_failed`, `declared_late`, `call_incomplete`, `call_failed`, `call_cancelled`, `call_interrupted`,
`recording_gap`, `no_verification`, `verification_failed`, `verification_unknown`,
`verification_not_positive`, `use_mismatch`, `unverifiable_use`, `missing_input`, `withheld_literal`.

A part's outcome is the one the agent stated; else, for the procedure, the attempt's declared end
(`abandoned` is not completed), and for another part, completed when its parent is. So the procedure of a
version interpreted at a checkpoint is refused (`completion_not_declared`) until the end, then admitted
by the evaluation every later checkpoint, end or `candidate` request runs again. An interpretation given
after an attempt was interrupted may label and never complete (`declared_late`). Under A nothing was
pruned: a failed or retried step kept its parent out, and a step could still be admitted alone, with its
entry state as its prerequisite. Since 14 October 2026 a completed procedure's version holds the method
only, so its retries are no part of it. Evaluations are appended only when a decision changes, with the policy's version.

A says the method's checks passed; it does not say the user's goal was reached: closing an Export dialog
is not a file on disk. A child's completion derived from its parent's declaration is the agent's statement
carried down, not a verification of the child's result; each child's operations are still verified on
their own.

**Operational state.** `memory_part_states` appends `usable`, `to_reevaluate` (out of the catalogue
until declared usable again) or `retired` (out for good), with reason and author. A policy can be put in
quarantine: what it admitted stops being offered, and nothing it decided is deleted.

**The catalogue** (`SQLiteProcedureRepository.catalogue(after:limit:)`, paged by part id) offers the parts
of current versions whose latest evaluation, under a policy still active, admits them and whose latest
state, and that of every part they contain, is usable: a step taken out of use takes its block and its
procedure with it, so it never comes back through its parent. It reads the authoritative tables; an index
built from it is derived and can be rebuilt.

**Alternatives.** Admission from the agent's declaration (refused: a declaration is no verification);
pruning failed steps from an admitted parent (refused under A: a method with a retry is not the method without
it; taken on 14 October 2026 for a completed procedure, whose mistakes stay as evidence in its candidate);
a numeric score (refused: the reasons are what a reader acts on).

**Limit.** Evidence is the check of each path within its limits (`windowWide`, `noExpectation`…); a
check that passed on the wrong window region passes here too.

## The functional Brain

**Problem.** The projection's transitions predicted effects per anchor across a whole application, learned
from effects no check verified, and loaded the application's whole Brain to answer one click.

**States.** A functional state is a structural scene of structure-v4 (`SceneStructureMatcher`): the same
surfaces, paths, roles, captions and collections; documents, values, titles, positions and captions that name
a file are no part of it ([Structure-v4](MemorySchema.md#scenes-and-structure-v4)). A capture is placed in a state only when it is complete and exactly one stored scene is the same and
none is uncertain. `brain_scene_shapes` keeps each scene's role key (`SceneSkeleton.roleKey`, its roles
sorted and joined), so a capture is compared with the scenes of its own roles only.

**Elements: a template and its instance.** `SceneElementKey.key` is a template:
`control|<path>|<role>|<name>` outside a collection, `item_template|<collection>|<role>|<caption>` inside
one, nothing for content. A control's name is its label when the label came from a title, a description
or the developer's accessibility identifier, never a value, a row's content or a position, so a field keeps
its key whatever it holds and wherever the window is. A template identifies an instance only where nothing
else in the capture shares it (`SceneElementKey.identities(in:)`): two unnamed fields of one container are
`indistinct`, and nothing learned on one is attributed to the other or to both. A row's template is its own
identity on purpose: a click on any file's row is a click on the list's rows. A call's target is resolved
among the physical elements of its `before` capture, counted before any key is deduplicated
(`SceneElementKey.target(role:label:in:)`): none, several (`ambiguous`), or one with its identity.

**Relations.** `BrainRelationPolicy` (`brain-relations-3`) turns one concluded operation into at most one
relation, keyed by application, context, the state before, the identified element (nil for an operation
on the focus or the window), the precise verb with its fixed arguments, the state after, the outcome and
the effect's family. Per family, every argument of the request has a role (`argumentRoles`): fixed, in the
key, because it decides the effect; a parameter, out of the key, because a new value repeats the method;
or the element:

| Verb | Fixed (in the key) | Parameter (out of the key) | Element |
| --- | --- | --- | --- |
| `click`, `double_click`, `triple_click`, `right_click` | none; each verb its own relation | none | `target` |
| `set_toggle` | `value=on\|off` | none | `target` |
| `select` | `item=<normalized item>` | none | `control` |
| `type_text` | `replace=true\|false` | `text` | `target` |
| `insert_text` | none | `text`, `expected_value` | the focus |
| `press_key` | `key`, `modifiers`, `count` | none | the focus |
| `scroll` | `direction`, `over=window\|target` | `lines` | `target`, or the window |
| `drag` | `to=<destination's identity>`, or `to=offset;dx=<sign>;dy=<sign>` | the distance | `from` |
| `context_menu` | `item=<normalized item>` | none | `target` |
| `menu` | `path=<normalized titles>` | none | the window |
| `press` | `button=<normalized title>` | none | the window |

Version 3 (14 October 2026) gives one family to what a command chosen in the menu bar or a dialog's button
pressed leaves on screen: `elementsAppeared`, never `menuOpened`, whatever pop-ups the dialog holds (a submenu keeps
its own condition). On PhotoCraft, Image Size, Black and White and Close had each been learned under both families,
which split one command's relation in two.

The summary a model reads says the parameters a relation does not hold (`type_text [replace=true] (any
text)`). An item chosen is fixed because two choices of one pop-up lead to different effects; a typed text
or a file's name is a parameter because a new value repeats the method. Withheld values are never part of a
key: a call with any withheld argument other than a parameter of its family (an item, a menu path, a button's
title) teaches nothing (`value_withheld`), since a placeholder in its key would merge it with any other withheld
choice; so does a call whose target or check holds a withheld value, which includes a typed secret read back.

Outcomes: `effect` (with its family; since the merge into `rename-app` a value change is one of them,
`valueChanged`, named by its family alone, never by the field or the text), `state_set`, `already_satisfied`
(from the state to itself),
`value_set`, `item_chosen`, `window_set_changed`. A passed positive check supports the relation; a failed
one contradicts the relations of its group with the outcome it expected (of any family when it expected
none). Exclusions: `not_an_operation`, `not_concluded`, `call_failed`, `recording_gap`, `no_verification`,
`verdict_unknown`, `no_oracle`, `substitute_gesture`, `delivery_uncertain`, `value_withheld`,
`no_before_state` (no sample before acting, or one that can never be placed: incomplete or uncertain),
`awaiting_state` (a complete sample not placed yet), `no_structural_element`, `ambiguous_element`,
`indistinct_element`, `nothing_to_contradict`, `not_learnable`, `no_application`.

**Evaluations, recovery and counting once.** Every evaluation of a call is appended to
`brain_relation_evaluations` with its cause; a later one never erases an earlier one. Three exclusions are
recoverable because the evidence they lack may still arrive: `awaiting_state`, `not_concluded`, and
`nothing_to_contradict` (a failure that came before the relation it contradicts). A call is evaluated
again when that evidence arrives, when it was never evaluated (a process stopped before its derived write,
a queue that lost it, an archive migrated from an earlier schema) and when it was evaluated under another
policy. A relation's supports and contradictions are the evidence of each call's latest evaluation, so a
call counts once however often it is evaluated; an evaluation that decides what the latest one decided adds
nothing. `MemoryService` runs this recovery on its own (`SQLiteBrainRelationRepository.catchUp`): asked for
at every open and whenever a call waits for its state, it runs in the derived queue's drainer only while
the queue is empty, one pass of at most 25 calls of each kind, with the queue looked at again between
passes, so new acquisitions go first and an open, an action or a close never waits for it. It reads facts
and writes evaluations: no action is repeated. Its counts are in `MemoryService.Status.relationRecovery`;
`braus memory --apply-relations` runs it to its end at once.

**Thresholds.** A relation is offered (`exposed`) at one proof for a menu that opened and two for anything
else, and only as a possibility (`limited`) once contradicted; below its threshold it is kept
(`candidate`). The engine expects an effect (`BrainMemory.expectedEffect(of:on:in:)`, by family) only from
the one exposed, uncontradicted relation of the identified element and verb in the window's current state;
several outcomes, a contradiction, a toggle, an unrecognized state, an element that is ambiguous or
indistinct give no opinion.

**What a model reads.** The scene a tool answers is enriched (`BrainMemory.enrich(_:window:)`) with three
things, none of which changes its elements' identities, its states or its token: the elements named from
the part of the projection they can match (recalled labels, sibling groups); on each identified element of
the current state, its offered relations, alternatives side by side; and a `memory:` line under the scene's
header, followed by one `  window:` line per offered operation on the window itself (a key or a shortcut,
an insertion on the focus, a scroll of the window, a menu command, a dialog's button by title), with what
it needs that the memory does not know (`acts on the focused element, which was not recorded`). The
`memory:` line says whether what was learned applies (`applied`, `nothing` learned yet, the state
`unrecognized`, or `unavailable right now`), and the scene's changes say it again when it changed. When
any read the enrichment needs fails, the part of the projection, the state or the relations, the scene is
the live one with nothing of the memory on it, no recalled label, group, relation on an element or line of
the window, and says `memory: unavailable right now; the scene is live, what was learned is not shown`:
what it shows and what it says agree (review F05b; before, a projection that failed left the relations on
the elements and dropped the window's). No error, path or value reaches the model; the detail stays in the
process, in `BrainMemory.diagnostics()` (the failed reads and the last failure), which no screen or command
shows yet. Every read says only what it found: nothing an earlier enrichment said an element does is kept.
The engine's expectation reads no projection, so a projection that fails leaves it answering from the
relations.

**The part of the projection a scene reads.** Naming a scene's elements no longer reads the application's
whole projection (`BrainReading.projection(of:for:)`, `SQLiteBrainRows.slice`): it reads by index the
anchors one of the scene's labels names (by label or alias), the anchors a model named of the scene's kinds,
for the ordinal rescue the unlabeled members of groups near a labeled detection and every member of the
groups of an unlabeled detection's kind near it, and the groups all of those belong to, by membership. The
matcher finds in that part what it finds in the whole projection for those detections; transitions, states
and the clock are left out, since naming reads none of them. It is not cached. The whole projection is
still read, cached, by `braus memory <app>` and by the Brain's own updates.

**Learning point.** `CallRecorder` queues the relation of every operation after its end is saved, behind
the scene associations it reads, and asks for the recovery when the call waits for its state. `menu` and
`press` record their own perceptions of the window before and after the command (`PerceivedCommand`) as
the call's samples, in the app's session and in the Seat's, keeping the window check they report; a
command refused before any gesture records no sample. A command asks for the window after it only once its
gesture was dispatched; when it throws after that (review F07b), the samples already perceived stay the
call's, the window before it and, if perceived, the one after it, and the error ends the call. A dialog's
button whose window cannot be perceived after its press concludes as a menu command already did: made, its
effect unknown (`window_set_changed` unknown, `no_after_scene`), no scene, no error text, not pressed again;
a cancellation arriving then is thrown, the call ends cancelled with its window before it. Nothing is made
up: no window after it, no success, no absence of effect. A cancellation before the command, already there
or arriving while the window before it is perceived, whatever that perception answers, is thrown before the
command starts (review F07c): no gesture, no sample, the call ends cancelled. A perception before the
command that fails for another reason only leaves its sample out, and the command goes on. The projection (anchors, groups, recalled labels)
still learns, only from a structural effect its check verified as the requested gesture's.

**Alternatives.** Keeping the projection's transitions as expectations (refused: unverified and
application-wide); a similarity threshold to place captures (refused: an uncertain capture is no state; structure-v4 takes a
complete capture's captions as proof instead); one relation per value (refused: the method, not the episode); a value or a position as part
of an element's identity (refused: a field would change identity with what it holds); attributing a
relation learned on an indistinct template to every instance (refused: a false attribution); a cache of the
whole projection on the ordinary path (refused: any write empties it, and its first read is still the
whole application).

**Limit.** Two states that differ only by a caption stay uncertain and teach nothing (measured below: with
captions alone, 376 of 400 operations taught nothing). Controls of one role and one container with no name
are indistinct and teach nothing. Contexts (version, locale) are mostly unknown.

## The method, phases, result and repeated runs

Decided on 14 October 2026 by the product owner, after the PhotoCraft runs of that day: nine completed tasks
made nine procedures, none admitted whole, six of them two operations repeated three times each; a third of
their steps were mistakes and retries; recall proposed the raw traces and the agent never chose one. Four
choices change what a completed task teaches. None changes the schema: they use the tables of schema 3 as
they are.

**The method, not the trace** (`ProcedureAssembly.leftOut`). A version of a procedure taken to be completed
(its stated outcome, else the attempt's end) keeps only the candidate's steps that did their part: a call
that did not conclude (`not_concluded`), a gesture that never went out, a refusal or a miss
(`nothing_sent`), a check that failed (`check_failed`) and a step the agent declared failed or not completed
(`declared_failed`) are left out. They stay in the candidate and its calls as evidence; the interpretation's
answer lists them (`left_out`). The definition is numbered again from 0; `ProcedureVersion.candidatePositions`
keeps each step's candidate position, which the findings and the agent's statements use. A procedure not taken
to be completed keeps every step, as before. A state already present (a toggle already on) sent no gesture
and verified the state, so it stays.

**Phases** (`PartReference.phase`). The agent names the task's stages in `phases`, each a run of consecutive
steps with a label (open the file, apply the change, save the copy). They become the subprocedures, each
covering the method's steps inside it; without phases the blocks are, as before. Before, a task in one
application had no part between the procedure and its steps, so no stage of it could be reused alone.

**The result Braus reads itself** (`TaskResultCheck`). A task names what its result is in `result_check`, one check
or a list, at its end, at a checkpoint (a stage's own result, read before what shows it goes away) or in the
interpretation that follows an end that named none. Braus reads the disk or the screen itself, so the verdict is
never the agent's word. The kinds, as the evening's revision of 14 October 2026 has them:

| Kind | Passed when | Stored with method |
| --- | --- | --- |
| `file_written` (or `file` alone) | the file exists and was written once the attempt had opened (two seconds of tolerance between the clocks) | `file_check` |
| `file_changed` | written during the attempt with another content than when the task declared it (SHA-256 read at `begin` or `update`); by time alone, and said, when it was not read | `file_check` |
| `file_unchanged` | the same content as at the start (by time when it was not read) | `file_check` |
| `file_absent` | no file at the path; unknown when there was none at the start either | `file_check` |
| `file_moved {to}` | nothing left at the path and, at `to`, the content the path had at the start (a rename keeps the time) | `file_check` |
| `file_copied {to}` | at `to` the content the path still has | `file_check` |
| `file {contains}` | a text file written during the attempt holding the text | `file_check` |
| `window {app, open}` | a window of the application whose title contains the text is open (or none is) | `window_census` |
| `element {value / state / present}` | the session's scene, read at the check, matches the normalized label in visible elements or read-only fields past the window's edge; checks the value, the state, or presence (or absence) | `control_value`, `control_state`, `scene_text` |
| `none` | never: the task says it leaves nothing to read, and why; it proves nothing and takes nothing from the other checks | `none` |

An `element` check can read `outOfViewFields` without making them action targets. A match there
says the element is past the window's edge. Values use the same trimmed, normalized comparison
as visible elements. Native text fields carry availability, not an on/off control state; a state
check with no readable state stays `unknown`, even when the field is present.

At a completed end Braus completes what the task named with what it reads on disk itself (`AutomationTools.completed`;
in test runs of 14 October 2026 agents checked «Salvato: <path>» on screen, or gave `none`, for files Braus
could read, and one `none` hid a file saved without its text):
- a file a screen check names by an absolute path is read too: `file_changed` when it was a file input read at the start,
  `file_written` otherwise;
- every file the outputs declare by an absolute path is checked written;
- guards, recorded with method `guard` and shown in the answer, never read by a part's qualification: every file input
  read at the start that no check or output names stays `file_unchanged` when the task writes a file (an export that also
  rewrote its original); and a folder listed at the start (a folder input, or the one a file input lies in) that the task
  wrote in holds no new file but those named (`no_other_files`: `ordine_57.txt.rtf` beside `ordine_57.txt`). Blocking, the
  folder's guard kept a right procedure out for a temporary file TextEdit's save left behind (test runs, 14 October
  2026); a new condition is informative before it decides anything.
An end with no check at all is recorded and its answer asks for one in the interpretation (`result_check: {status:
missing}`). Every check is a verification of scope `task` in `memory_verifications`, its expectation kept as JSON in
`expected_text` (the first version's plain path reads as `file_written`), a `verification` member of the attempt in
`memory_task_events` at its position among the calls; the attempt's current version is qualified again when one is
written. A path or a text is read as the agent gave it, in memory only, and kept minimized as every text of the task
is. What was found is kept in words, never the content read.

**Qualification B** (`qualification-b-1`). A's rule stands for steps. A procedure or a subprocedure of a
completed attempt whose result passed is not kept out by a step that is only unproven: its own check unknown or
missing or its delivery uncertain, never failed, never another gesture than the one asked, the call concluded with
no recording gap (PhotoCraft answers a double click on a save panel's folder with an error and opens the folder). A
step of an offered procedure or subprocedure is offered with it (`SQLiteRecallRows`): a method admitted on its result
is chosen and reused whole. A
result that failed keeps it out (`verification_failed`, with no step) whatever its steps say. Which result a part
reads: the procedure, every check of the attempt but Braus's guards; a subprocedure, the first checks recorded after its last step (those
with no step of the method between them), so a stage checked at a checkpoint stands on its own check and a failed end
does not keep it out; a subprocedure no check follows reads none, and A's rule. Several checks pass together only when
each that could read something passed (`TaskResultCheck.combined`). On PhotoCraft 44% of the checks were unknown, a
menu opening a remote panel or a field that cannot be read back, though every output was right on disk.

**A repeated method is a new run** (`ProcedureMethod`). The first version of a completed attempt that has the
same method as the current version of another attempt ended completed replaces it in the catalogue: its route
supersedes that one (`memory_routes.supersedes_route_id`), and the interpretation's answer names it
(`repeats`). Two steps are one method when they have the same application and tool, the same fixed choices (a
menu path, a key, an item, a button, a toggle's value, replace or append), a parameter wherever the other has
one, any typed text, and the same element, read by its role alone when its label names a file (a row of a file
list) or when it is a pop-up a selection is made in. A section is a search hint and never compared. Under B, a
step of the repeating version whose own check is only unproven is verified by the evidence its counterpart was
admitted on, which names the earlier run's call. A declared variant (`variant_of`) keeps its own lineage and is
never taken for a repeat. Before, every run made a procedure of its own and the evidence of one run helped no
other. Since the test runs of that evening, which left five of fifteen repeats apart for no difference of method,
three more things are the same method: an element the interpretation made a parameter and the same content item named
literally (a file's row); `press` on a dialog's button and a click on it; the fields of one form set in another order
(consecutive steps that type, insert, select or set a switch). A fixed argument made a parameter covers any value at
it. Replayed on that archive, 14 of the 15 pairs are one method (the fifteenth took another path), and none of the 420
pairs of runs of different tasks is.

**What a step keeps of its run.** An element the agent clicked by its id mark (`control|foto1png`) and stated as the
task's file is kept by its name, the parameter whole (`{input_name}`), since `control|foto_3.png` would mark nothing at
a reuse. A section that names a day, an hour or a file (`list view / Today at 15:52`, `content (foto_1.png …)`) is left
out of the definition and of what a reuse receives (`ProcedureAssembly.isStableSection`): another run would not find it.

**The result a procedure carries** (`RecallSource.results`). A source's result checks reach a proposal as templates
over its parameters (`file_written {output_folder}/{output_name}.jpg`: a value that is a whole leading path, a whole
component or a component's name before its extension is written as its parameter, and inside any text a value that is
a path or a file's name, `Salvato: {folder}/{file_name}`), with the kind of result the source makes and when it was
made: at the end, or after a step, at a checkpoint before what shows it goes away. A choice whose tract carries out that
step delivers them bound to the new task's values (`resultCheck`). Braus's own guards and `none` are not delivered. The
evidence a proposal names says whether the source's result was checked.

**Reuse that is counted.** Each need of a proposal carries `readyPlan`, the plan item that chooses the suggestion (the
need covered `all` only when the suggestion covers it whole, else `part`), else the runs of its first source's steps a
choice admits (`RecallChoice.admissibleRuns`: offered, in the need's application,
not excluded), covering the need in part and naming in `uncovered` the steps left to the agent, so that following a
source is one call and is recorded; a source with none gives no plan. Until 14 October 2026 the plan was the whole
source, and Braus refused the plan it had written when a step of it was not offered (review R3). A run that repeats a source a proposal
offered to its attempt, with no choice made, is said in the interpretation's answer (`reuse`) and counted as followed
without a choice (`InterpretationOutcome.followedUnchosen`), derivable from the proposal's sources and the version's
`supersedes_route_id`.

**Phases procedures share** (`ProcedureFamilies`). Parts of different versions that hold one method form a family: the
subprocedures that open a file, save a copy or close a window in twenty procedures are one family, with the labels
their members were given and the one most share. A candidate's answer names the runs of its steps that hold the method
of an admitted phase of another task (`known_phases`, with that label), among the steps the method would keep: a retried
miss does not hide a phase, and the instructions ask the agent to make each
a phase with that label. `braus memory --consolidation` measures, read only, what a consolidation would share and the
goal families (tasks that chose a source and reached its goal another way); on an archive of 15 PhotoCraft test tasks, 81
subprocedures form 20 families and 220 steps 24. Sharing them as one procedure called by the others (`route_call`,
which the schema has) and summing their evidence is the next step, not taken here.

**What the audit of 14 October 2026 added** (flexibility of learning and recall, failures of unattended runs).
Mechanisms only: no sentence was added to the agent's instructions and no condition made stricter.
- *Uses Braus infers* (`InferredUses`). A value the agent typed, chose in a pop-up or set that is exactly one of the
  task's inputs (or that input and a file extension: `foto_mail.jpg` for `foto_mail`) is read as that input's parameter,
  stated or added with the input's name, role and kind, and checked by the assembly like a stated use. It reads values
  only, never an element's label: a button Export and a file named Export keep their roles, and a row clicked by a
  file's name is still the agent's to state. Before, such a value stayed a literal and a reuse delivered the old one (D7).
- *Braus's interpretation* (`ProcedureProducer.brausInterpretation`). A completed task whose candidate the agent left
  uninterpreted after its reminder is interpreted by Braus at the end of a script's request: the task's goal as the
  procedure's label, the phases already known where its steps hold them, the uses inferred. The qualification decides
  as for any interpretation; no step is labelled, so none is offered alone. A failed or abandoned task is not.
- *A weaker repeat* (`SQLiteProcedureRepository.WeakerRepeat`). A run that repeats an admitted procedure but whose own
  procedure is refused (its result failed or was not read) does not replace it: it is written as a version of its own,
  and the admitted one stays offered. Before, a second run with a failed result took the first out of the Recall.
- *Variants Braus records*. A completed run that chose a learned source (`memory_task choose`) and did the work another
  way is that source's variant (`variant_of_route_id`), from the first step where the operations part, its prefix
  checked as a declared one's (`VariantPrefix`). None was declared in any test run.
- *The result read* (`hasReadResult`). A check that read something, never a guard Braus added nor a `none`, is the
  attempt's result: an end whose result a checkpoint already read is not asked for it, and a `none` at the end no longer
  makes the interpretation skip the check it names.
- *A pass that proves less* (`QualificationPolicy.StepFacts.isOnlyUnproven`). A step whose check passed on a condition
  that does not prove the request (a pop-up closed after a choice) is unproven, like an unknown one, not a contradiction:
  a method whose result Braus read is admitted over it.
- *Inputs guarded in every task* (`AutomationTools.guards`). Every file input read at the beginning that no check names
  is guarded at a completed end, also when the task writes nothing: an application that saved over its input by itself
  is shown. Guards stay informative.
- *An application not read* (`TaskResultCheck.Reading.unread`). A window check whose application name is ambiguous or
  whose windows cannot be listed is unknown; only a name no running application answers to says it is not running.
- *A use that names no query* is answered (`use_not_recorded`) and no longer keeps the end from being recorded, which left
  the task open and then abandoned.

| Proof | Test |
| --- | --- |
| The method left out and said, phases as subprocedures, the file checked | `ProcedureMethodTests.theMethodOnly` |
| Uses Braus infers; a label equal to a value keeps its role | `ProcedureMethodTests.usesBrausInfers`, `ProcedureLearningTests` (file named Export) |
| Braus interprets a completed task the agent left, never a failed one | `ProcedureMethodTests.brausInterpretsWhatTheAgentLeft` |
| A refused repeat leaves the admitted version offered | `ProcedureMethodTests.aWeakerRepeat` |
| A chosen source adapted is its variant | `ProcedureResultTemplateTests.aChosenSourceAdapted` |
| A `none` at the end, then a file named at the interpretation, is read; a checkpoint's reading is the result | `TaskResultKindsTests.noneAtTheEndThenAFile`, `.aSwitchCheckedAtACheckpoint` |
| An in-app task's input guarded; a bad use answered, the end recorded | `TaskResultKindsTests.anInAppTaskKeepsItsInput`, `.aBadUseDoesNotKeepTheTaskOpen` |
| A ready plan of admitted runs, accepted | `RecallLifecycleTests.readyPlanOfferedStepsOnly` |
| B admits a procedure over an unknown step when the result passed, refuses it when the result failed | `ProcedureMethodTests.resultAdmitsTheProcedure`, `ProcedureMethodRuleTests.policyB` |
| A repeated method replaces the first version and inherits its verified step | `ProcedureMethodTests.aRepeatedMethod` |
| What a method is | `ProcedureMethodRuleTests.signature` |
| The result's verdict | `ProcedureMethodRuleTests.resultVerdict` |
| Every kind of result, judged and kept | `TaskResultJudgmentTests` |
| A file changed in place, an original kept, a switch checked at a checkpoint for its phase, a result from the outputs or the interpretation, the guard | `TaskResultKindsTests` |
| The same method despite order, press and parameters; stable sections | `ProcedureMethodRuleTests.tolerance`, `ProcedureMethodRuleTests.stableSections` |
| A procedure's result as a template, proposed and delivered bound; the ready plan; a source followed without a choice | `ProcedureResultTemplateTests` |
| Families of parts and the phases a candidate shares | `ProcedureFamiliesTests` |

**Limits.** A repeat is recognized only at the same number of steps: a run that took another path to the same
result (Go to Folder against the sidebar) is another procedure, linked to the source it chose as its variant when it
chose one, else only in the goal families the consolidation reports. A repeat is looked for only on an attempt's
first version: an agent that interpreted at a checkpoint makes no repeat at the end (review A7-2, open). A file's row
clicked by its name is a literal unless the agent states the use. A screen check reads the session's scene at that moment: an element the window
no longer shows cannot be checked after it closes, and an element that exposes no value reads unknown. Application
settings stored on disk (`defaults`), the pasteboard and effects outside the Mac have no reader yet. An element's
label that is content without naming a file (a person's name on a button) still distinguishes two methods. Versions
built before 14 October 2026 keep their whole traces.

## Producers and their guarantees

| Moment | What happens | Where |
| --- | --- | --- |
| Operation ends | Its relation evaluated in the derived queue after its end is saved; the recovery asked for when it waits for its state | `CallRecorder.learn` |
| Queue empty | One bounded pass of the relation recovery, again while one is wanted | `MemoryService.drain` |
| Producer's open | The migration if any, then the recovery asked for | `MemoryService` |
| `checkpoint`, `end` | The checkpoint saved first; then, after the derived queue drained within 2 s, the attempt's candidate built from the facts and the current version evaluated again; the answer carries the candidate (or `candidate_error`, while the checkpoint stays saved) | `ProcedureProducer.candidate`, `AutomationTools` |
| `candidate` | The candidate of the producer's task again, for an agent that lost it or an interrupted attempt | the same |
| `interpret` | Prefix check, interpretation, version, parts, contracts, bindings and qualification in one transaction | `SQLiteProcedureRepository.interpret` |

The app's workers, its external MCP clients and `braus chat` reach all of it through `memory_task`, under
their own `CallProducer`; another producer's candidate is refused (`foreign_task`). Every write
is one transaction that reads the facts it decides on inside it; none is held across a gesture or a
model's turn. Two openers of one archive serialize on the store's writer; a candidate or an
interpretation offered twice, even by two connections at once, is written once (`alreadyApplied`), and
different interpretations offered at once take successive revisions. Two recoveries at once (the app's and
`--apply-relations`) evaluate a call at most once more, since an evaluation that decides the same adds
nothing.

## Diagnosis and the non-destructive procedures

`braus memory --task <id>` reads one task by its id, read only (as `--status`: shared presence lock, one
read transaction, an archive of exactly this build's shape): each attempt's calls with what each is to the
procedures (`step` with its occurrence, `container`, `skipped`, `context`), its check and what it taught
the relations (the latest evaluation, its cause and sequence, or the first policy's word for a call
evaluated by nothing since); the candidates with their blocks; each version with its parts (verdict,
reasons, state, whether the catalogue offers it), its variant prefix, steps with their arguments
(parameters and templates by name, a literal typed text by its length only), parameters with their
bindings' sources (`held`, `missing`, `withheld`, never a value), contracts with an entry state known
since; the relations the task's calls proved; and the counts kept apart (operational steps, containers,
skipped, context; candidates, versions; parts admitted, refused, offered; legacy Routes of the archive).
`--graph` prints the same objects as Mermaid: containment solid, step order dotted, relations between
states labelled (a state may lead to itself; no part contains itself). `ProcedureInspectionTests` prove that
the graph's edges are the rows SQL counts.

To take knowledge out of use without deleting it, and to evaluate it again:

```bash
braus memory --task <task id>
```

```bash
braus memory --part <part id> --state to_reevaluate --reason "<why>"
```

```bash
braus memory --requalify <route id>
```

```bash
braus memory --part <part id> --state usable --reason "<why>"
```

```bash
braus memory --quarantine-policy qualification-a-1 --reason "<why>"
```

```bash
braus memory --apply-relations
```

A part to evaluate again also keeps the parts containing it out of the catalogue. `retired` instead of
`to_reevaluate` is final. A quarantined policy stops offering everything it admitted;
the parts are offered again only by a build whose policy has another version, after `--requalify`.
`--apply-relations` runs the relation recovery to its end at once; a second run evaluates nothing. Nothing
of these deletes a row.

**Disabling what was learned without losing facts.** If the relations of a build turn out wrong, the
facts they come from stay: calls, samples, verifications and evaluations are kept, and a build with
another `BrainRelationPolicy.version` evaluates every call again on its own, its earlier evaluations kept
as history. A procedure part or a qualification policy is taken out of use as above. The archive's
verified copies (`memory.sqlite.schema-<n>-…`, the backups) are kept beside it.

## Measures

`ProcedureLearningCostTests` (run with `BRAUS_MEMORY_MEASURE=1`; skipped otherwise) on 2026-10-11, Apple
M4, 16 GiB, macOS 27.0 (26A428), Swift 6.4, SQLite 3.54.0, debug build, temporary archives. The load: one
application of 20 structural states (22 toolbar buttons, a panel of the state's own roles, a field, a
button to the next state), 4 tasks of 100 clicks each through the tools (alternately a toolbar button, a
self-loop, and the next state), then 1,000 probes. The larger projection: 400 screens of ten labels in a
column (4,000 anchors, 400 groups of ten), ten of its scenes read 200 times. The test asserts what was
learned, never a duration.

After the first corrections, at schema 4, three runs (the range below). Measured again after the second
corrections, at schema 5, three runs: bootstrap of a new archive 61 to 66 ms; migrations 2 → 5 and 3 → 5,
copy included, 193 to 200 ms; the recovery after them 365 to 387 ms (912 to 967 µs per call); every other
quantity within the ranges below or a few percent from them (an `act` p50 4.2 to 4.4 ms, a scene enriched
p50 796 to 812 µs, the part of the larger projection p50 636 to 641 µs).

| Quantity | Result |
| --- | --- |
| Bootstrap of a new archive (apart) | 49 to 53 ms |
| An `act` through the tools, recorder and essential writes included | p50 4.2 to 4.5 ms, p95 8.9 to 9.6 ms |
| `end` with a 100-step candidate (queue drained, candidate built, version evaluated) | p50 122 to 135 ms |
| Interpretation of 100 steps | 48 to 51 ms |
| State of a new capture | p50 104 to 108 µs, p95 125 to 135 µs |
| Relations of a state and two elements | p50 52 to 53 µs, p95 60 to 65 µs |
| The engine's expectation (state, identity among the capture's elements, relations) | p50 221 to 228 µs, p95 243 to 267 µs |
| A catalogue page of 100 parts | p50 10.7 to 11.8 ms |
| A scene enriched as a model reads it (part, state, relations), the load (25 anchors) | p50 801 to 821 µs, p95 941 to 1,012 µs |
| Its part of the projection / the whole projection read without cache, the load | p50 369 to 380 µs / 293 to 300 µs |
| A scene enriched, the larger projection, labeled elements only | p50 798 to 836 µs |
| Its part of the projection (at most 10 anchors read) / the whole projection (4,000 anchors) | p50 648 to 650 µs / 14.5 to 14.7 ms |
| The same scenes with one unlabeled control: enriched / its part | p50 2.73 to 2.76 ms / 2.53 ms |
| Migration 2 → 4 of the loaded archive, verified copy included (apart) | 173 to 177 ms; 20 shapes for 20 window scenes |
| The service's own recovery after it: 400 calls never evaluated | 374 to 379 ms, 935 to 947 µs per call |
| Migration 3 → 4, verified copy included (apart) | 175 to 181 ms |
| The service's own recovery after it: 400 calls evaluated again under this policy | 363 to 372 ms, 907 to 930 µs per call |

The archive held 404 calls, 25 anchors with 25 label keys, 21 scenes (20 states and the application
scope), 160 relations (80 exposed), 400 evaluations, 400 pieces of evidence and 101 parts, about 13 MB.
After each migration the recovery gave the relations learned while acting, support for support, and a pass
after it found nothing left. On a projection this small the part costs more than the whole (several
indexed reads instead of one scan); on the larger one it costs 1/22 of the whole. An unlabeled control
makes the ordinal rescue read every member of its kind's groups (4,000 here): that read is bounded by the
groups' size, not by an index. The engine's expectation costs about 45 µs more than in the first delivery
(p50 173 to 179 µs), the identification of the target among the capture's elements.

The first delivery's runs, on the same machine before the corrections, are kept for comparison:

| Quantity | Result |
| --- | --- |
| Bootstrap of a new archive (apart) | 38 to 40 ms (82 ms in the first run) |
| An `act` through the tools, recorder and essential writes included | p50 4.4 to 4.5 ms, p95 8.0 to 8.2 ms (p50 8.0 ms, p95 16.4 ms in the first run) |
| `end` with a 100-step candidate | p50 93 to 123 ms |
| Interpretation of 100 steps | 49 to 53 ms |
| Relations applied from the facts, one transaction per call (acquisition alone) | 0.80 to 0.94 ms per call |
| State of a new capture | p50 112 to 115 µs, p95 122 to 131 µs |
| Relations of a state and two elements | p50 46 to 47 µs, p95 52 to 63 µs |
| The engine's expectation (state and relations) | p50 173 to 179 µs, p95 188 to 226 µs |
| A catalogue page of 100 parts | p50 10.9 to 11.4 ms |
| Migration 2 → 3 of the loaded archive, verified copy included (apart) | 153 to 160 ms |

Before the catalogue read each version once per page it took 715 ms for the same page. No baseline of D1
on the same load was measured, and 400 operations and a page of 100 parts are not the scale of an archive
of hundreds of thousands of rows, which D3 must measure.

**The first load, kept.** The load first measured had states that differed only by their field's caption.
structure-v3 keeps captions, so its scenes were uncertain against each other: 24 of 400 operations taught a
relation and 376 were excluded (`no_before_state` in the first policy's words). The load was then changed so
each state shows its own roles; that change makes the load measurable and proves nothing about real
applications whose screens differ by captions. Such screens teach nothing until a stored scene and the
capture are the same: this is the matcher's conservative choice, and the signals that would resolve it
(an identifier of the window's purpose, a document kind, a verified navigation between the two) are not
recorded. The live applications chosen for the realistic tests must be checked against it before any
relation coverage is claimed.

## Requirements and proofs

| Area | What implements it | What proves it |
| --- | --- | --- |
| Parts 3 to 5 of the one schema text, the migration from 1 | `brain-living-memory-schema.sql`, `SQLiteMemorySchema` (`migrationText`, `derivedRows`: the `brain_scene_shapes` backfill), `fillLabelKeys` | `SchemaMigrationTests` (`oneText`, `sceneShapes`), `ProcedureRepositoryTests.developmentVersionsRefused`, `ProjectionSliceTests.migrationFillsTheKeys`, `verify-memory-schema.py` |
| Segmentation, occurrences, blocks A→B→A | `ProcedureSegmentation`, `SQLiteProcedureRepository.buildCandidate` | `ProcedureConstructionTests`, `ProcedureLearningTests.wholeCycle`, `.partialBatchRetryAndFailedParent` |
| Interpretation, templates, S23, secrets | `ProcedureInterpretation`, `ProcedureAssembly`, `MemoryTaskTool` | `ProcedureConstructionTests`, `ProcedureLearningTests.homonymsAndContradiction`, `.secretParameter`, `ProcedureRepositoryTests` |
| Idempotency, conflicts, staleness, interruption, variants and their prefixes, concurrency | `SQLiteProcedureRepository.interpret`, `VariantPrefix` | `ProcedureLearningTests.interruptionAndIdempotency`, `.variantOfAnEarlierVersion`, `ProcedureRepositoryTests.concurrentProducers`, `D2StorageIndependentReviewTests`, `VariantPrefixTests`, `VariantCorrespondenceTests`, `D2CorrectionsIndependentReviewTests` |
| Qualification A, states, quarantine, catalogue | `QualificationPolicy`, `setState`, `quarantine`, `catalogue` | `ProcedureConstructionTests`, `ProcedureRepositoryTests`, `ProcedureInspectionTests.graphIsTheRows` |
| Producers per client | `ProcedureProducer`, `AutomationTools` | `ProcedureLearningTests.producersKeepTheirCandidates`, `.newValues` |
| Element identity, argument roles, thresholds, contradictions | `SceneElementKey`, `BrainRelationPolicy`, `SQLiteBrainRelationRepository`, `BrainMemory` | `BrainRelationPolicyTests`, `BrainRelationLearningTests`, `BrainMemoryTests`, `BrainMemoryDeliveryTests`, `D2IndependentReviewTests`, `ReviewCorrectionTests.withheldFixedArgument` |
| Evaluations, recovery, late entry states | `SQLiteBrainRelationRepository.apply`, `.catchUp`, `MemoryService` recovery | `RelationRecoveryTests`, `ReviewCorrectionTests.lostDerivedWritesRecovered`, `BrainRelationLearningTests.migratedHistoryOnRequest`, `D2StorageIndependentReviewTests` |
| Delivery to the model, visible degradation, part of the projection | `BrainMemory.enrich`, `SceneKnowledge`, `SQLiteBrainRows.slice` | `BrainMemoryDeliveryTests`, `BrainMemoryDegradationTests`, `D2CorrectionsIndependentReviewTests`, `ReviewCorrectionTests.windowKnowledgeAndDegradation`, `ProjectionSliceTests` |
| Native `menu` and `press` samples, on success, refusal, cancellation before the command or after its gesture, and a failure before or after it | `PerceivedCommand`, `DialogButtonPress.observed`, `BrokeredAutomationSession` | `ReviewCorrectionTests.nativeCommandsArePerceived`, `.refusedCommandRecordsNothing`, `NativeCommandEvidenceTests`, `D2NativeCommandIndependentReviewTests`, `D2BeforePerceptionCancellationReviewTests` |
| Diagnosis by id, graph = SQL | `ProcedureInspection`, `SQLiteMemoryInspection.task`, `braus memory --task` | `ProcedureInspectionTests`, `RelationRecoveryTests.lateEntryState` |

All of these are unit or integration proofs over doubles of the operating system; no live desktop run was
made for D2. The Seat's `menu` and `press` share `PerceivedCommand` and the same commands with the app's
session; no test drives the Seat's, which needs a host with the accessibility grant and a real application.

## Corrections after the independent reviews

The independent review of the first delivery (2026-10-11) asked for eight corrections and added five
counterexamples that failed. The counterexamples are kept, adapted only in their API's shape
(`Tests/Engine/MemoryTests/Review/D2IndependentReviewTests.swift`,
`Tests/Engine/SQLiteMemoryTests/Review/D2StorageIndependentReviewTests.swift`), and pass. The second review
of the same day found three residues, F04b, F05b and F07b, each with a counterexample that failed; they are
kept unchanged (`Tests/Engine/MemoryTests/Review/D2CorrectionsIndependentReviewTests.swift`,
`Tests/Integration/AutomationRuntimeTests/D2NativeCommandIndependentReviewTests.swift`) and pass. The third
review confirmed those three and found F07c, with a fixture of four tests, three of which failed; it is kept
unchanged (`Tests/Integration/AutomationRuntimeTests/D2BeforePerceptionCancellationReviewTests.swift`) and
passes.

| | Problem | Choice | Where |
| --- | --- | --- | --- |
| F01 | Two unnamed fields of one container shared a key, so a relation learned on one showed on the other; two controls of one label counted as one target | A template is an instance's identity only where the capture holds no other; targets are resolved among physical elements before keys are deduplicated; a name never comes from a value; the same identity for learning, lookup, expectation and enrichment | `SceneElementKey`, `BrainRelationPolicy`, `BrainMemory` |
| F02 | Relations of the window or the focus were stored and never reached the model | The `memory:` and `  window:` lines of the scene, rendered and in its changes, with the condition an operation on the focus or the window needs | `SceneKnowledge`, `BrainMemory.annotate`, `SceneRendering`, `SceneChanges` |
| F03 | An exclusion was final even when its evidence arrived later; a lost derived write needed a command | An append-only history of evaluations with recoverable exclusions, evidence counted from each call's latest evaluation, a bounded recovery in the service's ordinary cycle, and the entry state known since shown beside a contract | schema 4, `SQLiteBrainRelationRepository`, `MemoryService`, `StoredProcedureVersion.lateEntryStates` |
| F04 | A variant's common prefix was declared, never checked | `VariantPrefix` on the generalized definitions: verified, suggested with its reason, or refused with nothing written | `VariantPrefix`, `SQLiteProcedureRepository.interpret`, schema 4 |
| F05 | A failed read became a scene without knowledge, indistinguishable from none | The live scene with `memory: unavailable right now`; no error in the model's context; the detail in `BrainMemory.diagnostics()` | `BrainMemory`, `SceneKnowledge` |
| F06 | `select` lost its item, `press_key` its count, a drag its destination | An argument role per family: fixed, parameter or element, and the parameters named in the summary | `BrainRelationPolicy.argumentRoles` |
| F07 | `menu` and `press` gave the recorder no sample before acting | `PerceivedCommand` perceives the window before and after the command as the call's own samples, keeping the window check | `PerceivedCommand`, `AutomationSession`, `BrokeredAutomationSession` |
| F08 | Every enrichment read the application's whole projection | The part a scene can match, by indexes, with no cache; the whole projection only for the CLI and the Brain's updates | `BrainReading.projection(of:for:)`, `SQLiteBrainRows.slice`, schema 4 |
| F04b | A parameter shared by two prefix steps was taken for two independent ones: the type alone was compared | One correspondence of the parameters across the prefix, with the same contract; otherwise `suggested` (`parameter_correspondence`); schema 5 for the reason, schema 4's verified prefixes checked again on migration | `VariantPrefix`, `SQLiteProcedureRepository`, schema 5 |
| F05b | A projection that failed left relations on the elements under `unavailable`, and dropped the window's | Any failed read leaves the live scene with nothing of the memory, said unavailable | `BrainMemory` |
| F07b | A button whose window after the press could not be perceived lost the window before it | The samples perceived stay the call's when a command throws after its gesture; the press concludes unknown with `no_after_scene`, a cancellation thrown | `PerceivedCommand`, `DialogButtonPress` |
| F07c | A cancellation of the perception before a native command was taken for a missing sample, and the command started | The cancellation thrown, and the task's checked before the command, whatever the perception answered; another failure still only leaves the sample out | `PerceivedCommand` |

## What D3 can rely on

D3 is built on these and is described in [MemoryRecall](MemoryRecall.md): its index reads the catalogue's
offered parts and their contracts, its selector reads versions whole (parts, contracts with entry states,
parameters with roles, bindings as episodic values never delivered), and five triggers of schema 6 on this
page's tables record its index work.

- `catalogue(after:limit:)`: each offered part with its procedure's label, candidate, task, attempt,
  revision, contract items, parameters (Route parameter and detail, never a value) and its qualification
  with the verifications it rests on.
- `version(_:)`, `versions(ofAttempt:)`: a version whole, with every part's latest evaluation and state,
  whether a later version superseded it, its variant prefix and the entry states known since it was built;
  bindings as episodic facts with their sources.
- `MemoryService.state(of:isComplete:in:)`, `relations(from:in:elementKeys:includingContext:)`,
  `SQLiteBrainRelationRepository.relations(of:)`, `evaluations(of:)` and `proofs(of:)`: the state of a
  capture and the relations of a state, with their standing, the current evidence, and each call's history.
- The legacy Routes, apart: Routes with no version row.

## Deliberate changes to earlier behavior

- `EffectExpecting.expectedEffect` takes the window (`PerceivedWindow`) instead of the bundle id, and
  answers an effect's family with no payload; the engine compares families.
- The projection's transitions are no expectation and no affordance any more; `BrainMemoryTests` and
  `MemoryWiringTests` say so where they expected one, and a scene's `does` now shows relations.
- The projection learns a transition only from a structural effect its check verified as the requested
  gesture's; the D1 fixtures of an earlier build apply their Brain record directly, as that build did.
- A scene a model reads may carry `memory:` lines; its elements and token are the live perception's.
- `menu` and `press` perceive the window before and after acting, two captures more per command.
- A dialog's button whose window after the press cannot be perceived answers an unverified outcome with an
  unknown check, as a menu command already did, instead of throwing the perception's error.
- Tests pinned to schema 2, 3 or 4 (versions, shapes, migration rows) follow schema 5.

On 14 October 2026, after the PhotoCraft runs:

- A menu command or a dialog button whose application's windows did not change is judged again on its own
  window (`PerceivedCommand.checkedInWindow`): an attributable difference between the scenes before and after
  is a `structural_effect` passed, window-wide and with no expectation. A sheet, a dialog an application draws
  in its window and a panel that slides in were unknown: 21 of PhotoCraft's 28 menu commands.
- `type_text` reads the field back from the scene after it at the field's own place when its id moved with its
  value and no focus answers (`ActionEngine.sameField`): the name field of PhotoCraft's save panel, 9 of 9
  unknown before.
- Structure-v4 replaces structure-v3 ([Structure-v4](MemorySchema.md#scenes-and-structure-v4)).
- A completed procedure's version holds its method, the agent's phases are subprocedures, the end may name a
  result Braus checks on disk, qualification B is in force and a repeated method is a new run
  ([The method, phases, result and repeated runs](#the-method-phases-result-and-repeated-runs)).

## Known limits

- No live desktop run: the GUI, Seat and live tiers were not run for D2. The Seat's `menu` and `press`
  perceptions, and their conclusion after a failed perception, are wired as the app's and not tested.
- A command's samples after a throw rest on its asking for the window after it only once its gesture was
  dispatched, which `MenuBarCommand` and `DialogButtonPress` do; a command that threw between its gesture
  and that request would leave no sample. A menu command whose window cannot be perceived after it says the
  perception's error in its message, as it did before D2.
- Captures that differ only by captions were uncertain under structure-v3 and taught no relation; since
  structure-v4 they are different states. An incomplete capture is never a state (the first load: 24 of 400
  learned).
- Unnamed controls of one role in one container are indistinct and teach nothing; a control whose only
  label is its value has no name.
- Calls of archives written before these corrections keep what they recorded: `menu` and `press` calls with
  no sample stay `no_before_state`, and relations keyed by the first policy stay in the archive with their
  proofs, counting nothing now.
- A contract's entry state stays unknown as built; the state known since is said beside it, never written
  into it.
- The ordinal rescue of an unlabeled control reads every member of its kind's groups.
- An enrichment of a scene an earlier enrichment already named keeps the labels it recalled when a read
  fails: callers enrich the live perception, whose labels are its own.
- A failed read of the memory is counted in `BrainMemory.diagnostics()`, not logged, and no screen shows it.
- The interpretation's idempotency compares a 64-bit digest and the length, not the statements.
- Contexts (application version, locale) are mostly unknown and prove no compatibility.
- An occurrence's end is left unknown when the calendar placed it before its start.

## Adapter steps and typed reuse

A procedure may combine verified UI operations, adapter mutations and read-only adapter calls whose results a later
step uses. Unused reads remain exploration. An adapter mutation needs its declared read-back evidence; an accepted
request alone does not prove an effect. Every step keeps its own verification and the origin of its evidence.

Structured arguments are delivered as constants, typed task parameters or references to results from earlier steps
of the current run. A reference with several possible sources stays unresolved. Confidential content is withheld
from durable records and supplied anew by the current task. Reuse resolves the current application, account and
required capabilities before acting; recalled values and earlier authorization confer no authority.

An uncertain mutation blocks repeats and dependent writes until later read evidence supports a reconciliation.
Read-only calls remain available for that check. Producer write claims cover concurrent callers, and persistent
refusals remain separate from episodic memory.
