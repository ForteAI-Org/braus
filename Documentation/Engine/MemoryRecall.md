# Memory recall

What the living memory answers a new task since G76 plan D3 (October 2026): a search of the procedures
D2 learned, from the agent's statement of the task, that proposes for each need at most one ordered
interval of one version's steps, with the task's current values bound, what it requires, and the evidence
it rests on; the derived index that search reads; and the linking of the calls an attempt makes
afterwards to the steps they carried out. How the selector decides, on which data, and what it cannot decide is in
[RecallSelection](RecallSelection.md).

**Status on 2026-10-13, branch `rename-app`.** The product's one path is the Recall by the agent's choice
([RecallAgentChoice](RecallAgentChoice.md)), chosen by the product owner on 2026-10-13: Engine searches a few sources,
the agent that runs the task chooses the tracts, Engine checks and delivers them. `memory_task` begin and recall answer
a proposal with no flag in the app, the MCP server and `braus chat` alike; `BRAUS_RECALL_AGENT_CHOICE` is gone. The
automatic selection described below stays as the control of the comparisons and the regression tests
(`RecallSelectionControl`, set only inside a test or a benchmark process), never as a second path or a fallback. The
product's configuration is the one A was measured with: hybrid, Granite 107m, weight 0.2
([the index](#the-index)); without the model's files the lexical index answers and says so. The sections below record
the D3 rounds as they were, dated.

The facts and procedures it reads are described in [MemoryFacts](MemoryFacts.md) and
[MemoryProcedures](MemoryProcedures.md); the tables in [MemorySchema](MemorySchema.md). D4 (sharing) is
not built here.

```text
memory_task begin ──▶ RecallRequest ──▶ RecallService.prepare ──▶ exact scoring of every indexed part
 (goal, remaining,     (needs, values,     (values masked,            (lexical, semantic or hybrid)
  needs, inputs)        reason)             current generation)               │
                                                                     versions read from SQL, not the index
                                                                              │
                         RecallDelivery ◀── last catalogue check ◀── RecallSelector (exclusions, episodes,
                         (per need: coverage,                         observed state, delimitation, producers,
                          one selection, alternatives,                requirements, bindings, ranking)
                          exclusions)
                                │
 calls of the attempt ──▶ RecallUseLinking ──▶ links + the agent's declared use (followed, adapted, …)

catalogue writes ──triggers──▶ memory_recall_work ──worker after the commit──▶ generations, documents,
 (D2 versions, qualifications,                                                 vectors, entries
  states, policies)
```

## The contract

`RecallContract` (version 1, selector `recall-selector-4`) is reached through `memory_task`, the same tool
for the app's workers, external MCP clients and `braus chat` ([MemoryFacts](MemoryFacts.md)). Since 2026-10-13 `begin`
and `recall` answer a proposal and `choose` delivers the agent's choice ([RecallAgentChoice](RecallAgentChoice.md));
`recall_mode: "propose"`, which the experiment's clients sent, is accepted and changes nothing. The delivery described
in this section is what `choose` answers for each tract, and what the selector's control answers in a test. A need's
`app` is a name or a bundle ID, resolved before anything filters or records it (`RecallApplications`, live run R01
LV03): among the applications the index's parts run in, with the names their installed bundles answer to, and those the
session offers; a bundle ID is a certain identity, a name nothing knows or several answer to excludes nothing and is
said in the search's note.

- `begin` records the task as before and, unless `recall` is false, searches once before any operation:
  `remaining` is the work still to do (the goal when omitted), `needs` (at most 8, each a text and
  optionally the app the request imposes) split it into sub-results. The task's inputs are the values a
  selection binds; they are never searched with. The task's constraints reach the selector: prohibitions are
  checked against the steps, everything else is carried to the agent as a condition. The texts are the agent's,
  in the person's language: no language is imposed (the English convention of the first delivery was withdrawn,
  see [the second comparison](#the-second-comparison)).
- `recall` searches again for the open task with a reason: `request_changed`, `input_changed`,
  `new_need` or `path_unusable`. `initial` is `begin`'s and is refused here; a new scene, a Brain update or
  a parameter resolved is no reason, and nothing queries on its own.
- `use`, also accepted by `checkpoint` and `end`: per need received, `followed`, `adapted`, `abandoned` or
  `not_executed`, with an optional cause (`method`, `driver`, `application`, `agent`, `input`, `unknown`)
  and note. A declaration is kept beside the facts, never in their place.

The answer (`RecallDelivery`) separates how far the search went from what it covered:

| Field | Meaning |
|---|---|
| `index.status` | `ready`, `building` (no complete generation yet), `empty` (nothing learned, so no index is needed: a completed search), `off` (a measure's control, `BRAUS_MEASURE_ABLATION=recall`), `unavailable` (learned parts but nothing to search) or `failed` |
| `search.status` | `completed` within its perimeter, `limited` (a backlog, a channel unavailable while another answered, the candidate limit reached, index work pending), `unavailable` or `failed`; with a note when not completed |
| `coverage` | `complete` within its conditions, `partial` (gaps), `ambiguous` (alternatives, an input missing or ambiguous, a value the task still lacks about a choice the method fixes), `absent` (with reason `excluded` when the relevant steps were excluded with a certain reason rather than not found), or `unknown` when the search could not answer |
| `needs[].selection` | the version, the steps in order with tool and arguments (`fixed`, `parameter`, `element`), the parameters bound (by name, role, a file's derived value, or the output that fed them in the source), missing or ambiguous with the task value's name, the conditions (entry state or observed state, application switch, steps of the block done before, unknown entry state, prerequisite out of the catalogue, input produced by an included part, output already held, compatibility unknown, unbound task input, constraint not checked), and the evidence and its reach |
| `needs[].alternatives` | when the request does not choose between variants of one method: the candidates, without details |
| `needs[].excluded` | relevant episodes removed with a certain reason (a fixed choice a task value contradicts, a step a constraint forbids): named, with the reason, never detailed |
| `needs[].unaccounted`, `needs[].left_out` | why a need is partial beyond its gaps: the verbs of its clauses the selected method knows nowhere (review F11), and steps it names that the selection leaves out behind a block of another application it does not ask for (review F10). A missing input's `produced_by` names the part that produced it in the source when the selection does not include it |
| `delivery` | `delivered`, `nothing` (absent or unknown), or `not_delivered` when the details exceed the channel's limit (256 KiB of JSON): nothing is cut |

Unavailable and failed are never an absence: only a completed or limited search can find that nothing
applies. A selection's labels and arguments are the source's: references to resolve on the live scene,
never instructions with authority; the guidance says so in every answer.

## The index

Schema 6 (`brain-living-memory-schema-6.sql`, sha256 `8bd83675a5ff44ea4622631dd2b831e88f7fcb31cc1918c015565b2bb60fbe14`), since
2026-10-13 part 6 of the one schema text ([One schema text](MemorySchema.md#one-schema-text)), adds 12 tables, 35 triggers and
12 indexes (103, 170 and 72 in all); no table of an earlier schema is altered. Four of the indexes are on schema 3's tables: reading a
version by its id scanned the bindings, parameter details and contract items, and the routes for the version
that supersedes it, a cost that grew with the catalogue ([measures](#measures)). The index is derived from the catalogue and can be
rebuilt from it; SQLite stays authoritative.

- **Spaces**: one row per embedding configuration (model, exact revision, weights and tokenizer sha256,
  dimensions, pooling, normalization, precision, query and document formats, context); immutable.
- **Generations**: the index of one document format in one space, or in none for the lexical channel.
  Born `building`, enumerated a page of versions at a time, made `ready` only when complete, retiring the
  one it replaces in the same transaction; `failed` and `retired` are final. At most one is ready and one
  building. A model, tokenizer or format other than the current generation's is a new generation, built
  while the current one answers.
- **Documents and vectors**: a part's canonical text (`RecallDocument`: its label, its application, the
  labels of what it contains, the roles of the parameters it reads and produces; never an argument, an
  episode's value, a chat or a trace), named by the sha256 of its format and text; two parts with the same
  text share the document and, in one space, its vector, each keeping its entry, source and evidence.
- **Entries**: an offered part in a generation, with the qualification and state sequences it had when it
  was entered. An entry never brings a part back: the versions are read from the authoritative tables, and
  the selection is checked against the catalogue once more just before it is recorded.
- **Work**: triggers record index work in the same transaction as every write that changes what the
  catalogue may offer (a version published or superseding another, a part evaluated, a part's state, a
  policy quarantined), one pending row per route or for the whole catalogue. A worker of `RecallService`
  takes it after the commit, in bounded passes, outside any transaction for the model; work that fails three
  times stays pending, counted, and said in every answer's search note. An archive migrated from schema 1 or from a
  historical shape ([MemorySchema](MemorySchema.md#historical-shapes)) gets one rebuild queued by the store in the
  migrating transaction; one that only takes the number 8 keeps its index.
- **The product's space.** The product's configuration is hybrid over Granite 107m (since 2026-10-13), so its
  generation lives in Granite's space. An archive whose current generation is lexical (every archive the provisional
  configuration indexed) gets a Granite generation built while the lexical one answers; until its vectors exist, or
  when the model's files are missing or refused, answers come from the lexical channel and say the semantic one is
  unavailable and why. The files come from an explicit setup step, `Tools/Engine/Scripts/fetch-recall-model.sh`,
  which downloads them, or with `--from <folder>` copies them from a folder already downloaded, and refuses any file
  whose sha256 the manifest does not pin; nothing downloads at run time.
- **Facts of the Recall**: each query (why, the remaining work, generation, channel, search status and
  note, candidates considered, coverage, delivery and its size, selector version, duration), its needs (with
  the reason of a coverage that is not complete, `excluded` for an absence by exclusion), the selections
  (selected, alternatives, excluded), their requirements (bindings name the task value, never the value; a
  constraint is named by its position in the task's revision, which keeps its text), the links of calls to steps
  and the declared uses. All immutable and kept.
- **Ownership**: the product's configuration owns the archive's index, in the app, the MCP server and the command
  line alike, so their workers build one generation together. A configuration chosen for one process by
  `BRAUS_RECALL` (a comparison, a diagnosis) is a guest: its worker keeps the live generations in line with the
  catalogue and never starts, abandons or promotes one, and its answers say they came from the owner's index
  (`limited`). Two owners of different configurations would retire each other's generations
  (`RecallOwnershipTests` shows both).

The search is exact: every entry of the current generation is scored in memory (`IndexCache`). The cache is read
whole once per generation, then kept current by what changed (second review): when the revision moves, only the
versions with index work since the cache's mark (the oldest work pending at its last read, or the next one) are read
again, in one snapshot with the new revision and mark, and their entries replaced in place (entries live in slots;
the ranking breaks ties by part id, so slots do not change it); vectors computed later are read for the documents
still without one, at once up to 2,048 documents and at most every 2 s above. More than 2,000 changed versions, or
another generation, is a whole read. `RecallCacheTests` proves the cache kept current equals a whole read after new
versions, a superseded version, a retired part and later vectors. No approximate index stands between a query and a part, so no
filter applied after a shortlist can lose the right one. A need bound to an application excludes the parts of
every other application before any cut (review F06); the best remaining entries name at most 12 versions per need
(at most 48 entries considered). The perimeter is declared: the search is `limited`, with a note, when more than
48 parts are relevant to a need or when relevant versions are left unread by the 12-version limit; a cut is never
an absence.

## Local embedding

`LocalEmbedding` runs a pinned BERT-family encoder on this Mac in Swift over Accelerate: safetensors read
by memory mapping, the XLM-RoBERTa Unigram tokenizer as Hugging Face's `tokenizers` 0.23 runs it
(precompiled normalizer, whitespace split, metaspace, Viterbi), mean or CLS pooling, L2 normalization.
`EmbeddingModelManifest` pins each model's revision, license, prefixes and the sha256 of its weights,
tokenizer and configuration; a directory with another file is refused at load, and the Recall answers on
the lexical channel, saying why. Nothing downloads at run time: `Tools/Engine/Scripts/fetch-recall-model.sh`
installs a model into `~/Library/Application Support/Braus/Models` (or `BRAUS_RECALL_MODELS`) as an explicit
setup step, and `--verify-only` checks an installed one without the network.

| Model | Revision | License | Weights | Pooling, prefixes |
|---|---|---|---|---|
| `intfloat/multilingual-e5-small` | `614241f622f53c4eeff9890bdc4f31cfecc418b3` | MIT | 470,641,600 B float32, sha256 `1a55775f…c98477` | mean, `query: ` / `passage: ` |
| `ibm-granite/granite-embedding-107m-multilingual` | `d6cffd338414d6a1c1f5decfad5fec62eebc90d5` | Apache-2.0 | 214,000,232 B bfloat16, sha256 `ae6f20cc…161283` | CLS, none |

EmbeddingGemma, the plan's other candidate, is gated on the Hub (a signed-in account and a manual
approval): an agent may not create accounts or sign in, and unofficial mirrors cannot be tied to Google's
artifact, so Granite replaced it, multilingual (Italian included), under Apache-2.0, in the same encoder
family as E5, so one runtime serves both. `LocalEmbeddingReferenceTests` compare token ids and vectors with
Hugging Face's own on 18 texts in Italian, English and mixed, for both models and both roles
(`recall-embedding-reference.json`, generated by `Tools/Engine/Scripts/recall-embedding-reference.py` in the
evaluation environment only): token ids equal, cosine to the reference ≥ 0.99999.

## Selection

`RecallSelector` decides per need by deterministic rules over the D2 contracts; similarity finds where a
version is relevant and never certifies coverage. Relevance, exclusion, delimitation, prerequisites, binding and
coverage are separate steps.

1. **Exclusion** (review F03). A step is excluded with a certain reason when it fixes a choice (a pop-up's item, a
   contextual menu's item) and a value of the task naming that choice's control contradicts it
   (`certain_conflict`: a method that chooses JPEG for a task that asks PNG), or when it does what a constraint
   forbids (`constraint_excluded`, below). Its whole episode goes with it, since the episode produces what the step
   chose; the version's other episodes stay selectable, and a whole part keeps its selectable run when what remains
   is relevant on its own. Where the episodes are not known (a step whose start was not recorded in a known state is
   an uncertain episode of its own), the excluded episode takes the uncertain episodes after it in its block, and,
   when its own start is unknown, those before it: a dialog whose states were not recorded is not delivered without
   the choice that defines it. A choice made with a parameter is never a conflict: a value the source never chose is a
   compatibility to check (`compatibility_unknown`); a value the task still lacks about a fixed choice leaves the
   selection ambiguous (`unbound_task_input`). Excluded episodes that were relevant are named in the answer.
2. **Constraints** (review F02, `RecallConstraint`). A constraint's prohibitions (`do not`, `don't`, `never`,
   `without`, `avoid`, `non`, `senza`, `mai`, `evita`, and a clause after `or` or `nor` that follows one) are checked
   against what a step states: a prohibition naming an application with at most a verb of opening or using it
   forbids that application's steps; one naming the item a step fixes forbids that step; any other forbids a step
   whose label and fixed texts hold all of its content words. What forbids nothing is carried to the agent as a
   `constraint_unchecked` condition, never as satisfied. The check reads words, not effects.
3. **Episodes and the observed state.** A version's steps are cut into episodes (`RecallSource.units`) from the
   functional states D2 recorded: a step that leaves its block's base state unchanged is one; every step from the
   one that leaves it (opens a dialog) to the one that returns to it is one. The latest observation of the task's
   session (the scene its producer's latest call or observation was confirmed in, within 15 minutes, read from the
   facts after a short flush of the derived queue) cuts an episode at the first step past its start that began in
   that state: the steps before reached it and are done; from it on, each step that keeps the state is an episode,
   so a need about one control of a dialog already open is that control alone (`observed_state`).
4. **Delimitation** (selector 3, second review; [RecallSelection](RecallSelection.md)). A version is read only when
   its most relevant selectable step, or offered part holding one, reaches `absolute`. The need's text, the task's
   values and every placeholder removed, is cut into clauses (punctuation, `and`, `then`, `e`, `ed`, `poi`,
   `quindi`). A word several episodes of the version hold says what the version works on; a word one episode alone
   holds points at it; an application's name says where. Each clause names the episode alone in holding the most of
   its words no other episode holds (a tie names none); a value of the task the need mentions (three characters or
   more, or a number of any length, held by no other value) names the episode that alone reads it (through every
   parameter bound to it). Values only add to words the version recognizes as naming its work: a word one episode
   alone holds, or one the procedure's or a part's label gives the work and no step spells ("Create the event" over
   "Start a new event"). A need with neither names nothing: one in another language than the labels, or one that
   shares only the object every episode works on ("Move the event …" against a version that creates events and
   invites to them). The selection runs from the first named episode to the last; nothing is proposed when no
   episode is named, when a named episode is excluded, by its words or by a value it alone reads (the exclusion is
   named), or when an excluded, done or other application's step lies between. An observation of a state after work the need names
   will not hold when the selection reaches it, so the version is then read without it. Relevance margins
   (`stepMargin`, `partMargin`), the number of values a method takes and the presence of any ready value no longer
   decide the extent. Selector 4 (third review) adds two rules:
   - A block of another application inside the tract, none of whose episodes the need names, cuts it. The named work
     after the block is kept; the earlier named work is said left out and the need is partial (F10).
   - A clause whose first word, the verb of an imperative request, the version knows nowhere (in no label, fixed text,
     parameter or application name) leaves the need partial, the verb named (F11). An object written otherwise
     ("photo" for "image") is no such word.
5. **Producers** (second review, F09). Outputs declared in D2's contracts (`direction = output`, `produced_by`) are
   the only producers read, and an input is related to one only by its stated origin (`RecallSource.feed(of:)`):
   every attempt binding that states where the input came from names the same output of the version (by the
   interpretation's name, or `<task id>/<output name>` of the attempt's task) as `previous_output` (the output itself)
   or `derived` (a value derived from it); another source or output contradicts it, `unknown` states nothing; taken
   as itself, the output must be of the input's kind and hold the input's value. Equal episodic values are no
   relation. A part the selection starts in, ending before it, whose every output the task already holds is not
   repeated (`output_ready`); an input fed by an output the task holds takes its value when it is the output itself
   (`produced`) and stays to derive otherwise. An input fed by an output the task lacks brings the producing part into
   the selection (`input_produced`, its condition naming the output, the relation and the part) only when nothing lies
   between them, or what lies between belongs to an episode of the producer or of the selection (third review, F10:
   selectable is not necessary). Otherwise the input stays missing and the delivery names its producer (`produced_by`),
   without proposing the unrelated work; the agent's choice can take producer and consumer as two tracts.
   The stated origin survives the archive (third review, F12):
   - On the path that knows the reference's role, a `source_ref` of the form `<task id>/<output name>` is kept as given
     when the producer's own task declared that output, in a checkpoint, an end or the very statement written, and its
     `source_version`, when given, is one of that task's attempts or revisions. `TaskOutputReference`, applied once for
     begin, update, checkpoint, end and interpretation (`TaskChannel.targets`).
   - Any other reference is minimized as any text: an unknown task, another producer's, an undeclared output, a wrong
     version. It never invents a relation, and a reference already withheld stays withheld.
6. **Prerequisites.** The selection starts in its block's base state, which the source reached by opening or
   focusing the application (`entry_state`), or in the observed state (`observed_state`, which proves the screen's
   state, not the document): conditions, not gaps. The steps of the same block before it are stated
   (`prepared_before`): the request does not name them and no contract says whether what they left is in place; the
   condition names them, the last label and the data they read that the task does not give. An episode whose start was not recorded in a known state, a step of a selected episode the catalogue
   does not offer, or a start inside an episode is a gap: `partial`. Application switches are stated.
7. **Bindings** (`RecallBinding`). Each parameter the interval reads takes the task's value of the same name, else
   of the same role, else a value derived from a file the task names (its name, extension or folder), else the one
   value whose name and role share most of the parameter's words; types must agree. A missing or ambiguous parameter
   leaves the selection `ambiguous` until the agent resolves it.
8. **Ranking.** Versions within `adequacy` of the best are ordered by coverage, then fewer preparations (a missing
   input, a gap, a switch of application, an unknown compatibility, steps before the selection), then evidence (a
   whole qualified part, confirmed reuses), then relevance; the number of the task's values a method takes is no
   longer a criterion. Between proposals equal in all of these, the version learned for that work alone comes
   first (fewer of its steps outside the proposal), then the procedure's label, then the version's id: learning
   gives versions random ids, so equal archives answer alike whatever ids they hold. Tied
   variants of one method (the same tools in order with the same fixed arguments but a choice) are an ambiguity
   unless the need names one side's words; tied different methods are not.

Each need is searched with the task's values masked by their names (`RecallText.masked`):
`report_q3.pdf to luca@example.com` is searched as `<file_name> to <recipient>`. The lexical channel scores the
share of the need's content words a document holds (Italian and English function words dropped, words cut to six
characters), each word weighed by `LexicalIndex.Weighting`: `uniform` (every word the same), `version` (its inverse
frequency among the documents of the part's own version) or `collection` (its inverse frequency in the whole
index). The first two make a part's score depend on the query and the part's version only, so the same part scores
the same in an archive of one procedure and among thousands (review F01); the third moves with the archive. The
semantic channel scores the inner product of normalized vectors; the hybrid one `(1 − w) · semantic + w · lexical`.

## Use and feedback

At a checkpoint or the end, `RecallUseLinking` links each call the attempt made after a delivery to the step it
carried out, in order, from the facts only (review F04): the same tool, on the same application (a call on an
application the facts do not name is no step), from the same functional state when both are known, on the same
element (the same functional identity when the Brain identified the element of both calls, so a field labelled by
its value is the same field under another value; else the same label), with the arguments that define the
operation equal (the verb and the toggle's state, the item, the typed text, the key with its modifiers and count,
the scroll's direction and amount, the drag's offset, the menu path, the button). A parameter or a template not
bound to a value matches nothing. An item template (`item_template|…`, what every row of a collection offers) is
not one row: the row is told by its label, so it is compared too (second review, F07); and an element the step
takes from the task (a parameter or a template) must be the task's value, bound and equal, whatever the identity
says. A whole parameter of a number or a flag (`lines`, `count`, `dx`, `dy`, `replace`) matches the call's value
its textual binding spells as that type, the rule D2 checks a use with (`BrainArgument.Value.isSpelled(by:)`, F08);
a text, digits or not, compares as a text. Typed text and file names compare as written (only canonical Unicode equivalence
is ignored); names the application shows compare without case or surrounding space. The values are those of the
task revision the query was made under. A call that matches a later step skips the ones between; a call that
matches none is the agent's own operation (adapted or a connector), or `undetermined` when it would carry out the
next step were the facts it lacks to agree (its application not recorded, the element's identity not derived while
its label differs): neither a confirmation nor a deviation. A link is confirmed when its call's own check passed. The
answer to `use` separates the steps carried out, those verified, those not carried out, the agent's own operations
and the undetermined ones; the declared use (followed, adapted, abandoned, not executed) stays beside them. A version's confirmed reuses count only selections whose every step was carried out by a confirmed call; a
declared `followed` with no call credits nothing, and nothing changes a part's qualification or state.

A need answered by the agent's choice (A, the product's path) delivers its tracts in order, each a selected row. Its calls are linked
tract by tract:
- a call that carried out no step of a tract may carry out one of the next;
- each call is linked once per query, to the tract (selection position) and step it carried out
  (`memory_recall_choice_links`), so one call never confirms two steps of two tracts;
- the answer to `use` names the tract (`tract`);
- a version's confirmed reuses count a tract only when every step of it was carried out by a confirmed call
  (`RecallChoiceToolTests.feedbackPerTract`).

Material only proposed, or a plan refused, delivers nothing and credits nothing.

## Diagnosis

- `braus memory --recall-status`: the configuration this process resolves, the generations, entries,
  vectors still to compute, index work pending with its failed attempts, without running any.
- `braus memory --recall-rebuild [--within <seconds>]`: queues a rebuild of the whole catalogue and runs the
  index work until it is done.
- `braus memory --recall-explain <text> [--limit <n>]`: every indexed part scored against a text, the most
  relevant first, with each channel's score; no query is recorded and nothing is selected.
- `BRAUS_RECALL=<channel>[:<model>]` and `BRAUS_RECALL_MODELS=<folder>` override the configuration of a
  process, for the comparison and for diagnosis; a configuration other than the product's is a guest of the
  archive's index (see [the index](#the-index)).
- `memory_task` `operation: status` names what the answering process resolved: `archive` (the store file it opened)
  and `recall` (`channel`, `model` with its revision, `models_folder`, `format`, `owns_index`, `model_state`), and
  `measure_ablation` when a measure turned knowledge off. A live run's preflight reads it from the process, not from a
  shell's variables; the unified log repeats the first two (`memory open: <path>`, `recall of <path>: channel …`,
  subsystem `dev.forte.Braus`).
- `BRAUS_MEASURE_ABLATION=recall|brain|recall,brain` (`MeasureAblation`) is the control of a measure, never a mode of
  the product: with `recall` every search answers that nothing fits and records why; with `brain` scenes are shown
  without the Brain's enrichment. Everything is still recorded and learned.
- `BRAUS_SQLITE_PROFILE=<file>` appends every statement's duration in nanoseconds and its text, never its bound
  values, for a measure of the store's cost (`SQLiteStatementProfile`).

## The comparison

The configuration is chosen by a comparison that could refute it, on the release build. There were three; the first
two are kept as history, results and preregistration unchanged (the third is
[below](#the-third-comparison)).

- **First comparison** (`RecallEvaluationTests`, `BRAUS_RECALL_EVAL=dev|final`, corpus `recall-corpus-v1`, calibration
  `recall-calibration-v1.json`): 19 knowledge items, 46 queries (26 development, 20 final, split by family), 22
  configurations. It chose the lexical channel; the review found its criteria too weak to close the semantic
  requirement (C4 met in form only, one false complete allowed) and its scale dependent on the collection (F01, F05).
  See [the first comparison](#the-first-comparison-history).
- **Second comparison** (`RecallEvaluationV2Tests`, `BRAUS_RECALL_EVAL=dev2|final2`, corpus `recall-corpus-v2`,
  calibration `recall-calibration-v2.json`), after the selector's corrections:
  - **Corpus**: v1's 19 procedures and four more learned through the tools (an invoice downloaded in Safari and
    emailed, whose interpretation declares the download's output; Contacts; Music; a Numbers chart exported and
    emailed, with a fixed PNG choice and a declared output). v1's 46 queries are the *regression* split, seen. 23 new
    *development* queries over v1's development families and the invoice family: the review's wordings of the first
    learned case and paraphrases in English, Italian and mixed; constraints; a dialog already open; produced inputs
    and ready outputs; a certain conflict; close negatives in English and Italian. 21 new *final* queries over three
    families never queried before (Contacts, Music, the chart), with the same kinds of cases: 14 positive needs (6 of
    Italian or mixed requests, two with inputs named in Italian), 7 close negatives (an absence or a certain
    conflict). `critical` marks the needs where an incompatible delivery or a false complete misleads into harmful
    or repeated work.
  - **Conditions**: every query on the archive of the whole corpus; a query naming `bootstrap` also on an archive
    holding only its family's knowledge, so the same thresholds must hold on a first learned procedure and among
    many others (F01). `observed` names the source step whose entry state the session showed before the query.
  - **Configurations**: 58: lexical under each weighting (`uniform`, `version`, `collection`), semantic over E5 and
    Granite, hybrid over each with w ∈ {0.2, 0.35, 0.5, 0.65} under each lexical weighting, in both document formats.
  - **Calibration** on development and regression, both conditions summed, over a grid (absolute by 0.01; stepMargin
    {0, 0.01, 0.02, 0.05, 0.1}; partMargin {−0.4, −0.3, −0.2, −0.1, −0.05, 0}; adequacy {0, 0.02, 0.05}; tie {0, 0.02,
    0.04}); objective: fewest incompatible deliveries and false completes of critical needs, then most correct
    queries, then fewest false completes, then the point inside the widest plateau.
  - **Criteria**, fixed in code before any run of the second corpus and frozen with the thresholds: K1 no incompatible
    delivery in any condition; K2 no false complete of a critical need; K3 at least 10 of the 14 positive needs
    selected exactly (full archive); K4 at least 4 of the 6 positive needs of Italian or mixed requests (a correct
    absence never counts); K5 at least 10 of the 14 positives on the minimal archives; K6 at least 6 of the 7 close
    negatives right (full) and 4 of 5 (minimal); K7 warm search p95 within 50 ms, measured, not a criterion. The rule
    of choice is the first comparison's; if no configuration meets K1–K6, the failure is reported and none is
    declared validated.
  - **Phases**, each with its denominator: positive needs whose accepted version is among the first 10 and 48 entries
    (candidates), whose accepted version has an entry over the absolute threshold (threshold), selected exactly
    (tract), Italian or mixed positives selected exactly; negatives whose every entry stays under the threshold, and
    those answered absent; bindings, expected exclusions, incompatible deliveries, false completes, critical unsafe
    answers. Every final delivery through `memory_task begin` must agree with the service's selection. The operational
    outcome of a delivery carried out is measured by the cycle, sharing and scope suites through the tools, not per
    corpus query.

## Agents' convention

The texts the Recall compares are all the agent's: the labels it interprets a candidate with, and the remaining work
and needs it searches with, in the person's language. The first delivery asked agents to write them in English
whatever the person's language; the review found that convention unproven (F05), and it was withdrawn: the normal
contract stands until a change is shown on the agent's real path and reviewed.

## The second comparison

Preregistration: the criteria K1–K7 were written in `RecallEvaluationV2Tests` before any run of the second corpus; the
development calibration ran on 2026-10-12 from 00:52 UTC on a source tree whose fingerprint was recorded before and
checked again after it (`1dd14fd9…f0fd1922`); the calibration was frozen at 01:27:07 UTC
(`recall-calibration-v2.json`, sha256 `a9f73229a1560e31fc8da62882a807649aa8b969e3a59915c2de2784304bd32c`; corpus sha256
`042797268429cc068015a1de0aabbc72bdaa464c1b14079315742f969949e03a`); the only change before the final run was the frozen
file's entry among the test resources. Final run on the release build, Apple M4. Every delivery through `memory_task
begin` agreed with the service's selection (21/21 for every configuration). Columns: correct development and regression
queries (both conditions, 78); on the final split's full archive the positive needs selected exactly, those of Italian or
mixed requests, those whose accepted version is among the first 10 entries, those whose accepted version has an entry over
the absolute threshold, the close negatives answered as expected; on the minimal archives the positives and negatives;
over all conditions the incompatible deliveries (a forbidden step or an excluded version delivered), the false complete
coverages of critical needs and of all needs; warm search p95 on the full archive.

| Configuration | Dev correct | Final: positives exact | it+mixed | candidates R@10 | kept by threshold | negatives right | Minimal: positives | negatives | Incompatible | Critical false complete | False complete | p95 ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| lexical/recall-document-1/uniform | 42/78 | 5/14 | 0/6 | 13/14 | 10/14 | 5/7 | 5/14 | 3/5 | 6 | 12 | 12 | 8.4 |
| lexical/recall-document-1/version | 39/78 | 6/14 | 1/6 | 13/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 8.3 |
| lexical/recall-document-1/collection | 45/78 | 6/14 | 1/6 | 13/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 8.4 |
| semantic/e5-small/recall-document-1 | 21/78 | 3/14 | 0/6 | 14/14 | 3/14 | 7/7 | 3/14 | 5/5 | 0 | 0 | 0 | 14.0 |
| hybrid0.2/e5-small/recall-document-1/uniform | 49/78 | 5/14 | 1/6 | 14/14 | 10/14 | 5/7 | 5/14 | 3/5 | 6 | 12 | 12 | 14.0 |
| hybrid0.35/e5-small/recall-document-1/uniform | 46/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 14.4 |
| hybrid0.5/e5-small/recall-document-1/uniform | 45/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 14.1 |
| hybrid0.65/e5-small/recall-document-1/uniform | 42/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 13.7 |
| hybrid0.2/e5-small/recall-document-1/version | 50/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 14.0 |
| hybrid0.35/e5-small/recall-document-1/version | 46/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 13.9 |
| hybrid0.5/e5-small/recall-document-1/version | 46/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 14.1 |
| hybrid0.65/e5-small/recall-document-1/version | 40/78 | 4/14 | 0/6 | 14/14 | 10/14 | 6/7 | 4/14 | 4/5 | 6 | 12 | 12 | 14.1 |
| hybrid0.2/e5-small/recall-document-1/collection | 48/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 13.6 |
| hybrid0.35/e5-small/recall-document-1/collection | 47/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 14.1 |
| hybrid0.5/e5-small/recall-document-1/collection | 57/78 | 6/14 | 0/6 | 14/14 | 11/14 | 3/7 | 6/14 | 3/5 | 6 | 12 | 12 | 13.9 |
| hybrid0.65/e5-small/recall-document-1/collection | 57/78 | 6/14 | 1/6 | 14/14 | 11/14 | 3/7 | 6/14 | 3/5 | 7 | 14 | 14 | 13.8 |
| semantic/granite-107m/recall-document-1 | 52/78 | 4/14 | 1/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 8 | 12 | 14 | 11.2 |
| hybrid0.2/granite-107m/recall-document-1/uniform | 66/78 | 4/14 | 0/6 | 14/14 | 13/14 | 4/7 | 4/14 | 3/5 | 8 | 18 | 20 | 11.5 |
| hybrid0.35/granite-107m/recall-document-1/uniform | 44/78 | 5/14 | 1/6 | 14/14 | 10/14 | 5/7 | 5/14 | 3/5 | 6 | 10 | 10 | 11.5 |
| hybrid0.5/granite-107m/recall-document-1/uniform | 45/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 11.3 |
| hybrid0.65/granite-107m/recall-document-1/uniform | 44/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 11.1 |
| hybrid0.2/granite-107m/recall-document-1/version | 44/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 12 | 12 | 11.5 |
| hybrid0.35/granite-107m/recall-document-1/version | 64/78 | 5/14 | 0/6 | 14/14 | 13/14 | 4/7 | 5/14 | 3/5 | 8 | 18 | 20 | 11.4 |
| hybrid0.5/granite-107m/recall-document-1/version | 44/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 6 | 10 | 10 | 11.4 |
| hybrid0.65/granite-107m/recall-document-1/version | 45/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 14 | 14 | 11.6 |
| hybrid0.2/granite-107m/recall-document-1/collection | 45/78 | 4/14 | 0/6 | 14/14 | 10/14 | 5/7 | 4/14 | 3/5 | 6 | 12 | 12 | 11.2 |
| hybrid0.35/granite-107m/recall-document-1/collection | 62/78 | 5/14 | 0/6 | 14/14 | 11/14 | 4/7 | 4/14 | 3/5 | 7 | 15 | 15 | 11.4 |
| hybrid0.5/granite-107m/recall-document-1/collection | 59/78 | 5/14 | 0/6 | 14/14 | 11/14 | 4/7 | 5/14 | 3/5 | 6 | 14 | 14 | 11.4 |
| hybrid0.65/granite-107m/recall-document-1/collection | 58/78 | 4/14 | 0/6 | 14/14 | 11/14 | 4/7 | 5/14 | 3/5 | 7 | 15 | 15 | 11.7 |
| lexical/recall-document-1c/uniform | 38/78 | 8/14 | 1/6 | 13/14 | 10/14 | 4/7 | 8/14 | 2/5 | 6 | 8 | 8 | 7.0 |
| lexical/recall-document-1c/version | 39/78 | 8/14 | 1/6 | 13/14 | 10/14 | 5/7 | 8/14 | 3/5 | 6 | 8 | 8 | 7.7 |
| lexical/recall-document-1c/collection | 39/78 | 8/14 | 1/6 | 13/14 | 10/14 | 5/7 | 6/14 | 3/5 | 5 | 7 | 7 | 7.1 |
| semantic/e5-small/recall-document-1c | 22/78 | 2/14 | 0/6 | 14/14 | 4/14 | 7/7 | 2/14 | 5/5 | 2 | 2 | 4 | 19.5 |
| hybrid0.2/e5-small/recall-document-1c/uniform | 34/78 | 5/14 | 0/6 | 14/14 | 8/14 | 6/7 | 5/14 | 4/5 | 2 | 6 | 8 | 13.8 |
| hybrid0.35/e5-small/recall-document-1c/uniform | 35/78 | 5/14 | 0/6 | 14/14 | 8/14 | 6/7 | 5/14 | 4/5 | 2 | 6 | 8 | 13.6 |
| hybrid0.5/e5-small/recall-document-1c/uniform | 36/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 10 | 12 | 13.7 |
| hybrid0.65/e5-small/recall-document-1c/uniform | 36/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 8 | 10 | 13.8 |
| hybrid0.2/e5-small/recall-document-1c/version | 34/78 | 5/14 | 0/6 | 14/14 | 8/14 | 5/7 | 5/14 | 3/5 | 4 | 8 | 10 | 13.4 |
| hybrid0.35/e5-small/recall-document-1c/version | 38/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 8 | 10 | 13.7 |
| hybrid0.5/e5-small/recall-document-1c/version | 39/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 10 | 12 | 14.2 |
| hybrid0.65/e5-small/recall-document-1c/version | 39/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 10 | 12 | 13.9 |
| hybrid0.2/e5-small/recall-document-1c/collection | 34/78 | 5/14 | 0/6 | 14/14 | 8/14 | 7/7 | 5/14 | 5/5 | 2 | 3 | 5 | 13.4 |
| hybrid0.35/e5-small/recall-document-1c/collection | 37/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 5/14 | 3/5 | 4 | 8 | 10 | 13.8 |
| hybrid0.5/e5-small/recall-document-1c/collection | 40/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 5/14 | 3/5 | 4 | 9 | 11 | 13.8 |
| hybrid0.65/e5-small/recall-document-1c/collection | 41/78 | 6/14 | 1/6 | 14/14 | 10/14 | 5/7 | 5/14 | 3/5 | 4 | 9 | 11 | 13.9 |
| semantic/granite-107m/recall-document-1c | 25/78 | 3/14 | 0/6 | 14/14 | 5/14 | 7/7 | 3/14 | 5/5 | 2 | 4 | 4 | 10.6 |
| hybrid0.2/granite-107m/recall-document-1c/uniform | 36/78 | 5/14 | 1/6 | 14/14 | 7/14 | 5/7 | 5/14 | 3/5 | 2 | 8 | 8 | 10.7 |
| hybrid0.35/granite-107m/recall-document-1c/uniform | 36/78 | 5/14 | 0/6 | 14/14 | 7/14 | 7/7 | 5/14 | 5/5 | 2 | 4 | 4 | 10.8 |
| hybrid0.5/granite-107m/recall-document-1c/uniform | 37/78 | 7/14 | 1/6 | 14/14 | 10/14 | 4/7 | 7/14 | 2/5 | 4 | 10 | 10 | 11.0 |
| hybrid0.65/granite-107m/recall-document-1c/uniform | 37/78 | 7/14 | 1/6 | 14/14 | 10/14 | 4/7 | 7/14 | 2/5 | 4 | 12 | 12 | 10.8 |
| hybrid0.2/granite-107m/recall-document-1c/version | 40/78 | 6/14 | 1/6 | 14/14 | 8/14 | 5/7 | 6/14 | 3/5 | 4 | 8 | 8 | 10.8 |
| hybrid0.35/granite-107m/recall-document-1c/version | 40/78 | 7/14 | 1/6 | 14/14 | 9/14 | 4/7 | 7/14 | 2/5 | 4 | 10 | 10 | 10.9 |
| hybrid0.5/granite-107m/recall-document-1c/version | 40/78 | 7/14 | 1/6 | 14/14 | 9/14 | 5/7 | 7/14 | 3/5 | 4 | 8 | 8 | 10.9 |
| hybrid0.65/granite-107m/recall-document-1c/version | 39/78 | 7/14 | 1/6 | 14/14 | 9/14 | 5/7 | 7/14 | 3/5 | 4 | 8 | 8 | 11.2 |
| hybrid0.2/granite-107m/recall-document-1c/collection | 39/78 | 6/14 | 1/6 | 14/14 | 8/14 | 7/7 | 4/14 | 5/5 | 2 | 4 | 4 | 10.5 |
| hybrid0.35/granite-107m/recall-document-1c/collection | 41/78 | 7/14 | 1/6 | 14/14 | 9/14 | 5/7 | 6/14 | 3/5 | 4 | 8 | 8 | 10.7 |
| hybrid0.5/granite-107m/recall-document-1c/collection | 41/78 | 7/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 8 | 8 | 10.8 |
| hybrid0.65/granite-107m/recall-document-1c/collection | 41/78 | 7/14 | 1/6 | 14/14 | 10/14 | 5/7 | 6/14 | 3/5 | 4 | 8 | 8 | 11.0 |


**No configuration is validated.** Every one fails K3 (at best 8 of 14 positives selected exactly), K4 and K5; only E5's
semantic channel avoids every incompatible delivery and critical false complete (K1, K2), by answering almost nothing (3 of
14 positives): an absence is not a solution. The product keeps a provisional configuration, said as such in
`RecallConfiguration.chosen`: by a rule that reads no final result, the lexical channel (no model file needed) over the
labelled documents with the uniform weighting (the property review F01 asked for), at its development thresholds. Its final
measure is in the first row; it is not safe on new families (six forbidden steps delivered, twelve critical false
completes over the two conditions).

Where the final result is lost, by phase:

- **Candidates are found**: the accepted version is among the first 10 entries for 13 (six lexical configurations) or 14
  of the 14 positives in every configuration; the losses come later.
- **Threshold**: 10 or 11 positives keep an entry over the absolute threshold in most configurations (13 in two, 3 to 9 in
  the more conservative ones); the Italian requests whose inputs are named in Italian are lost here or at binding.
- **Delimitation** (most of the unsafe answers): a trailing episode the need does not ask for is kept when the channel finds
  it relevant on its own (sharing the contact after creating it: 28 of 58 configurations, 27 trim it); a whole cut by a
  constraint is refused when no step of it is relevant on its own (the contact without sharing: 26 select steps 1–5, 31
  answer absent); the first episodes a request names are dropped when the anchor is the episode that takes its values and
  no whole takes more of them (the chart's creation before its export, in the mixed request); a partial request without a
  declared ready input or an observed state gets the whole procedure (adding a song to an existing playlist recreates it in
  53 of 58).
- **Close negatives**: renaming a playlist is answered with steps of its creation by 52 of 58 configurations (51 as
  complete), deleting it (in Italian) with steps of its creation or selection by 30; only the most conservative answer
  them absent.
- **Binding**: inputs named in Italian bind to English parameters only through a shared word (`playlist`).

These are the findings the next round starts from; the final split's cases now count as development, and a correction
needs a new final split of families not seen, as the first comparison's cases became regression here.

## The third comparison

After selector 3 ([RecallSelection](RecallSelection.md)), a new final on families not seen, with the second comparison's
judge (`RecallEvaluationV2Tests`, modes `dev3`, `final3`, `diagnose3`). Records in
`.scratch/brain-memory-recall/corrections2/final3/`.

- **Corpus** `recall-corpus-v3` (sha256 `c0209428169c28e1b1a10828e654a94443761ba727aa49f9efaff9486fbb27b3`): v2's 23
  knowledge items and 90 queries, all development now (their v2 split kept as `v2_split`), and three knowledge items in
  families never queried (Calendar: an event created, then an invitation sent; Photos: an album created and a photo
  added; Keynote: a slide exported as PNG, then sent with Messages). The 24 final queries hold 16 positive needs (5 of
  Italian or mixed requests) and 8 close negatives; 18 are critical. The corpus was written and hashed before any
  selector read it (09:26:24 UTC). It was regenerated once, at 09:39:10, because its first build had replaced Keynote's
  v1 windows instead of adding to them; no query had been selected yet.
- **Configurations**: three, not the 58 again: lexical uniform; semantic Granite; hybrid Granite 0.2 uniform. Grid:
  absolute by 0.01, adequacy {0, 0.02, 0.05}, tie {0, 0.02, 0.04}; stepMargin and partMargin fixed at 0 (selector 3
  reads neither).
- **Criteria**, fixed at 09:27:54 UTC: K1 and K2 as before; K3 at least 12 of 16 positives exact (full); K4 at least 4
  of 5 Italian or mixed positives; K5 at least 12 of 16 on the minimal archives; K6 at least 7 of 8 negatives (full) and
  5 of 6 (minimal); K7 measured.
- **Calibration** on development (90 queries on the full archive and 28 on minimal ones), frozen at 09:40:08 UTC
  (`recall-calibration-v3.json`, sha256 `e1229096d24d4f77af644eca32eb37d8cc17c34bd8e0d2bbd1026ea159082b7b`): lexical 61
  of 118 correct at absolute 0.62, adequacy 0, tie 0.04; semantic 75 at 0.79, 0.02, 0.04; hybrid 76 at 0.68, 0.05, 0.04.

Final at 09:40:22 UTC, release build; every delivery through `memory_task begin` agreed with the service (24/24).

| Configuration | Positives exact (full) | it+mixed | Negatives right (full) | Positives (minimal) | Negatives (minimal) | Incompatible | Critical false complete | Search p95 ms (full) |
|---|---|---|---|---|---|---|---|---|
| lexical/recall-document-1/uniform | 7/16 | 2/5 | 6/8 | 7/16 | 5/6 | 1 | 2 | 14.4 |
| semantic/granite-107m/recall-document-1 | 8/16 | 2/5 | 5/8 | 8/16 | 4/6 | 1 | 2 | 25.4 |
| hybrid0.2/granite-107m/recall-document-1/uniform | 9/16 | 3/5 | 5/8 | 9/16 | 4/6 | 1 | 2 | 30.8 |

**No configuration is validated**: none meets K1–K6, and each delivers one incompatible step and two critical false
completes. The product keeps its provisional configuration. Read after the final (its cases are development since):

- **A defect of the fixtures.** The Photos library window, and in the full archive the Keynote deck window, were not
  recognized as scenes: their steps' entry states are unknown, the episodes uncertain, and the answers honest partials
  (`partial(gaps)`, `unknown_entry_state`). A check of the corpus now lists such versions before a final is frozen:
  `RecallEvaluationV2Tests.unknownEntries`, written into the development report (`unknownEntryStates`) and at the head of
  every diagnosis. On v3 it lists `keynote-slide-message@1` steps 1, 2 (full archive) and `photos-new-album@1` steps 1,
  4, 5 (full and minimal).
- **Three defects of the rules**, all safety failures: the incompatible delivery (a JPEG asked of a PNG export whose
  dialog states were unknown: the rest of the dialog was delivered); a move answered with the creation (values named an
  episode though only the object was shared); and the critical false completes (a short number, "slide 2", was no
  mention, so the slide's selection was left out before its export).
- **Open**: words of context that share a stem with a label ("Cancella l'evento … dal calendario" names the step that
  adds the event to the calendar), and the lexical channel's retrieval misses.

**After the final** (development on cases now seen, not a measure). Six changes, listed with their tests in
[RecallSelection §6](RecallSelection.md#the-third-comparison-and-what-followed), diagnosed in three rounds with
`diagnose3` at the frozen thresholds (`final3/diagnose3-after*/`). Correct development queries of 118 (frozen dev3 →
now); then the final split's counts:

| Configuration | Development | Positives exact (full) | it+mixed | Negatives (full) | Positives (minimal) | Negatives (minimal) | Incompatible | Critical false complete |
|---|---|---|---|---|---|---|---|---|
| lexical | 61 → 65 | 7/16 | 2/5 | 8/8 | 9/16 | 6/6 | 0 | 0 |
| semantic Granite | 75 → 75 | 8/16 | 2/5 | 7/8 | 10/16 | 5/6 | 0 | 0 |
| hybrid Granite 0.2 | 76 → 76 | 9/16 | 3/5 | 6/8 | 11/16 | 5/6 | 0 | 0 |

No configuration delivers an incompatible step or a critical false complete, in any split or condition. The
positives stay under K3–K5 even on these seen cases. Every positive the hybrid configuration still misses is on a version
the corpus check lists. Whether those versions would be right with recognized scenes is not measured: correcting the
frozen corpus would make a new final, not a measure of this one. Deciding the configuration needs a new final on
families not seen, written by someone other than the author, after the corpus check passes, together with the
decisions of [RecallSelection §7](RecallSelection.md#7-decisions-for-review).

## The first comparison (history)

Kept as written on 2026-10-11 with the selector of that day; two references are marked where the code changed since.

Final split, 20 queries (21 needs), every configuration with the thresholds frozen on the development split
(`recall-calibration-v1.json`, sha256 `560fc7ff…29758`, frozen at 19:55 UTC on 2026-10-11 before the final run;
corpus sha256 `83164c0b…1daf00`), release build on an Apple M4. Columns: correct queries on development and
final, final requests in Italian and in English, incompatible deliveries, false complete coverages, warm search
p50/p95 in milliseconds (search only: embedding, scoring, reading the versions), and the inviolable criteria met
or failed. Every configuration answered the four expected absences absent; the candidate recall at 10 was 1.00
everywhere; the deliveries through `memory_task begin` agreed with the service's selections for every query of
every configuration.

| Configuration | Dev | Final | it | en | Incompatible | False complete | Search p50/p95 ms | Criteria |
|---|---|---|---|---|---|---|---|---|
| lexical/recall-document-1 | 16/26 | 13/20 | 3/6 | 10/14 | 0 | 1 | 5.4/6.7 | C1–C5 |
| semantic/e5-small/recall-document-1 | 8/26 | 8/20 | 1/6 | 7/14 | 0 | 1 | 10.6/12.8 | C4,C5 |
| hybrid0.2/e5-small/recall-document-1 | 12/26 | 10/20 | 1/6 | 9/14 | 0 | 1 | 10.6/17.6 | C4 |
| hybrid0.35/e5-small/recall-document-1 | 14/26 | 10/20 | 1/6 | 9/14 | 0 | 1 | 10.4/12.6 | C4 |
| hybrid0.5/e5-small/recall-document-1 | 17/26 | 13/20 | 3/6 | 10/14 | 0 | 1 | 10.6/13.6 | C1–C5 |
| hybrid0.65/e5-small/recall-document-1 | 17/26 | 13/20 | 3/6 | 10/14 | 0 | 1 | 10.6/12.7 | C1–C5 |
| semantic/granite-107m/recall-document-1 | 8/26 | 8/20 | 1/6 | 7/14 | 0 | 0 | 8.6/18.9 | C4,C5 |
| hybrid0.2/granite-107m/recall-document-1 | 13/26 | 11/20 | 2/6 | 9/14 | 0 | 1 | 8.7/12.6 | C4 |
| hybrid0.35/granite-107m/recall-document-1 | 16/26 | 11/20 | 3/6 | 8/14 | 1 | 1 | 8.4/11.7 | C1 |
| hybrid0.5/granite-107m/recall-document-1 | 15/26 | 12/20 | 3/6 | 9/14 | 0 | 1 | 8.2/10.3 | C1–C5 |
| hybrid0.65/granite-107m/recall-document-1 | 16/26 | 12/20 | 3/6 | 9/14 | 0 | 1 | 8.3/11.2 | C1–C5 |
| lexical/recall-document-1c | 14/26 | 11/20 | 2/6 | 9/14 | 0 | 1 | 4.6/6.2 | C4 |
| semantic/e5-small/recall-document-1c | 9/26 | 7/20 | 1/6 | 6/14 | 0 | 2 | 10.6/12.3 | C2,C4,C5 |
| hybrid0.2/e5-small/recall-document-1c | 12/26 | 10/20 | 1/6 | 9/14 | 0 | 1 | 10.5/12.3 | C4 |
| hybrid0.35/e5-small/recall-document-1c | 12/26 | 9/20 | 1/6 | 8/14 | 1 | 1 | 10.6/15.1 | C1,C4,C5 |
| hybrid0.5/e5-small/recall-document-1c | 14/26 | 11/20 | 2/6 | 9/14 | 0 | 1 | 10.3/13.6 | C4 |
| hybrid0.65/e5-small/recall-document-1c | 14/26 | 11/20 | 2/6 | 9/14 | 0 | 1 | 10.4/15.4 | C4 |
| semantic/granite-107m/recall-document-1c | 11/26 | 12/20 | 3/6 | 9/14 | 0 | 2 | 8.1/9.3 | C2 |
| hybrid0.2/granite-107m/recall-document-1c | 13/26 | 11/20 | 2/6 | 9/14 | 0 | 1 | 8.2/9.3 | C4 |
| hybrid0.35/granite-107m/recall-document-1c | 15/26 | 12/20 | 3/6 | 9/14 | 0 | 1 | 8.1/9.5 | C1–C5 |
| hybrid0.5/granite-107m/recall-document-1c | 15/26 | 12/20 | 3/6 | 9/14 | 0 | 1 | 8.1/9.8 | C1–C5 |
| hybrid0.65/granite-107m/recall-document-1c | 15/26 | 12/20 | 3/6 | 9/14 | 0 | 1 | 8.2/9.2 | C1–C5 |

**Chosen: `lexical/recall-document-1`.** Five configurations met C1 to C5 with one unsafe answer and 13 or 12
correct; the lexical channel and the hybrid ones over E5 (w = 0.5 and 0.65) tied at 13/20 with one false
complete, and the preregistered rule takes the simpler channel. It needs no model file, so the Recall works on a
fresh install; the semantic runtime, both models and their indexes stay available behind `BRAUS_RECALL`.

What the result does and does not say:

- The semantic requirement (C4) is met in form only. The lexical channel's three correct Italian requests are an
  absence, a request that names "PDF" and "Pages", and one whose folder name the masking turned into a
  placeholder; no configuration understood Italian requests over English labels reliably (at best 3 of 6 on the
  final split, 3 of 8 on development). The agents' convention was then the mitigation in production (withdrawn since,
  see the agents' convention); a stronger
  multilingual model, or labels written in the person's language, is what the next comparison should try.
- The one false complete of every configuration is `notes-2` ("Create a new note titled Idee in Notes"): the
  first block of the learned procedure, labelled "Create a note titled <note_title> and share it by Mail", is
  proposed whole; the request wanted its first two steps.
- The lexical scale depends on the collection: its scores weigh a word by its rarity in the indexed documents, so
  the absolute threshold calibrated on the corpus does not transfer to an archive of one procedure, where the same
  request is found absent (pinned then by `RecallCycleTests.smallArchiveLimit`, replaced by the invariance test of the
  correction round). The error is safe (nothing wrong is
  delivered) but the Recall does not help a fresh archive until it holds more knowledge. A threshold or a weighting
  independent of the collection's size needs a new comparison, with a new final split.
- The thresholds were chosen to deliver nothing unsafe on 26 development queries; they are conservative, and many
  requests worded away from the learned labels are found absent. The comparison measures the corpus it has, 19
  procedures over synthetic windows; it is not a measure of the knowledge of a real user.

## Measures

On an Apple M4 (10 cores, 16 GiB, macOS 27.0), release build. Reports outside the repository, in
`.scratch/brain-memory-recall/` (`scale/` for the first delivery, `corrections/scale/` for the correction round,
`corrections2/scale/` for the second, `experiment-a/contention/` for the experiment A round).

### Learning to 20,000 procedures again (a3 round, 2026-10-13)

`LearningCostProbeTests` (gated by `BRAUS_LEARNING_PROBE`) learned 20,000 procedures from an empty archive through the
producers, with the staged load's generator (`BRAUS_LEARNING_PROBE_WORDS=load`), the product's configuration owning the
index and a release build, as the staged load below did. Report in
`.scratch/brain-memory-recall/live-r01-corrections/a3-2026-10-13/scale/`.

| Stage | Staged load (D3, `7ee2552`), mean ms a procedure | a3 candidate, mean | a3, p50 of the stage's last thousand |
|---|---|---|---|
| up to 5,000 | 59 | 61.5 | 53.1 |
| 5,000–10,000 | 163 | 71.1 | 56.8 |
| 10,000–20,000 | 378 | 75.9 | 72.2 |

The archive at the end has the staged load's third stage entities (20,000 versions, 100,000 parts, 80,200 documents
each with its vector, 200,000 events, 600 scenes, 800 relations; 2.21 GB), the process at most 255 MB resident. The
growth the staged load met is gone; which change removed it (the index corrections of the D3 rounds, the SQLite
compiled in, the merge) is not separated. Beyond 20,000 nothing was measured, by decision.

The same archive measured again without learning (`RecallLoadTests.reuse`, p50 / p95 / p99): A's whole proposal through
`memory_task begin` 105.8 / 114.0 / 181.0 ms (40 queries); warm searches through the service 119.7 / 134.8 / 152.9 ms
with the hybrid owner and 100.3 / 110.3 / 113.2 ms with the lexical guest, slower than the staged load's corrected
figures (75 and 28 ms at p50), the exact scoring first, for causes not investigated; 140 / 208 / 733 ms while another
producer learns; opening 0.6 s, the first search after it 7.4 s, 1,087 MB resident after it; a rebuild of the whole
catalogue 236 s, the ready generation answering meanwhile at 558 / 1,444 / 2,932 ms.

### The index worker apart from another producer (experiment A round)

`RecallLoadTests` in mode `contention:8` on a copy of the same staged archive (removed after its run; the original's
sha256 the same before and after). Its perimeter and margins were fixed before any run.
- 30 `act` calls run first, with nothing else running.
- Then 8 rounds, in the order paused, active, active, paused, paused, active, active, paused. In each round another
  producer learns 30 procedures while 10 `act` calls are sampled.
- In a paused round the index worker takes no work; the triggers still queue it, and the queue is drained after the
  round.
- Two runs.

| Run | `act` p95, index paused / active | Ratio | Essential writes' queue p95, paused / active | Store time ≥ 1 ms in active rounds: index worker / all |
| --- | --- | --- | --- | --- |
| 1 | 38.4 / 52.2 ms | 1.36 | 18.7 / 43.5 ms | 0.56 / 11.2 s |
| 2 | 37.0 / 44.5 ms | 1.20 | 14.2 / 23.3 ms | 0.49 / 10.9 s |

- **Within the fixed margin.** The index worker's share is within the margin of 1.5 in both runs.
- **What holds the store most.** The learning producer's `memory_task` writes (about 3 s per arm) and the derived Brain
  records (about 2.5–3 s), not the worker.
- **The idle baseline.** Its p95 (80–81 ms) ran right after the copy was opened and migrated. It is higher than the
  producer-alone p95 and not interpretable.
- **One unattributed operation.** In each run one store operation of about 1.1 s happened in a paused round, so not the
  worker's.

### The index in memory during learning, and the act call (second correction round)

`RecallLoadTests` in mode `refresh:<arm>:<rounds>[:scan|tracked]` on a clone (an APFS copy, removed after its run) of the
staged load's archive at its third stage: 20,125 procedures, 100,625 entries of the ready Granite hybrid generation that
owns the index, 600 scenes. The original's sha256 (`fae56cef…`) was the same before and after the campaign. Each run:
30 `act` calls with the index idle, then 3 rounds in which another producer learns 30 procedures while 30 searches
(the service's `prepare` and selection) and 10 sampled `act` calls run. Six runs, in the order whole:tracked,
changed:tracked, changed:scan, changed:scan, changed:tracked, whole:tracked. The perimeter and each claim's margin
were written before the first run (`claims-fixed-before-results.md`, 09:28:22 UTC); a claim is made only if it holds in
both runs of its arm.

- `whole` reads the index again whole at every revision (the behaviour before this round); `changed` reads only the
  versions with index work since the cache's mark.
- `scan` looks for documents without a vector by scanning at every pass of the worker (the behaviour before); `tracked`
  follows the versions the worker wrote, with a whole scan every 600 s.

| Run | Arm | Search p50 / p95 / p99 / max ms | Index phase p50 / p95 | `act` idle p50 / p95 | `act` while the index works p50 / p95 | Whole reads | Reads of changed versions p50 ms | Store operations ≥ 300 ms (vector scans) |
|---|---|---|---|---|---|---|---|---|
| 1 | whole:tracked | 1,646 / 4,336 / 6,180 / 7,420 | 1,541 / 4,174 | 14.2 / 24.4 | 12.4 / 36.5 | 78 | — | 82 (1) |
| 2 | changed:tracked | 166 / 219 / 329 / 472 | 54 / 93 | 12.2 / 16.4 | 13.5 / 60.0 | 0 | 24.6 | 3 (1) |
| 3 | changed:scan | 453 / 1,115 / 1,487 / 1,903 | 285 / 774 | 15.0 / 20.5 | 22.3 / 93.4 | 0 | 37.0 | 143 (140) |
| 4 | changed:scan | 410 / 878 / 1,074 / 1,811 | 40 / 531 | 17.2 / 24.9 | 18.2 / 73.4 | 0 | 24.8 | 84 (81) |
| 5 | changed:tracked | 154 / 235 / 330 / 449 | 48 / 87 | 13.5 / 28.3 | 12.5 / 75.5 | 0 | 24.9 | 4 (1) |
| 6 | whole:tracked | 1,720 / 7,929 / 9,000 / 10,067 | 1,590 / 7,740 | 12.7 / 28.2 | 13.6 / 44.5 | 74 | — | 79 (1) |

- **Claim 1 holds** (the cache kept current by what changed): search p95 during learning 219 and 235 ms against 4,336
  and 7,929 ms read whole (between runs: sd 7.9 ms against 1,796 ms).
- **Claim 2 holds** (tracking the vectors): the `act` call's p95 while the index works is no more than 10% above the
  scan's in both pairs (60.0 against 93.4 ms, 75.5 against 73.4), and the slow vector scans fall from 140 and 81 to 1
  and 1.
- **Claim 3 fails** (non-regression of the essential writes): in changed:tracked the `act` call's p95 while the index
  works is 3.67 and 2.67 times its idle p95 (60.0 against 16.4 ms, 75.5 against 28.3), above the margin of 2. No
  non-regression is declared.

What is measured is the whole `act` call on the session double (its start write, the gesture, perception and tool on
the double, its end write), not one commit: the earlier name "essential commit" was wrong. Two more changed:tracked runs
split it (`act-split/`), p50 / p95 ms, each run:

| Part of the call | Index idle | Index working |
|---|---|---|
| Whole call | 11.9 / 17.7; 14.5 / 23.0 | 14.4 / 42.4; 16.4 / 69.5 |
| Start write, waited (inside the store) | 5.5 / 11.8 (1.2 / 2.4); 7.1 / 10.6 (1.4 / 4.8) | 5.8 / 16.1 (1.3 / 2.2); 4.4 / 43.2 (1.4 / 7.0) |
| End write, waited (inside the store) | 4.8 / 6.7 (2.4 / 3.7); 6.8 / 12.1 (3.3 / 8.3) | 6.0 / 35.9 (2.8 / 28.4); 8.3 / 38.8 (3.0 / 6.2) |
| Rest: gesture, perception, tool, hops | 0.4 / 0.6; 0.4 / 0.5 | 0.5 / 0.7; 0.5 / 0.6 |

The two essential writes are the call's critical path, and under load their tail is mostly waiting for the store, not
work inside it. The store serializes this process's reads and writes; during the rounds its queue holds the learner's
writes (one `memory_task` write took 503 ms) and the index worker's passes. Which of them each wait was behind is not
attributed, and nothing bounds the worker's passes while calls arrive (not built).

**A stall found and removed.** In a trial run one search took 51 s (`smoke6/`, max 51,245 ms). `sample` showed the store's
actor inside `SQLiteMemoryStore.verify(copy:expecting:)`, the integrity check of the daily copy of the archive (2.2 GB).
The check now runs outside the store's actor; `SQLiteSnapshotTests.storeFreeDuringVerification` shows reads and writes
completing while a check is held. The campaign above ran after the fix.

Distance from the target: as for the staged load below. 100,625 parts is the low end of "hundreds of thousands";
procedures (20,125) and states (600 scenes) are one to two orders of magnitude below it.

### The staged load (correction round)

`RecallLoadTests` learned generated procedures through the real producers (the tools over the session double: D1's
facts and Brain, D2's candidates, interpretations and qualification), each with documents of its own (an account in its
object), four steps over two hundred applications, with the Granite hybrid configuration owning the index and the
provisional lexical configuration measured as its guest. The run was stopped after its third stage: learning slowed with
the archive's size (59 ms a procedure up to 5,000, 163 to 10,000, 378 to 20,000; a sample of the process at 10,000 showed
mostly SQLite reads and the Brain's per-application work, which does not separate the causes), and the fourth stage
(40,000) would have taken about four more hours. The same archive was then measured again with the two corrections below (`BRAUS_RECALL_SCALE=reuse`).

| Stage | Procedures (versions) | Parts (entries) | Steps | Distinct documents = vectors | Events | Brain scenes / relations | Archive |
|---|---|---|---|---|---|---|---|
| 1 | 5,000 | 25,000 | 20,000 | 20,200 | 50,012 | 600 / 800 | 0.55 GB |
| 2 | 10,000 | 50,000 | 40,000 | 40,200 | 100,024 | 600 / 800 | 1.10 GB |
| 3 | 20,000 | 100,000 | 80,000 | 80,200 | 200,036 | 600 / 800 | 2.21 GB |

Every part is evaluated once (a qualification each); no part state was written; the scenes and relations stay few because
the generated windows repeat in each application. Distance from the target: 100,000 queryable parts is the low end of
"hundreds of thousands"; procedures (20,000) and states (600 scenes) are one to two orders of magnitude below a target of
hundreds of thousands of procedures and states, which this load does not reach.

Warm searches through the service (`RecallService.prepare` and the selection, 100 queries each, p50 / p95 / p99 in ms):

| Stage | Hybrid, Granite | of which scoring, reading, embedding, selection (p50) | Lexical guest (product's channel) | Bound to one application of 200 | `memory_task begin` with search, record and delivery (40) |
|---|---|---|---|---|---|
| 1, before the corrections | 42.4 / 43.9 / 44.7 | 11.3, 6.1, 2.6, 0.12 | 32.0 / 33.8 / 34.9 | 40.3 / 41.6 / 42.2 | 64.1 / 67.3 / 76.5 |
| 2, before | 93.4 / 97.4 / 97.8 | 23.8, 6.4, 2.6, 0.12 | 74.4 / 78.2 / 78.8 | 89.4 / 108.6 / 119.3 | 163.9 / 171.3 / 201.3 |
| 3, before | 216.9 / 225.7 / 228.2 | 50.2, 15.7, 2.9, 0.12 | 175.1 / 183.3 / 196.8 | 198.7 / 206.2 / 208.0 | 406.2 / 421.6 / 432.2 |
| 3, after | 75.2 / 84.1 / 85.9 | 49.6, 22.3, 2.5, 0.12 | 28.3 / 31.5 / 33.1 | 51.4 / 57.9 / 59.7 | 254.8 / 262.3 / 262.7 |

- **Correction 1, measured by the load**: each query read the index's status by counting the generation's entries and the
  documents without a vector, a cost that grew with the archive (about 150 ms of the 217 at stage 3). The query now reads
  the live generations and the pending work only, and takes the counts from the index it holds in memory.
- **Correction 2**: while vectors were missing, every query read the whole index again; it now reads it again at most every
  2 seconds (the parts still without a vector are scored lexically and the answer says so).
- Every query named a procedure of its own and found it (100 of 100 selected in the query's application, bound or not).
- **During concurrent learning** (50 procedures learned by another producer while 50 searches ran), the searches answered
  but slowly (stage 3, after: 1,686 / 1,721 / 1,902 ms): each new entry moves the generation's revision, and the index held
  in memory is read again whole. An incremental refresh of that cache is not built; the index caught up 0.7 s after the
  writes, nothing pending.
- **Reopening**: opening the archive 191 ms; the first search after it 2,145 ms (the index of 100,000 entries and 80,500
  vectors read, the model loaded); footprint after it 1,052 MB with both the owner's and the guest's index in memory.
- **Rebuild** of the whole catalogue at stage 3: 422 s (vectors reused by document), the ready generation answering
  meanwhile at 599 / 615 / 620 ms.
- **Brain lookups the Recall makes**: the calls of an attempt with their states and elements 0.2 / 0.3 / 0.6 to 3.2 ms, the
  latest observed state of a stream under 0.2 ms, at every stage. Essential commit of a call (5 calls per stage): 2.2 / 3.4,
  4.7 / 101.3 (one call), 2.9 / 6.9 ms (p50 / max).
- **Approximate index**: at 100,000 entries the exact scoring takes about 19 ms lexically and about 50 ms in the hybrid
  channel (the vector part about 30 ms), growing linearly. The provisional lexical configuration stays within the 50 ms
  budget; a semantic configuration at this size needs first the contiguous matrix the kernel measures below (about three
  times faster), then an approximate index past a few hundred thousand vectors. None is built: no semantic configuration is
  validated, and the exact search keeps the perimeter declared.

**The index's cost on learning** (`BRAUS_RECALL_SCALE=ablation:3000`): the same 3,000 procedures learned in three fresh
archives, with no index (a guest of an archive no owner indexes), with the lexical owner and with the Granite hybrid owner;
essential commits sampled on 30 calls, Brain lookups on 6.

| Arm | Learning per procedure p50 / p95 / p99 (mean) | Essential commit of a call p50 / p95 / max | Calls of an attempt with states and elements | Archive |
|---|---|---|---|---|
| No index | 29.4 / 33.2 / 35.0 ms (27.2) | 2.2 / 2.7 / 10.9 ms | 1.82 ms | 294 MB |
| Lexical owner | 30.7 / 40.8 / 295.4 ms (36.4) | 1.8 / 11.5 / 11.6 ms | 1.84 ms | 306 MB |
| Granite hybrid owner | 46.3 / 95.9 / 552.5 ms (61.6) | 2.5 / 14.3 / 15.2 ms | 1.85 ms | 333 MB |

The index's worker does worsen the tails: an essential commit's p95 goes from 2.7 ms to 11.5 (lexical) and 14.3 ms
(hybrid), learning's p99 from 35 ms to 295 and 553 ms; the Brain lookups do not change. The cause is the worker's
transactions and, for the hybrid, its embedding beside the learning; neither is bounded by the learning yet (a smaller
transaction per pass, or index work deferred while calls arrive, are not built). Whether the growth of learning with the
archive's size comes from the index is not separated by this ablation, which stays at 3,000 procedures.

### The first delivery's measures (history)


`RecallScaleTests` and `recall-ann-compare.py`. Load data, not knowledge: 2,000
generated procedures of four steps over forty applications, learned through the tools as tasks are (60 s), 10,000
indexed parts, 4,840 distinct documents, a 217 MB archive with every fact of those tasks.

| Measure | Lexical (chosen) | Hybrid, E5 |
|---|---|---|
| Warm search p50/p95/p99, 40 queries × 5 | 8.5 / 9.0 / 9.5 ms | 20.1 / 22.0 / 25.1 ms |
| of which: embedding, scoring, reading versions, selection (p50) | 0.4, 2.6, 5.1, 0.06 ms | 4.7, 4.8, 5.6, 0.07 ms |
| First search of a process (index read, model load) | 168 ms | 834 ms |
| Index build | settled with the learning | E5: 46 s for 4,840 documents |
| Process footprint after the measures | 673 MB (the E5 model loaded) | |

- **Reading the versions** was 55.6 ms p50 before schema 6's four indexes on schema 3's tables: D2's reads of a
  version by id scanned its bindings, parameter details, contract items and the routes for the version superseding
  it. With them it is 5.1 ms, and the answers of the final split are identical (rerun on every configuration).
- **Exact scoring alone**, random 384-dimension vectors: per entry as the service runs it, p50 0.61 ms for 10,000,
  6.8 ms for 100,000, 69 ms for 1,000,000 (1.5 GB of vectors; p95 609 ms under memory pressure on 16 GiB); one
  matrix-vector product over the same vectors stored contiguously is about three times faster (0.19, 2.5, 22 ms).
  The index cache keeps every vector in memory; ten million vectors are not supported by this design.
- **Approximate index**: usearch HNSW over the same 4,840 E5 vectors finds 97.5 % to 99.3 % of the exact top 48
  (the worst query 85 % to 96 %) in 0.06 to 0.19 ms, where the exact inner product takes 0.21 ms in numpy. At this
  size an approximate index would lose candidates for nothing; it would pay from about 10⁵ to 10⁶ vectors.
- **Models** (one query, after a warm-up; batch of 256 documents): E5-small loads in 717 ms with its weights hashed
  (452 ms without), adds 551 MB, embeds a query in 4.5 ms p50 and 178 documents a second; Granite-107m 610 / 445 ms,
  272 MB, 2.1 ms, 382 documents a second. Both read 512 tokens at most; a longer text is cut and the vector says so;
  no document of the load was cut.

What is not measured here: archives of real users, concurrent writers during a rebuild, and the cost of a whole
task (turns, tokens, retries, connectors) with and without the Recall, which needs live agents.

## Tests and proofs

| Suite | What it proves |
|---|---|
| `LocalEmbeddingReferenceTests` (needs `BRAUS_RECALL_MODELS`) | token ids and vectors equal to Hugging Face's on 18 texts, both models, both roles; a model with a missing or different file is refused |
| `RecallSelectionTests` | episodes, intervals, wholes, absence, gaps, missing parameters, application binding, variants and their ambiguity, a fixed choice the task contradicts excluded, binding rules, masking, on versions built by hand |
| `RecallScopeSelectionTests` | certain conflict, unknown compatibility and missing input kept apart; constraints read clause by clause; episodes the need names and the work before and after them; the observed state cutting a dialog's episode; producers included and ready outputs not repeated; a truly missing input |
| `RecallScopeGuideTests` | the second review's guide cases: a contact created without sharing it, a song added to a playlist that exists, rename, delete and open not taken for create, an observation behind the work the need names, values that name an episode only when one reads them; and the third final's: an exclusion over uncertain episodes, short numbers as mentions, a move not taken for a creation, a label's words recognizing the work, equal proposals ordered by content |
| `RecallProvenanceTests` | an input fed by an earlier output only by its stated origin: a true dependency, a ready output (the input itself or derived from it), contradicted origins, equal values with no relation, two producers of equal file names |
| `RecallSecondReviewTests` | the second review's four counterexamples, expectations unchanged |
| `RecallThirdReviewTests`, `RecallScopeDependencyTests`, `RecallUnaccountedWorkTests` | the third review's counterexamples of scope (F10, F11), expectations unchanged; a producer with unrelated work between it and the selection, in one application and across them, and with related work between; the paraphrase partial with its verb named, the original wording complete, an object written otherwise no gap |
| `RecallProvenanceBoundaryTests`, `TaskReferenceTests` | the third review's counterexample of provenance (F12) through the tool and SQLite; an admitted reference and its version kept through an update and a reopening; unknown, foreign, undeclared and wrongly versioned references minimized; secrets withheld; a checkpoint's and an interpretation's reference to the task being written; the dependency recalled through it |
| `RecallChoiceTests` | the agent's choice on versions built by hand: the shortlist; the paraphrase chosen whole; producer and consumer as two tracts; declarations that cannot override facts; one need uncovered; refused names, ranges, orders, applications, retired steps, superseded versions, certain conflicts and constraints; stale and unknown proposals |
| `RecallChoiceToolTests` | the agent's choice through `memory_task` and SQLite: off unless enabled; a proposal recorded and never delivered as a plan; a choice recorded and delivered; given again, answered unchanged; another plan refused; a refusal that records and runs nothing; stale after a revision, unknown after a resumption; a retired step and a superseded version between proposal and choice; feedback per tract; producer and consumer as two tracts on corpus v4, recorded and delivered; retries (F13): stale after a revision, the recorded receipt in the same revision, refused after a catalogue change, with no new fact; a choice the archive cannot record (R2); on corpus v4, tracts around a conflicting choice refused with its episode and an independent compatible episode reused (R3); variants whose fixed choice must be settled, by a value, the request's words or a quotation, and the ambiguous answer recorded and delivered (R5); the evidence of a choice follows its role (F14): a file name or an unrelated code never settles a format, the request read with values masked, the same on the print scope, a refused plan records no query |
| `RecallUseLinkingTests` | the first review's four counterexamples, now with a valid application and state, and the whole matrix of tools: a call confirms a step only on the same application, state, element and defining arguments with bound values; a row template told by its label; numbers and flags typed as D2 binds them; an undetermined use |
| `RecallScopeTests` | through `memory_task` on the corpus learned by D2's producers: a note created without the forbidden sharing, a constraint not checked carried to the agent, a dialog already open, an input truly missing, an incoherent variant excluded, an input produced by an earlier part and an output already held |
| `RecallSharingTests` | learned by an app worker and recalled by an MCP client through its router, and the other way round; motivated queries; adapted, abandoned and merely declared uses credit nothing undue; another control credits nothing; a field labelled by its value linked by identity; two rows of one item template through the SQL facts (the row named, another row, none named); the query's own revision's values |
| `RecallCacheTests` | the index in memory kept current by what changed equals a whole read after new versions, a superseded version, a retired part and later vectors; a new generation read whole |
| `RecallPerimeterTests` | a rare method in the imposed application read behind sixty more relevant ones elsewhere; the version limit declared as `limited` |
| `RecallOwnershipTests` | a guest configuration never replaces the owner's generation; the control: two owners retire each other's |
| `RecallLifecycleTests` | unavailable and failed are not absence; a part retired between search and delivery is never delivered; a superseded version leaves the index; failing work stays pending and is said; a new space is built while the old generation answers; an interrupted build resumes; a failed build leaves the ready generation; a schema 5 archive migrates and queues one rebuild |
| `RecallCycleTests` | the cycle on the corpus archive through the tools; the first learned procedure recalled on an archive of one procedure; a part's lexical score independent of the archive under the uniform and version weightings, dependent under the collection's |
| `RecallEvaluationTests`, `RecallEvaluationV2Tests` (modes `dev2`, `final2`, `diagnose2`, `dev3`, `final3`, `diagnose3`; the corpus check of unknown entry states), `RecallChoiceEvaluationTests` (mode `choice4`: experiment A with a real agent against the automatic selector on corpus v4), `RecallScaleTests`, `RecallLoadTests` (gated; `refresh:` compares how the index in memory is kept current on a clone of the staged load and splits the `act` call; `contention:` separates the index worker's contention from another producer's) | the comparisons and the measures |
| `SQLiteSnapshotTests.storeFreeDuringVerification` | the store answers reads and writes while a copy is checked; a close then still ends the copy with no file left |
| `verify-memory-schema.py` | schema 6's constraints and triggers, 481 checks of which 403 refuse an invalid row |

All of them run over the session double that replaces only the operating system and the applications. No live
run was made: the cycle on real applications, the reuse between the app and an MCP client on the desktop, and the
ablations of a task's cost remain to be run in a dedicated session.

## Known limits

- **No configuration is validated** by the second or the third comparison (see above): the product's configuration is
  provisional. On the third final every configuration delivered a forbidden step and two critical false completes; the
  rules fixed after it are safe on those cases, now seen, which proves nothing of new families. The Recall's selections are proposals the
  agent checks on the live scene; nothing here is a guarantee.
- **Delimitation** (selector 3) reads the need's exclusive words, the values it mentions, states and declared
  contracts, with the limits of [RecallSelection §5](RecallSelection.md#5-not-decidable-without-new-information): done
  work stated only in words ("the downloaded invoice") names an episode as work; context words that are also an
  episode's words name it, across languages when the stems agree ("calendario"); work before the selection is stated,
  never planned, even when it was needed; synonyms and derivations ("write"/"create", "resize"/"size") name nothing; an
  object word one episode alone holds names it; steps whose entry state was not recorded make the selection partial.
- **Requests in another language than the labels** name no episode in the automatic selection and get nothing, whatever
  the channel finds.
  - The agent's choice, now the product's path, reads them: on development cases 29 of 32 Italian or mixed
    positives exact with Sonnet, against 15 for the automatic selector; on its independent holdout 5 of 5.
  - Its development measure failed the safety and negative criteria; after the review's corrections its independent
    holdout met K1–K6 with Sonnet ([RecallAgentChoice](RecallAgentChoice.md#independent-holdout-2026-10-12)). Haiku
    and Luna, the models of the next live runs, are not measured on it.
- **Producers** are known only from outputs D2's contracts declare, and a consumer only from its stated origin.
  - A `source_ref` of the form `<task UUID>/<output>` is kept only when it names an output that the producer's own task
    declared (`TaskOutputReference`). Otherwise it is withheld as any text.
  - A reference to another producer's task stays withheld.
- **Constraints** are checked against words, not effects; what forbids nothing is carried to the agent, unchecked.
- **The observed state** is the latest observation of the producer's stream within 15 minutes; an older or another
  stream's state is unknown.
- An interval is one version's: tracts of two sources are not joined, and a need the agent does not split is one need.
- The index cache holds every entry and vector of the current generation in memory; the first search of a process reads
  the whole index (5.5 s inside the store at 100,000 parts), and another generation is read whole again. Sizes measured in
  [measures](#measures); a few hundred thousand parts are the measured ceiling, not millions.
- Long reads still hold the store at an open of the large archive: the relation recovery's first pass (2.8–3.1 s) and the
  first whole read of the index; a `memory_task` write of a large interpretation took up to 1.2 s.
- While the index works beside another producer's learning, the `act` call's p95 is 2.7–3.7 times its idle p95, from
  waiting for the store ([measures](#the-index-in-memory-during-learning-and-the-act-call-second-correction-round)).
  - Measured apart ([measures](#the-index-worker-apart-from-another-producer-experiment-a-round)), the index worker adds
    1.2–1.4 times on top of the producer's own contention.
  - The learning producer's writes hold the store far longer than the worker.
  - The worker's passes are still not bounded. The `act` call's tail against an idle store is not interpretable from
    that campaign.
- Only `act` calls were sampled whole under contention; the other tools' calls have only their time inside the store
  measured.
- **The agent's choice** (A, the product's one path) has limits that Engine cannot check:
  - an agent can fill a negative with a generic step of a procedure of another action (the instructions ask it not to;
    Engine sees no conflict in such a step);
  - it can take a tract too wide in a compatible version;
  - a `settled_by` quotation is checked to be the request's words, not to mean the choice.

  Since the review's corrections, a tract around a conflicting step is refused with its episode, and variants with a
  different fixed choice need it settled or the need answered ambiguous.

  Its safety depends on the model ([RecallAgentChoice](RecallAgentChoice.md#measured-development-2026-10-12)).
- Learning through the producers slowed with the archive in D3 (378 ms a procedure at 20,000 procedures); on the a3
  candidate it stays near flat to 20,000 (75.9 ms), with the cause of the change not separated, and nothing is measured
  beyond 20,000 ([the a3 round](#learning-to-20000-procedures-again-a3-round-2026-10-13)).
- Index work is taken by the worker of a process that runs the Recall; a guest process never builds the owner's
  generation.

## What D4 can rely on

- Schema 6's facts: every query with its reason, task revision, generation, channel, search status and coverage; its
  selections, alternatives and exclusions with their versions and intervals; the requirements, bindings by task value name
  and constraints by position; the links of calls to steps with their confirmation or undetermined use; the declared uses
  with their causes. All immutable and kept.
- `RecallService.recall`, `link`, `report` and `status`, `RecallSource` (the version as the selector reads it from the
  authoritative tables) and the index's ownership rule.
- The index is derived: a generation can be rebuilt from the catalogue at any time, in any space.
- Not the selection's quality: the automatic selector's configuration was never validated, and the agent's choice was
  measured on one holdout with one model.
- Schema 7's tables of the agent's choice exist in every archive and are immutable; since 2026-10-13 every search of the
  product records a proposal, and every choice a query.
