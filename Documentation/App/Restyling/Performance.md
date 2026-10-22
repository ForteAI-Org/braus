# Braus restyling: performance pass (P10)

Date: 22 October 2026. Branch `elio/app-restyling-p10`, from `a4cab8bb`. Decision 17 of
`.superpowers/sdd/Plan/round-2-direction.md`, row P10 of [Integration.md](Integration.md).

Goal (the person): the lowest possible consumption, keeping today's visual result.

All paths below are under `BrausApp/App/Braus/`.

---

## 1. How it was measured

**The probe.** `Core/Checks/RoomCostCheck.swift`, launched like the other checks:

```sh
BRAUS_APP_SUPPORT_DIR=<scratch> BRAUS_ISOLATED_RUN=1 \
BRAUS_ROOM_COSTS=9|30|60 BRAUS_ROOM_COST_MODE=rooms|rows|compact \
[BRAUS_ROOM_LIGHT=precomputed] [BRAUS_ROOM_COST_SHOW=1] Braus.app/Contents/MacOS/Braus
```

- It builds a synthetic team in a temporary store, as the house snapshots of 30 and 60 workers do: every
  seventh worker off, every fifth waiting, every third of the rest busy through a stand-in agent that only
  waits, the rest free. Nine workers give 2 busy, 1 waiting, 1 off, 5 free.
- It hosts the real `HouseShellView` at 1200 × 900, or at the narrowest window (600) for `compact`.
- With `BRAUS_ROOM_COST_SHOW=1` the window is put on screen (the person's Mac was free for it), so the
  drawables, Core Animation and WindowServer run for real. All numbers below are on screen.
- Nothing is clicked or typed. The divider moves through `NSSplitView.setPosition` at 60 Hz, the selection
  through the team, the rooms scroll through their clip view.
- Each event runs until the rooms are quiet: nothing in flight and no submission for a second.
- `BRAUS_ROOM_COST_IDLE=1` leaves every worker idle; `BRAUS_ROOM_COST_ONLY=appear` stops after the first
  appearance and the rest.
- `BRAUS_ROOM_COSTS=kernel` times the precomputed light alone, the live frame's shader.

**What is recorded.**

- GPU: every room submission's `gpuEndTime − gpuStartTime`, by kind (`RoomCostLedger`): live frame,
  preview, full render with its pulse, body pose, passage frames. It records nothing unless the probe runs.
- Main thread: busy time between run loop waits, its longest stretch, and stretches over 16.7 ms (hitches).
- Memory: the GPU's `currentAllocatedSize`, the process's physical footprint, and the images the rooms keep
  (pulse, body, passage, last image, preview), each counted once.
- At rest, over ten seconds: the app's CPU, the rooms' submissions, the animations running in the window,
  and WindowServer's CPU with the window shown and then ordered out.

**Events.** Cold appear (first window of the process), warm appear (a second window, same team, after the
first closed), a sidebar drag (280 → 330 → 280 pt over one second) and its settle, compaction (280 → 180,
the rooms reshape to one column) and its settle, selection (a room empties, the plaque, the hero) and a
switch to another worker, scrolling the rooms to the end and back (30 and 60 only), and rest.

**Machine and build.** Apple M4 (MacBook Pro, 120 Hz built-in display, a 144 Hz display beside it),
macOS 27, Debug build as the person runs it. Ray traced means the denoised ray tracer this Mac picks;
precomputed is `BRAUS_ROOM_LIGHT=precomputed`, the path an M1 takes. The person's M1 was not measured.

**Before and after.** Before is `a4cab8bb` with only the ledger's lines added; after is this branch. Each
configuration ran once before and once after, back to back. Worker ids, and so shapes and behaviour loops,
are random per run: the number of body poses differs by about ±15% between runs, which shows in GPU totals.

---

## 2. What was found

1. **Every room counted as visible.** Since views stopped clipping to their bounds, AppKit's
   `visibleRect` also covers what the window shows beyond a view. A room scrolled out of the sidebar still
   had a non-empty visible rect, so every room in the team drew a live frame at every step of a drag, was
   previewed and ray traced after it settled, and baked its body poses and passage again: after one drag of
   a 30-worker team, 30 full renders and about 200 ray-traced poses.
2. **Rooms out of sight kept everything.** A room far down the list kept its pulse, body and passage frames
   (4 to 12 MB a room), and its denoiser claim.
3. **The live frame's shader** spent about half its time (tilted) and nine tenths (from above) testing the
   32 points of the lamp, and the screen's 16, against the body, for every pixel, even where the line
   passes far from it.
4. **Main thread.** Every body pose that landed rebuilt the body's whole motion; every SwiftUI update of a
   room recomputed where its camera shows the face (`RoomCamera.face`), walking the outline hundreds of
   times; and every update of the brows removed and re-added their room light. On a selection with 30
   workers, the face alone took about 40% of the main thread.
5. **The ray tracer kept each room's acceleration structure** after its bakes, though every pose rebuilds
   it and a room at rest never reuses it.
6. **Each baked frame was copied twice** on its way from the GPU to an image.

---

## 3. What changed

None of these changes what a room shows; section 5 says how that was checked.

| Change | Where | Effect |
|---|---|---|
| A room is visible only within its own bounds (`isShown`) | `RoomLightView` | Off-screen rooms draw no live frames, no previews, and rank behind visible ones |
| Rooms out of sight are culled: beyond 360 pt they keep only their last image; back within 120 pt they render again as after a resize | `RoomLightView` | Off-screen rooms render nothing and hold no frames or denoiser claim; bakes run only for rooms in reach |
| The lamp's and the screen's points skip the body search where their line clears the body's bounding ball | `RoomLight.metal` | Live frame −35% tilted, −60% from above; bit-identical output |
| The body's motion is rebuilt only when its loop, action, room or size changes | `RoomLightView.prepareBody` | Main thread per pose |
| The camera's face is kept per shape, size and lean | `RoomCamera.face` | Main thread on every update of the rooms |
| The brows catch the room light again only when it changes | `MascotLayer.catchRoomLight`, `status` | Main thread on every update of the rooms |
| The ray tracer lets its acceleration structure go once a room has nothing left to trace | `RayTracedRoomRenderer`, `RoomLightView` | GPU memory per room |
| A frame is read straight into its image's storage | `RoomLightView.image(from:)` | One copy of every baked frame instead of two |

---

## 4. Cost table

Every cell is **before → after**. *RT* is the denoised ray tracer, *PC* the precomputed light (an M1's
path). GPU and main thread in milliseconds, memory in MB. "Settle" is from the end of a drag until the rooms
are quiet: previews, full renders, pulse, body poses and passages.

### 4.1 The live frame's shader alone (`BRAUS_ROOM_COSTS=kernel`, GPU ms per room at 2×)

| Room | Tilted | From above |
|---|---|---|
| Busy, 127 × 104, circle, screen | 0.41 → 0.25 | 0.19 → 0.12 |
| Free, wide 260 × 104, square | 1.14 → 0.61 | 0.87 → 0.25 |
| Waiting, 127 × 104, triangle | 0.68 → 0.47 | 0.45 → 0.19 |
| Off, 127 × 104, diamond | 0.69 → 0.47 | 0.45 → 0.17 |
| Row, 73 × 73, leaning | 0.48 → 0.41 | 0.22 → 0.11 |
| Empty room | 0.03 → 0.03 | 0.02 → 0.02 |
| **Mean** | **0.57 → 0.37** | **0.37 → 0.14** |

### 4.2 Nine workers (2 busy, 1 waiting, 1 off, 5 free), on screen

| Event | Metric | Rooms RT | Rooms PC | Rows RT | Rows PC | Compact RT | Compact PC |
|---|---|---|---|---|---|---|---|
| Cold appear | GPU | 952 → 844 | 155 → 102 | 686 → 659 | 92 → 66 | 618 → 772 | 100 → 64 |
| | Main | 930 → 641 | 518 → 212 | 1472 → 1145 | 1234 → 1096 | 965 → 952 | 744 → 484 |
| | Every room fully lit | 1693 → 1534 | 105 → 143 | 60 → 56 | 28 → 28 | 1590 → 1795 | 627 → 610 |
| Warm appear | GPU | 995 → 980 | 180 → 128 | 874 → 826 | 130 → 90 | 1052 → 920 | 109 → 81 |
| | Main | 1429 → 1337 | 937 → 577 | 1361 → 1023 | 1061 → 609 | 1585 → 1414 | 1146 → 878 |
| Drag, 60 steps | Live frames per step | 9 → 9 | 9 → 9 | 0 → 0 | 0 → 0 | – | – |
| | GPU per live frame | 1.28 → 0.73 | 1.09 → 0.65 | – | – | – | – |
| | GPU per step | 11.5 → 6.6 | 9.8 → 5.9 | 0 → 0 | 0 → 0 | – | – |
| | Main per step | 17.5 → 16.1 | 15.2 → 14.2 | 9.1 → 9.6 | 9.2 → 9.4 | – | – |
| Settle | GPU | 711 → 679 | 81 → 60 | 0 → 0 | 0 → 0 | – | – |
| | Main | 702 → 425 | 391 → 123 | 269 → 259 | 272 → 271 | – | – |
| | Duration | 1615 → 1534 | 407 → 130 | – | – | – | – |
| Compaction | Main per step (spring) | 27.6 → 33.6 | 29.5 → 27.1 | 21.1 → 20.7 | 21.7 → 21.3 | – | – |
| | Settle GPU | 950 → 1040 | 245 → 140 | 0 → 0 | 0 → 0 | – | – |
| | Settle main | 1077 → 828 | 686 → 416 | 395 → 450 | 434 → 369 | – | – |
| Selection | GPU | 216 → 207 | 29 → 24 | 300 → 281 | 28 → 20 | 310 → 380 | 14 → 11 |
| | Main | 1198 → 1346 | 1434 → 1032 | 814 → 511 | 521 → 409 | 1386 → 1222 | 1093 → 1028 |
| | Longest stall | 730 → 842 | 742 → 730 | 199 → 165 | 140 → 161 | 783 → 751 | 770 → 767 |
| Switch | Main | 670 → 541 | 718 → 400 | 391 → 311 | 547 → 319 | 656 → 587 | 310 → 337 |
| Memory after appear | Images kept | 69.2 → 71.1 | 49.1 → 49.8 | 28.3 → 28.0 | 17.1 → 16.7 | 43.1 → 46.8 | 35.9 → 36.7 |
| | Largest room | 22.3 → 23.4 | 14.9 → 14.0 | 5.7 → 5.7 | 3.1 → 3.3 | 9.2 → 9.2 | 6.4 → 6.7 |
| | GPU allocated | 118.2 → 106.4 | 4.9 → 4.9 | 44.6 → 32.7 | 2.7 → 2.7 | 47.5 → 35.6 | 4.1 → 3.9 |
| | Footprint | 461 → 454 | 183 → 185 | 336 → 322 | 139 → 137 | 353 → 349 | 161 → 163 |
| Rest, 10 s | App CPU | 0% → 0% | 0% → 0% | 0% → 0% | 0% → 0% | 0% → 0% | 0% → 0% |
| | Room submissions | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 | 0 → 0 |
| | Animations running | 172 → 172 | 169 → 169 | 174 → 162 | 171 → 171 | 172 → 172 | 169 → 169 |

Rows: the portraits keep their size, so a drag or a compaction costs them no GPU; what is left is SwiftUI's
layout. Compact: the sidebar is fixed at 140 pt, so it has no drag. Nine rooms all show at once, so culling
changes nothing here: the gains are the shader, the main thread and the acceleration structures.

### 4.3 Thirty and sixty workers, rooms grid unless named

Cold appear and rest come from teams with no busy worker (`BRAUS_ROOM_COST_IDLE=1`, see 6.2); the rest
from the same teams with their busy workers.

| Event | Metric | 30 RT | 30 PC | 30 compact RT | 60 RT | 60 PC | 60 compact RT |
|---|---|---|---|---|---|---|---|
| Cold appear | GPU | 1787 → 1076 | 553 → 161 | 1442 → 536 | 3079 → 882 | 1108 → 161 | 3066 → 640 |
| | Main | 2795 → 1357 | 1379 → 351 | 3391 → 1391 | 6074 → 1564 | 2908 → 580 | 6814 → 1942 |
| | Rooms in sight fully lit | 2801 → 2784 | 471 → 554 | 2341 → 2214 | 3140 → 2883 | 848 → 779 | 2994 → 2756 |
| Memory after appear | Images kept | 165 → 95 | 125 → 76 | 131 → 49 | 315 → 91 | 248 → 77 | 253 → 50 |
| | GPU allocated | 155 → 109 | 13.5 → 7.4 | 83 → 36 | 209 → 110 | 25.6 → 7.3 | 133 → 36 |
| | Footprint | 678 → 515 | 329 → 254 | 555 → 373 | 1007 → 543 | 570 → 290 | 841 → 412 |
| Rest, 10 s | App CPU | 0.1% → 0% | 0% → 0% | 0.1% → 0% | 0.1% → 0% | 0% → 0% | 0.1% → 0% |
| | Animations running | 574 → 510 | 556 → 508 | 562 → 487 | 1151 → 942 | 1128 → 928 | 1139 → 907 |
| Drag, 60 steps | Live frames per step | 30 → 13 | 30 → 13 | – | 60 → 13 | 60 → 13 | – |
| | GPU per step | 36.4 → 8.7 | 33.1 → 8.6 | – | 64.3 → 7.9 | 61.1 → 8.7 | – |
| | Main per step | 44.4 → 25.7 | 41.2 → 23.2 | – | 127.7 → 40.6 | 79.9 → 37.5 | – |
| | Longest stall | 83 → 53 | 64 → 40 | – | 1948 → 81 | 161 → 80 | – |
| Settle | GPU | 1799 → 1022 | 270 → 88 | – | 2964 → 837 | 466 → 100 | – |
| | Main | 2451 → 841 | 1244 → 122 | – | 5760 → 1345 | 2244 → 293 | – |
| | Duration | 4943 → 2590 | 1171 → 157 | – | 9887 → 2982 | 2106 → 187 | – |
| Compaction | Main per step (spring) | 74.1 → 47.7 | 62.0 → 36.3 | – | 116.1 → 83.3 | 133.2 → 72.1 | – |
| | GPU during the spring | 409 → 91 | 414 → 106 | – | 714 → 81 | 687 → 93 | – |
| | Settle GPU | 1900 → 1253 | 440 → 151 | – | 3682 → 854 | 472 → 100 | – |
| | Settle main | 2704 → 1139 | 1636 → 595 | – | 8493 → 1452 | 2622 → 436 | – |
| Selection | Main | 1510 → 1422 | 1478 → 1079 | 1570 → 1514 | 1700 → 1481 | 1612 → 1265 | 1807 → 1498 |
| | Longest stall | 830 → 740 | 789 → 791 | 825 → 904 | 850 → 931 | 812 → 792 | 888 → 830 |
| Scroll to the end | GPU | 0 → 907 | 0 → 147 | 0 → 531 | 0 → 765 | 0 → 171 | 0 → 551 |
| | Main | 482 → 1003 | 512 → 260 | 210 → 732 | 627 → 1385 | 770 → 504 | 732 → 1049 |
| And back | GPU | 0 → 609 | 0 → 79 | 0 → 471 | 0 → 924 | 0 → 163 | 0 → 456 |
| Memory after scrolling | Images kept | 185 → 139 | 165 → 109 | 144 → 52 | 352 → 119 | 315 → 90 | 282 → 62 |
| | Footprint at the end | 838 → 959 | 596 → 345 | 705 → 884 | 1448 → 1230 | 1159 → 591 | 1368 → 1168 |

Scrolling is the one event that costs more after: a room that comes back within reach renders again,
where before every room had rendered everything at appear and after every resize, seen or not. The
footprint at the end of the 30 and 60 RT runs includes allocator memory the process keeps after freeing;
the images the rooms keep are the measure of what culling holds.

Rows with 30 and 60 workers have no numbers: both builds stop with AppKit's "more Update Constraints in
Window passes than there are views in the window" exception (6.2).

---

## 5. Visual equality

- **The shader's skip is exact.** A line the skip leaves out passes the body by more than the softening, so
  the search would have added exactly zero. `RoomCameraTests` "The floor plan's rooms render as recorded"
  renders 9 rooms on both paths and both cameras and compares SHA-256 digests of the pixels: all 36 are
  unchanged, bit for bit.
- **The caches return what they replace.** The body's motion, the camera's face and the brows' light are
  built from the same inputs as before and reused only while those hold. The brows keep the very animation
  they had, phased to the host clock (`MascotLayerTests` "Caught again with the same light...").
- **The acceleration structure and the single copy** change no pixel: a structure is released only when
  nothing in flight reads it, and every pose rebuilt it anyway; the image holds the same bytes.
- **Visibility and culling are the only changes of behaviour**, and only for rooms out of sight:
  - During a drag, a room scrolled out of the sidebar no longer draws a live frame at every step. It keeps
    its last image until it is back within reach, then renders as after a resize.
  - A room more than 360 pt out of sight keeps only its last image. Back within 120 pt it renders again as
    after a resize: a ray-traced room shows the precomputed light, then the ray tracer's image fades in over
    0.15 s, its pulse and body starting once baked. A room whose light pulses and that already shows draws
    one live frame at the pulse's weight first, so its light does not jump. A room that shows before its
    first render gets the precomputed light at once.
  - With nine workers every room is in sight, so none of this happens there. Tested by `RoomLightTests`
    "A room scrolled far out of sight renders nothing and lets its pulse go, and renders again back in sight".
- **House snapshots** (`BRAUS_SNAPSHOTS=1`, `house-*`): they cannot be compared pixel for pixel, because the
  synthetic workers' ids, and with them their shapes and brows, are new at every run. The same build run
  twice differs by 11k–768k pixels in every `house-*` file, as much as before against after. Seen side by
  side, before and after show the same light. The snapshots light each room with the precomputed kernels,
  whose output the digests above prove unchanged.
- **The old shell** (`window-*`, `settings-*` and the rest) against `.scratch/integration-baseline/`: the
  same differences as the base `a4cab8bb`, all in the known run-to-run list, plus `settings-window-light`,
  which the base already shows.

---

## 6. What is left, and what needs the person

### 6.1 What it still costs

- **Body poses after every settle.** After an appear, a drag or a compaction, every room in reach bakes its
  body's poses again at its new size: about 70 ray-traced poses for nine rooms, 0.5–0.7 s of GPU. They are
  the room's own frames at that size, so the look needs them.
- **SwiftUI's layout of every room during a drag.** After this pass a drag costs 14–16 ms of main thread per
  step with nine workers and 23–41 ms with 30 and 60, almost all of it SwiftUI updating each room's cell
  (Debug build). The grid is eager on purpose, so the rooms keep their frames through a compaction. A lazy
  grid would lay out only the rooms in sight, but it rebuilds rooms as they come into sight and changes the
  compaction's motion. **For the person:** keep it eager, or try a lazy grid?
- **The passage baked ahead.** Every tilted room keeps its way out baked, so a choice plays at once: 20 frames
  for a room whose light pulses, about 40% of its images. Baking it on hover would save that, but a choice by
  the keyboard would then start with the cut-out fallback for a frame or two. **For the person:** worth it?
- **WindowServer at rest.** The window runs 170 Core Animation loops with nine workers (brows' morphs, bodies,
  pulses, the openings' glow) and about 1,000 with 60, composited at 120 Hz. WindowServer's own CPU varied by
  ±10 points between ten-second windows with other content on screen, so the window's share could not be
  separated: shown against ordered out, 1 to 16 points, and the same before and after. Capping the ambient
  loops at 60 Hz (`preferredFrameRateRange`) showed no difference within that noise and would change the
  motion on a 120 Hz display, so it is not applied.
- **The first selection** stalls the main thread for 0.73–0.93 s in both builds. Repeated selections in the
  same window stall at most 80 ms, so it is the conversation built the first time (`HouseLiveConversation`),
  not the rooms. Most of it was the hero's silhouettes, built once (section 7).
- **The M1.** Not measured. The precomputed columns are its path; its GPU is slower than the M4's, so its
  GPU numbers will be higher in proportion.

### 6.2 Found on the way, in both builds

- **Turns starting together with 30 or more workers.** Right after the probe starts 7 (30 workers) or 14
  (60) turns, the main thread spends more than a minute laying out the house again and again (`NSDisplayCycle`
  → window layout → `HouseSidebar` and `HouseRoomsGrid` bodies, observation invalidations, SwiftUI's toolbar
  bridge), and no room renders meanwhile. With no turn running, the same window appears in 1.4–6.8 s of
  main thread before this pass and 0.35–1.9 s after. In rows mode the same start aborts the app with
  AppKit's "more Update Constraints in Window passes than there are views in the window" exception, raised
  from SwiftUI's toolbar bridge. Starting that many turns at once is the probe's doing and may not happen by
  hand, but the loop is real. It needs a ticket of its own (fixed since: section 7).
- **AppKit's `visibleRect`** reaches beyond a view's bounds now that views do not clip to them, so any
  "is it visible" test needs the bounds too (finding 1).

---

## 7. Follow-up: the layout loop and the first selection

Branch `elio/app-restyling-loopfix`, from `8a6bb9ab`. Same probe, machine and build as section 1, on screen,
ray traced, with the busy workers of section 1.

- **The layout loop (6.2).** `HouseSidebar` bound its search field's focus with `.searchFocused`. Each layout
  of a hosting view in the window hands the window's focus store to its graph, which invalidated the
  sidebar's focus state and ran the sidebar's body again; that body places the search field again
  (`.searchable`), whose hosting view then needs layout. Started while the house changed, the cycle never
  settled. The sidebar now holds no focus state, and Find… (⌘F) makes the search field first responder
  through AppKit (`HouseSidebar.find(in:)`). Tested by `HouseAnsweringTeamTests`: before, the window held the
  main thread until the test's three-minute watchdog; after, its longest stretch is about 0.1 s.
- **The first selection (6.1).** Most of it was the one-time build of the portraits' eight silhouettes, which
  the hero needs for its height (`HouseHero.portraitHeight`): the hull read `ShapeOutline.bottom`, which
  walks the outline's arcs, once for every point. It now reads it once per hull, the same value. Rows built
  the silhouettes as they appeared, so there it was their appearance that paid.

| Event | Metric | 9 rooms | 30 rooms | 60 rooms | 30 rows | 60 rows |
|---|---|---|---|---|---|---|
| Cold appear, turns starting | Main | 633 → 594 | still looping at 150 s → 1193 | still looping at 480 s → 1548 | exception after 195 s → 1452 | → 1420 |
| | Longest stall | 19 → 12 | → 27 | → 145 | → 205 | → 62 |
| First selection | Main | 1270 → 599 | 1482 → 767 | 1598 → 1016 | 690 → 648 | 693 → 672 |
| | Longest stall | 760 → 200 | 913 → 259 | 901 → 315 | 209 → 207 | 214 → 271 |

Milliseconds. With 30 and 60 workers the selection's "before" is the build with only the loop fixed, since
the base never reaches it; for rows, its cold appear took 2501 and 2224 ms there. The 60 rows' base was not
run again.

---

## 8. Follow-up: at rest with a conversation open

Branch `elio/app-restyling-idlecpu`, from `24e870b8`. Same machine and Debug build as section 1, on screen,
nine workers, with no busy worker unless named.

**The probe.** `BRAUS_ROOM_COST_ONLY=select` selects the worker at `BRAUS_ROOM_COST_SELECT` (1 unless
set), then, with `BRAUS_ROOM_COST_SWITCH`, changes to another one, and records the rest with that
conversation open; `BRAUS_ROOM_COST_REST` sets the rest's seconds (75 here). Besides the probe's own
figure, `ps` (CPU time over 30 s), `top` (one sample a second over 30 s) and `sample` measured the
process from outside during the rest.

**What it was.** With no worker selected the app rested at 0%, with a conversation open at 0.6–0.8%.
The main thread was idle; the time went to RenderBox's surface pool (`RB::SurfacePool::notifier_callback`,
called from an IOKit notification port) and the kernel around it. Taking the hero apart:

| Hero (probe's figure over 75 s) | CPU at rest |
|---|---|
| Whole | 0.6% |
| Without the worker's portrait (body, brows and their loops) | 0.5% |
| Without the glass | 0.6% |
| The caption alone: no portrait, glass or capsule light (`HeroLight`) | 0.7% |
| Without the caption (and so its glass and light) | 0% |
| No portrait, caption without its text renderer (`WordFade`) | 0% |

The cost was the caption's `.textRenderer`. Any use of RenderBox in the process, a text renderer or an
`ImageRenderer`, leaves its surface pool notified at every frame the window draws from then on, even after
the view that used it is gone, as long as anything in the window animates: with every animation of the
window removed the same process rests at 0%, and a new window in the same process costs the same. The
portraits', rooms' and openings' loops were not the cost, nor the glass over them.

**What changed.** `WordFade` is no text renderer any more: each word is the whole line masked to that
word, from the middle of the space before it to the middle of the space after it, faded through its
view's opacity, blur and offset, which Core Animation draws. The caption shows its lines through it only
while it writes them; at rest they are plain texts. Tested by `WordFadeTests`: whole, the faded words
are the plain line pixel for pixel, short, long, truncated and empty. Against the old renderer, rendered side
by side at ten instants of the fade for a short and a long line, the frames differ by at most 25 of 255 on the blurred edges, and
not at all once whole. On screen, the resting caption's glyph edges differ from before by antialiasing
only (at most 90 of 255, on edges, no pixel moved): the old renderer's text went through RenderBox,
the new one is drawn like every other text in the app.

| At rest, 9 workers, conversation open | Before | After |
|---|---|---|
| Rooms, worker selected | 0.58% (top), 0.7% (probe) | 0% (top), 0% (probe) |
| Rooms, after a change of worker | 0.65%, 0.8% | 0%, 0% |
| Rows, worker selected | 0.56%, 0.7% | 0%, 0% |
| Rows, after a change of worker | 0.56%, 0.7% | 0%, 0% |
| Rooms, a busy worker selected | 0.61%, 0.8% | 0%, 0% |

`ps` agrees: before 0.20–0.23 s of CPU over the 30 s, after 0.00–0.01 s. The window runs the same 174–207
Core Animation loops before and after; nothing was paused.

**What is left.** RenderBox is still used by `BubbleFlight.image` (an `ImageRenderer`, when a message is
quoted, taken back from the quote strip or sent from the queue) and, not measured, probably by the
Brain's `Canvas` in Settings. After one `ImageRenderer` image the process rested at 0.57% with a
conversation open; the old text renderer's leftover had not faded after 200 s. Drawing those without RenderBox would need a
ticket of its own.
