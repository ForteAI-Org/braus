# Canvas perception

A canvas is a window area whose drawn content the accessibility tree does not describe.
The scene names the area and whether its pixels changed; a separate request returns pictures.
The scene itself holds no image. This describes issue #16 as implemented on 3 November 2026.

## Finding canvases and reading the scene

`AccessibilityAugmentation` accepts opaque `AXGroup`, `AXImage`, `AXScrollArea`,
`AXLayoutArea`, `AXUnknown` and empty-role nodes outside controls and collections.
A candidate needs no title, description or value, no readable descendant and no unread child
list. The outermost candidate wins. Its visible frame must be at least 64×48 window points
and cover less than 90% of the window. There are at most 16 canvases.

Some applications draw where there is no accessibility element at all. After a complete
coverage walk, `UncoveredAreas.swift` finds holes on an 8-point grid. Any visible descendant
frame touching a cell covers it. It excludes the top 28 points and an 8-point border;
a hole must be at least 40 points on both axes and 5% of the window area. Largest,
non-overlapping rectangles win, then sort top to bottom and left to right. A hole over
90% of the window rejects the hole result: an almost empty tree cannot establish coverage.

`ScenePipeline.withoutEmptyCanvases` samples colour spread. A described canvas with spread
at most 8 levels is dropped as flat; a failed sample keeps it. A hole is admitted only with
spread greater than 8, sampled one grid cell inside its edge to avoid adjacent controls.
OCR text inside a canvas remains in the scene.

A compact scene line looks like:

```text
[canvas] canvas 1 [changed] @15,23 82x44
```

Position and size are whole percentages of the window, with a top-left origin.
The marker is `[changed]` or `[unchanged]`; the first observation has neither.
Element canvases receive ordinals in tree order, holes after them in position order.
Ordinals are assigned before empty regions are filtered, so gaps are possible.
The canonical ID is `canvas|canvas1`; identity follows ordinal position, not document content.
Use a fresh scene after a layout change. `CanvasTiles` compares matching IDs; incompatible
capture or region sizes count as a whole-region change, while a new ID stays unmarked.

## Tiles, noise and retained history

`RegionTileDiff` samples each region independently at downscale 4, then hashes 8-pixel
reduced tiles. Each tile spans 32 **capture pixels**: 32 window points at 1× capture scale,
16 at 2×. Coordinates in this component are image pixels. Equal hashes return immediately;
otherwise reduced RGBA channels are compared. A tile changes only if some channel differs
by more than 6 levels. Captures of unchanged content can jitter by a level or two across
the window; exact hashes alone would mark all of it changed. Fixed samples can miss detail
thinner than four capture pixels.

`CanvasNoise` learns a tile after two idle comparisons in which it changed, and forgets
it after 30 idle comparisons without a change. Input comparisons advance the baseline
without teaching or forgetting. It uses the same 6-level tolerance. Size or grid changes
reset learning. When learned noise covers more than 50% of tiles, `isAlwaysChanging` is true
and the mask is empty, so moving video cannot disappear behind a noise mask.

`CanvasHistory` follows one window and retains two generations of canvas-only bitmaps,
not full window captures. Each generation has a 16 MiB pixel budget, reduced together when
necessary: 32 MiB total retained pixel payload, excluding hashes, counters, scenes and other
overhead. Changing windows or losing canvases resets the history. `noteAction(at:)` receives
the window points of delivered gestures, including both drag endpoints, for the next
observation's crop. `learnIdle` teaches from intermediate frames without replacing either
observation. Unknown or out-of-order frame times count as input; idle learning must never
turn an action's change into noise.

## Crops, captions and privacy

`CanvasCrop.layout` intersects changed tiles with the canvas, groups tiles less than
24 points apart, and selects the group at or nearest each eligible action point. Multiple
selected groups are united. With no eligible point it chooses the largest group. Points
farther than 24 points outside the canvas are ignored; points in that outer margin still
participate. Other changed regions are omitted, not learned as noise.

The selected bounds grow by a 24-point margin, clip to the canvas and round inward to
whole window points. Default output is 1 pixel per point; explicit zoom 2 requests two.
If the selected region's bounding area exceeds 60% of the canvas, the whole canvas is used
and its long edge is capped at 1280 pixels, reducing the effective zoom if needed.
The same rectangle is rendered before and after as PNG. Uncovered source areas are grey.
The long-edge cap applies to whole-canvas output, not every small-region crop.

`CanvasCaption` uses only text already in the scene. It supplies row names up to 240 points
left of the canvas, ruler labels up to 40 points above it, and a heading from the container,
section or single label above. Named row groups replace their individual control labels;
the outermost group under half the canvas height wins. Ranges are translated into crop
pixels and may lie outside the crop. Editable labels are excluded.

`CanvasPrivacy` checks intersecting scene elements before rendering. Editable fields are
blanked grey in both pictures. A secure field (`AXSecureTextField`, including the normalized
secure subrole) or an editable field whose label or value is withheld refuses the entire
crop. A withheld non-editable element is blanked. Changed pairs check both scenes and apply
the union of blanking rectangles. This relies on observed scene geometry and the caller's
withholding policy; it does not detect secrets inside arbitrary drawn pixels.

## The canvas tool

Call `canvas` after observing the held Seat window, and observe again after an action
before asking for its pictures:

```json
{"id":"canvas 1","zoom":1}
```

`id` is required and accepts `canvas 1`, `canvas1` or `canvas|canvas1` (positive ordinal,
no leading zero). `zoom` is optional, defaults to 1 and accepts only 1 or 2; other arguments
are refused. The tool reads retained history without capturing, advancing the scene or
saving images in the action archive. Missing history, unknown IDs, unavailable pixels
and privacy refusal are errors.

A changed result contains one text block followed by two MCP `image` blocks, before then
after, with base64 PNG data and `mimeType: image/png`. An unchanged or unavailable pair
falls back to one current whole-canvas picture when current pixels exist. Text gives the
canonical ID, origin and size in window points, requested and effective zoom, PNG dimensions,
picture order, caption and estimated image tokens. To map a picture pixel point back:

```text
window point = crop origin + picture point / effective zoom
```

Both coordinates use a top-left origin. These coordinates describe the picture; they do
not authorize point input into it.

## Worker loop and chat pictures

`ModelToolLoop` decodes MCP image blocks into `TurnImage` values beside the result text.
The current run keeps images across tool rounds. Anthropic sends base64 image sources
inside `tool_result`; Gemini sends `inlineData` parts beside the function response and
sets `MEDIA_RESOLUTION_LOW` when both image edges are at most 768 pixels and the model
name selects the supported generation 3 or 4 families.
Ollama sends a base64 `images` array on the tool message. CLI providers receive the MCP
image blocks through their bridge. A model without known vision support gets the text
`picture omitted: this model does not read images` instead of images. At a later run or
summary boundary, `forHistory` replaces each picture with
`[picture omitted from earlier turn]`; it must not rewrite an active tool loop's prefix.

The app records tool pictures separately for the transcript. Under a tool line the chat
shows only the last picture, the after image of a pair. Its label comes from the first
caption line, otherwise the first result line, and passes through withholding. The row's
VoiceOver action says `Open pictures of <label>` (or `Open pictures`). Clicking once opens
the displayed picture through `ConversationEnlargedPictures` in the window's SwiftUI
overlay; closing returns it to the small picture. This uses the window's existing overlay,
not a view manually added above its hosting view.

## Human-control report

`HumanInterventionCanvases` keeps a separate history per window in an episode. It observes
at handoff and after actions, and the person's input counts as input for noise learning.
It currently supplies no action points to crop selection, so this path chooses the largest
changed region. Safe changed crops join the findings; refused or failed crops are omitted.
The digest adds a line such as:

```text
Canvas changed: Timeline (human_step picture 3).
```

The shorthand names `human_step` with `{"picture":3}`. For a step with canvas changes it
returns the caption and PNG before/after pair; it is available during the resumed turn.
Steps can contain more than one canvas pair. There is no canvas line or crop when only
masked noise changes. The consumer takes up to four idle frames 200 ms apart after reads
to teach noise, stopping on input, a pressed button, failed capture or cancellation.
The existing per-click picture remains a separate path.

## Isolated runs and fixtures

`Tools/IsolatedRun/run.sh <script.json> [--keep-open]` builds and launches a model-free
worker with disposable state. Set `SCRATCH` to a fresh absolute scratch directory.
The runner exports `BRAUS_ISOLATED_RUN=1`, `BRAUS_APP_SUPPORT_DIR`, `BRAUS_SCRIPTED_WORKER`,
`BRAUS_SCRIPTED_CHECK=1`, `BRAUS_SCRIPTED_CHECK_QUIT`, `CFFIXED_USER_HOME` and `TMPDIR`.
`BRAUS_ISOLATED_REBUILD=1` forces rebuilding. Preferences, caches and logs are redirected;
missing cache-redirection support refuses the launch. `audit.sh` compares shared storage
before and after; `clean.sh` cleans the owned run using its recorded process identity.
`isolated-audit` keeps `scripted-check.json`, the shutdown receipt, log and
`scripted-tools.jsonl`. The JSONL names returned PNGs and their dimensions and byte counts;
`image-N.png` files stay in the run's support directory, not the copied audit directory.
Inspect the receipts, not just exit.

A script is a JSON array of rounds: non-final rounds contain a nonempty `calls` array
of `{"tool":"name","arguments":{}}`; the final round contains only a nonempty `answer`.
At most 100 tool rounds run serially through the real loop. A `$session` argument uses
the last successful earlier round's session ID. Tool failures are logged and execution
continues; this exercises tool delivery without model interpretation.

`Tools/Fixtures/CanvasFixture/build.sh <outdir>` builds a standalone fixture with native
controls, a timeline, picture and empty surface. Flags are `--still`, `--meter-phase 0...1`,
`--clip-offset lane:points` (lanes 1...4) and `--meter-two-levels`. Still disables timer
animation. Two-level mode takes precedence and steps the meter and caret between extremes
only on the distributed notification
`dev.forte.CanvasFixture.step`, preventing capture cadence from aliasing a timer.
`record.sh <workdir>` regenerates fixture recordings; with an app argument it records
outside the repository, using `BRAUS_CANVAS_RECORDINGS` and optional `BRAUS_CANVAS_DOCUMENT`.
Recording and live checks need an awake display, permissions and exclusive desktop use.

The live scenario uses a native idle baseline and a delivered drag on the fixture. It checks
that meter-only changes yield no canvas line, then verifies the report, tool blocks and
PNG pair for the moved clip. With a fixture already built, run from the repository root:

```sh
BRAUS_LIVE_REPORT=canvas BRAUS_CANVAS_FIXTURE="$SCRATCH/fixture/CanvasFixture.app" \
BRAUS_CANVAS_EVIDENCE_DIR="$SCRATCH/canvas-evidence" \
/usr/bin/swift test --disable-sandbox --filter HumanInterventionLiveTests
```

## Costs

Release measurements on 3 November 2026 used an Apple M4, 16 GiB, macOS 27.0.1
(26A434), Swift 6.4.2, two warm runs and 20 untimed warmups per operation. These were
loaded-host measurements, taken **before action-region cropping and colour tolerance**.
They exclude capture, accessibility/OCR, transport serialization and network.

| Operation | Samples | Median ms | p95 ms |
| --- | ---: | ---: | ---: |
| Fixture hash + diff | 2000 | 0.455 | 1.283 |
| Fixture hole search | 2000 | 0.047 | 0.098 |
| Fixture history observation | 600 | 0.929 | 1.829 |
| Pro Tools hash + diff | 2000 | 0.026 | 0.049 |
| Pro Tools hole search | 2000 | 0.090 | 0.251 |
| Pro Tools history observation | 600 | 0.157 | 0.866 |
| Tool changed pair | 400 | 0.854 | 2.401 |
| Tool unchanged whole | 400 | 5.175 | 15.831 |
| Tool changed pair, zoom 2 | 400 | 6.338 | 10.537 |

The fixture was a recorded 1100×732 image; Pro Tools used synthetic 1× pixels with a
1515×923 window's recorded geometry, not a live clip edit. Tool timings include privacy,
caption, PNG encoding and base64/result construction. The earlier changed pair was
400×112, 8,722 PNG bytes and 120 estimated Claude tokens; current changed-pair geometry
is 368×112, **112 estimated Claude tokens** for both images. The earlier whole canvas
was 900×320, 17,452 bytes and 396 tokens; zoom 2 was 800×224 ×2, 26,524 bytes and 464 tokens.
No new latency or byte measurement is implied by the smaller current geometry.

Retained pixels plateaued after two generations: 3,097,600 bytes for the fixture,
1,331,200 for Pro Tools and 33,530,976 for a reduced 4000×3000 stress case. An offline
30-second idle proxy used 0.220% of one core (sleeping control 0.011%); it did not measure
live capture, accessibility/OCR or intermediate idle-frame cadence. Whole-canvas fallback
occurred in 8 of 14 replay calls without learned noise; that is not a live usage estimate.

The picture/token experiment tested two clip moves, with two repeats per question. A 1×
changed crop pair with 24-point context answered movement and exact-name questions correctly
in all trials across three models; whole-window after-only pictures did not establish movement.
Padding those crops to multiples of 28 pixels gave Claude token parity (104/96 per pair),
but raised GPT estimates from 86.4/72 to 115.2/105.6. Padding is not part of the implementation.
The outlined after-only variant had one name abstention, so the pair was the cheapest tested
representation with full accuracy across all three models. Gemini was unavailable in that
experiment. These are geometric token estimates, not measured marginal billing, and four
trials per question do not establish general reliability.

## Limits

Acting inside a canvas with clicks or drags by point is not supported yet; Pro Tools'
track area, for example, is read only. In the human report the crop is the largest changed
region, since the person's input brings no points: a clip the person moved in Pro Tools came
back as its lane with the ruler above it (1056×152 of a 1096×776 timeline), the whole
timeline only when the person also cleared a selection across the tracks.
