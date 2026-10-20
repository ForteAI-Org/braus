# Braus restyling: design

Date: 20 October 2026. Branch: `elio/app-restyling`, from `main` at `39aa712c`.

This document records what the restyling brainstorm decided. A builder who knows
SwiftUI, AppKit, Core Animation and Metal should be able to plan the work from it
without going back to the person who decided it. The interactive prototypes in
[`prototypes/`](prototypes/) show every surface; open
[`prototypes/index.html`](prototypes/index.html) in a browser. They are HTML
approximations: timings, shapes and colours are meant literally, the rendering
technique is not.

Each decision carries a tag:

- **[decided]**: chosen in the brainstorm.
- **[proposed]**: proposed during the brainstorm and accepted without objection.
  It can be revisited without reopening the rest.
- **[later]**: its interface is designed now and its behaviour arrives later.
  The mockup shows the control; nothing has to work behind it.

## Intent

Braus today reads as a standard messaging app or a standard agent tool: a
column of rows, a conversation, a formal inspector. The restyling changes the
feeling, not the workflow. Braus becomes a house and the workers are its
butlers, each with a room. The app should feel light, alive and premium, with the
conversation between the person and one worker at the centre and everything else
quiet.

Two things carry that feeling. Every component is finished to a premium level
(dark glass, satin metal, rounded forms with sharp cuts like the wordmark), and
everything moves (Core Animation and Metal, never decoration for its own sake).
The UX stays the macOS UX: Human Interface Guidelines, standard window
structure, standard keys.

When Braus is closed it lives in the menu bar and offers four new surfaces: the
ring, the task bar with its window, the worker's screen window and the voice
bubble.

## Scope

**Goals**

- A graphic mockup inside the app of every surface below, driven by fake data.
- Animations at production quality, built with Core Animation, with Metal for
  light, glass and waves.
- The real app structure (sidebar, content, inspector) kept, so each part can
  later be wired to the engine one at a time.

**How the mockup sits in the app** [decided, from "the work is only graphic, a mockup; once approved things get attached gradually"]:
the restyling is built beside the current views, behind a switch, on fake
data. Outside the switch the app looks and behaves exactly as today until a
piece is approved and swapped in. The new surfaces (menu bar, ring, task
window, screen window, voice) exist only in mockup mode until then.

**Non-goals**

- Wiring the mockup to the engine, the Seat or the providers. That follows
  approval, piece by piece.
- Braus choosing which worker gets a voice request, taking control of the
  worker's screen, or speaking to the worker from that window. These are [later].
- New providers, settings pages or onboarding.

**Anti-goals**, which would make the work a failure even if it ran:

- A UI that breaks macOS conventions: custom window chrome, no Esc, focus taken
  from the person's app, controls that VoiceOver cannot reach.
- Animation that costs CPU at rest. The app already watches idle CPU; a mockup
  that burns it is not approvable.
- Information shown twice. The model lives only in the composer and the worker's
  name only once on screen.
- Status noise: no state on successful messages, badges only for errors or
  attention, no counter that is always on.

## Constraints

- Follow [CONTRIBUTING.md](../../../CONTRIBUTING.md), [CodeStyle.md](../../../CodeStyle.md)
  and the app's folder layout (`Views/<view>/parts`, `Components`, `Model`,
  `Extensions`, `Core/Checks`).
- Animation: Core Animation (`CALayer`, `CABasicAnimation`,
  `CAKeyframeAnimation`, `CASpringAnimation`) wherever it reaches; Metal for room
  light, sphere shading, glass and the voice waves; SwiftUI animation only where
  Core Animation cannot reach.
- Room light: Metal hardware ray tracing on Macs that have it (M3 and later);
  light precomputed on the GPU, as in games, on the others. The second path must
  not cost per-frame work beyond compositing.
- Testers run macOS 26; this Mac runs 27. Both must render the mockup.
- Reduce Motion replaces every travel, morph and bounce with a cross-fade or a
  cut. Reduce Transparency replaces glass with an opaque material of the same
  tone. Every control has an accessibility label.
- The app builds only through the workspace, always with `-derivedDataPath`.
- Dark only [decided]. The app drops its light appearance; every material here
  is specified for dark.
- No new dependencies.

## Where things are today

| Surface | Code today |
|---|---|
| Window shell, sidebar, inspector split | `BrausApp/App/Braus/Views/Team/TeamShellView.swift` |
| Sidebar rows, compact tiles, archive, providers footer | `Views/Sidebar/` (`TeamSidebarView`, `WorkerRowView`, `TeamSidebarFooter`, `TeamSidebarArchive`) |
| Inspector sections | `Views/Inspector/` (`WorkerInspectorView` and its sections, `WorkerScreenCard`) |
| Conversation, composer, model popup | `Views/Conversation/` |
| Mascot | `Components/MascotView.swift`, `Model/Workspace/MascotDrawing.swift`: a coloured ball, no brows yet |
| Menu bar item, global shortcut, floating panels | none yet |

## Shared materials

Colours, as RGB:

| Token | Value | Use |
|---|---|---|
| Busy | 255, 176, 72 (amber) | a worker that is working |
| Free | 48, 209, 88 (green) | a worker that is available |
| Waiting | 120, 170, 255 (blue) | a worker that needs the person |
| Off | no light | a worker that is not running |
| Brow | #F5F5F7 | brows, Offline brows #6E6E6E |
| Ground | #050505 to #0B0B0C | window background, radial lift at the top |

The status colours are [proposed]; their meaning is [decided].

- **Dark glass**, for the ring, the task bar, the task window and the menu-bar
  menu: a vertical gradient from near-black at the top to a lighter grey at the
  bottom, a strong background blur, a 1-pixel inner edge light and a soft
  outer shadow (as macOS Spotlight).
- **Satin metal slab**, for inspector blocks: a dark diagonal gradient with an
  edge light and a highlight on the top edge, 22–24 pt radius.
- **Mascot sphere**: the ibrows sphere (dark radial gradient), tinted with the
  worker's own colour from its persisted appearance [decided], so workers stay
  recognisable by colour; the brows stay white and the status stays in the
  light. It receives the light of its room: a sharp specular highlight at the top and a thin bounce
  light at the bottom in the room's colour, never a diffuse glow.
- **Shapes**: round forms with sharp cuts, after the wordmark. Pills and
  capsules for controls.

## 1. The house: the open app

Prototype: `prototypes/casa.html`.

**Structure** [decided]. A normal macOS app as today: sidebar, content, and an
inspector that opens from the toolbar. The `+` for a new worker stays beside the
traffic lights. The toolbar holds only the Screen and Inspector group, top
right. The worker's name is not repeated in the title bar, because the worker
already sits at the top of the conversation.

**Sidebar, two modes** [decided], chosen in Settings [decided]:

- **Rooms.** A floor plan of the house, one room per worker; the first room
  spans two columns. Two columns when the sidebar is wide, one when it is
  compact. Each room is lit by its worker: a radial light from the worker
  across floor and walls, and a contact shadow under the sphere. Busy light
  flickers gently (3.4 s cycle); waiting light breathes (2.2 s). Off rooms are
  dark. No LED edge [decided].
- **Rows.** One row per worker, 52 pt: the sphere with its status light behind
  it as a halo, the name, the activity line, and at the trailing edge the
  attention mark or the unread count. In the compact sidebar each row becomes a
  tile with the sphere and the name.

In both modes:

- The selected worker leaves its room and comes to the top of the conversation.
  Its room stays empty with its door lit and the label «è da te» [proposed]; in
  Rows the selected row is highlighted.
- Search (⌘F) sits at the top of the sidebar [proposed].
- The archive is the last item: a closed "cellar" room in Rooms, a last row in
  Rows [proposed].
- Unread replies and attention are a mark on the room or row corner
  [proposed], following the existing rules: a symbol for a failed or unseen
  turn, otherwise the unread count.
- The providers footer leaves the sidebar [decided]; see the inspector.

**Content** [decided]. The worker sits at the top centre, small (56 pt),
animated, with its name and its current activity under it (for example «sta
esportando l'AAF»). The conversation below has more air. The composer is the
glass pill with, from leading to trailing: `+` (attachments, web, show the
Chrome window [proposed]), the field, the model and effort pill, the context
ring, send.

**Inspector** [decided]. Only two satin slabs:

- **Screen**: the worker's live screen. Shown only while the worker has a
  window to watch.
- **Provider**: the worker's provider, how it answers, and its connection,
  with a dot only when the connection has trouble. Under it, a row «Tutti i
  provider · 3 pronti» opens provider management [decided].

Everything else the inspector shows today moves or goes [proposed, the
placement as a whole was accepted]:

| Today | After |
|---|---|
| Identity (mascot, name, role) | the worker at the top of the conversation; role on hover of the name |
| Status (Answering, Idle) | room or row light and the brows |
| Compacting Context | the context ring on the composer |
| Computer activity | the line under the worker's name |
| Show Chrome Window | the composer's `+` menu |
| Last turn (model, start, result) | removed: the result is in the conversation, the time on hover of a message |
| Model and effort | only in the composer, never in the inspector |

**Empty state** [proposed]. With no worker selected the content shows a small
lit floor plan, «Nessun worker scelto» and «Scegli una stanza per parlare con il
suo worker»; the inspector says the details appear when a room is chosen.

## 2. The ring

Prototype: `prototypes/anello.html`.

Braus closed lives in the menu bar [decided]. When the last window closes the
app keeps running and its Dock icon disappears; opening a window brings it back
[decided]. A global shortcut opens the ring
over whatever app is in front [decided]. The prototype uses ⌥Space; the real
combination is open (see Open points).

**Form** [decided]. One continuous ring of dark glass, thick (about 82 pt wide
on a 370 pt diameter), like Spotlight's material. Each element owns a zone of the
ring, separated by hairlines; the zone lights up when the pointer is over it,
with its worker's status colour. A busy worker's zone keeps a faint amber light.

**Content** [decided]. At most four workers, the three dots, and a sphere of
glassy metal for voice.

**Context** [decided]. The ring knows the app it opens over and recommends the
workers that fit that app's category. On the desktop it shows the most used.
The app category comes from the category the app declares to macOS
(`LSApplicationCategoryType`) [proposed]. The worker's category is set by the
person when the worker is created, then Braus tunes it with use [decided]. The
ring's centre names the app and why («Pro Tools · consigliati per audio»).

**Build** [decided]. The first opening draws the ring in 2 s (a sweep around
the circle, the elements popping in as the sweep reaches them); later openings
take under 0.5 s.

**Three dots** [decided]. Hovering the dots makes their zone glow three times
(1.35 s), then the ring re-forms larger with every worker.

**Choosing a worker** [decided]. Hovering a worker starts its preparation
animation (squash and stretch, 0.55 s). Then the worker's zone detaches: it
translates to where the bar will open and stands upright, keeping its curved
shape (0.5 s); then it spreads, its outline morphing continuously from the
curved sector into the bar's pill (0.55 s). No cross-fade. The rest of the ring
withdraws. Hover only counts once the pointer has moved after opening
[proposed], so a pointer already resting on a zone does not open a bar.

## 3. The task bar, the task window and the menu bar

Prototype: `prototypes/anello.html` (continue from the ring).

**Bar** [decided]. Identical in material and proportions to Spotlight: the
worker's mascot on the leading side, the field («Cosa deve fare Delivery?»),
the microphone on the trailing side. Under it, a separate glass card lists
other workers with their status and activity and ⌘1–⌘4 to switch, so a worker
chosen by mistake is one key away. When the chosen worker is busy the card
opens with «Adesso»: its current task, step and a Guarda button that opens the
task window.

**Task window** [decided]. On send the bar grows downward into the task window
(0.6 s), and the card retracts behind it. The window recentres as it grows.

- Header: mascot, the task as typed, and «Delivery · passo 2 di 5 · 0:04». At
  the trailing edge an icon button «Apri in Braus» and `–` to put it away.
- Context labels under the header, aligned to the window's leading edge, with
  air between them (app, document, folder).
- The steps, appearing one after another once planned, joined by a vertical
  thread. Each step has a title and a description under it. States: done
  (filled with a check, the thread above it turns white), in progress
  (a turning arc), to do (an empty ring).
- If the worker is busy: «Adesso» with the current task and its progress, then
  «In coda» with the new task, its position, its labels and an estimate of when
  it starts. Spacing follows the HIG, with room under the last card.
  A footer suggests a free worker that fits («Dallo a Mixing») [proposed].

**Menu bar** [decided]. `–` or Esc shrinks the window into Braus's menu-bar
icon (0.48 s) and the icon bounces. Clicking the icon opens a glass menu with
the tasks in progress (worker, step, a thin progress bar) and the finished
ones; choosing one brings its window back down from the icon as it was. The
icon shows the brows of the busiest state and the number of active tasks; a
notification arrives when a worker finishes [proposed].

## 4. The worker's screen window

Prototype: `prototypes/schermo.html`.

[decided] An ordinary macOS window, not a picture-in-picture: traffic lights,
it goes behind other windows like any window. The title bar holds the mascot
(with its status dot), the worker's name and the task title, no steps. «Apri in
Braus» is an icon only. Below it, the worker's live screen.

[proposed] Inside the screen, the worker's own cursor carries its mascot so it
is never confused with the person's; each click leaves an amber ripple; a small
caption at the bottom says what it is doing. The controls appear on hover over
the screen as small pills: Ferma works today; Prendi il controllo and Dì
qualcosa are [later].

## 5. Voice

Prototype: `prototypes/voce.html`.

[decided] The person speaks to Braus in general; Braus decides which worker
gets the work. The routing is [later], its interface is designed: when Braus
hands off, the worker's mascot leaves the voice sphere and settles into the
reply with its name and first step.

[decided] The voice bubble sits at the top right of the screen. It is small,
the size of a mascot (64 pt), and is born as a mutation of the mascot: the brows
melt into a point of light, the mascot's metal turns to glass, the waves start.
Its material is graphite satin glass: metal, but not shiny and not liquid metal,
transparent enough to show what is behind it, and deliberately not Apple's
sphere. Inside, waves of light are born at the centre and spread outward. The
layers have different sensitivities: white answers to a whisper, amber to normal
voice, blue to a raised voice, violet only to a loud one. The bubble lights the
room around it: a halo on the desktop and on the nearest window edge, pulsing
with the voice.

[proposed] The transcript sits beside the sphere: the person's words in a light
bubble as they speak, Braus's reply in dark glass, and a state line (In ascolto,
Ci penso, Braus risponde). The bubble leaves by itself after a few seconds of
silence after the reply, or on Esc or a click, with the mutation reversed. The
way in is the voice sphere on the ring.

## 6. The conversation

Prototype: `prototypes/chat.html`.

The existing rules stay: glass pill composer, accent send at the bottom right,
Shift-Return for a new line, no state on successful messages, badges only for
errors, the "thinking" bubble, the tool line in human language above the reply,
the context ring, quote and queue above the composer.

[decided] What changes is how it moves:

- **Send.** The text lifts out of the field, the bubble grows around it in
  flight and it lands in place with a small bounce (0.56 s spring); the corners
  go from the pill to the bubble's shape. While the person types, the worker at
  the top raises its brows (Listening).
- **Queue.** While the worker works, what the person sends flies into a strip
  joined to the top of the composer: «In coda · parte a fine turno», the text,
  ‹ 2/3 › to page, «Invia ora» and ✕. At the end of the turn the first queued
  message flies from the strip into the conversation and the worker starts
  again.
- **Quote.** The reply arrow appears on hover of a bubble. Choosing it, the
  bubble nudges, and a copy of it lifts out and settles into the quote strip on
  the composer, shrinking without distorting its text (0.52 s); only then do
  «Rispondi a…» and the text appear. ✕ sends it back into its bubble. The sent
  bubble carries the quote at its top.
- **The worker answering.** The mascot prepares, then works with its amber
  light. A bubble with three living dots is born with a spring; the tool line
  appears above it and updates («Apre Pro Tools», «Esporta gli stem», «Ha
  esportato 12 stem»); then the dots bubble widens into the reply and the words
  arrive one by one, from blurred to sharp.

## 7. The mascot's brows

Prototype: `prototypes/sopracciglia.html`.

[decided] Keep the ibrows system and its motion as it is. The face system's
source is the ibrows page; the outlines are in the prototype.

- Seven states: Idle, Listening, Working, Asking, Done, Failed, Offline, plus a
  Look outline used when Idle follows the pointer.
- Every outline has 320 points, so a state change morphs instead of cutting.
  Ease-in-out cubic. 360 ms for calm states; 230 ms with no stagger for Working
  and Failed. The two brows start 40 ms apart in random order, and a brow whose
  group does not change in the new state holds still.
- The head breathes (half a percent vertically every 6.5 s). The brows turn on
  the sphere following the pointer and, at rest, look the person's way.
- The head stays dark on Done and Failed: the outcome is the room's light
  [decided]. Only Offline greys the head and the brows [proposed].

## Motion summary

| Moment | Duration | Curve |
|---|---|---|
| Ring build, first opening | 2 s | ease-in-out |
| Ring build, later openings | under 0.5 s | ease-out |
| Three dots glow | 3 × 0.45 s | ease-in-out |
| Worker preparation | 0.55 s | spring |
| Zone travels and stands up | 0.5 s | ease-out |
| Zone spreads into the bar | 0.55 s | ease-out |
| Bar grows into the task window | 0.6 s | ease-out |
| Task window to and from the menu bar | 0.48 s / 0.52 s | ease-in / spring |
| Message send flight | 0.56 s | spring |
| Quote flight | 0.52 s | ease-out |
| Brows, calm / decisive | 360 ms / 230 ms | ease-in-out cubic |
| Room light flicker, busy | 3.4 s | ease-in-out |
| Head breathing | 6.5 s | ease-in-out |

## Calls made while checking this document

These were settled without asking, because a sensible builder could; each can
be changed without touching the rest.

- Every input in mockup mode is simulated: the voice level, the app the ring
  opens over (a picker in the mockup), the nearest window edge for the voice
  halo, task progress. No microphone permission, no notification permission;
  the "worker finished" notice is an in-app banner in the mockup.
- UI copy follows the app's language, English. The Italian strings in the
  prototypes give the meaning, not the final wording.
- The room light's target look is the prototype's: rooms seen from above as
  shallow boxes (floor and low walls), the worker sphere lit by its room, a
  soft contact shadow, the specular highlight and the floor bounce on the
  sphere. Ray tracing adds accurate soft shadows and reflections on the sphere
  and the walls; it does not change the camera or add geometry beyond that.

## Left to the builder

- How the mockup is reached in the app (a check switch, a launch environment,
  a separate scene) and where its fake data lives.
- Component boundaries and the split between Core Animation layers and Metal
  views, within the app's folder rules.
- The Metal implementation of the room light, the sphere shading, the ring
  glass and the voice waves, including the precomputed-light path.
- How the menu-bar item, the global shortcut and the floating panels are hosted
  (status item, non-activating panels), as long as they never take focus from
  the person's app.

## Open points

- **The ring's shortcut.** ⌥Space in the prototype; the real one must not clash
  with Spotlight or common apps.
- **Cost of room light without hardware ray tracing.** Measure the precomputed
  path on the M1 that is available for testing before committing to the look.
