# Braus vs Cua Driver: detailed measurements

**13 October 2026 · companion to [the reviewed report](CUADriverBenchmark20261013.md)**

**Naming:** Braus is the new name of the product recorded as Mecum in this experiment. Product labels use Braus; measured revisions, recorded driver IDs, binary names, environment variables and historical source references are retained verbatim.


The tables below retain the English team report's detailed measurement cells and source notes, with product labels updated to Braus. They are supplied experiment outputs, not a new independent run. The reviewed report governs the interpretation of these numbers.

- The reported step aggregates are weighted medians of operation percentiles, not raw pooled percentiles. They include out-of-declaration Qt attempts and unverified effects.
- “Billed tokens” in the source task tables means the sum of recorded input/output/cache usage, with unequal billing categories. Costs are separately reported by the CLI.
- `ALL(supported)` selects different task sets for different drivers; compare named tasks or all five attempts, keeping the inconclusive run visible.
- The declared/measured support flags are generated from driver verdicts or probe counters. An unverified “works” flag is not confirmed support; a missing readable effect is not automatically a proved failure. The generic Photoshop matrix does not include all its document/menu workflow operations.
- Soak slopes are extrapolated units, from 40 steps and four samples. The reported zero drift compares overlapping 50-call slices and is not evidence of stability.
- The historical deltas use different subsets from today's headline. Rounded source cells such as 38 → 38 do not permit an exact −2% inference.
- Component notes and branch/ticket chronology are the team's statements at the experiment revision; no release integration is implied.

No red/green “winner” markers are used. Original supplied files remain archived separately in the local preparation package.

## 1. Method

| Item | Configuration |
|---|---|
| Mac | Mac16,1; Apple M4; 10 cores; 16 GB |
| OS | macOS 27.0.1, build 26A434 |
| Power / thermal | AC Power; battery 100%; low power False; thermal nominal |
| Displays | 1512x982 built-in, 1920x1080 |
| Stage Manager | GloballyEnabled = 0 |
| Braus | commit b737e71, 0 modified files, binary built 2026-10-13T12:58:55 |
| Cua | cua-driver 0.34.0, commit c1c2b5f, binary built 2026-10-13T12:59:11; CuaDriver.app installed: False |
| Run | started 2026-10-13T12:58:37; finished 2026-10-13T14:06:12; 68 min |
| Blockers / warnings | none / none |

**Invocations recorded in the data**

| Mode | Started | Reps | Order | Apps | Drivers | Cooldown s | Idle windows x s | Pauses | Soak steps | Phases |
|---|---|---|---|---|---|---|---|---|---|---|
| ops | 2026-10-13T12:59:56 | 3 | abba | Calculator, TextEdit, Google Chrome, Prism Launcher, kitty, Safari, Stocks, Obsidian, DaVinci Resolve, Photoshop | mecum, cua, cua-overlay | 5.0 | [1, 5.0] | - | - | no |
| chain | 2026-10-13T13:41:36 | 8 | abba | Calculator, TextEdit | mecum, cua, cua-overlay | 5.0 | [3, 10] | [0.0, 3.0] | - | no |
| soak | 2026-10-13T13:52:01 | 8 | abba | TextEdit | mecum, cua, cua-overlay | 5.0 | [3, 10] | - | 40 | no |

Each driver runs in its own block per application, in ABBA order (`mecum`, `cua`, `cua-overlay`, `cua-overlay`, `cua`, `mecum`) so slow drift
is spread over the drivers. Every block starts a fresh driver process after a cooldown. One warm-up and `--reps` measured repetitions per
operation; the warm-up is excluded. Latency is client wall time from request to reply including JSON and pipe transport. Resource deltas
come from `proc_pid_rusage` around the call (WindowServer through `ps`, 10 ms resolution). An independent probe (AX values, frontmost app,
cursor, windows and their display) runs outside the measured window.

**Success** is an effect the probe confirmed. `honest_miss`, `ambiguous`, `refused`, `error` and an `acted_unverified` that says delivery
failed count as failures; an operation the probe cannot see stays unverified and never counts as a success. The equivalent step is one
`run_actions` call with `observe:true` for Cua and the action call alone for Braus (its reply already has the scene); a menu adds a diff read
for Cua. The pooled step medians use the operations every driver completed, weighted by their repetitions. **Tokens**: text is characters / 4,
images are width x height / 750 after resizing; they estimate context, not billed tokens (the task phase has billed tokens). **Intervals**:
Wilson 95% for proportions; the mean of a latency has a normal 95% interval from its standard deviation. A marker is 🟡 ("even") when the
difference is within 10% or the intervals overlap; otherwise the best value is 🟢 and the others 🔴.

**Review note:** measured operation repetitions are split across the ABBA passes in the available scheduler, not repeated in full in each block. The scheduler was checked read-only at the resolved experiment revision `b737e719d36f04195c1eebfeb026946ea9c0f475` during repository integration.


## 2. Parity of the components

| Component | Braus | Cua |
|---|---|---|
| Watcher | On: the one-a-second focus-recovery heartbeat re-reads the cursor, the event tap and the focus preparation | Post-action window watch polls every 50 ms for up to 1,000 ms (default kept) |
| Watchdog | On: the eight seat-invariant checks, run on events and one heartbeat a second | No equivalent |
| Cursor fence | On: HID-level event tap that keeps the physical cursor on physical displays | No; the agent cursor overlay is a separate drawn cursor (variant `cua-overlay` only) |
| Window follower | On: moves windows the target opens into the seat | No; the target window stays where it is |
| Window stream | On: persistent window stream of the attested window (ADR 0034), observation reads from it | No; a capture per read |
| Stream rest | On: ADR 0036, the stream drops to 1 fps after 2.5 s unused (offline tests only on 7 Oct) | Not applicable |
| Telemetry | Not applicable | Off (`CUA_DRIVER_RS_TELEMETRY_ENABLED=0`) |
| Defaults | Release `mecum-mcp-stdio`, research opt-in for an unvalidated macOS build (`MECUM_BENCH_UNVALIDATED=1`) | Every default kept, including the 1,000 ms post-action window watch; `cua-fast` is never in a report |

| Variant | Launched as |
|---|---|
| `mecum` | `.build/release/mecum-mcp-stdio <knowledge dir>`, one Seat session per app block, `MECUM_APP_SUPPORT_DIR` in the run directory |
| `cua` | `cua-driver mcp --direct`: the MCP process owns the runtime, no agent cursor overlay |
| `cua-overlay` | the harness spawns `cua-driver serve --embedded --socket <run dir>/cua.sock` as its own child (the documented embedding path, no CuaDriver.app installed) and speaks MCP to `cua-driver mcp --embedded --socket <same>`; overlay on |

## 4. Equivalent step per application

Pooled over the operations every driver completed (weighted median of the per-operation percentiles).

| Application | Matched ops | Braus p50 / p90 / p99 (ms) | Cua p50 / p90 / p99 (ms) | Cua overlay p50 / p90 / p99 (ms) | Braus 6 Oct → now (same operations) |
|---|---|---|---|---|---|
| Calculator (SwiftUI) | 3 | 412 / 426 / 430 | 1,227 / 1,232 / 1,233 | 1,203 / 1,206 / 1,207 | 1,047 → 412 (-61%) |
| DaVinci Resolve (Qt + GPU UI) | 4 | 384 / 881 / 992 | 1,635 / 1,640 / 1,641 | 1,730 / 1,768 / 1,777 | 1,257 → 384 (-69%) |
| Google Chrome (Chromium) | 6 | 1,174 / 1,198 / 1,205 | 1,535 / 1,560 / 1,566 | 1,735 / 1,753 / 1,757 | 1,226 → 1,174 (= -4%) |
| Obsidian (Electron) | 5 | 844 / 1,100 / 1,146 | 1,256 / 1,266 / 1,268 | 1,203 / 1,208 / 1,209 | 1,316 → 844 (-36%) |
| Photoshop (Adobe proprietary toolkit (UXP)) | 4 | 1,151 / 1,163 / 1,166 | 1,168 / 1,205 / 1,216 | 1,164 / 1,164 / 1,164 | n/a |
| Prism Launcher (Qt 6) | 2 | 412 / 925 / 1,028 | 1,172 / 1,216 / 1,226 | 1,147 / 1,201 / 1,213 | 1,096 → 412 (-62%) |
| Safari (WebKit) | 8 | 864 / 1,205 / 1,224 | 1,267 / 1,268 / 1,268 | 1,195 / 1,196 / 1,196 | 1,089 → 754 (-31%) |
| Stocks (Mac Catalyst) | 3 | 955 / 1,074 / 1,100 | 1,767 / 1,802 / 1,810 | 1,779 / 1,791 / 1,794 | n/a |
| TextEdit (AppKit) | 8 | 393 / 915 / 1,036 | 1,234 / 1,252 / 1,256 | 1,182 / 1,186 / 1,187 | 1,066 → 379 (-64%) |
| kitty (OpenGL/GLFW) | 4 | 978 / 1,061 / 1,073 | 1,259 / 1,263 / 1,264 | 1,222 / 1,224 / 1,225 | 1,155 → 978 (-15%) |

**Review note:** Cua timings for Resolve/Prism are attempted Qt interactions outside its declared background support. Source p90/p99 aggregates are weighted summaries of operation percentiles, not pooled-tail estimates.


## 5. Delay between steps

| App | Driver | Pause s | n | p50 ms | p90 | p99 | First step after rest | Later steps | Gap s (median) |
|---|---|---|---|---|---|---|---|---|---|
| Calculator | Braus | 0 | 12 | 764 | 847 | 865 | 603 | 770 | 0.00 |
| Calculator | Braus | 3 | 12 | 600 | 931 | 935 | 591 | 600 | 3.01 |
| Calculator | Braus | wake | 14 | resting 602 | warm 770 |  | cost -168 |  |  |
| Calculator | Cua | 0 | 12 | 1,336 | 1,633 | 1,730 | 1,568 | 1,275 | 0.00 |
| Calculator | Cua | 3 | 12 | 1,330 | 1,664 | 1,714 | 1,533 | 1,280 | 3.01 |
| Calculator | Cua overlay | 0 | 12 | 1,276 | 2,340 | 2,454 | 2,445 | 1,228 | 0.00 |
| Calculator | Cua overlay | 3 | 12 | 1,380 | 1,556 | 1,573 | 1,566 | 1,219 | 3.00 |
| TextEdit | Braus | 0 | 12 | 463 | 500 | 519 | 483 | 441 | 0.00 |
| TextEdit | Braus | 3 | 12 | 872 | 926 | 947 | 938 | 842 | 3.01 |
| TextEdit | Braus | wake | 14 | resting 842 | warm 441 |  | cost 400 |  |  |
| TextEdit | Cua | 0 | 12 | 1,262 | 1,734 | 1,755 | 1,234 | 1,289 | 0.00 |
| TextEdit | Cua | 3 | 12 | 1,275 | 1,717 | 1,742 | 1,195 | 1,307 | 3.01 |
| TextEdit | Cua overlay | 0 | 12 | 1,479 | 1,871 | 1,892 | 1,889 | 1,248 | 0.00 |
| TextEdit | Cua overlay | 3 | 12 | 1,257 | 1,745 | 1,753 | 1,170 | 1,264 | 3.00 |

The wake row counts Braus steps that followed a gap above 2.5 s (ADR 0036); resting is inferred, not observed.

## 6. Reads

| App | Driver | Read | ms p50 / p90 / p99 | Text tokens | Image tokens | Total | Total on 6 Oct |
|---|---|---|---|---|---|---|---|
| Calculator | Braus | full | 52 / 58 / 60, mean 51 ±12 | 190 | 0 | 190 | 476 |
| Calculator | Cua | full | 202 / 202 / 202, mean 199 ±6 | 604 | 126 | 730 | 3,801 |
| Calculator | Cua overlay | full | 189 / 200 / 203, mean 194 ±9 | 604 | 126 | 730 | n/a |
| Calculator | Braus | unchanged | 50 / 61 / 63, mean 52 ±12 | 37 | 0 | 37 | 38 |
| Calculator | Cua | diff (since:latest) | 52 / 52 / 53, mean 52 ±1 | 60 | 0 | 60 | n/a |
| Calculator | Cua overlay | diff (since:latest) | 59 / 64 / 65, mean 61 ±4 | 60 | 0 | 60 | n/a |
| DaVinci Resolve | Braus | full | 334 / 337 / 337, mean 238 ±191 | 360 | 0 | 360 | 764 |
| DaVinci Resolve | Cua | full | 298 / 324 / 329, mean 306 ±24 | 626 | 1,534 | 2,160 | 17,924 |
| DaVinci Resolve | Cua overlay | full | 329 / 376 / 387, mean 346 ±41 | 626 | 1,534 | 2,160 | n/a |
| DaVinci Resolve | Braus | unchanged | 72 / 283 / 331, mean 152 ±181 | 37 | 0 | 37 | 38 |
| DaVinci Resolve | Cua | diff (since:latest) | 44 / 48 / 49, mean 44 ±6 | 60 | 0 | 60 | n/a |
| DaVinci Resolve | Cua overlay | diff (since:latest) | 53 / 65 / 68, mean 57 ±12 | 60 | 0 | 60 | n/a |
| Google Chrome | Braus | full | 186 / 399 / 446, mean 272 ±176 | 399 | 0 | 399 | 978 |
| Google Chrome | Cua | full | 261 / 267 / 268, mean 256 ±17 | 1,661 | 1,534 | 3,195 | 13,986 |
| Google Chrome | Cua overlay | full | 253 / 258 / 259, mean 253 ±7 | 1,664 | 1,534 | 3,198 | n/a |
| Google Chrome | Braus | unchanged | 74 / 364 / 430, mean 181 ±252 | 38 | 0 | 38 | 38 |
| Google Chrome | Cua | diff (since:latest) | 71 / 75 / 76, mean 72 ±4 | 92 | 0 | 92 | n/a |
| Google Chrome | Cua overlay | diff (since:latest) | 82 / 83 / 83, mean 80 ±5 | 93 | 0 | 93 | n/a |
| Obsidian | Braus | full | 437 / 450 / 453, mean 311 ±264 | 652 | 0 | 652 | 738 |
| Obsidian | Cua | full | 546 / 550 / 550, mean 542 ±12 | 1,332 | 1,534 | 2,866 | 7,307 |
| Obsidian | Cua overlay | full | 580 / 586 / 587, mean 576 ±16 | 1,332 | 1,534 | 2,866 | n/a |
| Obsidian | Braus | unchanged | 35 / 44 / 46, mean 37 ±11 | 38 | 0 | 38 | 97 |
| Obsidian | Cua | diff (since:latest) | 77 / 84 / 86, mean 76 ±12 | 82 | 0 | 82 | n/a |
| Obsidian | Cua overlay | diff (since:latest) | 72 / 80 / 82, mean 75 ±7 | 82 | 0 | 82 | n/a |
| Photoshop | Braus | full | 202 / 304 / 326, mean 202 ±249 | 340 | 0 | 340 | n/a |
| Photoshop | Cua | full | 255 / 257 / 257, mean 255 ±3 | 13 | 1,034 | 1,047 | n/a |
| Photoshop | Cua overlay | full | 227 / 252 / 258, mean 233 ±26 | 13 | 1,034 | 1,047 | n/a |
| Photoshop | Braus | unchanged | 225 / 378 / 413, mean 225 ±375 | 38 | 0 | 38 | n/a |
| Photoshop | Cua | diff (since:latest) | 38 / 40 / 40, mean 38 ±2 | 10 | 0 | 10 | n/a |
| Photoshop | Cua overlay | diff (since:latest) | 44 / 46 / 46, mean 45 ±1 | 10 | 0 | 10 | n/a |
| Prism Launcher | Braus | full | 42 / 289 / 344, mean 139 ±207 | 326 | 0 | 326 | 622 |
| Prism Launcher | Cua | full | 331 / 369 / 378, mean 344 ±35 | 617 | 1,534 | 2,151 | 4,157 |
| Prism Launcher | Cua overlay | full | 336 / 347 / 349, mean 340 ±10 | 617 | 1,534 | 2,151 | n/a |
| Prism Launcher | Braus | unchanged | 127 / 294 / 331, mean 170 ±168 | 37 | 0 | 37 | 39 |
| Prism Launcher | Cua | diff (since:latest) | 44 / 53 / 55, mean 47 ±8 | 60 | 0 | 60 | n/a |
| Prism Launcher | Cua overlay | diff (since:latest) | 51 / 51 / 51, mean 50 ±3 | 60 | 0 | 60 | n/a |
| Safari | Braus | full | 446 / 448 / 449, mean 359 ±174 | 432 | 0 | 432 | 977 |
| Safari | Cua | full | 254 / 267 / 270, mean 250 ±25 | 1,573 | 1,534 | 3,107 | 34,002 |
| Safari | Cua overlay | full | 245 / 256 / 259, mean 248 ±11 | 1,574 | 1,534 | 3,108 | n/a |
| Safari | Braus | unchanged | 446 / 446 / 446, mean 320 ±247 | 38 | 0 | 38 | 38 |
| Safari | Cua | diff (since:latest) | 58 / 61 / 61, mean 59 ±3 | 92 | 0 | 92 | n/a |
| Safari | Cua overlay | diff (since:latest) | 62 / 63 / 63, mean 62 ±2 | 82 | 0 | 82 | n/a |
| Stocks | Braus | full | 439 / 444 / 445, mean 343 ±195 | 621 | 0 | 621 | n/a |
| Stocks | Cua | full | 636 / 647 / 650, mean 633 ±22 | 2,115 | 1,534 | 3,649 | 5,755 |
| Stocks | Cua overlay | full | 586 / 590 / 591, mean 586 ±5 | 2,115 | 1,534 | 3,649 | n/a |
| Stocks | Braus | unchanged | 348 / 429 / 447, mean 320 ±164 | 38 | 0 | 38 | n/a |
| Stocks | Cua | diff (since:latest) | 108 / 110 / 110, mean 107 ±4 | 60 | 0 | 60 | n/a |
| Stocks | Cua overlay | diff (since:latest) | 75 / 77 / 77, mean 75 ±3 | 60 | 0 | 60 | n/a |
| TextEdit | Braus | full | 62 / 93 / 100, mean 62 ±44 | 342 | 0 | 342 | 385 |
| TextEdit | Cua | full | 190 / 197 / 198, mean 185 ±18 | 1,366 | 370 | 1,736 | 6,185 |
| TextEdit | Cua overlay | full | 191 / 200 / 202, mean 190 ±14 | 1,370 | 370 | 1,740 | n/a |
| TextEdit | Braus | unchanged | 56 / 61 / 62, mean 57 ±6 | 38 | 0 | 38 | 100 |
| TextEdit | Cua | diff (since:latest) | 48 / 55 / 57, mean 49 ±8 | 74 | 0 | 74 | n/a |
| TextEdit | Cua overlay | diff (since:latest) | 51 / 52 / 52, mean 51 ±1 | 74 | 0 | 74 | n/a |
| kitty | Braus | full | 336 / 386 / 398, mean 286 ±163 | 80 | 0 | 80 | 142 |
| kitty | Cua | full | 209 / 213 / 214, mean 190 ±42 | 207 | 1,534 | 1,741 | 4,566 |
| kitty | Cua overlay | full | 168 / 170 / 170, mean 168 ±3 | 207 | 1,534 | 1,741 | n/a |
| kitty | Braus | unchanged | 135 / 287 / 322, mean 181 ±144 | 38 | 0 | 38 | 39 |
| kitty | Cua | diff (since:latest) | 37 / 37 / 37, mean 36 ±1 | 74 | 0 | 74 | n/a |
| kitty | Cua overlay | diff (since:latest) | 38 / 41 / 42, mean 39 ±3 | 74 | 0 | 74 | n/a |

## 7. Tokens per step

| App | Step | Braus text + image = total | Cua text + image = total | Cua overlay text + image = total |
|---|---|---|---|---|
| Calculator | click | 63 + 0 = 63 | 150 + 0 = 150 | 150 + 0 = 150 |
| Calculator | front_restored | 0 + 0 = 0 | 0 + 0 = 0 | - |
| Calculator | key | 82 + 0 = 82 | 139 + 0 = 139 | 139 + 0 = 139 |
| Calculator | menu | 76 + 0 = 76 | 94 + 0 = 94 | 94 + 0 = 94 |
| DaVinci Resolve | click | 325 + 0 = 325 | 108 + 0 = 108 | 108 + 0 = 108 |
| DaVinci Resolve | click_back | 376 + 0 = 376 | 106 + 0 = 106 | 106 + 0 = 106 |
| DaVinci Resolve | front_restored | 0 + 0 = 0 | 0 + 0 = 0 | 0 + 0 = 0 |
| DaVinci Resolve | scroll_down | 114 + 0 = 114 | 108 + 0 = 108 | 108 + 0 = 108 |
| DaVinci Resolve | scroll_up | 97 + 0 = 97 | 108 + 0 = 108 | 108 + 0 = 108 |
| Google Chrome | click | 189 + 0 = 189 | 146 + 0 = 146 | 146 + 0 = 146 |
| Google Chrome | hotkey | 121 + 0 = 121 | 122 + 0 = 122 | 122 + 0 = 122 |
| Google Chrome | key | 116 + 0 = 116 | 122 + 0 = 122 | 122 + 0 = 122 |
| Google Chrome | menu | - | 247 + 0 = 247 | 247 + 0 = 247 |
| Google Chrome | scroll_down | 400 + 0 = 400 | 140 + 0 = 140 | 140 + 0 = 140 |
| Google Chrome | scroll_up | 418 + 0 = 418 | 140 + 0 = 140 | 140 + 0 = 140 |
| Google Chrome | type | 96 + 0 = 96 | 223 + 0 = 223 | 209 + 0 = 209 |
| Obsidian | click | 822 + 0 = 822 | 423 + 0 = 423 | 423 + 0 = 423 |
| Obsidian | front_restored | - | - | 0 + 0 = 0 |
| Obsidian | hotkey | 210 + 0 = 210 | 110 + 0 = 110 | 289 + 0 = 289 |
| Obsidian | key | 672 + 0 = 672 | 409 + 0 = 409 | 424 + 0 = 424 |
| Obsidian | key_close | 90 + 0 = 90 | 112 + 0 = 112 | 112 + 0 = 112 |
| Obsidian | type | 167 + 0 = 167 | 149 + 0 = 149 | 149 + 0 = 149 |
| Photoshop | close_doc | 364 + 0 = 364 | - | - |
| Photoshop | dont_save | - | - | - |
| Photoshop | key | 49 + 0 = 49 | 48 + 0 = 48 | 48 + 0 = 48 |
| Photoshop | menu_rotate | 101 + 0 = 101 | - | - |
| Photoshop | menu_rotate_back | 80 + 0 = 80 | - | - |
| Photoshop | new_doc | 414 + 0 = 414 | - | - |
| Photoshop | new_doc_confirm | 313 + 0 = 313 | 50 + 0 = 50 | 50 + 0 = 50 |
| Photoshop | scroll_down | 96 + 0 = 96 | 67 + 0 = 67 | 67 + 0 = 67 |
| Photoshop | scroll_up | 91 + 0 = 91 | 67 + 0 = 67 | 67 + 0 = 67 |
| Prism Launcher | click | 174 + 0 = 174 | 108 + 0 = 108 | 108 + 0 = 108 |
| Prism Launcher | key | 89 + 0 = 89 | 90 + 0 = 90 | 90 + 0 = 90 |
| Safari | click | 111 + 0 = 111 | 145 + 0 = 145 | 145 + 0 = 145 |
| Safari | front_restored | - | 0 + 0 = 0 | 0 + 0 = 0 |
| Safari | hotkey | 76 + 0 = 76 | 122 + 0 = 122 | 111 + 0 = 111 |
| Safari | key | 89 + 0 = 89 | 122 + 0 = 122 | 111 + 0 = 111 |
| Safari | menu | 460 + 0 = 460 | 126 + 0 = 126 | 116 + 0 = 116 |
| Safari | menu_back | 472 + 0 = 472 | 126 + 0 = 126 | 116 + 0 = 116 |
| Safari | scroll_down | 420 + 0 = 420 | 140 + 0 = 140 | 129 + 0 = 129 |
| Safari | scroll_up | 452 + 0 = 452 | 140 + 0 = 140 | 129 + 0 = 129 |
| Safari | type | 89 + 0 = 89 | 222 + 0 = 222 | 197 + 0 = 197 |
| Stocks | key | 88 + 0 = 88 | 90 + 0 = 90 | 90 + 0 = 90 |
| Stocks | scroll_down | 648 + 0 = 648 | 108 + 0 = 108 | 108 + 0 = 108 |
| Stocks | scroll_up | 641 + 0 = 641 | 108 + 0 = 108 | 108 + 0 = 108 |
| TextEdit | click | 357 + 0 = 357 | 166 + 0 = 166 | 166 + 0 = 166 |
| TextEdit | front_restored | 0 + 0 = 0 | 0 + 0 = 0 | - |
| TextEdit | hotkey | 143 + 0 = 143 | 103 + 0 = 103 | 103 + 0 = 103 |
| TextEdit | key | 89 + 0 = 89 | 103 + 0 = 103 | 103 + 0 = 103 |
| TextEdit | menu | 368 + 0 = 368 | 108 + 0 = 108 | 108 + 0 = 108 |
| TextEdit | scroll_down | 364 + 0 = 364 | 122 + 0 = 122 | 122 + 0 = 122 |
| TextEdit | scroll_up | 344 + 0 = 344 | 121 + 0 = 121 | 121 + 0 = 121 |
| TextEdit | type | 372 + 0 = 372 | 1,422 + 0 = 1,422 | 1,426 + 0 = 1,426 |
| TextEdit | undo | 142 + 0 = 142 | 102 + 0 = 102 | 102 + 0 = 102 |
| kitty | hotkey | 92 + 0 = 92 | 103 + 0 = 103 | 103 + 0 = 103 |
| kitty | key | 89 + 0 = 89 | 104 + 0 = 104 | 104 + 0 = 104 |
| kitty | scroll_down | 97 + 0 = 97 | 122 + 0 = 122 | 122 + 0 = 122 |
| kitty | scroll_up | 97 + 0 = 97 | 122 + 0 = 122 | 122 + 0 = 122 |
| kitty | type | 85 + 0 = 85 | - | - |

## 8. CPU and energy per call

Medians per call; app CPU and energy belong to the target process.

| App | Driver | Call | Driver ms | Proxy ms | App ms | WindowServer ms (10 ms ticks) | Driver mJ | App mJ |
|---|---|---|---|---|---|---|---|---|
| Calculator | Braus | action | 59.7 | n/a | 66.6 | 190 | 80 | 31 |
| Calculator | Braus | full read | 10.3 | n/a | 1.9 | 20 | 36 | 0 |
| Calculator | Cua | action | 52.3 | n/a | 75.6 | 530 | 55 | 121 |
| Calculator | Cua | full read | 29.7 | n/a | 17.1 | 170 | 132 | 34 |
| Calculator | Cua overlay | action | 1,101.3 | 0.2 | 69.1 | 550 | 6,091 | 128 |
| Calculator | Cua overlay | full read | 216.9 | 1.5 | 20.6 | 170 | 1,051 | 26 |
| DaVinci Resolve | Braus | action | 97.2 | n/a | 47.7 | 140 | 155 | 9 |
| DaVinci Resolve | Braus | full read | 48.0 | n/a | 24.7 | 80 | 217 | 4 |
| DaVinci Resolve | Cua | action | 121.7 | n/a | 289.5 | 460 | 323 | 707 |
| DaVinci Resolve | Cua | full read | 114.1 | n/a | 32.2 | 170 | 524 | 31 |
| DaVinci Resolve | Cua overlay | action | 1,733.8 | 0.2 | 302.5 | 545 | 9,629 | 585 |
| DaVinci Resolve | Cua overlay | full read | 425.6 | 33.1 | 32.7 | 270 | 2,028 | 30 |
| Google Chrome | Braus | action | 290.7 | n/a | 40.0 | 210 | 1,091 | 63 |
| Google Chrome | Braus | full read | 107.1 | n/a | 11.9 | 10 | 382 | 40 |
| Google Chrome | Cua | action | 105.5 | n/a | 66.2 | 220 | 236 | 119 |
| Google Chrome | Cua | full read | 53.1 | n/a | 33.5 | 200 | 220 | 155 |
| Google Chrome | Cua overlay | action | 1,520.8 | 0.2 | 57.4 | 440 | 8,444 | 128 |
| Google Chrome | Cua overlay | full read | 277.3 | 12.5 | 35.4 | 190 | 1,352 | 126 |
| Obsidian | Braus | action | 214.7 | n/a | 69.8 | 220 | 837 | 190 |
| Obsidian | Braus | full read | 164.8 | n/a | 18.7 | 100 | 705 | 42 |
| Obsidian | Cua | action | 68.9 | n/a | 60.1 | 180 | 72 | 67 |
| Obsidian | Cua | full read | 223.1 | n/a | 24.9 | 250 | 1,065 | 117 |
| Obsidian | Cua overlay | action | 1,119.5 | 0.2 | 44.8 | 260 | 6,419 | 99 |
| Obsidian | Cua overlay | full read | 682.0 | 117.9 | 27.5 | 300 | 3,533 | 100 |
| Photoshop | Braus | action | 175.3 | n/a | 195.1 | 475 | 525 | 625 |
| Photoshop | Braus | full read | 33.0 | n/a | 3.0 | 60 | 117 | 1 |
| Photoshop | Cua | action | 65.4 | n/a | 95.6 | 520 | 39 | 12 |
| Photoshop | Cua | full read | 41.4 | n/a | 7.0 | 220 | 157 | 1 |
| Photoshop | Cua overlay | action | 1,012.8 | 0.2 | 118.5 | 610 | 5,692 | 15 |
| Photoshop | Cua overlay | full read | 253.3 | 13.5 | 8.1 | 220 | 1,215 | 2 |
| Prism Launcher | Braus | action | 116.4 | n/a | 19.6 | 130 | 311 | 6 |
| Prism Launcher | Braus | full read | 15.9 | n/a | 1.6 | 10 | 47 | 0 |
| Prism Launcher | Cua | action | 72.4 | n/a | 41.1 | 230 | 103 | 14 |
| Prism Launcher | Cua | full read | 117.6 | n/a | 16.7 | 200 | 506 | 4 |
| Prism Launcher | Cua overlay | action | 1,149.5 | 0.2 | 48.2 | 380 | 6,492 | 19 |
| Prism Launcher | Cua overlay | full read | 427.2 | 40.0 | 13.0 | 240 | 2,060 | 12 |
| Safari | Braus | action | 218.5 | n/a | 97.7 | 255 | 670 | 355 |
| Safari | Braus | full read | 145.1 | n/a | 9.8 | 100 | 617 | 23 |
| Safari | Cua | action | 88.1 | n/a | 58.0 | 165 | 160 | 89 |
| Safari | Cua | full read | 56.7 | n/a | 3.4 | 170 | 240 | 8 |
| Safari | Cua overlay | action | 1,267.3 | 0.2 | 60.8 | 340 | 6,734 | 215 |
| Safari | Cua overlay | full read | 279.3 | 16.1 | 2.1 | 210 | 1,338 | 5 |
| Stocks | Braus | action | 279.1 | n/a | 72.6 | 170 | 822 | 176 |
| Stocks | Braus | full read | 160.1 | n/a | 31.9 | 90 | 641 | 92 |
| Stocks | Cua | action | 118.0 | n/a | 72.6 | 160 | 198 | 98 |
| Stocks | Cua | full read | 232.8 | n/a | 41.0 | 300 | 991 | 125 |
| Stocks | Cua overlay | action | 1,635.4 | 0.2 | 56.9 | 380 | 9,320 | 153 |
| Stocks | Cua overlay | full read | 687.2 | 131.0 | 40.2 | 380 | 3,450 | 158 |
| TextEdit | Braus | action | 102.5 | n/a | 26.1 | 150 | 171 | 7 |
| TextEdit | Braus | full read | 11.4 | n/a | 1.9 | 10 | 37 | 0 |
| TextEdit | Cua | action | 58.3 | n/a | 47.8 | 265 | 68 | 10 |
| TextEdit | Cua | full read | 28.8 | n/a | 13.9 | 130 | 128 | 16 |
| TextEdit | Cua overlay | action | 1,038.3 | 0.2 | 41.2 | 260 | 5,935 | 8 |
| TextEdit | Cua overlay | full read | 201.1 | 1.4 | 16.5 | 150 | 970 | 14 |
| kitty | Braus | action | 155.5 | n/a | 8.8 | 170 | 437 | 1 |
| kitty | Braus | full read | 66.7 | n/a | 3.3 | 70 | 236 | 0 |
| kitty | Cua | action | 93.4 | n/a | 12.9 | 140 | 84 | 2 |
| kitty | Cua | full read | 29.7 | n/a | 11.5 | 160 | 123 | 1 |
| kitty | Cua overlay | action | 1,504.3 | 0.2 | 14.4 | 240 | 8,589 | 2 |
| kitty | Cua overlay | full read | 191.2 | 2.0 | 10.6 | 120 | 911 | 1 |

## 9. Idle CPU

WindowServer baseline without a driver: 224 ms/s over 2 samples. Target for an open session at rest: 1.5 ms/s.

| App | Driver | Window | Seconds since last call | Driver ms/s | Proxy ms/s | App ms/s | WS over baseline | Wakeups/s |
|---|---|---|---|---|---|---|---|---|
| Calculator | Braus | window_1 | 0 | 11.79 | n/a | 9.29 | 216 | 2.7 |
| Calculator | Cua | window_1 | 0 | 0.02 | n/a | 0.30 | 58 | 0.3 |
| Calculator | Cua overlay | window_1 | 0 | 846.52 | 0.00 | 0.33 | 106 | 80.5 |
| DaVinci Resolve | Braus | window_1 | 0 | 9.46 | n/a | 85.11 | -34 | 2.5 |
| DaVinci Resolve | Cua | window_1 | 0 | 0.01 | n/a | 77.86 | -81 | 0.3 |
| DaVinci Resolve | Cua overlay | window_1 | 0 | 835.92 | 0.00 | 65.18 | 29 | 89.8 |
| Google Chrome | Braus | window_1 | 0 | 5.74 | n/a | 4.22 | -180 | 3.8 |
| Google Chrome | Cua | window_1 | 0 | 0.02 | n/a | 2.30 | -195 | 0.5 |
| Google Chrome | Cua overlay | window_1 | 0 | 821.26 | 0.00 | 1.83 | -39 | 85.9 |
| Obsidian | Braus | window_1 | 0 | 5.43 | n/a | 3.89 | -184 | 4.2 |
| Obsidian | Cua | window_1 | 0 | 0.00 | n/a | 0.54 | -126 | 0.1 |
| Obsidian | Cua overlay | window_1 | 0 | 828.41 | 0.00 | 0.49 | -22 | 91.0 |
| Photoshop | Braus | window_1 | 0 | 6.79 | n/a | 14.02 | -152 | 2.2 |
| Photoshop | Cua | window_1 | 0 | 0.02 | n/a | 24.03 | -198 | 0.4 |
| Photoshop | Cua overlay | window_1 | 0 | 817.50 | 0.00 | 20.53 | -26 | 85.6 |
| Prism Launcher | Braus | window_1 | 0 | 4.97 | n/a | 6.05 | -192 | 4.7 |
| Prism Launcher | Cua | window_1 | 0 | 0.05 | n/a | 0.26 | -206 | 0.2 |
| Prism Launcher | Cua overlay | window_1 | 0 | 850.30 | 0.00 | 0.42 | -11 | 82.2 |
| Safari | Braus | window_1 | 0 | 5.40 | n/a | 4.69 | -183 | 3.8 |
| Safari | Cua | window_1 | 0 | 0.01 | n/a | 6.55 | -173 | 0.5 |
| Safari | Cua overlay | window_1 | 0 | 813.83 | 0.00 | 5.34 | -77 | 83.1 |
| Stocks | Braus | window_1 | 0 | 7.35 | n/a | 4.87 | -173 | 4.1 |
| Stocks | Cua | window_1 | 0 | 0.04 | n/a | 0.05 | -206 | 0.4 |
| Stocks | Cua overlay | window_1 | 0 | 842.26 | 0.00 | 0.13 | -15 | 82.8 |
| TextEdit | Braus | window_1 | 0 | 11.22 | n/a | 7.11 | -67 | 5.0 |
| TextEdit | Cua | window_1 | 0 | 0.02 | n/a | 1.18 | -180 | 0.4 |
| TextEdit | Cua overlay | window_1 | 0 | 820.32 | 0.00 | 0.60 | -40 | 83.1 |
| kitty | Braus | window_1 | 0 | 5.29 | n/a | 3.53 | -187 | 3.6 |
| kitty | Cua | window_1 | 0 | 0.01 | n/a | 0.03 | -182 | 0.2 |
| kitty | Cua overlay | window_1 | 0 | 812.67 | 0.00 | 0.02 | -107 | 82.0 |

## 10. Memory and soak

| Driver | MCP ready ms | Footprint median MB | Peak MB | Median on 6 Oct |
|---|---|---|---|---|
| Braus | 65 | 87.0 | 222.2 | 131.7 |
| Cua | 109 | 12.7 | 106.5 | 35.1 |
| Cua overlay | 136 | 173.1 | 3,967.3 | n/a |

| App | Driver | Steps | Samples | First MB | Last MB | Driver MB/100 steps | App MB/100 steps | Errors | Stalls | Step ms p50 / p90 / p99 | Drift ms (last 50 vs first 50) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| TextEdit | Braus | 40 | 4 | 73.9 | 79.3 | 21.45 | 151.52 | 0 | 0 | 751 / 1,044 / 1,073, mean 692 ±76 | 0 |
| TextEdit | Cua | 40 | 4 | 9.2 | 9.3 | 0.34 | -1.31 | 0 | 0 | 1,470 / 1,712 / 1,769, mean 1,461 ±76 | 0 |
| TextEdit | Cua overlay | 40 | 4 | 168.0 | 168.5 | 18.20 | 0.00 | 0 | 0 | 1,714 / 1,761 / 1,855, mean 1,495 ±85 | 0 |

## 11. Robustness

| App | Driver | Reported ok / actions | Wilson 95% | Probe confirmation |
|---|---|---|---|---|
| Calculator | Braus | 10/10 | 0.72-1.00 | confirmed 6/6 [0.61-1.00] |
| Calculator | Cua | 10/10 | 0.72-1.00 | confirmed 6/6 [0.61-1.00] |
| Calculator | Cua overlay | 9/9 | 0.70-1.00 | confirmed 6/6 [0.61-1.00] |
| DaVinci Resolve | Braus | 13/13 | 0.77-1.00 | confirmed 3/9 [0.12-0.65] |
| DaVinci Resolve | Cua | 13/13 | 0.77-1.00 | confirmed 3/9 [0.12-0.65] |
| DaVinci Resolve | Cua overlay | 13/13 | 0.77-1.00 | confirmed 3/9 [0.12-0.65] |
| Google Chrome | Braus | 18/21 | 0.65-0.95 | confirmed 12/21 [0.37-0.76] |
| Google Chrome | Cua | 21/21 | 0.85-1.00 | confirmed 11/18 [0.39-0.80] |
| Google Chrome | Cua overlay | 21/21 | 0.85-1.00 | confirmed 10/18 [0.34-0.75] |
| Obsidian | Braus | 15/15 | 0.80-1.00 | unverified |
| Obsidian | Cua | 15/15 | 0.80-1.00 | unverified |
| Obsidian | Cua overlay | 16/16 | 0.81-1.00 | unverified |
| Photoshop | Braus | 16/18 | 0.67-0.97 | confirmed 6/8 [0.41-0.93] |
| Photoshop | Cua | 12/27 | 0.28-0.63 | confirmed 0/18 [0.00-0.18] |
| Photoshop | Cua overlay | 12/27 | 0.28-0.63 | confirmed 0/18 [0.00-0.18] |
| Prism Launcher | Braus | 6/6 | 0.61-1.00 | confirmed 3/6 [0.19-0.81] |
| Prism Launcher | Cua | 6/6 | 0.61-1.00 | confirmed 3/6 [0.19-0.81] |
| Prism Launcher | Cua overlay | 6/6 | 0.61-1.00 | confirmed 3/6 [0.19-0.81] |
| Safari | Braus | 24/24 | 0.86-1.00 | confirmed 12/18 [0.44-0.84] |
| Safari | Cua | 25/25 | 0.87-1.00 | confirmed 9/18 [0.29-0.71] |
| Safari | Cua overlay | 25/25 | 0.87-1.00 | confirmed 5/18 [0.12-0.51] |
| Stocks | Braus | 9/9 | 0.70-1.00 | confirmed 0/9 [0.00-0.30] |
| Stocks | Cua | 9/9 | 0.70-1.00 | confirmed 0/9 [0.00-0.30] |
| Stocks | Cua overlay | 9/9 | 0.70-1.00 | confirmed 0/9 [0.00-0.30] |
| TextEdit | Braus | 24/25 | 0.80-0.99 | confirmed 18/24 [0.55-0.88] |
| TextEdit | Cua | 25/25 | 0.87-1.00 | confirmed 12/24 [0.31-0.69] |
| TextEdit | Cua overlay | 24/24 | 0.86-1.00 | confirmed 12/24 [0.31-0.69] |
| kitty | Braus | 15/15 | 0.80-1.00 | confirmed 0/6 [0.00-0.39] |
| kitty | Cua | 12/15 | 0.55-0.93 | confirmed 0/9 [0.00-0.30] |
| kitty | Cua overlay | 12/15 | 0.55-0.93 | confirmed 0/9 [0.00-0.30] |

**Failures (most common per operation)**

- Braus · DaVinci Resolve · scroll_down x3: acted_unverified
- Braus · DaVinci Resolve · scroll_up x3: acted_unverified
- Cua · DaVinci Resolve · scroll_down x3: ok
- Cua · DaVinci Resolve · scroll_up x3: ok
- Cua overlay · DaVinci Resolve · scroll_down x3: ok
- Cua overlay · DaVinci Resolve · scroll_up x3: ok
- Braus · Google Chrome · scroll_down x3: found_acted
- Braus · Google Chrome · scroll_up x3: found_acted
- Braus · Google Chrome · menu x3: refused: View > Always Show Bookmarks Bar is disabled right now. An application in the background ca
- Cua · Google Chrome · type x1: ok
- Cua · Google Chrome · scroll_down x3: ok
- Cua · Google Chrome · scroll_up x3: ok
- Cua overlay · Google Chrome · type x2: ok
- Cua overlay · Google Chrome · scroll_down x3: ok
- Cua overlay · Google Chrome · scroll_up x3: ok
- Braus · Photoshop · open_session x1: {"guidance":"Effects may be partial. Observe before deciding the next action; do not replay automati
- Braus · Photoshop · dont_save x2: honest_miss: No button 'Don't Save' in the dialog in front. It has no buttons accessibility can read
- Cua · Photoshop · new_doc x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua · Photoshop · new_doc_confirm x3: ok
- Cua · Photoshop · menu_rotate x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua · Photoshop · menu_rotate_back x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua · Photoshop · close_doc x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua · Photoshop · dont_save x3: run_actions: step 1 of 1 failed; 0 step(s) ran before it, 0 not run
1. click ERROR (find): no button
- Cua overlay · Photoshop · new_doc x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua overlay · Photoshop · new_doc_confirm x3: ok
- Cua overlay · Photoshop · menu_rotate x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua overlay · Photoshop · menu_rotate_back x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua overlay · Photoshop · close_doc x3: invoke_menu: path segment 1 is disabled. No menu window this call opened is still on screen.
- Cua overlay · Photoshop · dont_save x3: run_actions: step 1 of 1 failed; 0 step(s) ran before it, 0 not run
1. click ERROR (find): no button
- Braus · Prism Launcher · key x3: acted_unverified
- Cua · Prism Launcher · key x3: ok
- Cua overlay · Prism Launcher · key x3: ok
- Braus · Safari · key x3: acted_unverified
- Braus · Safari · hotkey x3: found_acted
- Cua · Safari · type x1: ok
- Cua · Safari · key x1: ok
- Cua · Safari · hotkey x1: ok
- Cua · Safari · scroll_down x3: ok
- Cua · Safari · scroll_up x3: ok
- Cua overlay · Safari · type x2: ok
- Cua overlay · Safari · key x3: ok
- Cua overlay · Safari · hotkey x2: ok
- Cua overlay · Safari · scroll_down x3: ok
- Cua overlay · Safari · scroll_up x3: ok
- Braus · Stocks · key x3: acted_unverified
- Braus · Stocks · scroll_down x3: found_acted
- Braus · Stocks · scroll_up x3: found_acted
- Cua · Stocks · key x3: ok
- Cua · Stocks · scroll_down x3: ok
- Cua · Stocks · scroll_up x3: ok
- Cua overlay · Stocks · key x3: ok
- Cua overlay · Stocks · scroll_down x3: ok
- Cua overlay · Stocks · scroll_up x3: ok
- Braus · TextEdit · click x1: honest_miss: no element 'Line two.' in TextEdit
- Braus · TextEdit · type x1: acted_unverified
- Braus · TextEdit · undo x3: acted_unverified
- Braus · TextEdit · scroll_down x1: acted_unverified
- Cua · TextEdit · click x3: ok
- Cua · TextEdit · undo x3: ok
- Cua · TextEdit · scroll_down x3: ok
- Cua · TextEdit · scroll_up x3: ok
- Cua overlay · TextEdit · click x3: ok
- Cua overlay · TextEdit · undo x3: ok
- Cua overlay · TextEdit · scroll_down x3: ok
- Cua overlay · TextEdit · scroll_up x3: ok
- Braus · kitty · scroll_down x3: acted_unverified
- Braus · kitty · scroll_up x3: acted_unverified
- Cua · kitty · type x3: run_actions: step 1 of 1 failed; 0 step(s) ran before it, 0 not run
1. type_text ERROR (action): typ
- Cua · kitty · scroll_down x3: ok
- Cua · kitty · scroll_up x3: ok
- Cua overlay · kitty · type x3: run_actions: step 1 of 1 failed; 0 step(s) ran before it, 0 not run
1. type_text ERROR (action): typ
- Cua overlay · kitty · scroll_down x3: ok
- Cua overlay · kitty · scroll_up x3: ok

## 12. Intrusion seen by the independent probe

| App | Driver | Calls probed | Frontmost changed | Cursor moved (probe window) | Cursor moved (call alone) | Window on user display |
|---|---|---|---|---|---|---|
| Calculator | Braus | 31 | 1 | 9 | 8 | 0 |
| Calculator | Cua | 32 | 1 | 8 | 7 | 0 |
| Calculator | Cua overlay | 32 | 0 | 0 | 0 | 0 |
| DaVinci Resolve | Braus | 36 | 2 | 6 | 5 | 0 |
| DaVinci Resolve | Cua | 32 | 1 | 6 | 5 | 0 |
| DaVinci Resolve | Cua overlay | 32 | 1 | 4 | 4 | 0 |
| Google Chrome | Braus | 51 | 0 | 0 | 0 | 0 |
| Google Chrome | Cua | 52 | 0 | 0 | 0 | 0 |
| Google Chrome | Cua overlay | 52 | 0 | 0 | 0 | 0 |
| Obsidian | Braus | 41 | 0 | 4 | 2 | 0 |
| Obsidian | Cua | 37 | 0 | 1 | 1 | 0 |
| Obsidian | Cua overlay | 37 | 0 | 3 | 3 | 0 |
| Photoshop | Braus | 38 | 0 | 0 | 0 | 1 |
| Photoshop | Cua | 77 | 0 | 0 | 0 | 0 |
| Photoshop | Cua overlay | 77 | 0 | 7 | 4 | 0 |
| Prism Launcher | Braus | 26 | 0 | 0 | 0 | 0 |
| Prism Launcher | Cua | 22 | 0 | 0 | 0 | 0 |
| Prism Launcher | Cua overlay | 22 | 0 | 0 | 0 | 0 |
| Safari | Braus | 56 | 0 | 0 | 0 | 0 |
| Safari | Cua | 62 | 1 | 0 | 0 | 0 |
| Safari | Cua overlay | 62 | 0 | 0 | 0 | 0 |
| Stocks | Braus | 31 | 0 | 0 | 0 | 0 |
| Stocks | Cua | 27 | 0 | 0 | 0 | 0 |
| Stocks | Cua overlay | 27 | 0 | 0 | 0 | 0 |
| TextEdit | Braus | 56 | 0 | 0 | 0 | 0 |
| TextEdit | Cua | 57 | 1 | 22 | 17 | 0 |
| TextEdit | Cua overlay | 57 | 0 | 0 | 0 | 0 |
| kitty | Braus | 41 | 0 | 0 | 0 | 0 |
| kitty | Cua | 37 | 0 | 0 | 0 | 0 |
| kitty | Cua overlay | 37 | 0 | 0 | 0 | 0 |

## 13. Support: declared against measured

Declared support is each driver's own documentation (Cua at c1c2b5f; Braus paths are repo-relative, with no public URL). `cua` is the measured variant. Flags mark a declared refusal that works and a declared support that fails.

<details>
<summary>SwiftUI (Calculator)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| observe | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| click | Braus | supported | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix`; `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix` |
| click | Cua | supported | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| type | Braus | not mentioned | gap | not run | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| type | Cua | not mentioned | gap | not run | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| key | Braus | not mentioned | gap | 3/3, confirmed 3/3 | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| key | Cua | not mentioned | gap | 3/3, confirmed 3/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| hotkey | Braus | not mentioned | gap | not run | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| hotkey | Cua | not mentioned | gap | not run | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| scroll | Braus | not mentioned | gap | not run | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| scroll | Cua | not mentioned | gap | not run | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| menu | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| menu | Cua | partial | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | supported | generic_contract | 30/31, unverified | - | `Documentation/Driver/README.md#agentseatkit` |
| background_no_activation | Cua | supported | declaration | 31/32, unverified | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos); [docs/content/docs/cua-driver/concepts/platform-support.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/concepts/platform-support.mdx) |
| cursor_untouched | Braus | supported | generic_contract | 23/31, unverified | - | `Documentation/Driver/README.md#agentseatkit`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | supported | generic_contract | 25/32, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract); [docs/content/docs/cua-driver/reference/mcp-tools/click.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/click.mdx) |

</details>
<details>
<summary>AppKit (TextEdit)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| observe | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| click | Braus | partial | qualification_result | 2/3, confirmed 2/3 | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| click | Cua | supported | declaration | 3/3, confirmed 0/3 | declared supported but fails | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| type | Braus | supported | qualification_result | 3/3, confirmed 2/3 | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures`; `Documentation/Driver/adr/Adr0029PrepareTextEditMenuCommands.md#decision` |
| type | Cua | supported | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| key | Braus | partial | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| key | Cua | not mentioned | gap | 3/3, confirmed 3/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| hotkey | Braus | not mentioned | gap | 3/3, confirmed 3/3 | - | `Documentation/Driver/adr/Adr0029PrepareTextEditMenuCommands.md#decision` |
| hotkey | Cua | not mentioned | gap | 3/3, confirmed 3/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| scroll | Braus | not mentioned | gap | 6/6, confirmed 5/6 | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| scroll | Cua | supported | declaration | 6/6, confirmed 0/6 | declared supported but fails | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| menu | Braus | partial | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/adr/Adr0029PrepareTextEditMenuCommands.md#decision` |
| menu | Cua | partial | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | partial | qualification_result | 56/56, unverified | - | `Documentation/Driver/adr/Adr0029PrepareTextEditMenuCommands.md#decision`; `Documentation/Driver/adr/Adr0013BriefActivationForStaleMenus.md#the-decision` |
| background_no_activation | Cua | supported | declaration | 56/57, unverified | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| cursor_untouched | Braus | supported | generic_contract | 56/56, unverified | - | `Documentation/Driver/README.md#agentseatkit`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | supported | generic_contract | 40/57, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract); [docs/content/docs/cua-driver/reference/mcp-tools/click.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/click.mdx) |

</details>
<details>
<summary>Chromium (Google Chrome)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/platforms/Chromium.md#app-integration-and-readiness` |
| observe | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-narrow-carve-out](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-narrow-carve-out); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#browsers-on-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#browsers-on-macos) |
| click | Braus | supported | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier` |
| click | Cua | partial | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#browsers-on-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#browsers-on-macos); [libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-pixel-click-limits](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-pixel-click-limits) |
| type | Braus | supported | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier`; `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| type | Cua | supported | declaration | 3/3, confirmed 2/3 | - | [libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries); [docs/content/docs/cua-driver/concepts/platform-support.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/concepts/platform-support.mdx); [docs/content/docs/cua-driver/reference/mcp-tools/keyboard.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/keyboard.mdx) |
| key | Braus | supported | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier` |
| key | Cua | supported | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-pixel-click-limits](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-pixel-click-limits) |
| hotkey | Braus | partial | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier` |
| hotkey | Cua | partial | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract) |
| scroll | Braus | supported | qualification_result | 6/6, confirmed 0/6 | declared supported but fails | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier`; `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| scroll | Cua | partial | declaration | 6/6, confirmed 0/6 | - | [docs/content/docs/cua-driver/reference/mcp-tools/pointer.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/pointer.mdx) |
| menu | Braus | partial | qualification_result | 0/3, confirmed 0/3 | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier` |
| menu | Cua | partial | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | supported | qualification_result | 51/51, unverified | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier` |
| background_no_activation | Cua | partial | declaration | 52/52, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#browsers-on-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#browsers-on-macos); [libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries) |
| cursor_untouched | Braus | supported | qualification_result | 51/51, unverified | - | `Documentation/Driver/platforms/Chromium.md#repeatable-local-tier`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | supported | generic_contract | 52/52, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract); [docs/content/docs/cua-driver/reference/mcp-tools/click.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/click.mdx) |

</details>
<details>
<summary>WebKit (Safari)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | partial | qualification_result | 3/3, unverified | - | `Documentation/Driver/adr/Adr0014WindowlessContentOfAnOrdinaryWindow.md#the-decision`; `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| observe | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos); [libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/BROWSER.md#support-boundaries) |
| click | Braus | partial | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix`; `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix` |
| click | Cua | supported | declaration | 3/3, confirmed 3/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| type | Braus | partial | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix`; `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix` |
| type | Cua | supported | declaration | 3/3, confirmed 2/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| key | Braus | partial | qualification_result | 3/3, confirmed 0/3 | - | `Documentation/Driver/adr/Adr0014WindowlessContentOfAnOrdinaryWindow.md#the-decision` |
| key | Cua | supported | declaration | 3/3, confirmed 2/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| hotkey | Braus | not mentioned | gap | 3/3, confirmed 0/3 | - | `Documentation/Driver/adr/Adr0014WindowlessContentOfAnOrdinaryWindow.md#the-decision` |
| hotkey | Cua | supported | declaration | 3/3, confirmed 2/3 | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| scroll | Braus | not supported | qualification_result | 6/6, confirmed 6/6 | declared unsupported but works | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix` |
| scroll | Cua | supported | declaration | 6/6, confirmed 0/6 | declared supported but fails | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| menu | Braus | not mentioned | gap | 6/6, unverified | - |  |
| menu | Cua | partial | declaration | 6/6, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | supported | generic_contract | 56/56, unverified | - | `Documentation/Driver/README.md#agentseatkit` |
| background_no_activation | Cua | supported | declaration | 61/62, unverified | - | [libs/cua-driver/docs/action-support.md#native-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#native-macos) |
| cursor_untouched | Braus | supported | generic_contract | 56/56, unverified | - | `Documentation/Driver/README.md#agentseatkit`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | supported | declaration | 62/62, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |

</details>
<details>
<summary>Electron (Obsidian)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/SpiLedger.md`; `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| observe | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron) |
| click | Braus | partial | qualification_result | 3/3, unverified | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| click | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |
| type | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| type | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron) |
| key | Braus | partial | inference | 6/6, unverified | - | `Documentation/Driver/platforms/Chromium.md#chromium-qualification` |
| key | Cua | supported | declaration | 6/6, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |
| hotkey | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/Driver/platforms/Chromium.md#chromium-qualification` |
| hotkey | Cua | supported | declaration | 3/3, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |
| scroll | Braus | not mentioned | gap | not run | - | `Documentation/Driver/platforms/Chromium.md#chromium-qualification` |
| scroll | Cua | not supported | declaration | not run | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |
| menu | Braus | not mentioned | gap | not run | - | `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| menu | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | supported | generic_contract | 41/41, unverified | - | `Documentation/Driver/README.md#agentseatkit` |
| background_no_activation | Cua | supported | declaration | 37/37, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |
| cursor_untouched | Braus | supported | generic_contract | 39/41, unverified | - | `Documentation/Driver/README.md#agentseatkit`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | supported | declaration | 36/37, unverified | - | [libs/cua-driver/docs/action-support.md#shared-web-harnesses](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/action-support.md#shared-web-harnesses) |

</details>
<details>
<summary>Mac Catalyst (Stocks)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| observe | Cua | partial | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#verifying-actions-cross-check-the-tree-against-the-pixels-you-already-have](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#verifying-actions-cross-check-the-tree-against-the-pixels-you-already-have) |
| click | Braus | not mentioned | gap | not run | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| click | Cua | partial | inference | not run | - | [libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations) |
| type | Braus | not mentioned | gap | not run | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| type | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron); [docs/content/docs/cua-driver/reference/mcp-tools/keyboard.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/keyboard.mdx) |
| key | Braus | not mentioned | gap | 3/3, confirmed 0/3 | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| key | Cua | partial | inference | 3/3, confirmed 0/3 | - | [libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations); [docs/content/docs/cua-driver/reference/mcp-tools/keyboard.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/keyboard.mdx) |
| hotkey | Braus | not mentioned | gap | not run | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| hotkey | Cua | partial | inference | not run | - | [libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations) |
| scroll | Braus | not mentioned | gap | 6/6, confirmed 0/6 | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| scroll | Cua | not mentioned | gap | 6/6, confirmed 0/6 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron) |
| menu | Braus | not mentioned | gap | not run | - | `Documentation/LaunchCompatibility.md#compatibility-and-limitations` |
| menu | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | supported | generic_contract | 31/31, unverified | - | `Documentation/Driver/README.md#agentseatkit` |
| background_no_activation | Cua | partial | inference | 27/27, unverified | - | [libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#known-text-input-limits-catalyst--electron) |
| cursor_untouched | Braus | supported | generic_contract | 31/31, unverified | - | `Documentation/Driver/README.md#agentseatkit`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | supported | generic_contract | 27/27, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract); [docs/content/docs/cua-driver/reference/mcp-tools/click.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/click.mdx) |

</details>
<details>
<summary>OpenGL/GLFW (kitty)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| observe | Cua | partial | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-narrow-carve-out](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-narrow-carve-out) |
| click | Braus | not mentioned | gap | not run | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| click | Cua | foreground only | inference | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [docs/content/docs/cua-driver/guides/troubleshoot.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/guides/troubleshoot.mdx) |
| type | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| type | Cua | foreground only | inference | 0/3, confirmed 0/3 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| key | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| key | Cua | foreground only | inference | 3/3, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| hotkey | Braus | not mentioned | gap | 3/3, unverified | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| hotkey | Cua | foreground only | inference | 3/3, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| scroll | Braus | not mentioned | gap | 6/6, confirmed 0/6 | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| scroll | Cua | foreground only | inference | 6/6, confirmed 0/6 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| menu | Braus | not mentioned | gap | not run | - | `Documentation/Driver/compatibility/T13Campaign26A428.md` |
| menu | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | supported | generic_contract | 41/41, unverified | - | `Documentation/Driver/README.md#agentseatkit` |
| background_no_activation | Cua | not supported | declaration | 37/37, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| cursor_untouched | Braus | supported | generic_contract | 41/41, unverified | - | `Documentation/Driver/README.md#agentseatkit`; `Documentation/Driver/README.md#the-fence-is-alive-only-while-somebody-holds-it` |
| cursor_untouched | Cua | not supported | inference | 37/37, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#delivery_mode-on-the-pointer-family-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#delivery_mode-on-the-pointer-family-macos) |

</details>
<details>
<summary>Qt + GPU UI (DaVinci Resolve)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| observe | Cua | partial | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations) |
| click | Braus | supported | qualification_result | 6/6, confirmed 3/3 | - | `Documentation/Driver/platforms/Qt.md#function-matrix`; `Documentation/Driver/platforms/Qt.md#current-repeatable-snapshot` |
| click | Cua | foreground only | declaration | 6/6, confirmed 3/3 | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| type | Braus | supported | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix`; `Documentation/Driver/platforms/Qt.md#mecum-application-flow` |
| type | Cua | foreground only | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| key | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| key | Cua | foreground only | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| hotkey | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| hotkey | Cua | foreground only | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| scroll | Braus | partial | qualification_result | 6/6, confirmed 0/6 | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| scroll | Cua | foreground only | declaration | 6/6, confirmed 0/6 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| menu | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix`; `Documentation/Driver/platforms/Qt.md#mecum-application-flow` |
| menu | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | partial | qualification_result | 34/36, unverified | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| background_no_activation | Cua | not supported | declaration | 31/32, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| cursor_untouched | Braus | supported | qualification_result | 31/36, unverified | - | `Documentation/Driver/platforms/Qt.md#current-repeatable-snapshot`; `Documentation/Driver/platforms/Qt.md#function-matrix` |
| cursor_untouched | Cua | not supported | inference | 27/32, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#delivery_mode-on-the-pointer-family-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#delivery_mode-on-the-pointer-family-macos) |

</details>
<details>
<summary>Qt 6 (Prism Launcher)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 3/3, unverified | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| observe | Cua | partial | declaration | 3/3, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/docs/macos-background-input-v1-plan.md#compatibility-expectations) |
| click | Braus | supported | qualification_result | 3/3, confirmed 3/3 | - | `Documentation/Driver/reports/ExpandedApplicationChecks.md#additional-application-matrix`; `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix`; `Documentation/Driver/platforms/Qt.md#function-matrix` |
| click | Cua | foreground only | declaration | 3/3, confirmed 3/3 | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| type | Braus | supported | qualification_result | not run | - | `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix`; `Documentation/Driver/platforms/Qt.md#function-matrix` |
| type | Cua | foreground only | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| key | Braus | partial | qualification_result | 3/3, confirmed 0/3 | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| key | Cua | foreground only | declaration | 3/3, confirmed 0/3 | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| hotkey | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| hotkey | Cua | foreground only | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| scroll | Braus | supported | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| scroll | Cua | foreground only | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| menu | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| menu | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | partial | qualification_result | 26/26, unverified | - | `Documentation/Driver/platforms/Qt.md#function-matrix` |
| background_no_activation | Cua | not supported | declaration | 22/22, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) |
| cursor_untouched | Braus | supported | qualification_result | 26/26, unverified | - | `Documentation/Driver/platforms/Qt.md#current-repeatable-snapshot` |
| cursor_untouched | Cua | not supported | inference | 22/22, unverified | declared unsupported but works | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#delivery_mode-on-the-pointer-family-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#delivery_mode-on-the-pointer-family-macos) |

</details>
<details>
<summary>Adobe proprietary toolkit (UXP) (Photoshop)</summary>

| Capability | Driver | Declared | Basis | Measured now | Flag | Source |
|---|---|---|---|---|---|---|
| observe | Braus | supported | qualification_result | 2/2, unverified | - | `Documentation/Driver/platforms/UXP.md#repeatable-matrix` |
| observe | Cua | not mentioned | gap | 3/3, unverified | - |  |
| click | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/UXP.md#mecum-app-integration`; `Documentation/Driver/platforms/UXP.md#repeatable-matrix` |
| click | Cua | not mentioned | gap | not run | - |  |
| type | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/UXP.md#repeatable-matrix`; `Documentation/Driver/reports/ApplicationFlowChecks.md#observed-effects-and-failures` |
| type | Cua | not mentioned | gap | not run | - |  |
| key | Braus | supported | qualification_result | 2/2, unverified | - | `Documentation/Driver/platforms/UXP.md#repeatable-matrix` |
| key | Cua | not mentioned | gap | 3/3, unverified | - |  |
| hotkey | Braus | partial | qualification_result | not run | - | `Documentation/Driver/platforms/UXP.md#repeatable-matrix`; `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix` |
| hotkey | Cua | not mentioned | gap | not run | - |  |
| scroll | Braus | partial | qualification_result | 4/4, unverified | - | `Documentation/Driver/platforms/UXP.md#repeatable-matrix` |
| scroll | Cua | not mentioned | gap | 6/6, unverified | - |  |
| menu | Braus | partial | qualification_result | not run | - | `Documentation/Driver/adr/Adr0013BriefActivationForStaleMenus.md#the-decision`; `Documentation/Driver/adr/Adr0020PrepareEnabledAdobeMenuCommands.md#decision`; `Documentation/Driver/reports/StabilizationRounds.md#local-release-acceptance-matrix` |
| menu | Cua | partial | declaration | not run | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#navigating-native-menu-bars-axmenubar) |
| background_no_activation | Braus | partial | qualification_result | 38/38, unverified | - | `Documentation/Driver/adr/Adr0013BriefActivationForStaleMenus.md#the-decision`; `Documentation/Driver/platforms/UXP.md#repeatable-matrix` |
| background_no_activation | Cua | supported | generic_contract | 77/77, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract); [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#pixel-click-dispatch-macos](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#pixel-click-dispatch-macos) |
| cursor_untouched | Braus | supported | qualification_result | 38/38, unverified | - | `Documentation/Driver/platforms/UXP.md#repeatable-matrix`; `Documentation/Driver/platforms/UXP.md#mecum-app-integration` |
| cursor_untouched | Cua | supported | generic_contract | 77/77, unverified | - | [libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#the-no-foreground-contract); [docs/content/docs/cua-driver/reference/mcp-tools/click.mdx](https://github.com/trycua/cua/blob/c1c2b5fee428c3a39bebe5e77549c3d3525a608d/docs/content/docs/cua-driver/reference/mcp-tools/click.mdx) |

</details>

**Review note:** “declared unsupported but works” is an automatic source flag. Treat confirmed effects, driver verdicts and background probe counters separately; this flag does not amend either product’s support contract.


## 14. Tasks with a real model

**Braus**

| Task | Runs | Skipped | Inconclusive | Success | Wilson 95% | Wall s p50 / p90 | Billed tokens p50 / p90 | Cost USD p50 / p90 | Tool calls p50 / p90 | Tool ms p50 / p90 | Think ms p50 / p90 | Tool errors | Focus changes / cursor moves |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| calculator | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 21 / 21 | 59,381 / 59,381 | 0.064 / 0.064 | 8 / 8 | 854 / 1,440 | 1,902 / 2,380 | 0 | 0/0 |
| chrome-form | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 23 / 23 | 50,883 / 50,883 | 0.033 / 0.033 | 6 / 6 | 1,298 / 3,045 | 2,038 / 2,402 | 0 | 0/0 |
| kitty | 1 | 0 | 0 | 0/1 | 0.00-0.79 | 15 / 15 | 29,711 / 29,711 | 0.020 / 0.020 | 4 / 4 | 1,274 / 2,681 | 2,107 / 2,572 | 0 | 0/0 |
| prism-toggle | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 15 / 15 | 30,535 / 30,535 | 0.020 / 0.020 | 3 / 3 | 1,198 / 2,366 | 2,260 / 2,901 | 0 | 0/0 |
| textedit | 1 | 0 | 0 | 0/1 | 0.00-0.79 | 28 / 28 | 84,212 / 84,212 | 0.057 / 0.057 | 9 / 9 | 1,210 / 1,886 | 2,151 / 2,362 | 0 | 0/0 |
| ALL (supported) | 5 | 0 | 0 | 3/5 | 0.23-0.88 | 21 / 26 | 50,883 / 74,280 | 0.033 / 0.061 | 6 / 9 | 1,196 / 2,809 | 2,045 / 2,720 | 0 | 0/0 |
| ALL (every run) | 5 | 0 | 0 | 3/5 | 0.23-0.88 | 21 / 26 | 50,883 / 74,280 | 0.033 / 0.061 | 6 / 9 | 1,196 / 2,809 | 2,045 / 2,720 | 0 | 0/0 |

**Cua**

| Task | Runs | Skipped | Inconclusive | Success | Wilson 95% | Wall s p50 / p90 | Billed tokens p50 / p90 | Cost USD p50 / p90 | Tool calls p50 / p90 | Tool ms p50 / p90 | Think ms p50 / p90 | Tool errors | Focus changes / cursor moves |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| calculator | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 20 / 20 | 190,965 / 190,965 | 0.235 / 0.235 | 3 / 3 | 1,812 / 7,714 | 1,857 / 2,194 | 0 | 0/0 |
| chrome-form | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 18 / 18 | 220,155 / 220,155 | 0.123 / 0.123 | 3 / 3 | 1,646 / 5,875 | 2,085 / 2,393 | 0 | 0/0 |
| kitty | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 24 / 24 | 263,026 / 263,026 | 0.112 / 0.112 | 9 / 9 | 1,233 / 6,603 | 2,262 / 2,710 | 4 | 2/0 |
| prism-toggle | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 13 / 13 | 275,504 / 275,504 | 0.113 / 0.113 | 4 / 4 | 683 / 1,091 | 1,569 / 2,299 | 0 | 0/3 |
| textedit | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 92 / 92 | 1,848,573 / 1,848,573 | 0.655 / 0.655 | 28 / 28 | 1,107 / 2,634 | 2,493 / 4,978 | 1 | 0/0 |
| ALL (supported) | 4 | 0 | 0 | 4/4 | 0.51-1.00 | 22 / 71 | 241,590 / 1,372,909 | 0.179 / 0.529 | 6 / 22 | 1,191 / 6,307 | 2,301 / 4,091 | 5 | 2/0 |
| ALL (every run) | 5 | 0 | 0 | 5/5 | 0.57-1.00 | 20 / 64 | 263,026 / 1,219,345 | 0.123 / 0.487 | 4 / 20 | 1,138 / 6,088 | 2,278 / 3,942 | 5 | 2/3 |

**Cua overlay**

| Task | Runs | Skipped | Inconclusive | Success | Wilson 95% | Wall s p50 / p90 | Billed tokens p50 / p90 | Cost USD p50 / p90 | Tool calls p50 / p90 | Tool ms p50 / p90 | Think ms p50 / p90 | Tool errors | Focus changes / cursor moves |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| calculator | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 22 / 22 | 190,947 / 190,947 | 0.067 / 0.067 | 3 / 3 | 1,809 / 10,076 | 1,846 / 2,186 | 0 | 0/0 |
| chrome-form | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 19 / 19 | 219,518 / 219,518 | 0.119 / 0.119 | 3 / 3 | 1,280 / 6,684 | 2,106 / 2,282 | 0 | 0/0 |
| kitty | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 87 / 87 | 1,412,793 / 1,412,793 | 0.460 / 0.460 | 32 / 32 | 1,071 / 7,618 | 2,163 / 3,118 | 4 | 22/7 |
| prism-toggle | 1 | 0 | 0 | 1/1 | 0.21-1.00 | 10 / 10 | 208,368 / 208,368 | 0.081 / 0.081 | 3 / 3 | 1,253 / 1,807 | 1,372 / 1,833 | 0 | 0/0 |
| textedit | 1 | 0 | 1 | 0/0 | - | 241 / 241 | 365,691 / 365,691 | n/a / n/a | 6 / 6 | 1,464 / 4,907 | 3,737 / 108,256 | 1 | 23/3 |
| ALL (supported) | 4 | 0 | 1 | 3/3 | 0.44-1.00 | 54 / 195 | 292,604 / 1,098,662 | 0.119 / 0.392 | 4 / 24 | 1,106 / 7,940 | 2,163 / 3,426 | 5 | 45/10 |
| ALL (every run) | 5 | 0 | 1 | 4/4 | 0.51-1.00 | 22 / 179 | 219,518 / 993,952 | 0.100 / 0.358 | 3 / 22 | 1,125 / 7,844 | 2,106 / 3,403 | 5 | 45/10 |

## 15. Phase breakdown

No data: `--phases` was not run.

## 16. Changes since 6 October

**Braus**, medians over the apps both runs have, same operations for steps.

| Metric | 6 Oct | Now | Change |
|---|---|---|---|
| Equivalent step p50 (ms, same operations) | 1,191 | 754 | -37% |
| Full read tokens | 680 | 351 | -48% |
| Unchanged / diff read tokens | 38 | 38 | = -2% |
| Driver CPU at rest (last window, ms/s) | 9.57 ms/s | 5.59 ms/s | -42% |
| Driver CPU per action (ms) | 280 ms | 136 ms | -51% |
| Full read latency p50 (ms) | 425 ms | 260 ms | -39% |
| Action success rate (reported ok) | 100% | 100% | = +0% |
| Footprint median (MB) | 131.7 | 87.0 | -34% |

**Cua**, medians over the apps both runs have, same operations for steps.

| Metric | 6 Oct | Now | Change |
|---|---|---|---|
| Equivalent step p50 (ms, same operations) | 1,538 | 1,325 | Cua changed version (-14%) |
| Full read tokens | 6,185 | 2,160 | Cua changed version (-65%) |
| Unchanged / diff read tokens | n/a | n/a | n/a |
| Driver CPU at rest (last window, ms/s) | 0.01 ms/s | 0.02 ms/s | Cua changed version (+24%) |
| Driver CPU per action (ms) | 43 ms | 88 ms | Cua changed version (+103%) |
| Full read latency p50 (ms) | 321 ms | 261 ms | Cua changed version (-19%) |
| Action success rate (reported ok) | 100% | 100% | Cua changed version (+0%) |
| Footprint median (MB) | 35.1 | 12.7 | Cua changed version (-64%) |

Cua moved from 4f33cd6 to c1c2b5f: its reads were slimmed and its step loop changed (`run_actions` with `observe`), so these differences are not a Braus gain.


**What changed in Cua between the two commits**

- Unchanged between 4f33cd6 and c1c2b5f: the native macOS ledger, the shared web ledger, the browser support table, the canvas/Qt/OpenGL rule and the Catalyst/Electron text-input limits. The declared support per framework is therefore the same as on 6 Oct.
- Adds a launch_app urls row, the 250-node get_window_state cap with since diffs and tree_format, since:latest with include_screenshot:false, collapsed menus in reads, and invoke_menu in the Finder example. No change to any framework statement.
- New efficient loop: targeted query reads, run_actions with observe:true as the default way to act, and foreground_fallback for steps refused because the app ignores background input (Electron, LibreOffice).
- Documents that on Electron/Chromium windows a background scroll now reveals content through AX instead of posting wheel events, with foreground as fallback. This contradicts the unchanged ledger row that lists Electron scroll as background_unavailable. Frameworks: electron, chromium.
- Scroll Electron/Chromium windows in the background through AXScrollToVisible; nothing posted or fronted. Frameworks: electron, chromium. Commits: ea32762.
- Same-pid keyboard ambiguity check ignores off-screen or zero-size sibling windows and every sibling when AX proves the target is the app's key window; typed newline and tab become real Return and Tab keys. May change the Safari two-window refusal seen on 6 Oct only when the second window is hidden or the target is the key window. Frameworks: webkit, chromium, appkit. Commits: 144ec6a.
- Background type_text with a line break into a Chromium native field (omnibox) is refused with browser_field_needs_keystrokes; foreground typing into browsers now fully activates the window, waits 250 ms and restores the field focus. Frameworks: chromium. Commits: 3532ba5, c90e946.
- Background right click is posted once instead of twice on macOS. Frameworks: appkit, swiftui. Commits: 0b90b6f.
- LibreOffice and Tk-style pointer-reading toolkits refuse background pixel clicks; run_actions gains foreground_fallback. No listed benchmark framework is affected directly. Commits: 49e924c, 0188a55.
- Menu-bar item tokens run as invoke_menu inside run_actions. Frameworks: appkit, chromium, webkit, swiftui. Commits: 4c2403f.
- get_window_state is slimmed (250-node cap, one tree form, menus collapsed, metadata dropped) and batching is the default path, so the 6 Oct Cua full-read token and byte figures no longer describe the c1c2b5f binary. Commits: 45775a9, a03d05b, b869593, c1c2b5f.
- No doc or code change found that adds or removes declared support for Catalyst, OpenGL/GLFW, Qt or Adobe. Frameworks: catalyst, glfw, qt_gpu, qt6, adobe.

**Review note:** these change descriptions are supplied-source analysis. Their complete commit ranges were not independently re-audited for this editorial preparation. Historical percentages should be checked against unrounded raw summaries before reuse.


## 17. Limits

- One machine on one day, a small operation set and few repetitions per operation: small differences are not distinguishable.
- The probe sees AX values, not pixels: kitty, Obsidian and Photoshop pixel effects, scrolls and menu commands stay unverified.
- The person may use the Mac during a run: the cursor and WindowServer observations carry that noise; idle and baseline rows carry the same check.
- Braus's stream rest is inferred from the gap since the previous call; a `--phases` run shows the real `preview.rest` events.
- `cua-overlay` is measured with an embedded daemon when CuaDriver.app is not installed; the app-daemon path is a different process layout.
- Token counts are estimates. The task phase counts billed tokens for one model at one effort level with few repetitions per task.
- The benchmark server is the app's worker path (`BrokeredAutomationSession` over a `SeatBroker`), not the CLI's `AutomationSession`; the app's views are not measured.
- Cua changed version since 6 October: its deltas against that run say nothing about Braus.

## 18. Reproduction

```sh
cd Tools/Driver/CUAComparison
./bench.sh                     # everything, in order; a time estimate is printed first
./bench.sh --quick             # smoke test: 2 reps, chain 0/3 s, soak 20, one task rep
./bench.sh --apps Calculator,TextEdit --reps 8 --phases
```

`bench.sh` runs the preflight (`prepare.py`), builds both drivers when stale, the per-call run, chain mode, the soak, optionally the phase
breakdown, the model task phase (`tasks.py`), `summarize.py`, and `report.py`. Everything lands in `~/Forte_Projects/_bench/runs/<YYYYMMDD-HHMM>/`
(raw JSONL, summaries, logs); the two reports are written to `~/Downloads/`. Stage Manager must be off and no other Braus may run.

## 19. Per-operation latency

<details>
<summary>Calculator (SwiftUI)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 15 / 21 / 22, mean 15 ±14; ok 2/2; unverified | 11 / 12 / 12, mean 11 ±3; ok 2/2; unverified |
| open_session | 2,628 / 2,656 / 2,662, mean 2,336 ±606; ok 3/3; unverified | - | - |
| observe | 52 / 58 / 60, mean 51 ±12; ok 3/3; unverified | 202 / 202 / 202, mean 199 ±6; ok 3/3; unverified | 189 / 200 / 203, mean 194 ±9; ok 3/3; unverified |
| observe_unchanged | 50 / 61 / 63, mean 52 ±12; ok 3/3; unverified | 52 / 52 / 53, mean 52 ±1; ok 3/3; unverified | 59 / 64 / 65, mean 61 ±4; ok 3/3; unverified |
| click | 412 / 426 / 430, mean 411 ±21; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,352 / 1,395 / 1,404, mean 1,367 ±38; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,335 / 1,335 / 1,335, mean 1,333 ±3; ok 3/3; confirmed 3/3 [0.44-1.00] |
| key | 285 / 352 / 367, mean 304 ±65; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,227 / 1,232 / 1,233, mean 1,224 ±13; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,203 / 1,206 / 1,207, mean 1,195 ±19; ok 3/3; confirmed 3/3 [0.44-1.00] |
| menu | 454 / 455 / 455, mean 451 ±6; ok 3/3; unverified | 445 / 483 / 491, mean 455 ±38; ok 3/3; unverified | 587 / 616 / 622, mean 579 ±54; ok 3/3; unverified |
| close_session | 859 / 1,029 / 1,067, mean 861 ±237; ok 3/3; unverified | - | - |
| observe_after | - | 41 / 49 / 51, mean 42 ±9; ok 3/3; unverified | 50 / 53 / 53, mean 50 ±4; ok 3/3; unverified |
| front_restored | -; ok 1/1; unverified | -; ok 1/1; unverified | - |

</details>
<details>
<summary>DaVinci Resolve (Qt + GPU UI)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 17 / 19 / 19, mean 17 ±4; ok 2/2; unverified | 10 / 11 / 11, mean 10 ±3; ok 2/2; unverified |
| open_session | 2,401 / 4,871 / 5,427, mean 2,936 ±2,638; ok 3/3; unverified | - | - |
| observe | 334 / 337 / 337, mean 238 ±191; ok 3/3; unverified | 298 / 324 / 329, mean 306 ±24; ok 3/3; unverified | 329 / 376 / 387, mean 346 ±41; ok 3/3; unverified |
| observe_unchanged | 72 / 283 / 331, mean 152 ±181; ok 3/3; unverified | 44 / 48 / 49, mean 44 ±6; ok 3/3; unverified | 53 / 65 / 68, mean 57 ±12; ok 3/3; unverified |
| click | 343 / 916 / 1,045, mean 558 ±493; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,624 / 1,625 / 1,625, mean 1,612 ±24; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,884 / 1,918 / 1,926, mean 1,893 ±34; ok 3/3; confirmed 3/3 [0.44-1.00] |
| click_back | 384 / 921 / 1,042, mean 597 ±450; ok 3/3; unverified | 1,635 / 1,640 / 1,641, mean 1,618 ±40; ok 3/3; unverified | 1,910 / 1,914 / 1,915, mean 1,898 ±28; ok 3/3; unverified |
| scroll_down | 449 / 637 / 679, mean 505 ±179; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,716 / 1,719 / 1,719, mean 1,716 ±3; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,729 / 1,768 / 1,777, mean 1,740 ±38; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_up | 384 / 881 / 992, mean 586 ±411; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,745 / 1,757 / 1,760, mean 1,740 ±26; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,730 / 1,739 / 1,741, mean 1,732 ±9; ok 3/3; confirmed 0/3 [0.00-0.56] |
| close_session | 661 / 767 / 791, mean 697 ±96; ok 3/3; unverified | - | - |
| front_restored | -; ok 1/1; unverified | -; ok 1/1; unverified | -; ok 1/1; unverified |

</details>
<details>
<summary>Google Chrome (Chromium)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 8 / 8 / 8, mean 8 ±0; ok 2/2; unverified | 10 / 11 / 11, mean 10 ±1; ok 2/2; unverified |
| open_session | 2,123 / 2,559 / 2,657, mean 1,989 ±854; ok 3/3; unverified | - | - |
| observe | 186 / 399 / 446, mean 272 ±176; ok 3/3; unverified | 261 / 267 / 268, mean 256 ±17; ok 3/3; unverified | 253 / 258 / 259, mean 253 ±7; ok 3/3; unverified |
| observe_unchanged | 74 / 364 / 430, mean 181 ±252; ok 3/3; unverified | 71 / 75 / 76, mean 72 ±4; ok 3/3; unverified | 82 / 83 / 83, mean 80 ±5; ok 3/3; unverified |
| click | 1,163 / 1,240 / 1,257, mean 982 ±452; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,535 / 1,560 / 1,566, mean 1,528 ±48; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,943 / 1,960 / 1,963, mean 1,942 ±26; ok 3/3; confirmed 3/3 [0.44-1.00] |
| type | 1,681 / 1,857 / 1,897, mean 1,411 ±756; ok 3/3; confirmed 3/3 [0.44-1.00] | 2,474 / 2,476 / 2,476, mean 2,378 ±190; ok 3/3; confirmed 2/3 [0.21-0.94] | 2,980 / 3,296 / 3,368, mean 3,025 ±374; ok 3/3; confirmed 1/3 [0.06-0.79] |
| key | 1,174 / 1,208 / 1,215, mean 1,130 ±130; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,212 / 1,225 / 1,228, mean 1,194 ±51; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,188 / 1,200 / 1,202, mean 1,187 ±19; ok 3/3; confirmed 3/3 [0.44-1.00] |
| hotkey | 1,169 / 1,198 / 1,205, mean 1,159 ±59; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,214 / 1,251 / 1,259, mean 1,225 ±35; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,197 / 1,202 / 1,203, mean 1,199 ±4; ok 3/3; confirmed 3/3 [0.44-1.00] |
| scroll_down | 1,184 / 1,193 / 1,195, mean 1,155 ±69; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,772 / 1,773 / 1,774, mean 1,764 ±17; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,735 / 1,753 / 1,757, mean 1,736 ±23; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_up | 1,195 / 1,196 / 1,196, mean 1,189 ±12; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,719 / 1,744 / 1,749, mean 1,724 ±26; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,771 / 2,238 / 2,343, mean 1,958 ±389; ok 3/3; confirmed 0/3 [0.00-0.56] |
| menu | -; ok 0/3; confirmed 0/3 [0.00-0.56] | 446 / 454 / 456, mean 435 ±33; ok 3/3; unverified | 513 / 561 / 572, mean 505 ±82; ok 3/3; unverified |
| close_session | 666 / 815 / 848, mean 690 ±172; ok 3/3; unverified | - | - |
| observe_after | - | 84 / 90 / 91, mean 78 ±20; ok 3/3; unverified | 72 / 73 / 73, mean 72 ±1; ok 3/3; unverified |

</details>
<details>
<summary>Obsidian (Electron)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 16 / 23 / 24, mean 16 ±16; ok 2/2; unverified | 10 / 11 / 11, mean 10 ±1; ok 2/2; unverified |
| open_session | 2,109 / 3,665 / 4,015, mean 2,484 ±1,608; ok 3/3; unverified | - | - |
| observe | 437 / 450 / 453, mean 311 ±264; ok 3/3; unverified | 546 / 550 / 550, mean 542 ±12; ok 3/3; unverified | 580 / 586 / 587, mean 576 ±16; ok 3/3; unverified |
| observe_unchanged | 35 / 44 / 46, mean 37 ±11; ok 3/3; unverified | 77 / 84 / 86, mean 76 ±12; ok 3/3; unverified | 72 / 80 / 82, mean 75 ±7; ok 3/3; unverified |
| click | 801 / 932 / 962, mean 797 ±193; ok 3/3; unverified | 1,474 / 1,476 / 1,476, mean 1,463 ±23; ok 3/3; unverified | 1,399 / 1,441 / 1,450, mean 1,406 ±48; ok 3/3; unverified |
| type | 844 / 1,216 / 1,299, mean 962 ±345; ok 3/3; unverified | 1,516 / 1,521 / 1,522, mean 1,502 ±34; ok 3/3; unverified | 1,475 / 1,478 / 1,479, mean 1,466 ±23; ok 3/3; unverified |
| key | 692 / 907 / 955, mean 777 ±180; ok 3/3; unverified | 1,202 / 1,214 / 1,217, mean 1,205 ±12; ok 3/3; unverified | 1,202 / 1,203 / 1,203, mean 1,201 ±4; ok 3/3; unverified |
| key_close | 892 / 1,100 / 1,146, mean 870 ±332; ok 3/3; unverified | 1,245 / 1,260 / 1,263, mean 1,236 ±37; ok 3/3; unverified | 1,203 / 1,208 / 1,209, mean 1,201 ±11; ok 3/3; unverified |
| hotkey | 884 / 1,105 / 1,154, mean 865 ±344; ok 3/3; unverified | 1,256 / 1,266 / 1,268, mean 1,244 ±36; ok 3/3; unverified | 1,184 / 1,190 / 1,191, mean 1,185 ±7; ok 3/3; unverified |
| close_session | 619 / 690 / 706, mean 627 ±87; ok 3/3; unverified | - | - |
| front_restored | - | - | -; ok 1/1; unverified |

</details>
<details>
<summary>Photoshop (Adobe proprietary toolkit (UXP))</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 8 / 8 / 8, mean 8 ±1; ok 2/2; unverified | 11 / 12 / 12, mean 11 ±2; ok 2/2; unverified |
| open_session | 1,710 / 1,936 / 1,987, mean 1,710 ±554; ok 2/3; unverified | - | - |
| observe | 202 / 304 / 326, mean 202 ±249; ok 2/2; unverified | 255 / 257 / 257, mean 255 ±3; ok 3/3; unverified | 227 / 252 / 258, mean 233 ±26; ok 3/3; unverified |
| observe_unchanged | 225 / 378 / 413, mean 225 ±375; ok 2/2; unverified | 38 / 40 / 40, mean 38 ±2; ok 3/3; unverified | 44 / 46 / 46, mean 45 ±1; ok 3/3; unverified |
| key | 1,171 / 1,174 / 1,175, mean 1,171 ±9; ok 2/2; unverified | 1,168 / 1,171 / 1,172, mean 1,168 ±5; ok 3/3; unverified | 1,164 / 1,164 / 1,164, mean 1,151 ±26; ok 3/3; unverified |
| scroll_down | 1,151 / 1,163 / 1,166, mean 1,151 ±31; ok 2/2; unverified | 1,713 / 1,731 / 1,735, mean 1,713 ±26; ok 3/3; unverified | 1,739 / 1,750 / 1,753, mean 1,739 ±17; ok 3/3; unverified |
| scroll_up | 791 / 1,084 / 1,149, mean 791 ±717; ok 2/2; unverified | 1,710 / 1,742 / 1,749, mean 1,721 ±28; ok 3/3; unverified | 1,729 / 1,755 / 1,761, mean 1,725 ±44; ok 3/3; unverified |
| new_doc | 938 / 970 / 978, mean 938 ±80; ok 2/2; confirmed 2/2 [0.34-1.00] | -; ok 0/3; confirmed 0/3 [0.00-0.56] | -; ok 0/3; confirmed 0/3 [0.00-0.56] |
| new_doc_confirm | 1,344 / 1,372 / 1,378, mean 1,344 ±67; ok 2/2; confirmed 2/2 [0.34-1.00] | 1,159 / 1,205 / 1,216, mean 1,174 ±43; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,133 / 1,153 / 1,157, mean 1,141 ±16; ok 3/3; confirmed 0/3 [0.00-0.56] |
| menu_rotate | 2,085 / 2,125 / 2,134, mean 2,085 ±99; ok 2/2; unverified | -; ok 0/3; confirmed 0/3 [0.00-0.56] | -; ok 0/3; confirmed 0/3 [0.00-0.56] |
| menu_rotate_back | 946 / 956 / 959, mean 946 ±26; ok 2/2; unverified | -; ok 0/3; confirmed 0/3 [0.00-0.56] | -; ok 0/3; confirmed 0/3 [0.00-0.56] |
| close_doc | 908 / 1,013 / 1,036, mean 908 ±256; ok 2/2; confirmed 2/2 [0.34-1.00] | -; ok 0/3; confirmed 0/3 [0.00-0.56] | -; ok 0/3; confirmed 0/3 [0.00-0.56] |
| dont_save | -; ok 0/2; confirmed 0/2 [0.00-0.66] | -; ok 0/3; confirmed 0/3 [0.00-0.56] | -; ok 0/3; confirmed 0/3 [0.00-0.56] |
| close_session | 1,042 / 1,043 / 1,044, mean 1,042 ±3; ok 2/2; unverified | - | - |
| observe_after | - | 37 / 39 / 42, mean 37 ±1; ok 12/12; unverified | 40 / 42 / 42, mean 39 ±2; ok 12/12; unverified |

</details>
<details>
<summary>Prism Launcher (Qt 6)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 15 / 22 / 23, mean 15 ±15; ok 2/2; unverified | 10 / 11 / 11, mean 10 ±3; ok 2/2; unverified |
| open_session | 1,869 / 2,458 / 2,590, mean 1,895 ±789; ok 3/3; unverified | - | - |
| observe | 42 / 289 / 344, mean 139 ±207; ok 3/3; unverified | 331 / 369 / 378, mean 344 ±35; ok 3/3; unverified | 336 / 347 / 349, mean 340 ±10; ok 3/3; unverified |
| observe_unchanged | 127 / 294 / 331, mean 170 ±168; ok 3/3; unverified | 44 / 53 / 55, mean 47 ±8; ok 3/3; unverified | 51 / 51 / 51, mean 50 ±3; ok 3/3; unverified |
| click | 412 / 925 / 1,041, mean 613 ±433; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,325 / 1,467 / 1,500, mean 1,348 ±164; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,273 / 1,310 / 1,318, mean 1,280 ±42; ok 3/3; confirmed 3/3 [0.44-1.00] |
| key | 754 / 978 / 1,028, mean 787 ±263; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,172 / 1,216 / 1,226, mean 1,179 ±51; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,147 / 1,201 / 1,213, mean 1,169 ±45; ok 3/3; confirmed 0/3 [0.00-0.56] |
| close_session | 630 / 699 / 714, mean 656 ±59; ok 3/3; unverified | - | - |

</details>
<details>
<summary>Safari (WebKit)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 8 / 8 / 8, mean 8 ±0; ok 2/2; unverified | 11 / 11 / 11, mean 11 ±0; ok 2/2; unverified |
| open_session | 2,244 / 2,565 / 2,638, mean 2,145 ±631; ok 3/3; unverified | - | - |
| observe | 446 / 448 / 449, mean 359 ±174; ok 3/3; unverified | 254 / 267 / 270, mean 250 ±25; ok 3/3; unverified | 245 / 256 / 259, mean 248 ±11; ok 3/3; unverified |
| observe_unchanged | 446 / 446 / 446, mean 320 ±247; ok 3/3; unverified | 58 / 61 / 61, mean 59 ±3; ok 3/3; unverified | 62 / 63 / 63, mean 62 ±2; ok 3/3; unverified |
| click | 751 / 1,084 / 1,159, mean 792 ±404; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,727 / 1,746 / 1,750, mean 1,707 ±63; ok 3/3; confirmed 3/3 [0.44-1.00] | 2,148 / 2,164 / 2,167, mean 2,153 ±15; ok 3/3; confirmed 3/3 [0.44-1.00] |
| type | 754 / 1,205 / 1,306, mean 928 ±383; ok 3/3; confirmed 3/3 [0.44-1.00] | 2,667 / 2,691 / 2,696, mean 2,587 ±186; ok 3/3; confirmed 2/3 [0.21-0.94] | 2,898 / 2,960 / 2,974, mean 2,706 ±454; ok 3/3; confirmed 1/3 [0.06-0.79] |
| key | 481 / 914 / 1,011, mean 657 ±358; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,222 / 1,256 / 1,264, mean 1,234 ±30; ok 3/3; confirmed 2/3 [0.21-0.94] | 1,188 / 1,190 / 1,190, mean 1,187 ±5; ok 3/3; confirmed 0/3 [0.00-0.56] |
| hotkey | 864 / 1,069 / 1,115, mean 904 ±226; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,267 / 1,268 / 1,268, mean 1,247 ±41; ok 3/3; confirmed 2/3 [0.21-0.94] | 1,195 / 1,196 / 1,196, mean 1,178 ±35; ok 3/3; confirmed 1/3 [0.06-0.79] |
| scroll_down | 1,115 / 1,206 / 1,227, mean 942 ±455; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,730 / 1,733 / 1,733, mean 1,721 ±21; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,741 / 1,753 / 1,755, mean 1,734 ±29; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_up | 1,207 / 1,221 / 1,224, mean 976 ±471; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,740 / 1,771 / 1,778, mean 1,749 ±30; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,750 / 1,753 / 1,754, mean 1,740 ±24; ok 3/3; confirmed 0/3 [0.00-0.56] |
| menu | 1,966 / 1,994 / 2,001, mean 1,972 ±30; ok 3/3; unverified | 267 / 518 / 575, mean 362 ±215; ok 3/3; unverified | 505 / 529 / 534, mean 428 ±180; ok 3/3; unverified |
| menu_back | 1,988 / 1,989 / 1,989, mean 1,984 ±9; ok 3/3; unverified | 257 / 460 / 505, mean 335 ±172; ok 3/3; unverified | 507 / 519 / 522, mean 421 ±183; ok 3/3; unverified |
| close_session | 807 / 827 / 831, mean 797 ±46; ok 3/3; unverified | - | - |
| observe_after | - | 61 / 78 / 79, mean 62 ±12; ok 6/6; unverified | 52 / 53 / 53, mean 52 ±1; ok 6/6; unverified |
| front_restored | - | -; ok 1/1; unverified | -; ok 1/1; unverified |

</details>
<details>
<summary>Stocks (Mac Catalyst)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 8 / 8 / 8, mean 8 ±0; ok 2/2; unverified | 10 / 11 / 11, mean 10 ±1; ok 2/2; unverified |
| open_session | 2,296 / 2,397 / 2,420, mean 2,041 ±628; ok 3/3; unverified | - | - |
| observe | 439 / 444 / 445, mean 343 ±195; ok 3/3; unverified | 636 / 647 / 650, mean 633 ±22; ok 3/3; unverified | 586 / 590 / 591, mean 586 ±5; ok 3/3; unverified |
| observe_unchanged | 348 / 429 / 447, mean 320 ±164; ok 3/3; unverified | 108 / 110 / 110, mean 107 ±4; ok 3/3; unverified | 75 / 77 / 77, mean 75 ±3; ok 3/3; unverified |
| key | 937 / 1,000 / 1,014, mean 873 ±209; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,259 / 1,265 / 1,267, mean 1,254 ±18; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,211 / 1,222 / 1,224, mean 1,210 ±18; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_down | 955 / 1,074 / 1,100, mean 913 ±242; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,803 / 1,812 / 1,815, mean 1,803 ±13; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,846 / 1,851 / 1,852, mean 1,844 ±10; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_up | 983 / 1,177 / 1,221, mean 979 ±281; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,767 / 1,802 / 1,810, mean 1,777 ±35; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,779 / 1,791 / 1,794, mean 1,781 ±14; ok 3/3; confirmed 0/3 [0.00-0.56] |
| close_session | 677 / 894 / 942, mean 731 ±221; ok 3/3; unverified | - | - |

</details>
<details>
<summary>TextEdit (AppKit)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 12 / 15 / 16, mean 12 ±8; ok 2/2; unverified | 11 / 12 / 12, mean 11 ±1; ok 2/2; unverified |
| open_session | 2,003 / 2,394 / 2,482, mean 1,888 ±756; ok 3/3; unverified | - | - |
| observe | 62 / 93 / 100, mean 62 ±44; ok 3/3; unverified | 190 / 197 / 198, mean 185 ±18; ok 3/3; unverified | 191 / 200 / 202, mean 190 ±14; ok 3/3; unverified |
| observe_unchanged | 56 / 61 / 62, mean 57 ±6; ok 3/3; unverified | 48 / 55 / 57, mean 49 ±8; ok 3/3; unverified | 51 / 52 / 52, mean 51 ±1; ok 3/3; unverified |
| click | 294 / 302 / 304, mean 294 ±21; ok 2/3; confirmed 2/3 [0.21-0.94] | 1,411 / 1,421 / 1,424, mean 1,398 ±38; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,385 / 1,407 / 1,411, mean 1,393 ±18; ok 3/3; confirmed 0/3 [0.00-0.56] |
| type | 280 / 342 / 356, mean 297 ±61; ok 3/3; confirmed 2/3 [0.21-0.94] | 1,234 / 1,252 / 1,256, mean 1,226 ±39; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,169 / 1,175 / 1,177, mean 1,170 ±8; ok 3/3; confirmed 3/3 [0.44-1.00] |
| undo | 441 / 462 / 467, mean 438 ±35; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,186 / 1,214 / 1,221, mean 1,192 ±31; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,162 / 1,178 / 1,181, mean 1,168 ±13; ok 3/3; confirmed 0/3 [0.00-0.56] |
| key | 412 / 924 / 1,039, mean 610 ±434; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,250 / 1,273 / 1,279, mean 1,251 ±32; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,238 / 1,240 / 1,240, mean 1,236 ±5; ok 3/3; confirmed 3/3 [0.44-1.00] |
| hotkey | 393 / 411 / 415, mean 382 ±45; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,179 / 1,213 / 1,220, mean 1,186 ±36; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,182 / 1,186 / 1,187, mean 1,180 ±10; ok 3/3; confirmed 3/3 [0.44-1.00] |
| scroll_down | 310 / 924 / 1,062, mean 554 ±513; ok 3/3; confirmed 2/3 [0.21-0.94] | 1,709 / 1,796 / 1,816, mean 1,728 ±93; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,716 / 1,717 / 1,717, mean 1,710 ±12; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_up | 379 / 915 / 1,036, mean 598 ±443; ok 3/3; confirmed 3/3 [0.44-1.00] | 1,711 / 1,732 / 1,736, mean 1,691 ±66; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,711 / 1,724 / 1,727, mean 1,715 ±12; ok 3/3; confirmed 0/3 [0.00-0.56] |
| menu | 1,363 / 1,375 / 1,378, mean 1,364 ±15; ok 3/3; confirmed 3/3 [0.44-1.00] | 425 / 449 / 454, mean 423 ±37; ok 3/3; confirmed 3/3 [0.44-1.00] | 475 / 477 / 477, mean 465 ±21; ok 3/3; confirmed 3/3 [0.44-1.00] |
| close_session | 729 / 818 / 838, mean 732 ±121; ok 3/3; unverified | - | - |
| observe_after | - | 46 / 56 / 59, mean 46 ±15; ok 3/3; unverified | 41 / 45 / 45, mean 42 ±4; ok 3/3; unverified |
| front_restored | -; ok 1/1; unverified | -; ok 1/1; unverified | - |

</details>
<details>
<summary>kitty (OpenGL/GLFW)</summary>

Cell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.

| Operation | Braus | Cua | Cua overlay |
|---|---|---|---|
| list_windows | - | 15 / 20 / 21, mean 15 ±13; ok 2/2; unverified | 10 / 10 / 11, mean 10 ±2; ok 2/2; unverified |
| open_session | 2,525 / 3,057 / 3,177, mean 2,460 ±866; ok 3/3; unverified | - | - |
| observe | 336 / 386 / 398, mean 286 ±163; ok 3/3; unverified | 209 / 213 / 214, mean 190 ±42; ok 3/3; unverified | 168 / 170 / 170, mean 168 ±3; ok 3/3; unverified |
| observe_unchanged | 135 / 287 / 322, mean 181 ±144; ok 3/3; unverified | 37 / 37 / 37, mean 36 ±1; ok 3/3; unverified | 38 / 41 / 42, mean 39 ±3; ok 3/3; unverified |
| type | 816 / 1,018 / 1,063, mean 819 ±280; ok 3/3; unverified | -; ok 0/3; confirmed 0/3 [0.00-0.56] | -; ok 0/3; confirmed 0/3 [0.00-0.56] |
| key | 978 / 1,091 / 1,117, mean 952 ±206; ok 3/3; unverified | 1,259 / 1,263 / 1,264, mean 1,258 ±8; ok 3/3; unverified | 1,222 / 1,224 / 1,225, mean 1,217 ±12; ok 3/3; unverified |
| hotkey | 952 / 998 / 1,008, mean 937 ±92; ok 3/3; unverified | 1,212 / 1,214 / 1,214, mean 1,199 ±27; ok 3/3; unverified | 1,145 / 1,153 / 1,155, mean 1,148 ±7; ok 3/3; unverified |
| scroll_down | 1,003 / 1,061 / 1,073, mean 950 ±179; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,708 / 1,736 / 1,742, mean 1,698 ±58; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,701 / 1,702 / 1,703, mean 1,699 ±5; ok 3/3; confirmed 0/3 [0.00-0.56] |
| scroll_up | 1,011 / 1,067 / 1,079, mean 1,032 ±47; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,674 / 1,708 / 1,715, mean 1,687 ±28; ok 3/3; confirmed 0/3 [0.00-0.56] | 1,709 / 1,714 / 1,715, mean 1,710 ±5; ok 3/3; confirmed 0/3 [0.00-0.56] |
| close_session | 951 / 1,017 / 1,031, mean 951 ±94; ok 3/3; unverified | - | - |

</details>
