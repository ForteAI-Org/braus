# Braus restyling: integration into the real app

Date: 22 October 2026. Branch `elio/app-restyling`, researched at `1408b917`.
Spec: [Design.md](Design.md), [Plan.md](Plan.md), `.superpowers/sdd/Plan/round-2-direction.md`.

Goal (the person): merge the restyling into the real app to test it properly, make sure it works with everything that
existed before without breaking the system, then bring it to `main`.

> **Phase R done (22/10):** one shell now. The house is the only team window; the switch, the old
> shell and the mockup are gone (see "Phase R" at the end). Sections 1 to 6 describe the integration
> as it was planned and carried out, with two shells side by side.

Principle: **two shells over one engine.** The restyled window (`HouseShellView`) and today's (`TeamShellView`) both
read the one `TeamModel`; a setting picks which one a team window shows. No change under `Sources/` (engine, Seat,
transports). App-layer additions only: a few `TeamModel` methods, one optional SwiftData column, two read-only
accessors. The mock mockup stays reachable with `BRAUS_RESTYLING=1` for design work.

All paths below are under `BrausApp/App/Braus/` unless they start with `BrausApp/` or `Sources/`.

---

## 0. Before anything: sync with `main`

`origin/main` is 3 commits past the branch base `39aa712c` (`5d929436` unified automation and procedural memory,
`f4f74105`, `58b126ec`). It changes files both shells use:

| File on main | What changed | Conflict with the branch |
|---|---|---|
| `BrausApp.swift`, new `BrausEntry.swift` | `@main` moves to `BrausEntry` (LaunchIsolation); TeamWindowView gets `channels`, `chromeProfiles`; Settings gets `chromeProfiles` | branch's `BehaviourPreview` / `RestylingMode` branches in the `WindowGroup` |
| `Views/Team/TeamWindowView.swift` | `channels`, `chromeProfiles` passed to `TeamModel` | none today; Phase 1 edits it |
| `Model/AppPreferences.swift` | `usesPersonalChrome`, `chromeProfiles`, `channels` | branch added `restyling.*` keys |
| `Views/Conversation/ConversationComposer.swift` | accessory becomes an `HStack` | branch added `height:` to `ConversationModelButton` |
| `Views/Inspector/InspectorBrowserSection.swift` | personal Chrome and paired profiles | the mock `HouseWebSection` copies the old one; its footer "never yours" becomes false |
| `Model/TeamModel.swift` | channels, chrome profiles (+217) | Phase 2 adds methods (kept in a separate file to avoid this) |

The branch itself already touches these real files (re-verify after merge, flag off): `BrausApp.swift`,
`Core/SeatReleasingDelegate.swift`, `Model/AppPreferences.swift`, `Model/AppPreferenceValues.swift`,
`Views/Conversation/ConversationModelButton.swift`, `Views/Inspector/InspectorTurnSection.swift`,
`Views/Inspector/WorkerInspectorView.swift`, `Views/Settings/SidebarSettings.swift`,
`Views/Team/TokenCounterButton.swift`, `Views/Team/ToolbarUsageCapsule.swift`, plus four `Restyling*` colour sets.

---

## 1. Mock → real mapping

### 1.1 The house and its workers

| Mock (file) | Field / call | Real source | Gap / decision |
|---|---|---|---|
| `MockHouse` | `workers` | `TeamModel.rows` (`TeamOutline.rows` over `active`, stable store order) | none |
| | `archivedCount` | `team.archived.count` | the house's archive button is inert; needs a list (P1) |
| | `mostUsed` | nothing | ring only (paused); deferred |
| | `add(name:role:shape:)` | `team.createWorker(name:role:instructions:appearance:selection:)` | needs a `shape:` parameter (P5) |
| | `suggestedShape(seed:)` | keep, over the live workers' shapes | none |
| `MockWorker` | `id`, `name` | `WorkerSnapshot.id`, `.name` | none |
| | `role` | `WorkerSnapshot.role` (optional) | empty role → the hero shows the name only |
| | `status` | derived, see 1.2 (`HouseRoster`, new) | the real app stores no status, by design |
| | `activity` | `team.activity(of:)` ("Using Pro Tools", "Waiting for the computer (2 ahead)") | gap: no plain-language current task; the open conversation can use the running tool phrase (`TranscriptWording.toolStep`, P8) |
| | `subtitle` | busy/waiting → activity, else role; `TeamRow.toConfigure` ("Needs Setup") | none |
| | `category` | nothing | ring only; deferred |
| | `shape` | new `Worker.shape: String?` (P5); nil → `WorkerShape.derived(from: id)` | persisted, see §4 |
| | `badge` | `TeamRow.needsAttention` → `.attention`; `TeamRow.badgeText`/`unread.replies` → `.unread(n)` (hidden when `sidebarShowsUnreadCount` is off; `99+` cap) | none |
| (missing) | screen light | `team.hasScreen(id)` | renderer gap: `screenStrength` keys off `status == .busy`; needs its own input (I1b) |
| (missing) | accessibility label | `TeamRow.accessibilityLabel` | use it in live mode |
| `MockAccount` | monogram, Sign Out | none in the public repo (account gate is private) | public build: no account in the foot |
| `SidebarMode` | rooms/rows | `AppPreferences.restylingSidebarMode` (exists) | show the picker when the new look is on |

### 1.2 Room status from real worker state

First match wins.

| Real condition | `WorkerStatus` | Brows | Light |
|---|---|---|---|
| archived | not a room (archive list) | — | — |
| `team.needsConfiguring(worker)` | `.off` | offline | moonlight |
| provider state ∈ {`credentialMissing`, `notInstalled`, `credentialRejected`} | `.off` | offline | moonlight |
| an adapter approval waits in the worker's conversation (P8 accessor) | `.waiting` | asking | blue |
| `team.isAnswering(id)` (turn or compaction) | `.busy` | working | amber; screen light only while `hasScreen` |
| `unread.replies > 0` and not answering **[Q1]** | `.waiting` | asking | blue |
| otherwise | `.free` | idle | green |

Transient connection states stay free (the inspector says what is wrong). A failed/stopped unseen turn is the `.attention` badge, not a fifth light. Hero: `.listening` while the draft has text and the worker isn't answering; `preparation` on the rising edge of `isAnswering`; activity = running tool phrase (P8) ?? desktop activity ?? "Working" while answering, else subtitle.

### 1.3 MockTeam → TeamModel

| `MockTeam` | Real |
|---|---|
| `selection(of:)` / `select(_:for:)` | `worker.configuration` + `team.configure(_:selection:)` on popup close |
| `catalogue(for:)` | `team.connections.catalogues[provider]`, `modelsUnavailable(for:)` |
| `changeProvider(of:to:)` | `team.changeProvider(of:to:)` with the consent dialog |
| `isAnswering`, `isCompacting` | `team.isAnswering(id)`, `team.isCompacting(id)` |
| `lastTurn(of:)` | `team.latestTurn(of:)` |
| `usage(of:)` | `team.usage[id]` |
| `compact`, `startFresh` | `team.compactContext(of:)`, `team.startFreshContext(of:)` |
| `compactIfFull` | drop (TeamModel compacts at 90% at turn end) |
| `connectionStates`, `readyConnections`, `check` | `team.connections.states`, ready count, `connections.refresh(_:)` |
| `showsBrowserWindow` | `team.showsBrowserWindow(in: conversationID)` — per conversation; after the main merge also personal Chrome/profiles |
| `showsUsage`, `showsContext` | `team.showsUsage`, `team.showsContext` |

### 1.4 MockConversation and MessageQueue → TeamModel + transcript

| Mock | Real |
|---|---|
| `messages`, `ChatTranscriptView` | `TranscriptController` over `team.transcriptSource` via `TranscriptHost`, as `WorkerConversationView` |
| `send` / `compose` / `post` | `team.draft` + `team.send()` (queues while answering) |
| `isAnswering`, `phase` | `team.isAnswering(id)` (reading vs working not distinguished) |
| `turns` | rising edge of `isAnswering` |
| `quote` | `team.draftQuote` (set by `controller.onReply`; persisted with the draft) |
| `queue` | `team.queue`, `shownQueuedIndex`, `showNextQueued()`, `sendQueuedNow()`, `removeShownQueued()`, `editShownQueued()` (real can edit) |
| `stopTurn` | `team.stopAnswering(id)` |
| simulated tool line, thinking | real tool steps and `ThinkingBlobView` |

### 1.5 Mock views that copy real ones

| Mock view | Real view in live mode |
|---|---|
| `HouseComposer` + `HouseComposerField` | `ConversationComposer` → `ComposerBar(chrome: .house)` (P2) |
| `QueueStrip`, `QuoteStrip` | `ConversationQueueStrip`, `ComposerStrip` (restyle later, M1) |
| `HouseUsageCapsule` | `ToolbarUsageCapsule` |
| `HouseNowSection` / `HouseModelSection` / `HouseWebSection` / `HouseScreenSection` + `HouseMockScreen` | `InspectorNowSection` / `InspectorModelSection` / `InspectorBrowserSection` (main's) / `InspectorScreenSection`, `WorkerScreenCard`, `WorkerScreenView` |
| `MockScreenView` in `WorkerScreenWindowController` | `WorkerScreenView(team:workerID:place: .window, isPaused:)` (P7) |
| `HouseNewWorkerSheet` (fixed connections) | same sheet fed by `team.connections`, creating through `team.createWorker` (P6) |
| `HouseArchiveButton` (inert) | archive popover over `team.archived` with `WorkerCommands` (P1) |
| `HouseFoot` Sign Out | not in the public repo |

---

## 2. Integration strategy

1. **One window root, two shells.** `TeamWindowView.content` shows `HouseShellView(team:isInspectorRequested:)` when the new look is on, else `TeamShellView`; same `TeamModel`, scene storage, launch/failure/opening states, quit handling, approvals, MCP, Team menu.
2. **The switch.** `AppPreferences.newLook = "restyling.newLook"`, default `false`, via `AppPreferenceValues`; a toggle "New Look (Preview)" in Settings > General; launch argument `-restyling.newLook YES` for test runs; changing it swaps the shell live; dark appearance while on, nil when off; `BRAUS_RESTYLING=1` keeps the mock mockup.
3. **Thin adapters, no engine changes.** `HouseRoster` (`Model/Restyling/HouseRoster.swift`): pure function `TeamModel → [HouseWorker]`, status rule as a static testable function. Live shell uses the real views directly; `HouseWorker` is the value both sides produce.
4. **Walking skeleton first.** `HouseShellView` first shows the house sidebar over real workers with today's `WorkerConversationView` and `WorkerInspectorView`; each Phase 2 ticket swaps one area.
5. **Old UI frozen.** With the flag off every ticket leaves unchanged: `BRAUS_SNAPSHOTS=1` PNGs vs baseline; `BRAUS_CLICK_CHECK=1`, `BRAUS_WINDOW_CHECK=1`, `=copy`; full `BrausTests`. Shared views only gain parameters defaulting to today's behaviour.
6. **To `main` behind the flag, default off.** Flip the default and delete the old shell in later PRs.

### 2.1 Feature parity checklist

| # | Feature (old UI) | New look | Ticket |
|---|---|---|---|
| 1 | Workspace open / failure / opening | shared | I3 |
| 2 | Selection and inspector request restored | same storage | I3 |
| 3 | Window minimum, two-step division, sidebar never hidden | `HouseSplit` + `RestylingWindowLayout` | I2 |
| 4 | Search by name and role; `sidebarShowsSearch` | `.searchable` + ⌘F, `TeamRow.matches` | P1 |
| 5 | Show model names setting | deferred (no model in rows by design) | — |
| 6 | Unread / attention badges | `HouseBadgeView` | P1 |
| 7 | Up/Down, Return to composer, click focuses | rows OK; rooms need arrow keys | P1 |
| 8 | Compact sidebar | one-column rooms / compact cards | done (verify) |
| 9 | Archive list, restore, delete, open archived | archive popover | P1 |
| 10 | Worker context menu (Stop, Release Computer, Choose Provider…, Archive/Restore, Delete…) | `WorkerCommands` + Edit Worker… | P1 |
| 11 | Team menu | same focused scene value | I3 |
| 12 | Providers footer with ready count | inspector Model `Providers…` + Team menu | P3 |
| 13 | New Worker (+, ⌘N) | `HouseNewWorkerSheet` live | P6 |
| 14 | Connections, Mac Access, first launch | same sheets; `FirstLaunchView` when empty | I3 |
| 15 | Delete dialog, problem alert, adapter approvals | same modifiers | I3 |
| 16 | Transcript (markdown, tools, paging, selection, copy, ⌘R, reading position, text settings…) | same controller under the hero | P2 |
| 17 | Empty conversation state | same | P2 |
| 18 | Composer (Return/⌘Return setting, Shift-Return, IME, Stop ⌘., Release, Needs Setup, draft save) | same with `chrome: .house` | P2 |
| 19 | Slash commands and popovers | same | P2 |
| 20 | Queue strip (next, Send Now, edit, remove) | same (house look later) | P2 / M1 |
| 21 | Reply strip | same (house look later) | P2 / M1 |
| 22 | Model popup | same | P2 |
| 23 | Toolbar usage ring + counter | same item | P4 |
| 24 | Screen toggle, floating, enlarged | inspector card + own window; floating/enlarged kept | P4 / P7 |
| 25 | Inspector sections | live house inspector (Worker editable + real sections) | P3 |
| 26 | Choose Provider… opens inspector | same | I3 |
| 27 | Worker header in toolbar | the hero | P2 |
| 28 | Rename / edit role | inspector Worker section (new) | P3 + P5 |
| 29 | Notifications | deferred | — |
| 30 | Snapshot / window checks | keep on old shell; add house snapshot | P9 |
| 31 | Light appearance | dark only (design); old UI keeps light | I3 |

---

## 3. Phases and tickets

Rules: one worktree and branch per ticket from the current integration head, owning only its listed files; build/test through the workspace with `-derivedDataPath`; run with `BRAUS_APP_SUPPORT_DIR` scratch/copy; never write the person's `dev.forte.Braus` defaults; stop only your own PID; no synthetic events. Acceptance always includes "old UI unchanged".

### Phase 0 — sync (serial)
**I0 Merge `origin/main`.** Resolve §0 conflicts; flag-off snapshot baseline in `.scratch/integration-baseline/`; tests green except a known list; mockup and plain launch both open.

### Phase 1 — the seam (serial)
- **I1** Rename `MockWorker` → `HouseWorker`, `MockBadge` → `HouseBadge`; add `usesScreen`.
- **I1b** Screen light as its own input (`RoomLightUniforms.screenLit`).
- **I2** `HouseSplit` extracted from `RestylingWindowView` (generic split, division, toolbar, backgrounds).
- **I4** `HouseRoster` + tests (can run beside I2).
- **I3** The switch and the walking skeleton: `newLook` setting, `TeamWindowView` picks the shell, `HouseShellView` with house sidebar over real workers + real conversation/inspector, all `TeamShellView` modifiers copied, selection mapping (pointer pick → composer focus).

### Phase 2 — areas in parallel (disjoint files)

| Ticket | Owns | Depends on |
|---|---|---|
| **P1 Sidebar live** | `HouseSidebar`, `HouseRoomsGrid`, `HouseRowsList`, `HouseRoomCell`, `HouseWorkerRow`, `HouseArchiveButton`, `HouseFoot`, new `HouseArchivePopover` | I3 |
| **P2 Conversation live** | `ComposerBar` (+`Chrome`), `ConversationComposer` pass-through, new `Live/HouseLiveConversation.swift`, composer tests | I3 |
| **P3 Inspector live** | new `HouseWorkerSection`, `HouseInspector`, new `Live/HouseLiveInspector.swift` | I3, P5 |
| **P4 Toolbar live** | new `Live/HouseLiveToolbar.swift` | I3 |
| **P5 Shape persistence** | `Worker.swift`, `WorkerSnapshot.swift`, `WorkspaceStore+Workers.swift`, new `TeamModel+Workers.swift`, `WorkerShape.swift`, migration tests (+ frozen `StoreShapeV6`), `WorkerEditTeamTests` | I0 (can start first) |
| **P6 New worker live** | `HouseNewWorkerSheet` (closures), `NewWorkerSheet.startingAppearance` internal | P5 |
| **P7 Screen window live** | `WorkerScreenWindowController`, `ScreenEnlargement` (`.window`) | I3 |
| **P9 House snapshot** | new `Core/Checks/WindowSnapshots+House.swift` + 1-line hook | I3 |

Only P2/P3 touch shared real views.

### Phase 3 — motion and signals on real data
- **P8 Signals:** `AdapterApprovals.waitingScopes` → waiting; `TranscriptController.runningStep` for the hero.
- **M1 Flights on the real transcript:** frame hook + hold row hidden until landed; restyled queue/quote strips over the real queue API (with Edit).
- **M2 Worker switch on real data:** leaving side keeps the hero and a cached transcript image.
- **P10 Performance pass:** decision 17 (cost table per mode; cull off-screen rooms; cap memory).

Until M1/M2 the new look sends without the flight and switches with the hero motion only (explicit deferral).

### Phase 4 — sign-off and main
1. The person runs §6.3 on both shells with a copy of the workspace, then the real one.
2. PR to `main` with the flag default off; before it, a separate small PR with P5 only.
3. Later: default on; remove the old shell.

---

## 4. Persistence

| Data | Where |
|---|---|
| Worker shape | new `Worker.shape: String?` (case name) → `WorkerSnapshot.shape` (nil → derived from id) — the only schema change |
| Sidebar mode | `restyling.sidebarMode` (exists) |
| New look | `restyling.newLook` (new; launch argument for tests) |
| Category, most used | none (deferred) |
| Behaviour, camera, gaze | derived, nothing stored |

Constraints: one schema, lightweight inferred migration (store backed up before upgrade); not inside `WorkerAppearance`; stored as `String`, never an enum column, never in a `#Predicate` (macOS 26 failure); `WorkerChange.shape(String?)`; migration test with frozen `StoreShapeV6`. **Downgrade risk:** an older build may refuse the upgraded store — test on a copy until P5 is on `main`, land P5 first as its own PR, verify on macOS 26.

---

## 5. Risks

| Risk | Mitigation / check |
|---|---|
| Metal rooms with many workers (eager grid, pulse + body frames: ~11 MB per busy RT room) | P9 30/60-worker snapshots; P10 cost table; cull off-screen rooms; idle CPU < 1%, no hitch > 16 ms |
| Live updates re-render rooms | re-render only on status/shape/occupant/screen change; test that a subtitle/badge change requests no render |
| Streaming transcript | unchanged real controller |
| Selection timing | single source `team.selection` |
| Focus / keyboard | pointer pick → `focusRequest`; check Tab, ⌘F, ⌘R, ⌘., ⌃⌥⌘I, ⌘+/− |
| Accessibility | `TeamRow.accessibilityLabel`, selected trait, actions; VoiceOver pass |
| macOS 15 vs 26 | existing gates; M1 runs precomputed |
| Dark-only appearance | set back to nil when the flag is off |
| Window minimum / inspector | `RestylingWindowLayout` rule; parked layout edge cases stay open |
| Branch still moving | freeze visual merges during Phase 0–1 or rebase Phase 2 branches |
| Chrome profiles from main | live mode uses the real browser section |

---

## 6. Test plan

### 6.1 Unit
`HouseRosterTests`; `WorkspaceMigrationTests` (+ `StoreShapeV6`); `WorkerEditTeamTests`; `RoomLightingTests` (screen follows `usesScreen`, no render on subtitle change); composer tests over both `ComposerBar.Chrome`; `newLook` preference default off; all restyling suites stay green on mock data.

### 6.2 UI flow checks
`BRAUS_SNAPSHOTS=1` old shell vs baseline (flag off) and house PNGs (P9); click and window checks on the old shell; in-process probes for the house.

### 6.3 Manual checklist (copy of the workspace first: `-restyling.newLook YES` with `BRAUS_APP_SUPPORT_DIR` = a `ditto` copy)
1. Workers in order; room colours match reality.
2. Select by click (composer focus) and arrows (sidebar keeps it); Return → composer; ⌘F by name and role.
3. Send: saves, answers, room amber and back, hero says what it does.
4. While answering: queue (next, Send Now, Edit, remove); Stop ⌘.
5. Reply (hover, ⌘R); quote shows, reveal works, sent bubble carries it.
6. Slash commands `/model`, `/usage`, `/context`, `/compact`, `/observe`.
7. Model/effort in composer; provider change with consent; Providers… opens connections.
8. Ring and counter popovers; compact; start fresh.
9. Worker using an app: Computer row, screen light, screen card, own window, enlarge, Release Computer.
10. Unread and attention badges set and clear.
11. New Worker with shape; rename, role, shape in the inspector; relaunch keeps them.
12. Archive, restore, delete from context menu and Team menu.
13. Adapter approval: sheet + blue room (after P8).
14. Resize: sidebar compacts before the inspector closes; nothing jumps.
15. Quit with a draft: restored.
16. Switch back to the old UI: same data; switch again.
17. Reduce Motion, Reduce Transparency, VoiceOver.
18. M1 (macOS 26): precomputed, idle CPU < 1%, team of 30.

---

## 7. Mockup-only pieces
Mock data (`MockHouse`, `MockConversation`, `MockTeam`, `MockAccount`, `MessageQueue`, `MockScreenView`, `HouseMockScreen`) stays for `BRAUS_RESTYLING=1`, previews and tests. House copies of real views stay mockup-only; delete or run the mockup on `WindowSnapshots.syntheticTeam` later. `BehaviourPreview` kept. Closed-app surfaces still paused. Composer `+` placeholders hidden in live mode. Sign Out only in the private repo.

---

## 8. Questions for the person
1. Blue = "needs you": pending approval only, or also unread replies?
2. Off = moonlight: Needs Setup / missing model / disconnected provider? Archived never a room?
3. Activity line until P8: desktop text ("Using Pro Tools") or "Working" — enough for the first test?
4. First test without the send/quote/queue flights and the full worker switch (M1/M2 later) — acceptable?
5. To `main`: behind a setting defaulting to off, with the shape column landing first as its own PR — OK?

### Answers (the person, 22/10)
1. Blue = pending approval **and** unread replies.
2. Off = needs setup, missing model or disconnected provider; archived workers are never rooms.
3. (activity line) the desktop text / "Working" is fine for the first test.
4. First test without the flights and the full worker switch on real data: yes, they come later (Phase 3).
5. **Not to `main` yet:** everything is integrated and tested in this branch; bringing it to `main` happens later, together, under the person's supervision. So no separate P5 PR now — the person tests the new look on a **copy** of the workspace (`BRAUS_APP_SUPPORT_DIR`) until then, because an older build may not open a store upgraded with the shape column.

### Correction (the person, 22/10, evening)
"Keep the old UI" meant **stability**, not the old look: the new look must work as reliably as the old one did. The product is the restyling only. The old shell stays in the branch **only as a regression oracle while integrating** (flag-off snapshots, the old views' tests). **Final phase R (after Phase 3 and P10, before the person's test):** remove every reference to the old UI — `TeamShellView` and the views used only by it (old sidebar, header, rows, old inspector container, old conversation container), the `restyling.newLook` switch, its Settings toggle and launch argument, the `ComposerBar.Chrome.standard` look (`.house` becomes the only look), dark-only appearance always on, and the snapshot/click/window checks pointed at the house. There is no way to switch between the two UIs in the final version. Real shared components the house uses (TranscriptController, ConversationComposer behaviour, Inspector sections, WorkerCommands, sheets) stay. The mockup (`BRAUS_RESTYLING=1`, mock data) stays as a design tool unless the person says otherwise.
- (same day) **The mockup goes too:** at the very end, remove `BRAUS_RESTYLING`, `RestylingMode`, `RestylingWindowView`, `BehaviourPreview` and every mock-only type and view (MockHouse, MockConversation, MockTeam, MockAccount, MessageQueue, MockScreenView, HouseMockScreen, the house copies of real views such as HouseComposer/HouseComposerField/HouseUsageCapsule/HouseToolbar/HouseNowSection/HouseModelSection/HouseWebSection/HouseScreenSection/ChatTranscriptView), keeping only what the live house uses; tests move to the live types or the synthetic team.

### Phase R (done, 22/10)
- **One shell.** `TeamWindowView` always shows `HouseShellView`. `restyling.newLook`, its Settings toggle and the
  `-restyling.newLook YES` launch argument are gone; Settings > Sidebar always offers Rooms and Rows. The delegate sets
  `NSApp.appearance` to dark Aqua at launch, so every window, Settings included, is dark; the Debug menu's Appearance
  picker went with it.
- **Old shell removed:** `TeamShellView`, the old sidebar (`TeamSidebarView`, header, footer, archive, rows, search
  field, blocks), `WorkerConversationView`, `WorkerHeaderView`, `ConversationTitleBarEdge`, `WorkerInspectorView` (its
  turn reading is now `InspectorTurnSection.Reading`), `InspectorIdentitySection`, `ShellChrome`, `NewWorkerSheet`
  (its starting appearance moved to `HouseNewWorkerSheet`), `MascotPalettePicker`, `MascotView`, `View.edgeBar`,
  `TeamRow.badgeText`, and `ShellMetrics`' old division rule (the house divides with `RestylingWindowLayout`).
- **One look:** `ComposerBar.Chrome` and `TranscriptStyle.Look` are gone, with the old pill, its glass buttons and
  surfaces (`RoundGlass`, `ComposerSurface`), the old strips (`ComposerStrip`, `ComposerStripCancelButton`,
  `ConversationQueueStrip`), tails on bubbles, the day label's rules and the worker-coloured thinking blob.
- **Mockup removed:** `BRAUS_RESTYLING`, `RestylingMode`, `RestylingWindowView`, `BehaviourPreview`, the mock data and
  every house copy of a real view; `BubbleFlight` keeps only the stage, the quote's flight and the timings the live
  flights share. Tests that exercised mock behaviour went; the rest run on `HouseFixture` (a list of `HouseWorker`s)
  or real teams.
- **Checks on the house:** `BRAUS_SNAPSHOTS=1` draws only dark pictures, the house windows as `house-*.png`; a room's
  plaque, seen in perspective, is composited in place (`render(in:)` ignores perspective). `BRAUS_CLICK_CHECK=1`,
  `BRAUS_WINDOW_CHECK=1` and `=copy` host `HouseShellView`. The click check no longer clicks a header or a Connections
  footer the house does not have, and leaves the rooms' arrow keys to `HouseSidebarTests`, since Tab reaches the rooms
  only with Full Keyboard Access.
- **Window chrome:** the house window's title bar is transparent (`TransparentTitleBar`); without it AppKit drew a grey
  strip behind the conversation's toolbar once the transcript's scroll view was in the column.

