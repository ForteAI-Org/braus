# Report Human Interaction: redesign

Status: implemented; the migration in section 6 is complete. The engine lives in
`Sources/SeatBroker/Seat/HumanIntervention*.swift`, with the recorder, the probes and the structural
reader in `Sources/InteractionObservation/`. Section 1 explains why the earlier, action-first report
was replaced; its numbers come from the loss audit (section 10) run on the earlier engine's replay
archives.

## 1. Why a redesign

The earlier report was built action-first: actions were partitioned into threads, a rule decided
a fact type per thread, and a thread was printed only when it had a recognised net outcome. Rules
were added per recording, and each new recording still found a new failure, because the rules sat
on top of three upstream defects that no rule can repair:

1. **Observation**: lists were read only where they were on screen, only through `AXRow` children,
   and a pane another process hosts was not read at all. What was not read cannot be reported, and
   what was not read cannot be told from what was removed.
2. **Identity**: rows were named by their longest text (a date, a preview line, a label with a
   count), the element key included the recognition kind (pixel text against control), and two
   reads only matched when the label was equal. A rename was always "one removed, one added"; rules
   then tried to put it back together.
3. **Interpretation**: an effect reached the report only through a thread that passed the gates,
   and every intermediate state was discarded or, worse, printed as if it were final.

### Audit summary

The audit compares, per archive, (a) the raw differences between each window's first and last
successful reads under the engine's identity, (b) the engine's own intermediate results (for the
earlier engine: delta objects, occurrences, outcomes, threads) and (c) the rendered digest. For two
recorded trials the truths are the person's own account of what they did; for the older archives
they are the replay tests' documented facts, which were partly derived from the reads and so cannot
expose observation losses.

| person truths (two trials) | count |
|---|---:|
| total | 36 |
| reported in the body | 21 (4 of them only as "performed, not verified" claims) |
| intermediate, kept for `human_step` | 2 |
| wrong place (an intermediate state printed as final) | 1 |
| dropped at observation | 8 |
| dropped at interpretation | 4 |
| dropped at identity or rendering | 0 |

The 78 replay-test facts of the older archives are all reported (circular by construction).

| report facts printed (all archives) | count |
|---|---:|
| supported by a raw change of the same kind and subject | 81 |
| unconfirmed: the object is not in the final read (intermediate or unobserved) | 6 |
| distorted: the change exists, the subject or type is wrong | 7 |
| invented: no raw change at all | 0 |
| action claims ("performed, not verified"), no observed effect | 21 |

The 7 distorted facts are what read as invented: `Delete: − All iCloud, 71 notes` (a folder row
whose count went 71 → 70), `No additional text moved after has unread changes` (two note rows
share a preview line), and five note edits named by their own content (the subject of each edit
was the text typed into it).

| raw net changes (all archives) | n | reported | dropped@observation | dropped@identity | dropped@interpretation |
|---|---:|---:|---:|---:|---:|
| tied to a truth | 68 | 68 | 0 | 0 | 0 |
| candidate (a persisting element's value, state, name, title or order) | 28 | 5 | 0 | 1 | 22 |
| list member entering or leaving | 302 | 2 | 273 | 26 | 1 |
| control shown or hidden | 308 | 11 | 296 | 0 | 1 |
| re-read turnover (same label, other key) | 1,441 | 2 | 1,407 | 32 | 0 |
| pixel-only text | 1,332 | 0 | 1,256 | 70 | 6 |
| readout, availability, dialogs and menus | 298 | 0 | 80 | 12 | 206 |
| **total** | **3,777** | | | | |

97% of raw net changes are observation churn the earlier engine had to reject by heuristics. Raw
step changes (each read against the previous read of the same window) number about 56,000, of which
132 are candidates. Of the 23 candidates the earlier engine did not report, 19 are counters in a DAW
(Pro Tools): 17 pointer readouts ("Cursor location" and "Cursor value"), correctly dropped, and 2
that a click moved; 3 are list reorders no rule reported, and 1 is a view-mode radio
(`list view: on → off`) left uncertain while its partner `icon view: off → on` was reported.
Rendering lost nothing: no archive reached the 1,000-byte budget.

### Top causes of loss, by stage

**Observation (8 of 12 person-truth losses, 6 unconfirmed facts, almost all churn).**

1. *Collections were read by viewport, and only through `AXRow`.*
   `AccessibilityAugmentation.harvest` walks `AXChildren` of a table, list or outline, keeps only
   children whose role is `AXRow`, and skips every row outside the clip. A file browser's icon view
   (Finder) is an `AXList` of `AXImage`/`AXGroup` items: in icon view no file was ever in a read, so
   a rename, a folder created and deleted, and a re-sort were unobservable; a final read in icon
   view after work in list view dropped the list rows, so a rename there was "unconfirmed". A note
   deleted from the top of the visible rows left in a way a scroll also explains, so `removedRuns`
   (which needed a surviving neighbour on both sides) could not claim it. In a DAW (Pro Tools) the
   output of a track whose I/O selector is off screen was never read.
2. *Content another process hosts was not read.* A settings pane served by a view service (the
   Displays pane of System Settings) gave the scene "Reduce/Increase Brightness" buttons and pixel
   text, never the slider or its level. Input there was routed to the lend; nothing read the content.
3. *Action reads and the final read were different instruments.* Action reads were text-only
   perception plus AX; the final read was full perception. The same label read as OCR text in one
   and as a control in the other produced 1,441 turnover changes and 1,332 pixel-text changes.
4. *Windows the person typed into were never read.* An in-place rename editor and a note's text
   view are separate windows; the consumer read the lent document.
5. *The archive did not keep read quality.* `CaptureQuality` (walk stopped by deadline, element
   budget, depth) was discarded, so a partial read could not be stated as partial.

**Identity (7 distorted facts).**

1. *Row name = longest descendant text* (`AccessibilityAugmentation.deepestNamed`). File rows were
   named by their date ("27 Oct 2026 at 16:40"), note rows by "No additional text", "has unread
   changes" or "18/10/2026". `HumanInterventionMembership.namingRows` repaired only rows holding one
   editable text field.
2. *A count inside a label was part of the name.* "All iCloud, 71 notes" → "70 notes" is one row
   relabelled; the earlier engine saw one row removed and, after a Delete command, reported it
   deleted.
3. *Labels were keys.* `HumanInterventionIdentity.match` paired two observations only when key and
   label were equal (or a content ID normalised equal). Every rename was remove plus add, every
   duplicate label was remove plus add, and three later rules (`renamedContainers`, `relabeled`,
   `replaced`) tried to recover renames from anchors, other texts or slots.
4. *Content as name.* A note's text area is labelled `Note[id=UUID]`; the earlier engine named it by
   the first line of its value, so the subject of an edit changed with the edit.

**Interpretation (4 person-truth losses, 1 wrong place, 21 claims instead of effects).**

1. *Intermediate consequences were either erased or printed as final.* A track dragged and dragged
   back netted out with no trace; pages visited in between and a note created and deleted left
   nothing in `human_step`; yet edits of notes deleted by the end were printed.
2. *Effects travelled only through threads.* A thread without a recognised outcome was one "Other:
   N threads omitted" (2 to 13 per report), and its effects with it unless the late
   `appendUninterpreted` pass happened to cover their role.
3. *Order changes were not effects.* A re-sort was printed as the menu choice that caused it
   (`Group → Size: performed, not verified`); the order itself was never stated.
4. *A value seen on one side only was never compared* (nil → value), so a field's first content
   was lost unless a creation rule claimed it.

## 2. Firm rules and decisions

Binding for every layer below:

- Generic for any application: no rule names an application, a bundle, a window title or a
  caption in one language. The caption vocabulary (`HumanInterventionVocabulary`) may refine
  wording, never decide a fact.
- English, compact, within the existing budget.
- Never invent: every fact in the body is an observed net effect.
- Every observed net change appears; one no rule recognises appears in neutral `before → after`
  form.
- Unobserved is stated as unobserved, never inferred as unchanged or removed.
- "[withheld]" memory redaction and value minimization are untouched.
- Embeddings never produce, remove or change an effect. They may rank which action caused one.

Decisions:

1. Intermediate consequences (a page visited in between, a folder created then deleted, a value
   tried and reverted) are not in the report body, only in the details (`human_step`). The body
   shows the net state.
2. Each consequence shows only its fact type in the body ("Rename: A → B", "Delete: − X",
   "Window title: A → B"); the causing action (command path, menu, shortcut) lives in the details.
3. Consequences with no attributable action (application or system made) go in a separate final
   group, "Also changed (cause unknown): …".
4. Attribution: deterministic gates produce the candidate actions for each observed change;
   Granite 107m embeddings rank the candidates when more than one remains; below a similarity
   floor the change stays "cause unknown" but is still reported.
5. A count or summary that changed as a consequence of another effect (a collection's item count
   after a deletion) goes to details, not the body.
6. Complete collection reads: 150 ms per read, at most 2,000 members per collection, a `range`
   certificate beyond it.

## 3. Architecture

```
 input events ──► Recorder ──────► actions, each with its target key and probe
                                            │
 lent windows ──► Observation ──► reads: keyed trees, complete collections, coverage marks
                                            │
                  Identity ──────► one subject per object across reads (keys, members, moves)
                                            │
                  Effects ───────► step effects (ledger) and net effects (source of truth)
                                            │
                  Attribution ───► cause and fact type per effect; never adds or drops one
                                            │
                  Rendering ─────► body: net facts by type, "Also changed", "Unobserved"
                                   details: causes, actions, intermediate effects
```

Each layer has one input and one output and is tested on archives alone. Effects is the source of
truth: anything the body says is an effect; attribution and rendering only describe effects.

### 3.1 Observation

A read is a structural accessibility read of a window, independent of the perception pipeline
that builds a worker's scene. It is taken after each action (coalesced by
`HumanInterventionConsumer`, with its scheduling, overlap detection and byte budget) and at
hand-back, with the same instrument both times.

- **Scope.** Every window of the lent process that is on screen (the earlier engine read only the
  action window), plus any window an action targeted (in-place editors, sheets, popovers) while it
  exists. A window closed before its read is recorded as closed, not as read.
- **Tree.** Window → elements with role, subrole, identifier, title, description, value (through
  the existing value guard and minimization), state, enabled, selected, and the parent link. Not
  clipped to the viewport: frames are recorded, and visibility is a property, not a filter.
- **Collections, complete.** For `AXTable`/`AXOutline`: `AXRowCount` when exposed, then `AXRows`
  read in batches (`AXUIElementCopyAttributeValues` with an index and a count), each member read
  with batched messages (`AXUIElementCopyMultipleAttributeValues`) for its name fields and
  `AXIndex`. For `AXList`, `AXGrid`, `AXBrowser` and any container whose children share a role:
  `AXChildren` the same way, whatever the children's role (icon views are `AXImage`/`AXGroup`).
  `AXVisibleRows`/`AXVisibleChildren` mark the viewport. Members carry only what identity needs
  (name candidates, file name or URL, identifier, index); the subtree of a member is read only
  when it is in the viewport or an action touched it.
- **Coverage certificate per collection.** `complete` (all members read and the count agrees),
  `range(first, last)` (members read by index), or `viewport` (the application exposes only what
  is shown: some web and custom toolkits). Removal can be claimed only inside the certified part.
- **Content other processes host.** An element whose `AXUIElementGetPid` differs from the lent
  process (view services, extensions) is read as part of the window, as the semantic probe does.
  If it refuses, its frame is recorded as an **unobserved region** with the hosting process name.
- **Pixels.** OCR runs only for windows or regions without accessibility content (a canvas). Pixel
  text is evidence for wording and for the person to see in details; it never carries identity and
  never produces a lifecycle effect.
- **Quality.** Each read keeps what stopped it (deadline, element budget, depth, a list that did
  not answer), as `CaptureQuality` computes. A partial read says which part is missing.
- **Time box order.** Collections are read as they are found, each with at most half of what the
  walk has left, so one slow list (a settings sidebar of unnamed rows) cannot keep the walk from
  the rest of the window; the walk stops at 85% of the box; field values (text, pop-up choices,
  levels) come last, the focused field and its neighbours first, and the fields left unread are
  counted.
- **Sections, row names, waiting.** A member that is a collection itself (an icon view grouped into
  sections) is read next as a collection of its own and is named only by itself, never by its first
  item. A row without a name of its own is named by the text with a letter its cell shows first in
  reading order, top then left (`AXPosition`), a level deeper when a child is a view holding the
  texts: the tree's order is not the reading order (a note list's row can list its preview before
  the title drawn above it). A structural read waits up to 50 ms per message instead of 5: an
  application still handling the input answers its window list late. On the recorded trials, 10 to
  36% of reads were lost whole at 5 ms, about 1% at 50 ms. The time the walk leaves goes back to
  the collections their share cut short.
- **Reads when nothing moves.** Three structural reads join the one after each action. When control
  passes, a long read (1 s box, larger element and field budgets) runs on its own task beside the
  transition and becomes the "before" of every window it reached (read -1); input during it drops
  it. When the person pauses 0.4 s after a read, the windows are read again and that read replaces
  the one it settles (a settings pane drawn after the read that followed its button). At hand-back
  the first surface of the final read takes the long box. Initial and settled reads travel on the
  final read's provenance; older archives have neither. Each field carries the names of its two
  nearest named ancestors (its track or row), and a control a person sets (a level, a pop-up's
  choice) is compared within its container, named by it only when its name alone is shared; a name
  carrying the value on a second line goes by its first.
- **Levels without a value.** A slider may answer "no value" for `AXValue`, `AXMinValue` and
  `AXMaxValue` and show only its thumb (a brightness slider in System Settings): its level is where
  the `AXValueIndicator` sits along the track, 0 at the start, 1 at the end. Effects compare a
  level control, named and unique in each read, between the first and the last structural read
  that show it, since no scene shows such a level.
- **Unobserved marks** are first-class data: window never read, window failed, region hosted and
  unreadable, collection partial, action target window never read. They flow to Effects unchanged.

The perception pipeline is not changed: its viewport-only, `AXRow`-only harvest is right for a
worker's scene, which must only offer what can be clicked. The structural reader lives in
`InteractionObservation` and reuses `LiveAccessibilityReader`'s primitives.

### 3.2 Identity

Identity turns a sequence of reads into subjects: one per object, stable across reads, renames,
scrolls and re-sorts.

**Element key**, first available wins:

1. `AXIdentifier`, when it is unique in the window and stays on the same element across reads
   within the episode (generated identifiers such as `_NS:188` qualify only if they keep their
   element; this is checked, not assumed).
2. A document identity the element exposes: `AXFilename`, `AXURL`, `AXDocument` (the probe reads
   `AXFilename` on file rows).
3. For a collection member: its **name field**. In order: the member's single editable text
   field (the cell an in-place rename edits), the cell of the first column (`AXColumn` index 0),
   the member's own `AXTitle`/`AXDescription`. Never the longest text.
4. A structural path: window, then each ancestor's role and identifier or title, then the
   element's role and its ordinal among siblings of that role. Collection members contribute
   their member key, never their row index.
5. Pixel text: no key. It cannot be matched, so it cannot be renamed, created or deleted.

The recognition kind (text, control) is not part of the key, so the same element read by two
instruments is one subject.

**Name and decoration.** A member's display name keeps its letters and drops counts and state
markers that change while the rest stays (`All iCloud, 71 notes` is the member `All iCloud` with a
count 71 → 70; `Selected. Audio 13` is `Audio 13` selected). The count is a value of the member,
so a count change is a value effect, not a lifecycle.

**Content as name.** When an element's only label is an identifier (`Note[id=…]`), the identifier
is its key and its display name comes from its collection member (the note row), never from its
own value.

**Tree diff.** Per window, subjects are matched by key. Per collection, members are matched by
member key; the longest increasing subsequence of shared members (`HumanInterventionScene.reordered`)
separates moves from stable members; a re-sort is a reorder where more than a quarter of the
members change rank and the new order follows one column (the column header's `AXSortDirection`
names it when exposed). Inside a complete or ranged collection, a member present before and absent
after is removed; inside a viewport-only collection it is "no longer seen", which is not an effect.

**Which collection continues which.** A named collection, the only one of its role, name and
identifier in both reads, continues that one. Unnamed ones (a web page's lists) continue the
earlier collection they share the most members with, and none when they share none: matched by
order, one untouched web page claimed 58 additions and 17 removals. A collection holding sections
states its sections as a value (`icon view groups: none → Folders, Documents`) only when every
section was read as a collection of its own. Such a change to a collection as a whole names no
member, so its cause is the one candidate that committed a choice nobody could represent (the
menu's "Kind"), when there is one; and since an application may draw it after the read that
followed the choice, that read's actions stay candidates.

**Scroll and virtualised lists.** A complete read makes scrolling irrelevant. A viewport-only
collection keeps its membership as "seen so far" and never claims a removal or a creation from
a member entering or leaving the viewport.

### 3.3 Effects (source of truth)

An effect is neutral and observed:
`(window, subject key, kind, before, after, first read, last read, coverage)` where kind is one of
appeared, disappeared, renamed, value, state, moved, re-sorted, window opened, window closed,
title. Coverage says whether the subject's region was complete, ranged or viewport in both reads.

- **Step effects** compare each read with the previous read of the same window. They form the
  ledger, in time order, with the actions the read covers.
- **Net effects** compose a subject's step effects from its first observation to its last:
  appeared then disappeared is nothing; A → B → A is nothing; A → B → C is A → C; a move and a
  move back is nothing; a rename and a move are both kept.
- **Intermediate effects** are step effects whose net is nothing or different: a page visited in
  between (title A → B → C), a folder created then deleted, a value tried and reverted. They stay
  in the ledger for `human_step`, never in the body (decision 1).
- **Noise is decided here, by evidence, not by application.** A live readout is an element whose
  value changes in a read whose covering actions neither touched it nor its container.
  Availability flips, selection and focus markers, and controls that appear or disappear outside
  a collection are interface state. All of them stay in the ledger and in details, counted, not in
  the body.
- **Unobserved.** A net effect whose subject sits in an unobserved region is "unobserved", and an
  action whose target is in an unobserved region produces an "unobserved" entry even with no
  effect.

### 3.4 Attribution (many to many)

Attribution links effects to actions. It adds a cause and refines the fact type. It never adds,
removes or changes an effect; if it finds no cause, the effect is still reported.

**Commands.** Actions are grouped into commands before linking, by structure only:

- a menu bar item, its submenus and the item chosen; a secondary-click menu and its item;
- a button or menu item that opens a surface (sheet, dialog, popover), the parameters set on it,
  and the control that closes it (default, cancel, Return, Escape);
- consecutive typing bursts, Return and editing shortcuts in one field;
- a drag (one action, source and destination);
- every other action alone.

These are the thread rules of `HumanInterventionThreads` without the earlier outcome gates: a
command is structure, not a claim of success.

**Candidates (deterministic gates).** For each effect, the candidate commands are those that

1. happened after the read before the effect's first read and before that read's capture (the
   action and read intervals recorded in `HumanActionProvenance` and `HumanReadProvenance`);
2. acted in the effect's window, or in a surface they opened that closed onto it;
3. touched the subject, its member, its container, or the field that had focus while typing; or
   are a command whose closing control closed the surface the effect followed.

Gate 3 is a preference, not a filter: if no command passes 1 to 3, those passing 1 and 2 remain
candidates.

**Ranking.** One candidate: it is the cause. Several: Granite 107m
(`ibm-granite/granite-embedding-107m-multilingual`, pinned for the report in
`HumanInterventionEmbeddings.manifest` and read from the shared models folder, whatever channel or
model the Recall uses; it takes no query or passage prefixes) ranks them by cosine between the
command text (path, target label, surface title) and the effect text (kind, subject, values); the
best wins when it passes a floor calibrated on the replays for this model (0.72); otherwise the
cause is unknown. Vectors from any other model id or revision are not ranked: causes from
embeddings stay "unranked", a log line says why, and the body is unchanged. The model used is
recorded in details and in the replay archive. No candidate: cause unknown.

**Fact type.** Comes from the effect kind (disappeared → "Removed", appeared → "Added", renamed →
"Rename", moved → "Move", value and state → the control's name, title → "Window title"). A
command's vocabulary may refine a compatible type ("Delete" for a disappearance caused by a
command whose caption means delete), never contradict it: a move caused by anything stays a Move,
so a move can never be printed under a Delete.

**Cases:**

| case | body | details |
|---|---|---|
| one action, several consequences (a menu command deletes three rows) | one fact line per type: `Delete: − A, B, C` | the command once, with its three effects |
| several actions, one consequence (menu → submenu → item; typing in bursts) | one fact: `Output: Output.L (Mono) on Audio 2` | the command, its path and each action |
| a consequence that does not survive (page visited, folder created and deleted, value tried and reverted) | nothing | the step effects in time order under their command |
| an action with no consequence (navigation, scroll, a click on the background) | nothing | counted in the footer, listed on request |
| a consequence with no attributable action (a counter, a brightness key outside the window) | `Also changed (cause unknown): Brightness: 40% → 75%` (values illustrative) | the effect, its reads, "no candidate" or "below floor" |
| an action whose effect could not be read (hosted pane, list part not read) | `Unobserved: Brightness (pane hosted by another process)` | the action and the unobserved region |

### 3.5 Rendering

Body, in this order, within 1,000 bytes:

```
<Application> — <document window title>
<fact type>: <operands>.            one line per fact type, net effects only
Also changed (cause unknown): …     net effects without a cause
Unobserved: …                       touched regions or targets that could not be read
Details: human_step (<N> actions, <M> without an observed change).
```

The operand interning (`HumanInterventionStrings`), the minimization and withholding pass and the
compaction levels stay. Compaction drops values before names and names before facts, and when the
budget still overflows it ends with "+N more changes in details", never with a silent omission.
Changes with no known cause are counted first, before any caused change loses a value, so noise
cannot turn a search the person typed into a bare "changed".
There is no "Other: N threads omitted" line: actions are not facts, and their count is in the footer.

Example bodies for three sessions (wording illustrative):

```
Finder — Downloads
Rename: Report draft.pdf → Report.pdf.
Re-sorted: Downloads by Size.
View: list view → icon view.
Details: human_step (…).

Notes — All iCloud
Delete: − Shopping list.
Details: human_step (…).            the counts that followed (All iCloud 70 → 69…) are in details

System Settings — Displays
Window title: Software Update → Displays.
Brightness: <before> → <after>.                    if the hosted pane reads
Unobserved: Brightness (pane hosted by another process).   if it does not
```

Details (`human_step`) lists per step the action, its command, the step effects under it (the
intermediate ones included) and per effect its cause and the candidates it beat.

## 4. Invariants

Checked by tests on every archive and, in debug builds, after every digest:

1. **No fact without an effect.** Every fact line in the body maps to one or more net effects.
2. **No effect without a line.** Every net effect that is not noise is in the body, in "Also
   changed", or counted in "+N more changes in details".
3. **Unobserved is stated.** Every action whose target window or region was not read appears under
   "Unobserved"; no effect is derived for a subject outside a certified collection part.
4. **Attribution is conservative.** Removing the attribution layer leaves the same set of effects
   in the body (only types and grouping change).
5. **Net means net.** No body fact names a subject that the final read shows in its earlier state,
   or does not show at all while its region was read completely.
6. **Determinism.** With embeddings disabled the body is identical; only causes in details may
   fall to "unknown".
7. **Subjects are names.** No body subject is a bare count, time, date or state marker ("6 notes",
   "15:18", "Yesterday at 14:04", "Shown."): counts are a member's value, markers its state, and a
   row labelled by a time goes by the first other text it shows.
8. **No rename chain.** No name is renamed onward in one window (A → B with B → C): that is what
   positional keys produce when rows shift. A member's name change is a rename only with evidence
   (the same stable identifier or document, or an in-place editor the person typed into and closed);
   otherwise it is a removal and an addition.

## 5. Components

| file | now | why |
|---|---|---|
| `HumanInterventionRecorder`, `HumanRecordedInteraction`, `HumanInteractionSource`, `HumanInteractionReading` | kept | input capture is sound; the action already carries its target element and probe |
| `InteractionSemanticProbe`, `InteractionSemanticSnapshot`, `NativeInteractionSemanticReader` | kept, extended | target, focus and selection at action time, plus the target's element key |
| `HumanInterventionConsumer`, `HumanSceneFinding`, `HumanReadProvenance`, `HumanIntervention` store | kept, read instrument replaced | scheduling, coalescing, overlap and byte budget stay; findings carry structural reads |
| `HumanInterventionReplay` | version 3 | archives carry structural reads and quality; earlier versions are not read |
| `HumanInterventionStrings`, `HumanInterventionEmbeddings`, `HumanInterventionVocabulary` | kept | interning; Granite 107m ranks causes instead of grouping threads; vocabulary only refines a type |
| `HumanSceneReading` / `NativeHumanSceneReader` | rewritten | a structural reader replaces text-only perception for action reads |
| `HumanInterventionIdentity`, `HumanInterventionChanges` | rewritten | keyed matching without label equality or recognition kind; `HumanInterventionChanges` keeps the step grouping of details |
| `HumanInterventionScene` | new | what the ledger reads off a scene: names, dialogs, members, row texts, row naming by the edit field or first text, reorders |
| `HumanInterventionEffects` | new, replaces `HumanInterventionDelta` | step and net effects; no creation evidence, removal bookkeeping, dialog-parameter capture or lifecycle reconciliation |
| `HumanInterventionThreads` | rewritten as commands | structure kept (menus, dialogs, typing, drags); conclusions and inclusion gates removed |
| `HumanInterventionAttribution` | new, replaces `HumanInterventionLinks` | gates, then Granite 107m ranking per effect |
| `HumanInterventionEvidence`, `HumanInterventionSummary` | rewritten | from effects; budget and compaction skeleton reused |
| `HumanInterventionDetails` | rewritten | per step: action, command, step effects, causes |

### Removed paths

- `HumanInterventionDelta` (interpretation, objects, occurrences, outcomes) and
  `HumanInterventionLinks`.
- The Membership guesses (`removedRuns`, `replaced`, `relabeled`, `followsNames`, `columns`,
  `namingRows`, `name(ofRow:)`): they existed only to guess what complete keyed reads state. The
  increasing-run reorder survives in `HumanInterventionScene`.
- The thread gates (`Inclusion`, `select(outcomes:)`, `included`).
- `HumanInterventionReplayAudit`: the loss audit supersedes it.
- `HumanInterventionSurfaces`, folded into the commands as `HumanInterventionThreads.Surfaces`: which
  window each action worked on, which actions were choices on a surface an earlier action opened.
  The opener relation is gate 2.
- Archives older than version 3, their replay tests and the per-recording rules that pinned their
  wording.

A command is unobserved when it committed what no reading represents and no effect is attributed
to it (`Root.isOpaqueCommit`).

Carried from the old interpretation into the ledger, generic: live readouts (a number that moved
without input able to set it, or while the person typed into another field; a value whose latest
change came with no input), the value a person left in a field they typed into, a typed field that
appeared during the session (empty before), a window's first non-empty title, the input-overlapped
mark, the order changes were first seen in, a structural arrival or departure timed across reads
that read the list in part, and, for a member added or removed, the command whose meaning matches
as the preferred cause.

Replaying the archives with structural reads after the removal left most reports identical. The
differences: a deletion is stated as `Delete` with its cause instead of `Removed`; a deletion that
had been guessed from the visible rows of a list without row names is no longer claimed, and the
counts that moved are stated unobserved; a browser tab that appeared and was deselected no longer
reports a state change; and where each effect has two candidate commands, none certain, more
actions are counted without an observed change.

## 6. Migration, in steps each verifiable on the replays

Every step kept the full suite green and ran the loss audit before and after. Steps 1 to 4 needed
no new recording; step 5 needed a new trial set and was verified on it, then on every older
archive.

1. **Effects ledger in shadow.** Step and net effects built from the archives' existing scenes,
   with the earlier identity, and the invariant checker. The report unchanged.
   *Verify:* the audit's raw net counts equal the ledger's; invariant 1 holds (0 invented).
2. **Body from net effects.** The body rendered from net effects with fact types, "Also changed"
   and the footer count; intermediate effects go to details; threads only name causes.
   *Verify:* intermediate-note facts leave the body (wrong place 1 → 0); a drag and drag back and
   the pages visited in between appear in details; every person truth reported before is still
   reported.
3. **Attribution.** Commands from the thread structure, gates, Granite 107m ranking with a floor
   calibrated so that every person truth gets the person's action as cause.
   *Verify:* causes match the trial notes; with embeddings off the body is identical.
4. **Identity on existing data.** Recognition kind out of the key; counts and markers as values;
   rows named by their name field; identifier-labelled elements named by their member; pixel text
   without identity.
   *Verify:* re-read turnover and pixel-text lifecycle effects drop to zero in the ledger; a
   folder row's item count is a value effect, not a deletion; distorted facts 7 → 0.
5. **Observation v3.** Structural reader, complete collections with certificates, hosted content,
   target windows, quality and unobserved marks; archive version 3. The trial set covers an icon
   view rename, create, delete and re-sort; a note created, written and deleted; a brightness
   change in a settings pane; a track output on an off-screen track; two browser pages and a search.
   *Verify:* every truth of the new set is reported or stated unobserved; no older truth regresses
   on replay (old archives keep their viewport certificate, so they cannot claim more than before).
6. **Delete the old path** (section 5, Removed paths); port the tests.
   *Verify:* full suite and the audit on all archives.
7. **Cheaper action reads.** Drop OCR from action reads where the structural read covers the
   window (section 9).
   *Verify:* identical ledger on the new trial set and lower per-read latency in the live log.

## 7. Expected impact, per audited loss

| loss (audit) | before | after | step |
|---|---:|---|---|
| person truths dropped at observation | 8 | 0 to 2 lost; the rest reported or stated "Unobserved" | 5 |
| ... icon view: rename, folder | 2 | 0 (icon-view children read) | 5 |
| ... folder created and deleted (intermediate) | 1 | 0: in details once the list is read | 5 |
| ... note removed at the edge of the visible rows | 1 | 0 (complete list) | 5 |
| ... brightness in a hosted pane | 2 | 0 if the view service exposes AX, else stated unobserved | 5 |
| ... track output on an off-screen track | 2 | stated unobserved unless the track's I/O is in the AX tree off screen | 5 |
| person truths dropped at interpretation (all intermediate) | 4 | 0: in details by decision 1 | 2 |
| intermediate states printed in the body | 1 | 0 | 2 |
| distorted facts | 7 | 0 | 4 |
| unconfirmed facts | 6 | 0 on new archives (complete final read) | 5 |
| claims instead of effects | 21 | 0 in the body; effects (re-sort, view mode) where observed | 2, 5 |
| candidates not reported, other than readouts | 4 | 0: every net effect has a line | 2 |
| re-read turnover and pixel lifecycle churn | 2,773 | 0 in the ledger | 4 |
| list members entering or leaving | 302 | only certified removals and additions | 5 |

Rendering had no loss and is not expected to gain. The budget stays: the largest audited report is
542 bytes; the new body carries fewer words per fact (no command path inline).

## 8. Risks

- **Cost of complete reads on very long collections** (a Downloads folder of 10,000 files, a
  mailbox). Mitigation: batched member reads, a per-read time box, a member cap per collection
  (2,000), `range` certificates beyond it. A capped list never claims removals outside its range.
- **Applications that expose only visible members.** They get `viewport` certificates and the
  report says less rather than guessing; the earlier interior-gap rule (`removedRuns`) could return
  as a weaker, explicitly labelled signal if needed.
- **View services that refuse accessibility.** Stated unobserved; the person sees the gap.
- **Unstable identifiers.** Identifiers are keys only after they prove stable within the episode.
- **Privacy.** Whole lists mean more names in memory and in the archive. Member reads keep names,
  file names and identifiers only, through the existing value guard, minimization and byte budget;
  field values are handled as before. Withholding is unchanged.
- **Main thread.** Structural reads run on the accessibility walk queue as perception's harvest
  does; an audit of the main thread found the harvest behind most hangs, so the time box is
  mandatory.
- **Ownership.** No change to Perception; the structural reader is a separate component in
  `InteractionObservation`.
- **Worker-visible change.** Body lines change shape (no inline cause, new groups) and
  `human_step` changes content; the worker prompt that explains the report must match.
- **Attribution mistakes.** Possible, but they only change a cause in details; the body's facts
  do not depend on attribution (invariant 4).

## 9. Cost and latency

Measured on the earlier engine (live logs of two recorded trials):

| stage | earlier engine |
|---|---|
| action read | 215 to 365 ms: capture 70 to 220, OCR 80 to 110, AX 66 to 124 |
| semantic probe per action | up to 100 ms (capped) |
| final read at hand-back | 0.68 to 1.79 s (`beginReview`) |
| evidence and digest | 0.05 to 0.40 s |
| embeddings | 15 to 27 ms for 2 to 6 threads |

Expected:

- **Action read:** structural read within a 150 ms time box. At 0.06 to 0.09 ms per message
  (measured) and two to four messages per member, the box holds about 400 to 1,200 members;
  a 150-item folder or a 60-track session takes 20 to 50 ms. Without OCR on accessible windows
  an action read becomes cheaper.
- **Final read:** the same instrument over every lent window: about the earlier figure, minus OCR.
- **Effects and identity:** hashing by key, linear in elements; well under the earlier 0.4 s.
- **Attribution:** one Granite 107m embedding per effect and per command with more than one
  candidate, batched: tens of texts at about 4 ms each (measured), so 40 to 150 ms in the worst
  audited case, off the main thread before the worker resumes.
- **Archive size:** members as names and keys add tens of KB per read, within the existing
  256 MB intervention budget.

### Action reads without OCR where structure covers

The structural read runs right after capture, before perception. When it reached the action's
window, that read's scene is perceived with native facts only (no OCR); otherwise, and at
hand-back, OCR stays. Replaying the recorded archives with every OCR-only element (text with no
accessibility role) removed from the action reads of covered windows left every report and every
ledger identical, while 8% to 70% of the elements went.

On the recorded trials, median perception per action read fell by about half (for example
276 → 152 ms in System Settings, 310 → 170 ms in Notes, 205 → 96 ms in Finder). Where the scene's
own accessibility pass, not OCR, takes about 1 s (Pro Tools) it fell less, 1487 → 1160 ms. The
whole read stays about the same, since the structural read (about 130 ms) now runs inside it.

## 10. The loss audit

`Tests/SeatBrokerTests/HumanInterventionLossAuditTests.swift` runs only with
`BRAUS_REPORT_AUDIT=1`:

```
BRAUS_REPORT_AUDIT=1 BRAUS_REPORT_AUDIT_OUT=/path/audit.md \
CLANG_MODULE_CACHE_PATH=/tmp/mecum-emb-module-cache /usr/bin/swift test --disable-sandbox \
  --no-parallel --filter HumanInterventionLossAuditTests
```

`BRAUS_REPORT_AUDIT_ONLY=<archive>,<archive>` narrows the run to the named archives;
`BRAUS_REPORT_AUDIT_VERBOSE=1` adds every net change with its disposition. Per archive it prints
the report, a truth table (reported, details only, stated unobserved, dropped), the ledger's net
changes by disposition (effect, intermediate, noise and its reason) and the effects. It checks the
budget, invariants 5, 7 and 8, that every net change is accounted for, the attribution model and
invariant 6. New trials need only their truths added to `LossAudit.truths`; the truths are audit
judgements and never move into the engine.

## 11. Input on hosted panes, and reads while the person pauses

A pane another process serves (an extension inside a settings window) takes input under that
process, which has no window of its own. Such input counted as the lent application's only when the
lent window was the front one under the pointer; a screen recorder's overlay, at a higher layer and
passed through by the input, hid it, and the change the person made there went unreported. Windows
above the lent one at a higher layer no longer count. Such a pane also answers slowly: the read
while the person pauses gets 0.5 s instead of an action's 0.15 s, and stops as soon as input arrives.
