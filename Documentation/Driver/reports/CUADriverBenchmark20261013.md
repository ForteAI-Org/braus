# Braus vs Cua Driver: macOS benchmark

**13 October 2026 · Apple M4, 16 GB RAM · macOS 27.0.1 (26A434)**

**Naming:** Braus is the new name of the product recorded as Mecum in this experiment. Product labels use Braus; measured revisions, recorded driver IDs, binary names, environment variables and historical source references are retained verbatim.


This experiment compares Braus's desktop worker backend with Cua Driver 0.34.0 on the same Mac. It includes individual operations in ten applications, reads, short action chains, a 40-step memory run and five tasks driven by a real model. Cua was tested both directly and with its cursor overlay through an embedded daemon.

Braus returned less estimated context in every full-read application row. Its matched-operation timing summaries were lower in most application scenarios, but it used more CPU and memory than Cua without the overlay. In the real-model phase, Braus passed three of five tasks; Cua passed all five, including a Prism task outside its declared background support. These are separate measurements, not a single ranking of the products.

The measured Braus revision is **`b737e719d36f04195c1eebfeb026946ea9c0f475`** (`b737e71` in the experiment output). This report describes that candidate, not an identified released installer. The macOS build required Braus's research opt-in. Application UI performance, broad framework compatibility and simultaneous-user input safety were not qualified by this run.

[Results](#results) · [Failures and UI effects](#failures-and-ui-effects) · [Real-model tasks](#real-model-tasks) · [Resources](#resources) · [Changes since 6 October](#changes-since-6-october) · [Method](#method) · [Reproduction](#reproduction) · [Detailed measurements](CUADriverBenchmark20261013Details.md)

## Results

### The main measurements

| Measurement | Braus | Cua direct | Cua overlay |
| --- | --- | --- | --- |
| Estimated tokens per full read, median across ten apps | 351 | 2,156 | 2,156 |
| Estimated tokens per unchanged / diff read, median across ten apps | 38 | 67 | 67 |
| Median driver footprint | 87.0 MB | 12.7 MB | 173.1 MB |
| Peak driver footprint | 222.2 MB | 106.5 MB | 3,967.3 MB |
| Idle driver CPU, median of the per-app operation-phase idle windows | 6.26 ms/s | 0.02 ms/s | 824.84 ms/s |
| Driver CPU during actions, source summary | 185.3 ms/s | 57.0 ms/s | 906.0 ms/s |
| Real-model tasks: confirmed pass / decided runs | 3/5 | 5/5 | 4/4, plus one inconclusive run |

CPU milliseconds per second are process CPU time divided by elapsed wall time; they are not wall-clock latency. The overlay column represents the embedding layout tested here, not the installed CuaDriver.app path.

The full-read median is approximately **84% lower** for Braus than Cua, calculated as `1 − 351 / 2,155.5` before rounding. Across individual paired apps, the reduction is **67.5–95.4%**. This is estimated tool-response context, not billed cost or complete-task token savings. The median comparison is a ratio of medians, not the median of per-app percentage reductions.

### Estimated context per read

Braus returns a structured text scene. Cua's full read returns a screenshot and a capped accessibility tree. Both Cua variants also have a compact diff-read path in this run.

| Application | Braus full | Cua full | Cua overlay full | Fewer estimated tokens vs Cua |
| --- | --- | --- | --- | --- |
| Calculator | 190 | 730 | 730 | 74.0% |
| DaVinci Resolve | 360 | 2,160 | 2,160 | 83.3% |
| Google Chrome | 399 | 3,195 | 3,198 | 87.5% |
| Obsidian | 652 | 2,866 | 2,866 | 77.3% |
| Photoshop | 340 | 1,047 | 1,047 | 67.5% |
| Prism Launcher | 326 | 2,151 | 2,151 | 84.8% |
| Safari | 432 | 3,107 | 3,108 | 86.1% |
| Stocks | 621 | 3,649 | 3,649 | 83.0% |
| TextEdit | 342 | 1,736 | 1,740 | 80.3% |
| kitty | 80 | 1,741 | 1,741 | 95.4% |

| Application | Braus unchanged | Cua diff | Cua overlay diff |
| --- | --- | --- | --- |
| Calculator | 37 | 60 | 60 |
| DaVinci Resolve | 37 | 60 | 60 |
| Google Chrome | 38 | 92 | 93 |
| Obsidian | 38 | 82 | 82 |
| Photoshop | 38 | 10 | 10 |
| Prism Launcher | 37 | 60 | 60 |
| Safari | 38 | 92 | 82 |
| Stocks | 38 | 60 | 60 |
| TextEdit | 38 | 74 | 74 |
| kitty | 38 | 74 | 74 |

Text is estimated at four characters per token. Images use `width × height / 750` after resizing. A smaller response is not proof of equivalent information, faster observation or better task completion. The complete read-latency and text/image breakdown is in the [details](CUADriverBenchmark20261013Details.md#6-reads).

Photoshop's unchanged/diff result is a counterexample to a universal context advantage: Braus returned 38 estimated tokens versus 10 for both Cua variants. Action-result context also varies: Braus's response is larger in some rows. Full-read savings must not be applied to every action or the entire conversation.

### Equivalent step latency

An equivalent step returns an action result and an updated view:

- **Braus:** one action call already returns the scene.
- **Cua:** `run_actions` with `observe:true`; menu actions add a diff read.

Each value below is the source's **weighted median of per-operation p50 values**, weighted by reported-completed repetitions, for operation types present in every driver's successful-response set. It is not a median recomputed from all raw step samples, and a successful response is not necessarily an independently confirmed effect. Only a few repetitions contribute to each operation.

| Application / framework | Matched operation types | Braus (ms) | Cua (ms) | Cua overlay (ms) |
| --- | --- | --- | --- | --- |
| Calculator (SwiftUI) | 3 | 412 | 1,227 | 1,203 |
| DaVinci Resolve (Qt + GPU UI) | 4 | 384 | — | — |
| Google Chrome (Chromium) | 6 | 1,174 | 1,535 | 1,735 |
| Obsidian (Electron) | 5 | 844 | 1,256 | 1,203 |
| Photoshop (Adobe proprietary toolkit (UXP)) | 4 | 1,151 | 1,168 | 1,164 |
| Prism Launcher (Qt 6) | 2 | 412 | — | — |
| Safari (WebKit) | 8 | 864 | 1,267 | 1,195 |
| Stocks (Mac Catalyst) | 3 | 955 | 1,767 | 1,779 |
| TextEdit (AppKit) | 8 | 393 | 1,234 | 1,182 |
| kitty (OpenGL/GLFW) | 4 | 978 | 1,259 | 1,222 |

The operation sets exclude types with no successful response from a driver. This is a timing comparison of that shared subset, not an overall measure of reliability. Photoshop's times are close; its matched subset excludes the document/menu operations that Cua refused.

**Qt boundary.** As in the [6 October report](CUADriverBenchmark20261006.md#qt-background-support), Cua's cited macOS documentation places Qt/GPU interactions outside its declared background support. Its Resolve and Prism action timings are therefore shown as dashes here. Both variants were nevertheless tried: the probe confirmed their simple click effects, and the Prism real-model task passed. The [details](CUADriverBenchmark20261013Details.md#4-equivalent-step-per-application) retain those measured timings. A dash means outside declared support, not an unattempted or failed operation. None of these checks proves general Qt or Resolve GPU editing support.

The source's all-application weighted step summary is 864 ms for Braus, 1,352 ms for Cua and 1,335 ms for Cua overlay. It includes those Qt attempts and response-completed operations without verified effects; it must not be presented as an in-support, successful-task speedup.

### Driver-reported completions and probe checks

The source counts below are reported-done / attempted action calls, followed by independently confirmed effects / checkable calls. They are not task completion or a percentage of framework support. Unverified actions are kept distinct.

| Application | Braus reported done; confirmed effect | Cua reported done; confirmed effect | Cua overlay reported done; confirmed effect |
| --- | --- | --- | --- |
| Calculator | 10/10; 6/6 | 10/10; 6/6 | 9/9; 6/6 |
| DaVinci Resolve | 13/13; 3/9 | — | — |
| Google Chrome | 18/21; 12/21 | 21/21; 11/18 | 21/21; 10/18 |
| Obsidian | 15/15; unverified | 15/15; unverified | 16/16; unverified |
| Photoshop | 16/18; 6/8 | 12/27; 0/18 | 12/27; 0/18 |
| Prism Launcher | 6/6; 3/6 | — | — |
| Safari | 24/24; 12/18 | 25/25; 9/18 | 25/25; 5/18 |
| Stocks | 9/9; 0/9 | 9/9; 0/9 | 9/9; 0/9 |
| TextEdit | 24/25; 18/24 | 25/25; 12/24 | 24/24; 12/24 |
| kitty | 15/15; 0/6 | 12/15; 0/9 | 12/15; 0/9 |

Across all attempted scenarios, including the out-of-declaration Qt attempts, the source totals are 150/156 reported done and 60/107 probe-confirmed for Braus; 148/166 and 44/117 for Cua; 147/165 and 39/117 for Cua overlay. The denominators differ because the call and checkable-effect sets differ. The details retain Wilson 95% intervals; with three or fewer observations in many individual rows, no broad reliability ranking follows.

## Failures and UI effects

### Cases that need attention

| Case | Recorded outcome |
| --- | --- |
| Braus / Chrome menu | All three tested Bookmarks menu calls were refused as disabled. Cua's corresponding menu calls returned successful responses; their effects were not independently verified. |
| Braus / TextEdit | One click could not resolve the label `Line two.`; two of three click effects and two of three typing effects were confirmed. The separate real-model TextEdit task failed. |
| Braus / Photoshop | One of three session opens failed. Two document-create, confirm and close effects were confirmed; two `Don't Save` attempts returned `honest_miss`. This does not establish full Photoshop or Adobe Suite support. |
| Cua / Photoshop | Document-create, rotate and close menu calls were refused as disabled. The generic framework matrix omits some of these workflow operations, so it must not be used to claim that all tested Photoshop actions passed. |
| kitty | Cua's operation-phase `type` calls failed, but its separate real-model kitty task passed. Braus's real-model kitty task failed. Those results describe different procedures and checks. |
| Unconfirmed action effects | Scroll, key or menu rows can return a successful response without a readable effect. For example, Stocks has 0/9 confirmed effects for all drivers despite reported-completed actions. |

The probe reads AX values, frontmost application, cursor position and window placement. Not every pixel change, menu effect or keyboard operation has a suitable independent oracle. A driver verdict must not be promoted to a confirmed outcome, and an unreadable effect must not automatically be described as a proved failure.

### Foreground and cursor observations

| Source operation-phase probe totals | Braus | Cua | Cua overlay |
| --- | --- | --- | --- |
| Calls probed | 407 | 435 | 435 |
| Frontmost application changed | 3 | 4 | 1 |
| Cursor moved during the call | 15 | 30 | 11 |
| Target window on the person's display | 1 | 0 | 0 |

These counters describe observed changes in the probe windows, not changes causally attributed to the driver. The person could use the Mac during the experiment. The source heading calls them action observations, but the denominator includes other probed calls too. The real-model phase has its own counters in the details.

This run does not prove zero focus changes, untouched user input or safe simultaneous typing. A separate sentinel-window test is needed to measure lost or leaked keystrokes and pointer interference.

## Real-model tasks

Each driver attempted five task scenarios once, through Claude Code and its MCP server. The team records the configured model identifier as `claude-sonnet-5-5`, with `medium` effort. Task success was decided by a separate result check, rather than the model's final message. Full prompts, resolved model identity, starting-state traces and per-category usage need the original run bundle for independent reproduction.

### Braus

| Task | Outcome | Wall time (s) | Recorded usage tokens | Reported cost (USD) | Tool calls |
| --- | --- | --- | --- | --- | --- |
| calculator | Pass | 21 | 59,381 | 0.064 | 8 |
| chrome-form | Pass | 23 | 50,883 | 0.033 | 6 |
| kitty | Fail | 15 | 29,711 | 0.020 | 4 |
| prism-toggle | Pass | 15 | 30,535 | 0.020 | 3 |
| textedit | Fail | 28 | 84,212 | 0.057 | 9 |

### Cua direct

| Task | Outcome | Wall time (s) | Recorded usage tokens | Reported cost (USD) | Tool calls |
| --- | --- | --- | --- | --- | --- |
| calculator | Pass | 20 | 190,965 | 0.235 | 3 |
| chrome-form | Pass | 18 | 220,155 | 0.123 | 3 |
| kitty | Pass | 24 | 263,026 | 0.112 | 9 |
| prism-toggle | Pass | 13 | 275,504 | 0.113 | 4 |
| textedit | Pass | 92 | 1,848,573 | 0.655 | 28 |

### Cua overlay

| Task | Outcome | Wall time (s) | Recorded usage tokens | Reported cost (USD) | Tool calls |
| --- | --- | --- | --- | --- | --- |
| calculator | Pass | 22 | 190,947 | 0.067 | 3 |
| chrome-form | Pass | 19 | 219,518 | 0.119 | 3 |
| kitty | Pass | 87 | 1,412,793 | 0.460 | 32 |
| prism-toggle | Pass | 10 | 208,368 | 0.081 | 3 |
| textedit | Inconclusive | 241 | 365,691 | n/a | 6 |

The source calls these token counts “billed tokens.” The available task parser sums input, output, cache-creation and cache-read usage. They are recorded provider/CLI usage totals, not equally priced token units. Costs are CLI-reported USD values, rounded here to three decimals; cache categories and charges cannot be reconstructed from the supplied Markdown alone. An inconclusive run has missing cost, not zero cost.

Braus passed Calculator, the Chrome form and the Prism toggle; kitty and TextEdit failed. Cua direct passed all five attempts. Cua overlay passed four decided attempts; TextEdit remained inconclusive after 241 seconds. The inconclusive attempt must remain visible when reporting 4/4.

Prism is outside Cua's declared Qt background support but was attempted and passed. The source's `ALL(supported)` rows exclude it only for Cua variants, producing different task sets. They are not a fair shared-task aggregate and are omitted here. Even on the same task, the single repetitions do not establish a stable success rate, speed advantage or billed-cost saving. A failed run's lower cost is not the cost of completing that task.

## Resources

Braus's median footprint is lower than the embedded-overlay layout but higher than Cua direct. Its CPU also exceeds Cua direct in the source's action and idle summaries. The driver is not the whole application's resource footprint; the target app and WindowServer are measured separately.

### Idle and chain behavior

The operation phase recorded one five-second idle window per block. Both the headline and team report label it the “last” window; this is not a long-idle steady-state experiment. Chain and soak phases have separate idle settings. Braus's 6.26 ms/s median exceeds the team's 1.5 ms/s open-session target.

The action chains were measured in Calculator and TextEdit, with 0- and 3-second pauses:

| Application | Driver | Pause (s) | Measured steps | Step p50 (ms) | First step (ms) | Later steps (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| Calculator | Braus | 0 | 12 | 764 | 603 | 770 |
| Calculator | Braus | 3 | 12 | 600 | 591 | 600 |
| TextEdit | Braus | 0 | 12 | 463 | 483 | 441 |
| TextEdit | Braus | 3 | 12 | 872 | 938 | 842 |

The full three-driver chains are in the [details](CUADriverBenchmark20261013Details.md#5-delay-between-steps). The source infers stream rest from a gap longer than 2.5 seconds; it does not observe a rest event. Its inferred resting-versus-warm difference is −168 ms for Calculator and +400 ms for TextEdit. The team summary combines some values from different apps, so there is no single validated “wake-up cost” for this run. Internal phase instrumentation was not run.

### Forty-step TextEdit memory run

| Driver | Steps | Memory samples | First footprint (MB) | Last footprint (MB) | Fitted slope (MB / 100 steps) | Errors / stalls |
| --- | --- | --- | --- | --- | --- | --- |
| Braus | 40 | 4 | 73.9 | 79.3 | +21.45 | 0 / 0 |
| Cua | 40 | 4 | 9.2 | 9.3 | +0.34 | 0 / 0 |
| Cua overlay | 40 | 4 | 168.0 | 168.5 | +18.20 | 0 / 0 |

The slopes are regressions over the recorded samples, scaled to 100 steps; 100 steps were not actually run. Braus's driver footprint rose over this short sequence. Four samples cannot distinguish retained caches from a leak or establish long-session stability.

The source reports zero latency drift using “last 50 versus first 50” calls. With only 40 steps those slices overlap; the available summarizer would compare the same set. That zero is not evidence of stable latency and is excluded as a performance result here. Energy, per-app CPU and memory data remain in the details; no battery-life claim follows from process counters.

## Changes since 6 October

The earlier experiment used Braus `b2b5070` and Cua `4f33cd6`. This run records Braus `b737e71` and Cua `c1c2b5f`. Cua now uses capped reads, compact diffs and a different action/observe loop, so the old 85–97% full-read comparison is historical rather than a current claim against Cua 0.34.0.

For Braus alone, the source recomputes a historical comparison on applications and operation types present in both runs:

| Source historical subset | 6 October | 13 October | Change |
| --- | --- | --- | --- |
| Weighted median of operation p50 values | 1,191 ms | 754 ms | −37% |
| Estimated full-read tokens, median | 680 | 351 | −48% |
| Full-read latency p50, source median | 425 ms | 260 ms | −39% |
| Median driver footprint | 131.7 MB | 87.0 MB | −34% |

These are source-derived historical subsets, not the all-app step aggregate (864 ms) and not a repeated identical experiment. Repetitions, software, starting scenes and the measured operation mix changed. Raw rows are needed to independently verify the exact historical subsets. The unchanged-read summary rounds to 38 → 38, so no precise percentage is claimed from those displayed integers.

Cua's own reduced response sizes are not a Braus improvement. The [source change notes](CUADriverBenchmark20261013Details.md#16-changes-since-6-october) are retained with that distinction. Current support remains specific to the tested capability and task; newly accepted basic calls do not qualify an entire framework.

## Method

### Machine and software

| Item | Recorded configuration |
| --- | --- |
| Mac | Mac16,1; Apple M4; 10 cores; 16 GB RAM |
| OS | macOS 27.0.1, build 26A434 |
| Power / thermal | AC power; battery 100%; low-power mode off; thermal state nominal |
| Displays | 1512 × 982 built-in; 1920 × 1080 display |
| Stage Manager | Off (`GloballyEnabled = 0`) |
| Braus | `b737e71`; zero modified files reported; binary built 2026-10-13T12:58:55 |
| Cua | `cua-driver` 0.34.0; `c1c2b5f` (`c1c2b5fee428c3a39bebe5e77549c3d3525a608d` in source links); binary built 2026-10-13T12:59:11 |
| Cua host | CuaDriver.app not installed; direct MCP and embedded-daemon overlay variants |
| Experiment | 2026-10-13T12:58:37 to 2026-10-13T14:06:12; approximately 68 minutes |

The recorded build/run timestamps have no timezone suffix; they are reproduced without assigning a timezone. Application version numbers are absent from the supplied reports. The complete Braus commit ID was resolved from the repository during this documentation review; it is an ancestor of the current main revision.

### Paths and defaults

Braus used release `mecum-mcp-stdio`, one seat session per app block and a fresh knowledge directory. The source identifies its backend as `BrokeredAutomationSession` over `SeatBroker`, rather than the previous CLI `AutomationSession`. Watcher, watchdog, cursor fence, window follower and persistent stream remained enabled. `MECUM_BENCH_UNVALIDATED=1` is a research opt-in for an OS build outside the validated ledger, not OS qualification.

Cua direct used `cua-driver mcp --direct`. The overlay used `serve --embedded` plus an MCP proxy on the same socket, without installing CuaDriver.app. Telemetry was disabled; the default post-action window watch was retained. A faster, modified Cua configuration was not used. See the [component/path record](CUADriverBenchmark20261013Details.md#2-parity-of-the-components) for the measured configurations.

### Repetitions and checks

- **Operations:** ten apps, one warm-up excluded and three measured repetitions per operation/driver. The available harness splits those measured repetitions across forward/reverse ABBA passes; three is the total, not three additional repetitions in every block.
- **Chain:** Calculator and TextEdit, measured with 0- and 3-second pauses; per-scenario step counts are shown in the details.
- **Memory run:** TextEdit, 40 steps, four footprint samples per driver.
- **Tasks:** five scenarios, one attempt per driver, one configured model and effort level.

Latency is client wall time from request to reply, including JSON and pipe transport. Resource deltas are sampled around the call; the independent probe is outside that timing window. WindowServer readings have 10 ms resolution. Driver waits remain included.

The source's per-operation tables include p50/p90/p99 and normal 95% intervals for latency means; proportions use Wilson 95% intervals. With two or three samples, interpolated high percentiles do not describe rare-event tail latency. Source color markers based on thresholds and interval overlap are omitted: overlapping intervals and mixed “win” counts do not establish statistical equivalence or superiority.

### Limits and evidence scope

This report is an editorial review of two team-supplied Markdown outputs, not an independently rerun experiment. Raw JSONL, summary JSON, task transcripts, complete prompts and binary hashes were not supplied with those files. The harness at the resolved experiment revision was inspected read-only to confirm the repetition scheduler, usage-token categories and short-run drift calculation. No harness code was executed.

The run covers one machine on one day, a small operation set and limited starting windows. Probe blind spots, occasional person activity, response-completed rather than effect-completed timing, short idle windows and one real-model repetition per task limit the conclusions. There is no evidence here for universal application support, long-run reliability, zero input interference, learning efficacy, memory-related token savings or a released installer's behavior.

## Reproduction

The team records the harness under `Tools/Driver/CUAComparison/` and the raw outputs under its local `_bench/runs/<YYYYMMDD-HHMM>/` directory. That local path is a provenance hint, not an attached or public data bundle. A full reproduction needs the exact measured source revisions, build settings, fixtures, prompts, permissions and run files.

The source documents these commands, assuming the matching harness and both source checkouts are available:

```sh
cd Tools/Driver/CUAComparison
./bench.sh
./bench.sh --quick
./bench.sh --apps Calculator,TextEdit --reps 8 --phases
```

These are documented examples, **not the exact 13 October invocation**. Defaults in those examples differ from the recorded three-repetition, 40-step run. The source invocation record is retained in the details. The scripts build binaries when needed, launch apps and perform desktop actions; preparing this report did not execute them.

Keep the historical report unchanged. This dated report and its companion [details](CUADriverBenchmark20261013Details.md) add a new result at the measured revision; they do not update the product README or qualify a release.
