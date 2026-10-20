# Braus Restyling Mockup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the restyling as an in-app mockup on fake data, behind `BRAUS_RESTYLING=1`, with every surface of the design: the house, the ring, the task bar and window, the menu bar, the worker's screen window, voice, the conversation's motion and the mascot.

**Architecture:** A parallel set of views under `Views/Restyling/` and models under `Model/Restyling/`, reached only when `BRAUS_RESTYLING=1`; outside it the app is untouched. Native SwiftUI and AppKit components carry structure and controls; Core Animation carries motion; Metal renders the room light (hardware ray tracing where the GPU has it, light precomputed on the GPU elsewhere) and the voice orb. All timings and colours come from one constants file pinned by tests.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSPanel`, `NSStatusItem`, `NSPopover`, `NSWindow`, `NSVisualEffectView`), Core Animation, Metal and MetalKit (`MTKView`, `MTLAccelerationStructure`), Swift Testing.

**Spec:** [Design.md](Design.md), with the prototypes in [prototypes/](prototypes/). Read both; the prototypes' timings, shapes and colours are literal, their HTML technique is not.

## Global Constraints

- Work in the worktree `../mecum-app-restyling` on branch `elio/app-restyling`. Commits carry no co-author trailer and no person's name.
- Follow `CodeStyle.md`: one argument per line for multi-argument calls and declarations, aligned colons in small groups, one top-level type per file named after it, `///` doc comments that start with the type's name, no force-unwrap, no `try!`, visibility starts at `private`.
- Native first. Use the system component whenever one exists: `NavigationSplitView`, `.inspector`, `List(.sidebar)`, `.searchable`, `ContentUnavailableView`, `Button`, `Toggle`, `Picker`, `Menu`, `TextField`, `ProgressView`, `.keyboardShortcut`, `NSStatusItem`, `NSPopover`, `NSPanel`, `NSWindow` with `title` and `subtitle`, SF Symbols, `NSVisualEffectView` materials and `.glassEffect` on macOS 26. Never draw a fake control, fake traffic lights or a hand-made blur where the system has one. Custom drawing is for what the system lacks: the room light, the voice orb, the mascot, the ring's shape and the motion.
- Motion: Core Animation (`CABasicAnimation`, `CAKeyframeAnimation`, `CASpringAnimation`, `CATransaction`) wherever it reaches; Metal for room light and the voice orb; SwiftUI animation only where Core Animation cannot reach. Every animation goes through `RestylingMotion` (Task 2) so Reduce Motion turns travel, morph and bounce into a cross-fade or a cut.
- Dark only: the restyling root sets `NSApp.appearance = NSAppearance(named: .darkAqua)` and `.preferredColorScheme(.dark)`. Under Reduce Transparency every glass becomes an opaque surface of the same tone.
- Deployment target is macOS 15.0; anything from macOS 26 (`.glassEffect`, `ToolbarSpacer`) sits behind `if #available(macOS 26, *)` with a material fallback.
- Nothing costs CPU at rest: `MTKView`s render on demand (`isPaused = true`, `enableSetNeedsDisplay = true`); ambient motion (flicker, breathing) is a Core Animation layer animation, never a re-render.
- UI copy is English, matching the app. The prototypes' Italian gives the meaning.
- Mockup inputs are simulated: voice level, front app, task progress. No microphone or notification permission is requested.
- Build and test (from the worktree root; `DD` is a scratch derived-data folder such as `.scratch/dd`):
  - `xcodebuild -workspace BrausApp/AgentEnvironment.xcworkspace -scheme Braus -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build-for-testing`
  - `xcodebuild -workspace BrausApp/AgentEnvironment.xcworkspace -scheme Braus -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" test-without-building -only-testing:BrausTests/<SuiteStruct>`
- Run the mockup: `BRAUS_RESTYLING=1 BRAUS_APP_SUPPORT_DIR="$PWD/.scratch/restyling-support" "$DD/Build/Products/Debug/Braus.app/Contents/MacOS/Braus" & echo $!`. Stop it only with `kill <that pid>`, never a broad `pkill`. Do not drive the app with AppleScript.
- Files dropped in `BrausApp/App/Braus/` or `BrausApp/App/BrausTests/` join their targets automatically; a `.metal` file under `Braus/` compiles into the default library.

## Review Focus

- **VoiceOver users press Control-Option all the time.** The chord must not open the ring while VoiceOver runs, nor when Control-Option is held as a prefix for another key. Tests in Task 9.
- **The pointer is already resting on the ring when it appears.** No bar may open until the pointer has moved. Test in Task 10.
- **A Mac without hardware ray tracing (the M1 used for testing).** The precomputed path is chosen and renders without crashing; the override variable forces either path. Tests in Task 5.
- **Reduce Motion is on.** Every travel and morph becomes a cross-fade or a cut, and no breathing or flicker runs. Tests in Tasks 2, 4 and 12.
- **Several displays.** The ring, the bar and the voice orb appear on the screen that holds the pointer, never on the main screen by default. Tests in Tasks 10 and 16.

---

### Task 1: Mockup switch and dark root

**Files:**
- Create: `BrausApp/App/Braus/Model/Restyling/RestylingMode.swift`
- Create: `BrausApp/App/Braus/Views/Restyling/RestylingWindowView.swift`
- Modify: `BrausApp/App/Braus/BrausApp.swift` (the `WindowGroup("Braus")` at line 56, and `init`)
- Test: `BrausApp/App/BrausTests/Restyling/RestylingModeTests.swift`

**Interfaces:**
- Produces: `enum RestylingMode { static var isRequested: Bool; static func isRequested(in environment: [String: String]) -> Bool }`; `struct RestylingWindowView: View` (an empty dark root for now, filled by Task 7).

- [ ] **Step 1: Write the failing tests** `@Suite("RestylingMode") struct RestylingModeTests` with `@Test("Only the value 1 asks for the mockup")`: `#expect(RestylingMode.isRequested(in: ["BRAUS_RESTYLING": "1"]))`, `#expect(!RestylingMode.isRequested(in: [:]))`, `#expect(!RestylingMode.isRequested(in: ["BRAUS_RESTYLING": "0"]))`.
- [ ] **Step 2: Run them and see them fail** (build-for-testing fails on the missing type).
- [ ] **Step 3: Implement `RestylingMode`** reading `ProcessInfo.processInfo.environment`. In `BrausApp`, the window group's root is `RestylingWindowView()` when `RestylingMode.isRequested`, otherwise `TeamWindowView` as today; in `init`, set `NSApp.appearance` to dark Aqua only in mockup mode (defer to `applicationDidFinishLaunching` in `SeatReleasingDelegate` if `NSApp` is not ready). `RestylingWindowView` is a black `Color` with `.preferredColorScheme(.dark)`.
- [ ] **Step 4: Run the tests and see them pass.** Launch the mockup with the run command: the window is dark and empty; launch without the variable: the app is unchanged.
- [ ] **Step 5: Commit** `git commit -m "Add a switch that opens the restyling mockup"`.

### Task 2: Mock house, status light and motion constants

**Files:**
- Create: `Model/Restyling/WorkerStatus.swift`, `Model/Restyling/AppCategory.swift`, `Model/Restyling/MockWorker.swift`, `Model/Restyling/MockHouse.swift`, `Model/Restyling/RestylingTiming.swift`, `Model/Restyling/RestylingMotion.swift` (all under `BrausApp/App/Braus/`)
- Test: `BrausTests/Restyling/MockHouseTests.swift`, `BrausTests/Restyling/RestylingTimingTests.swift`

**Interfaces:**
- Produces:
  - `enum WorkerStatus: CaseIterable, Sendable { case busy, free, waiting, off }` with `var light: (red: Double, green: Double, blue: Double)?` (0...1) and `var lightStrength: Double`.
  - `enum AppCategory: CaseIterable, Sendable { case audio, video, design, web, files, general }`.
  - `enum MockBadge: Equatable, Sendable { case attention, unread(Int) }`.
  - `struct MockWorker: Identifiable, Sendable { let id: UUID; var name: String; var status: WorkerStatus; var activity: String; var category: AppCategory; var appearance: WorkerAppearance; var badge: MockBadge? }`.
  - `struct MockHouse: Sendable { var workers: [MockWorker]; var archivedCount: Int; var mostUsed: [String]; static let sample: MockHouse }`.
  - `enum RestylingTiming` with the motion table as `static let` seconds (names below).
  - `enum RestylingMotion { static var reducesMotion: Bool; static var reducesTransparency: Bool }` reading `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` and `…ReduceTransparency`, each overridable by a `static var override: Bool?` for tests.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test("Status light matches the design")
func statusLight() throws {
    let busy = try #require(WorkerStatus.busy.light)
    #expect(busy.red == 255.0 / 255 && busy.green == 176.0 / 255 && busy.blue == 72.0 / 255)
    let free = try #require(WorkerStatus.free.light)
    #expect(free.red == 48.0 / 255 && free.green == 209.0 / 255 && free.blue == 88.0 / 255)
    let waiting = try #require(WorkerStatus.waiting.light)
    #expect(waiting.red == 120.0 / 255 && waiting.green == 170.0 / 255 && waiting.blue == 1)
    #expect(WorkerStatus.off.light == nil)
    #expect(WorkerStatus.busy.lightStrength == 1 && WorkerStatus.free.lightStrength == 0.5)
    #expect(WorkerStatus.waiting.lightStrength == 0.9 && WorkerStatus.off.lightStrength == 0)
}

@Test("Timings match the motion table")
func timings() {
    #expect(RestylingTiming.ringBuildFirst == 2.0 && RestylingTiming.ringBuildLater == 0.45)
    #expect(RestylingTiming.dotsGlow == 1.35 && RestylingTiming.preparation == 0.55)
    #expect(RestylingTiming.zoneTravel == 0.5 && RestylingTiming.zoneSpread == 0.55)
    #expect(RestylingTiming.taskWindowGrow == 0.6)
    #expect(RestylingTiming.toMenuBar == 0.48 && RestylingTiming.fromMenuBar == 0.52)
    #expect(RestylingTiming.sendFlight == 0.56 && RestylingTiming.quoteFlight == 0.52)
    #expect(RestylingTiming.browsCalm == 0.36 && RestylingTiming.browsDecisive == 0.23)
    #expect(RestylingTiming.browStagger == 0.04)
    #expect(RestylingTiming.roomFlicker == 3.4 && RestylingTiming.waitingBreath == 2.2)
    #expect(RestylingTiming.headBreath == 6.5)
}
```

  And `@Test("The sample house")`: nine workers named Delivery, Render, Mastering, Ingest, Mixing, Design, Export, Research, PT Agent; Delivery busy (audio), Render busy (video, `.attention`), Mastering free (audio), Ingest waiting (files, `.unread(2)`), Mixing free (audio), Design free (design), Export waiting (design), Research free (web), PT Agent off; `archivedCount == 3`; `mostUsed == ["Delivery", "Ingest", "Research", "Render"]`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement the types.** Appearances come from `WorkerAppearance` with distinct palettes from `MascotPalette.all` so each worker has its own tint through `MascotImages.color(for:)`.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Commit** `git commit -m "Add the mockup's sample house, status light and timings"`.

### Task 3: Brow outlines and transitions

**Files:**
- Create: `Model/Restyling/BrowOutlines.json` (extracted), `Model/Restyling/BrowState.swift`, `Model/Restyling/BrowOutlines.swift`, `Model/Restyling/BrowTransition.swift`
- Test: `BrausTests/Restyling/BrowTests.swift`

**Interfaces:**
- Produces:
  - `enum BrowState: String, CaseIterable, Codable, Sendable { case idle = "IDLE", look = "LOOK", listening = "LISTENING", working = "WORKING", asking = "ASKING", done = "DONE", failed = "FAILED", offline = "OFFLINE" }` and `init(_ status: WorkerStatus)` (busy→working, free→idle, waiting→asking, off→offline).
  - `struct BrowOutlines: Sendable { let left: [BrowState: [CGPoint]]; let right: [BrowState: [CGPoint]]; static func load(from url: URL) throws -> BrowOutlines; static let bundled: BrowOutlines }` in the 240 × 170 artboard.
  - `struct BrowTransition: Equatable, Sendable { let movesLeft: Bool; let movesRight: Bool; let duration: Double; let leftDelay: Double; let rightDelay: Double; static func between(_ from: BrowState, _ to: BrowState, leftFirst: Bool) -> BrowTransition }`.

- [ ] **Step 1: Extract the outlines.** From `Documentation/App/Restyling/prototypes/sopracciglia.html`, take the JSON after `const OUT=` (up to the `;` that closes it) and write it to `Model/Restyling/BrowOutlines.json` unchanged: keys are the state raw values, each `{"L": [[x, y], …], "R": [[x, y], …]}` with 320 points.
- [ ] **Step 2: Write the failing tests.**

```swift
@Test("Every outline has 320 points")
func pointCount() {
    for state in BrowState.allCases {
        #expect(BrowOutlines.bundled.left[state]?.count == 320)
        #expect(BrowOutlines.bundled.right[state]?.count == 320)
    }
}

@Test("A brow whose group does not change holds still")
func holds() {
    let t = BrowTransition.between(.listening, .asking, leftFirst: true)
    #expect(!t.movesLeft && t.movesRight)
}

@Test("Calm states stagger, decisive states do not")
func timing() {
    let calm = BrowTransition.between(.idle, .listening, leftFirst: true)
    #expect(calm.duration == 0.36 && calm.leftDelay == 0 && calm.rightDelay == 0.04)
    let decisive = BrowTransition.between(.idle, .working, leftFirst: false)
    #expect(decisive.duration == 0.23 && decisive.leftDelay == 0 && decisive.rightDelay == 0)
}
```

- [ ] **Step 3: Run them and see them fail.**
- [ ] **Step 4: Implement.** Groups, copied from the prototype: left `idle z, listening a, asking a, offline a, working b, failed c, done d`; right `idle y, listening p, working q, asking q, offline r, failed r, done s`; `look` moves both. Decisive states are `working` and `failed` (duration `RestylingTiming.browsDecisive`, no delay); others use `browsCalm` and `browStagger` on the second brow.
- [ ] **Step 5: Run the tests and see them pass.**
- [ ] **Step 6: Commit** `git commit -m "Load the brow outlines and their transitions"`.

### Task 4: Mascot layer

**Files:**
- Create: `Views/Restyling/Mascot/MascotLayer.swift`, `Views/Restyling/Mascot/MascotFace.swift`
- Test: `BrausTests/Restyling/MascotLayerTests.swift`

**Interfaces:**
- Consumes: `BrowOutlines.bundled`, `BrowTransition`, `WorkerStatus`, `RestylingMotion`, `RestylingTiming`, `MascotImages.color(for:)`.
- Produces:
  - `final class MascotLayer: CALayer` with `var tint: NSColor`, `var status: WorkerStatus`, `var drawsBody: Bool` (false when Metal draws the body, Task 5), `func show(_ state: BrowState, animated: Bool)`, `func look(yaw: Double, pitch: Double)`, `func startBreathing()`.
  - `struct MascotFace: NSViewRepresentable { let appearance: WorkerAppearance; let status: WorkerStatus; let brows: BrowState; let size: CGFloat; var drawsBody: Bool = true }`.

- [ ] **Step 1: Write the failing tests.** `@Test("A calm change morphs both brows with a stagger")`: after `show(.idle, animated: false)` then `show(.listening, animated: true)` with `RestylingMotion.override` off, the left brow sublayer has an animation for key path `"path"` with duration 0.36 and the right one has `beginTime` 0.04 later. `@Test("Reduce Motion cuts instead of morphing")`: with reduce-motion override on, `show(.working, animated: true)` leaves no animation on either brow and the final path equals the working outline. `@Test("Reduce Motion stops breathing")`: `startBreathing()` adds no `"breathe"` animation under reduce motion.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Body: a `CAGradientLayer` of type `.radial` with the ibrows sphere stops (`#343230` 0, `#262423` 0.44, `#141313` 1), a tint layer in the worker's colour with `compositingFilter = "colorBlendMode"`, about 55% opaque at the centre falling to 10% at the edge, a sharp specular highlight and a thin bounce light at the bottom in `status.light` scaled by `lightStrength`. Brows: two `CAShapeLayer`s filled `#F5F5F7` (`#6E6E6E` when offline), placed by the ibrows numbers: span 54% of the width, gap 9%, brow line 36% from the top; each scaled from the 240 × 170 artboard. Morph with `CABasicAnimation(keyPath: "path")` and timing function `CAMediaTimingFunction(controlPoints: 0.65, 0, 0.35, 1)`. Breathing: `CABasicAnimation` on `transform.translation.y` by −0.45% of the height, `RestylingTiming.headBreath`, autoreverses, repeats forever. `look` shifts and narrows each brow as the prototype's `side()` does (yaw 0.62, pitch 0.30). Head colour never changes for done or failed; offline dims the body.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Commit** `git commit -m "Draw the mascot with morphing brows"`.

### Task 5: Room light in Metal

**Files:**
- Create: `Views/Restyling/RoomLight/LightingPath.swift`, `Views/Restyling/RoomLight/RoomLightUniforms.swift`, `Views/Restyling/RoomLight/RoomLightView.swift`, `Views/Restyling/RoomLight/RoomRenderer.swift`, `Views/Restyling/RoomLight/RayTracedRoomRenderer.swift`, `Views/Restyling/RoomLight/PrecomputedRoomRenderer.swift`, `Views/Restyling/RoomLight/RoomLight.metal`
- Test: `BrausTests/Restyling/RoomLightTests.swift`

**Interfaces:**
- Consumes: `WorkerStatus`, `MascotImages.color(for:)`.
- Produces:
  - `enum LightingPath: String, Sendable { case rayTraced, precomputed; static func choose(supportsRaytracing: Bool, override: String?) -> LightingPath }`; the override comes from `BRAUS_ROOM_LIGHT` (`raytraced` or `precomputed`).
  - `struct RoomLightUniforms: Equatable { var lightColor: SIMD3<Float>; var strength: Float; var tint: SIMD3<Float>; var hasOccupant: Bool; init(status: WorkerStatus, tint: NSColor, hasOccupant: Bool) }`.
  - `protocol RoomRenderer: AnyObject { func render(_ uniforms: RoomLightUniforms, into drawable: CAMetalDrawable, size: CGSize) }`, implemented by the two renderers.
  - `final class RoomLightView: MTKView` with `var uniforms: RoomLightUniforms` (setting it requests one render) and `let path: LightingPath`.

- [ ] **Step 1: Write the failing tests.** `@Test("Without hardware ray tracing the light is precomputed")`: `choose(supportsRaytracing: false, override: nil) == .precomputed`, `choose(supportsRaytracing: true, override: nil) == .rayTraced`, `choose(supportsRaytracing: true, override: "precomputed") == .precomputed`, `choose(supportsRaytracing: false, override: "raytraced") == .precomputed` (an override never asks for hardware the GPU lacks). `@Test("Uniforms follow the status")`: busy gives strength 1 and the amber colour, off gives strength 0. `@Test("The view renders on demand")`: a `RoomLightView` built with `MTLCreateSystemDefaultDevice()` has `isPaused == true` and `enableSetNeedsDisplay == true`; skip with `#require` when no device. `@Test("The precomputed path renders without hardware ray tracing")`: render one frame with `PrecomputedRoomRenderer` into an offscreen texture of 128 × 104 for a busy room; the centre pixel is brighter than a corner pixel and its red channel exceeds its blue.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement the scene.** A room seen straight from above (orthographic): a floor, four low walls (18% of the room's short side), the occupant as a sphere of radius 17% of the short side at the centre, lifted to touch the floor. The occupant lights the room: an area light just above the sphere in `lightColor × strength`. Output is the floor and walls with their light, the colour bleeding onto the walls, the sphere's soft contact shadow and the sphere body tinted with `tint`, its specular highlight and the bounce from the floor; the brows come from `MascotLayer` above it with `drawsBody = false`.
  - `RayTracedRoomRenderer`: a primitive acceleration structure of the triangles of floor, walls and a tessellated sphere; a compute kernel casts one primary ray per pixel, several shadow rays to the area light and one bounce; it accumulates 16 frames after a change and then stops.
  - `PrecomputedRoomRenderer`: a compute kernel evaluates the same scene analytically once per change (light falloff, wall bleed, analytic soft contact shadow, sphere shading) into a texture that is then drawn.
  - The busy flicker and waiting breath are `CABasicAnimation`s on the view layer's opacity (`RestylingTiming.roomFlicker`, `waitingBreath`), off under Reduce Motion.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Look at it.** Temporarily set `RestylingWindowView`'s body to one `RoomLightView` of 220 × 180 for a busy room, run the mockup twice, once with `BRAUS_ROOM_LIGHT=precomputed`, take `screencapture -l <windowid>` of each, compare with the room in `prototypes/casa.html`, then revert the temporary body.
- [ ] **Step 6: Commit** `git commit -m "Render the room light with ray tracing or precomputed light"`.

### Task 6: Sidebar in rooms or rows

**Files:**
- Create: `Model/Restyling/SidebarMode.swift`, `Views/Restyling/House/HouseSidebar.swift`, `Views/Restyling/House/HouseRoomsGrid.swift`, `Views/Restyling/House/HouseRoomCell.swift`, `Views/Restyling/House/HouseRowsList.swift`, `Views/Restyling/House/HouseRowCell.swift`, `Views/Restyling/House/HouseBadgeView.swift`
- Modify: `Model/AppPreferences.swift`, `Model/AppPreferenceValues.swift`, `Views/Settings/SidebarSettings.swift`
- Test: `BrausTests/Restyling/HouseSidebarTests.swift`

**Interfaces:**
- Consumes: `MockHouse`, `MascotFace`, `RoomLightView`, `ShellMetrics.showsCompactTiles(sidebarWidth:)`.
- Produces: `enum SidebarMode: String, CaseIterable { case rooms, rows }`; `AppPreferences.restylingSidebarMode = "restyling.sidebarMode"` with default `"rooms"`; `AppPreferenceValues.restylingSidebarMode: SidebarMode`; `enum HouseLayout { static func columns(sidebarWidth: CGFloat) -> Int }`; `struct HouseSidebar: View { let house: MockHouse; @Binding var selection: MockWorker.ID? }`.

- [ ] **Step 1: Write the failing tests.** `@Test("Rooms use two columns unless the sidebar is compact")`: `columns(sidebarWidth: 280) == 2`, `columns(sidebarWidth: 140) == 1`. `@Test("The sidebar mode defaults to rooms")`: reading a fresh defaults suite gives `.rooms`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
  - Rooms: `ScrollView` with `LazyVGrid`, rows 104 pt (92 pt compact), gap 6 pt; the first room spans both columns when there are two. Each `HouseRoomCell` is a `Button` (accessibility label "<name>, <activity>", `.isSelected` trait) holding `RoomLightView` and `MascotFace(drawsBody: false)`. The selected room is empty: no sphere, a lit door bar 26% wide and 4 pt high at the bottom in the status colour, the label "With you". Badges at the top trailing corner: `exclamationmark` symbol for `.attention`, a capsule count for `.unread`. The last item is the archive: a 40 pt "cellar" row "Archive · 3".
  - Rows: native `List(selection:)` with `.listStyle(.sidebar)`; each row 52 pt: `MascotFace` 30 pt with a radial halo of the status light behind it, name (13 pt semibold), activity (11.5 pt secondary), badge trailing. Compact: tile with face and name. The archive is the last row.
  - Search: `.searchable(text:placement: .sidebar)`, filtering by name.
  - Settings: in `SidebarSettings`, only when `RestylingMode.isRequested`, a `Picker("Workers", selection:)` with "Rooms" and "Rows", `.pickerStyle(.segmented)`.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Commit** `git commit -m "Show the mockup's workers as rooms or rows"`.

### Task 7: The house window

**Files:**
- Create: `Views/Restyling/House/HouseConversationView.swift`, `Views/Restyling/House/HouseHero.swift`, `Views/Restyling/House/HouseComposer.swift`, `Views/Restyling/House/HouseInspector.swift`, `Views/Restyling/House/ScreenSlab.swift`, `Views/Restyling/House/ProviderSlab.swift`, `Views/Restyling/Materials/SatinSlabStyle.swift`, `Views/Restyling/Materials/GlassCapsule.swift`
- Modify: `Views/Restyling/RestylingWindowView.swift`

**Interfaces:**
- Consumes: `HouseSidebar`, `MascotFace`, `MockHouse`, `RestylingMotion`.
- Produces: `RestylingWindowView` as the full house; `struct HouseComposer: View { let worker: MockWorker; let onSend: (String) -> Void }` (Task 17 adds motion to it); `struct GlassCapsule: ViewModifier` (`.glassEffect` on macOS 26, `.regularMaterial` otherwise, opaque under Reduce Transparency); `struct SatinSlabStyle: ViewModifier`.

- [ ] **Step 1: Build the window.** `NavigationSplitView` with `HouseSidebar`, the detail `HouseConversationView`, and `.inspector(isPresented:)` holding `HouseInspector`; `.toolbar(removing: .title)`. Toolbar: one group at the trailing edge with a `Toggle` (SF Symbol `display`, toggles the screen slab) and a `Button` (SF Symbol `info.circle`, ⌃⌥⌘I, toggles the inspector), styled like `TeamShellView`'s. The `+` for a new worker is a toolbar `Button` (SF Symbol `plus`) in the sidebar's toolbar section.
- [ ] **Step 2: Content.** `HouseHero`: `MascotFace` 56 pt, name (15 pt semibold), activity (11.5 pt secondary), at the top centre; the role in `.help`. A static sample conversation of four bubbles (Task 17 replaces it). `HouseComposer` in a `GlassCapsule`, 52 pt high: a `Menu` with SF Symbol `plus` ("Attach File…", "Search the Web", a `Toggle` "Show Chrome Window"), a `TextField` with the prompt "Message <name>", a `Menu` showing "Opus 5.5 · High" for model and effort, the existing context ring view used by `ToolbarUsageCapsule`, and a send `Button` (SF Symbol `arrow.up`, `.keyboardShortcut(.return)`).
- [ ] **Step 3: Inspector.** Two satin slabs: `ScreenSlab` ("Screen", the app name, a 16:10 mock screen with a moving amber dot) shown only for a busy worker; `ProviderSlab` ("Provider", "Anthropic", "Subscription · Claude Code", a chevron; a status dot only on trouble) and under a divider a `Button` row "All Providers · 3 Ready".
- [ ] **Step 4: Empty states.** No selection: `ContentUnavailableView` titled "Choose a Room" with the description "Pick a room to talk with its worker." and a small lit floor plan as its image; the inspector: `ContentUnavailableView("No Worker", systemImage: "info.circle", description: Text("Details appear when you choose a room."))`.
- [ ] **Step 5: Look at it.** Run the mockup; capture the window in both sidebar modes, with and without a selection, with the inspector open and closed; compare with `prototypes/casa.html`.
- [ ] **Step 6: Commit** `git commit -m "Lay out the mockup's house window"`.

### Task 8: Menu bar item and Dock presence

**Files:**
- Create: `Model/Restyling/DockPresence.swift`, `Views/Restyling/MenuBar/MenuBarController.swift`, `Views/Restyling/MenuBar/StatusIconRenderer.swift`
- Modify: `Core/SeatReleasingDelegate.swift` (start the controller in mockup mode)
- Test: `BrausTests/Restyling/DockPresenceTests.swift`

**Interfaces:**
- Consumes: `BrowOutlines`, `MockHouse`.
- Produces: `enum DockPresence { static func policy(visibleWindowCount: Int) -> NSApplication.ActivationPolicy; static func iconState(for statuses: [WorkerStatus]) -> BrowState }`; `@MainActor final class MenuBarController { let statusItem: NSStatusItem; var activeTaskCount: Int; func showMenu() }` (Task 14 fills the menu).

- [ ] **Step 1: Write the failing tests.** `policy(visibleWindowCount: 0) == .accessory`, `policy(visibleWindowCount: 1) == .regular`; `iconState(for: [.free, .busy, .waiting]) == .asking`, `iconState(for: [.free, .busy]) == .working`, `iconState(for: [.free, .off]) == .idle`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** In mockup mode only: observe `NSWindow.willCloseNotification` and `didBecomeKeyNotification`, count visible regular windows, call `NSApp.setActivationPolicy(DockPresence.policy(…))`; keep the app alive after the last window closes. The status item shows a template image of the brows of `iconState` (drawn by `StatusIconRenderer` from the outlines, 18 pt) and the active task count as its title when it is above zero.
- [ ] **Step 4: Run the tests and see them pass.** Run the mockup, close the window: the Dock icon goes, the menu-bar item stays; click it: Task 14's menu is a placeholder for now.
- [ ] **Step 5: Commit** `git commit -m "Keep the mockup in the menu bar when its window closes"`.

### Task 9: The Control-Option chord

**Files:**
- Create: `Model/Restyling/ModifierChordDetector.swift`, `Views/Restyling/Ring/RingShortcut.swift`
- Test: `BrausTests/Restyling/ModifierChordDetectorTests.swift`

**Interfaces:**
- Produces: `struct ModifierChordDetector { enum Input { case modifiers(NSEvent.ModifierFlags), keyDown }; mutating func handle(_ input: Input, at time: TimeInterval, isVoiceOverRunning: Bool) -> Bool }` (true means open the ring); `@MainActor final class RingShortcut { init(onChord: @escaping () -> Void); func start(); func stop() }`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test("Control and Option pressed together and released alone fire")
func fires() {
    var d = ModifierChordDetector()
    #expect(!d.handle(.modifiers([.control]), at: 0, isVoiceOverRunning: false))
    #expect(!d.handle(.modifiers([.control, .option]), at: 0.05, isVoiceOverRunning: false))
    #expect(d.handle(.modifiers([]), at: 0.2, isVoiceOverRunning: false))
}

@Test("A key pressed during the chord cancels it")
func keyCancels() {
    var d = ModifierChordDetector()
    _ = d.handle(.modifiers([.control, .option]), at: 0, isVoiceOverRunning: false)
    _ = d.handle(.keyDown, at: 0.1, isVoiceOverRunning: false)
    #expect(!d.handle(.modifiers([]), at: 0.2, isVoiceOverRunning: false))
}

@Test("Another modifier, a long hold or VoiceOver cancel it")
func cancels() {
    var a = ModifierChordDetector()
    _ = a.handle(.modifiers([.control, .option, .command]), at: 0, isVoiceOverRunning: false)
    #expect(!a.handle(.modifiers([]), at: 0.1, isVoiceOverRunning: false))
    var b = ModifierChordDetector()
    _ = b.handle(.modifiers([.control, .option]), at: 0, isVoiceOverRunning: false)
    #expect(!b.handle(.modifiers([]), at: 0.6, isVoiceOverRunning: false))
    var c = ModifierChordDetector()
    _ = c.handle(.modifiers([.control, .option]), at: 0, isVoiceOverRunning: true)
    #expect(!c.handle(.modifiers([]), at: 0.1, isVoiceOverRunning: true))
}
```

- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** The chord fires on release when Control and Option were both down, no other modifier joined, no key went down, and the hold lasted under 0.5 s. `RingShortcut` installs `NSEvent.addGlobalMonitorForEvents` and `addLocalMonitorForEvents` for `.flagsChanged` and `.keyDown` (the app already holds Accessibility trust) and reads `NSWorkspace.shared.isVoiceOverEnabled`. The menu-bar menu gets "Open Ring" so the ring stays reachable under VoiceOver.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Commit** `git commit -m "Open the ring with a Control-Option chord"`.

### Task 10: The ring

**Files:**
- Create: `Model/Restyling/RingGeometry.swift`, `Model/Restyling/HoverArming.swift`, `Views/Restyling/Ring/RingPanel.swift`, `Views/Restyling/Ring/RingLayerView.swift`, `Views/Restyling/Ring/RingController.swift`
- Test: `BrausTests/Restyling/RingGeometryTests.swift`

**Interfaces:**
- Consumes: `RingShortcut`, `MockHouse`, `MascotLayer`, `RestylingTiming`, `RestylingMotion`.
- Produces:
  - `struct RingGeometry { let outerRadius: CGFloat; let thickness: CGFloat; let count: Int; func zone(at point: CGPoint) -> Int?; func midAngle(of zone: Int) -> CGFloat; func zonePath(_ zone: Int) -> CGPath; static let standard: (outerRadius: CGFloat, thickness: CGFloat); static let everyone: (outerRadius: CGFloat, thickness: CGFloat) }`, point relative to the centre, angle 0 at the top going clockwise.
  - `enum RingBuild { static func duration(isFirstOpening: Bool) -> Double }`.
  - `struct HoverArming { mutating func pointerMoved(to point: CGPoint) -> Bool }` (true once armed).
  - `enum RingPlacement { static func frame(size: CGSize, onScreenWithPointer screens: [NSRect], pointer: CGPoint) -> NSRect }`.
  - `@MainActor final class RingController { func open(); func close(); var onChoose: ((MockWorker, RingZoneSnapshot) -> Void)? }` where `struct RingZoneSnapshot { let zone: Int; let geometry: RingGeometry; let frameInScreen: NSRect }`.

- [ ] **Step 1: Write the failing tests.** Standard ring is outer radius 185, thickness 82; everyone ring 250 and 78. For a 6-zone standard ring: `zone(at: CGPoint(x: 0, y: -144)) == 0` (top, y down), `zone(at: CGPoint(x: 125, y: -72)) == 1`, `zone(at: .zero) == nil`, `zone(at: CGPoint(x: 0, y: -200)) == nil`. `duration(isFirstOpening: true) == 2.0`, `false` gives 0.45. Arming: `pointerMoved(to: .zero)` false, then `(3, 0)` false, then `(7, 0)` true. Placement: with screens `[0,0,1440,900]` and `[1440,0,1920,1080]`, pointer `(2000, 500)`, the ring frame is centred in the second screen.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
  - `RingPanel`: `NSPanel` with `.nonactivatingPanel`, `.borderless`, `.fullSizeContentView`, clear background, level `.statusBar`, `canBecomeKey` true (for the bar's field), joins all spaces; Esc closes.
  - Glass: an `NSVisualEffectView` (`.hudWindow`, `.behindWindow`, `.active`, dark appearance) masked by a donut `CAShapeLayer`; under Reduce Transparency an opaque `#1C1C1E` layer instead. Hairline dividers between zones; a 1 px inner edge light.
  - Zones: a `CAGradientLayer` of type `.radial` per zone, masked to `zonePath`, in the worker's status colour (white for dots and voice), opacity 0 at rest (0.3 for busy), 1 on hover.
  - Build: the donut mask's `strokeEnd` animates 0 to 1 over `RingBuild.duration(isFirstOpening:)` starting at the top; each item pops in with a `CASpringAnimation` on scale when the sweep reaches its angle. Reduce Motion: a 0.2 s fade.
  - Content: up to four recommended workers (Task 11), the dots, the voice sphere. Hover arms only after `HoverArming` says so; resting 0.42 s on a worker calls `onChoose`; resting 0.25 s on the dots glows their zone three times over `RestylingTiming.dotsGlow`, then the ring rebuilds with every worker using `RingGeometry.everyone` in 0.7 s.
  - Opened by `RingShortcut` and by "Open Ring" in the menu-bar menu, on the screen with the pointer.
- [ ] **Step 4: Run the tests and see them pass.** Run the mockup, press Control-Option, compare with `prototypes/anello.html`.
- [ ] **Step 5: Commit** `git commit -m "Draw the ring with its zones and build"`.

### Task 11: Recommendations by app category

**Files:**
- Create: `Model/Restyling/RingRecommender.swift`, `Views/Restyling/MenuBar/FrontAppPicker.swift`
- Modify: `Model/Restyling/AppCategory.swift`
- Test: `BrausTests/Restyling/RingRecommenderTests.swift`

**Interfaces:**
- Produces: `AppCategory.init?(bundleCategory: String)`; `enum RingRecommender { static func workers(for category: AppCategory?, in house: MockHouse) -> [MockWorker] }` (at most four); `struct MockFrontApp { let name: String; let category: AppCategory? }` with the samples Desktop (nil), Pro Tools (audio), Photoshop (design), Chrome (web).

- [ ] **Step 1: Write the failing tests.** `AppCategory(bundleCategory: "public.app-category.music") == .audio`, `"public.app-category.video" → .video`, `"public.app-category.graphics-design" → .design`, `"public.app-category.photography" → .design`, `"public.app-category.productivity" → .general`. `workers(for: .audio, in: .sample).map(\.name).prefix(3) == ["Delivery", "Mastering", "Mixing"]`; `workers(for: nil, in: .sample).map(\.name) == ["Delivery", "Ingest", "Research", "Render"]`; every result has at most four entries.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Matching workers first in house order, then the rest. The ring's centre shows the front app's name and "Suggested for <category>" (or "Most Used" on the desktop). The front app is chosen in the menu-bar menu under "Pretend Front App" (a submenu of the four samples) because mockup inputs are simulated.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Commit** `git commit -m "Suggest workers for the app the ring opens over"`.

### Task 12: From the ring to the bar

**Files:**
- Create: `Model/Restyling/SectorPillMorph.swift`, `Views/Restyling/Ring/RingBarMorph.swift`, `Views/Restyling/Ring/RingBarView.swift`, `Views/Restyling/Ring/RingWorkerCard.swift`
- Test: `BrausTests/Restyling/SectorPillMorphTests.swift`

**Interfaces:**
- Consumes: `RingZoneSnapshot`, `RingPanel`, `MascotFace`, `MockHouse`, `RestylingTiming`, `RestylingMotion`.
- Produces: `enum SectorPillMorph { static func sector(outerRadius: CGFloat, innerRadius: CGFloat, halfAngle: CGFloat, in box: CGSize) -> CGPath; static func pill(width: CGFloat, height: CGFloat, in box: CGSize) -> CGPath; static func shortestRotation(degrees: CGFloat) -> CGFloat }`; `struct RingBarView: View { let worker: MockWorker; @Binding var text: String; let onSend: () -> Void }`; `struct RingWorkerCard: View { let chosen: MockWorker; let house: MockHouse; let onSwitch: (MockWorker) -> Void; let onWatch: (MockWorker) -> Void }`.

- [ ] **Step 1: Write the failing tests.** In a 760 × 260 box, `sector(outerRadius: 185, innerRadius: 103, halfAngle: .pi / 6, in:)` and `pill(width: 660, height: 84, in:)` have the same number of path elements and the same element types in order (one move, six cubic curves, one close). `shortestRotation(degrees: 270) == -90`, `shortestRotation(degrees: -200) == 160`, `shortestRotation(degrees: 90) == 90`. A card for a busy chosen worker has a "Now" entry; for a free one it does not.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement the paths** as in the prototype (`sectorD` and `pillD` in `prototypes/anello.html`): the sector upright with its mid-radius point at the box centre, outer arc, two cubics down the right side, inner arc, two cubics up the left side; the pill as top edge, two quarter-arc cubics, bottom edge, two quarter-arc cubics.
- [ ] **Step 4: Implement the motion.** On choose: the worker's preparation (`RestylingTiming.preparation`); the zone becomes a glass layer masked by the sector path, placed and rotated where it was; the rest of the ring scales to 0.85 and fades. Phase one, `RestylingTiming.zoneTravel`: position to the bar's place and rotation to 0 by `shortestRotation`. Phase two, `RestylingTiming.zoneSpread`: the mask's `path` animates from sector to pill. Then the bar content fades in and the field takes focus. Reduce Motion: the ring fades out and the bar fades in.
- [ ] **Step 5: Implement the bar and the card.** Bar 660 × 84, radius 42: `MascotFace` 46 pt leading, a `TextField` at 26 pt light with the prompt "What should <name> do?", a microphone `Button` (SF Symbol `mic`) trailing. Card 14 pt below, radius 34: "Other Workers" rows (`MascotFace` 34 pt, name, status dot and activity, ⌘1–⌘4 by `.keyboardShortcut`); for a busy chosen worker a "Now" row first with its task, step and a "Watch" button.
- [ ] **Step 6: Run the tests and see them pass.** Run the mockup and compare frame by frame with `prototypes/anello.html`.
- [ ] **Step 7: Commit** `git commit -m "Turn the chosen ring zone into the task bar"`.

### Task 13: Task board and task window

**Files:**
- Create: `Model/Restyling/MockTask.swift`, `Model/Restyling/TaskBoard.swift`, `Views/Restyling/Task/TaskWindowView.swift`, `Views/Restyling/Task/TaskStepList.swift`, `Views/Restyling/Task/TaskQueueView.swift`, `Views/Restyling/Task/ContextChips.swift`
- Test: `BrausTests/Restyling/TaskBoardTests.swift`

**Interfaces:**
- Consumes: `MockHouse`, `RingPanel`, `RingBarView`, `RestylingTiming`.
- Produces: `struct MockStep { let title: String; let detail: String }`; `struct MockTask: Identifiable { let id: UUID; let worker: String; let text: String; let steps: [MockStep]; let chips: [String]; var phase: Phase; enum Phase: Equatable { case planning, running(step: Int), done, queued(position: Int) } }`; `@MainActor @Observable final class TaskBoard { private(set) var tasks: [MockTask]; func submit(_ text: String, to worker: MockWorker) -> MockTask; func advance(_ id: MockTask.ID); func suggestion(for task: MockTask, in house: MockHouse) -> MockWorker? }`.

- [ ] **Step 1: Write the failing tests.** Submitting to a free worker gives `.planning`, advancing gives `.running(step: 0)`, then each step, then `.done`. Submitting to a busy worker gives `.queued(position: 1)`; a second gives position 2; when the worker's running task reaches `.done`, the first queued becomes `.running(step: 0)` and the second becomes position 1. `suggestion` for a queued audio task in the sample house is Mastering or Mixing (a free worker of the same category), never a busy one.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement `TaskBoard`.** Progress is simulated by a timer in the mockup, not in the model.
- [ ] **Step 4: Implement the window.** On send the panel grows downward over `RestylingTiming.taskWindowGrow` (radius 42 to 34) and recentres on its screen; the card retracts behind it. Header: the worker's face, the task text, "<name> · Step 2 of 5 · 0:04", trailing an icon `Button` (SF Symbol `arrow.up.forward.app`, help "Open in Braus") and a `Button` (SF Symbol `minus`, help "Put Away", also Esc). `ContextChips` aligned to the window's leading padding (28 pt), 8 pt apart. `TaskStepList`: "Planning steps…" with a shimmer, then steps appearing 110 ms apart, each a 22 pt status mark (done: filled with a check; running: an indeterminate arc in amber; to do: an empty ring), title 15 pt and detail 12.5 pt, joined by a 1.5 pt thread that turns white above done steps. `TaskQueueView`: "Now" with the running task and a `ProgressView` in amber, "Up Next" with the queued task, its position, "Starts in about 2 minutes", its chips, and a footer "<free worker> is free and can do this" with a `Button` "Give to <free worker>"; 32 pt below the last card.
- [ ] **Step 5: Run the tests and see them pass.** Run the mockup, send to a free and a busy worker, compare with `prototypes/anello.html`.
- [ ] **Step 6: Commit** `git commit -m "Grow the bar into a task window with steps and queue"`.

### Task 14: Tasks in the menu bar

**Files:**
- Create: `Views/Restyling/MenuBar/MenuBarTasksView.swift`, `Views/Restyling/MenuBar/MenuBarHandoff.swift`, `Views/Restyling/MenuBar/FinishedBanner.swift`
- Modify: `Views/Restyling/MenuBar/MenuBarController.swift`
- Test: `BrausTests/Restyling/MenuBarTasksTests.swift`

**Interfaces:**
- Consumes: `TaskBoard`, `MenuBarController`, `RingPanel`, `TaskWindowView`.
- Produces: `enum MenuBarTasks { static func sections(of tasks: [MockTask]) -> (inProgress: [MockTask], finished: [MockTask]) }` (finished: the last three, newest first); `MenuBarHandoff.putAway(_ panel: NSPanel, to statusItem: NSStatusItem)` and `bringBack(_ task: MockTask)`.

- [ ] **Step 1: Write the failing tests.** Queued and running tasks are in progress; done tasks are finished, at most three, newest first; the status item's count equals the in-progress count.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Put away: the panel's snapshot layer animates its frame into the status item button's screen frame over `RestylingTiming.toMenuBar` (ease-in), the panel closes, the status button bounces (`CASpringAnimation` on scale). The status item opens an `NSPopover` with `MenuBarTasksView`: "In Progress" rows (face, task, "<name> · Step k of n", a thin `ProgressView`), "Finished" rows, a footer with "Open Braus", "Open Ring", "Pretend Front App" and a "Cycle Delivery's Status" item that steps Delivery through busy, free, waiting and off (it drives Task 19's measurement). Choosing a task brings its window back from the icon over `RestylingTiming.fromMenuBar` (spring). When a task finishes while its window is closed, `FinishedBanner` shows "<name> finished: <task>" in a small glass panel at the top right of the pointer's screen for 2.4 s.
- [ ] **Step 4: Run the tests and see them pass.**
- [ ] **Step 5: Commit** `git commit -m "Keep running tasks in the menu bar"`.

### Task 15: The worker's screen window

**Files:**
- Create: `Views/Restyling/Screen/WorkerScreenWindowController.swift`, `Views/Restyling/Screen/MockScreenView.swift`, `Views/Restyling/Screen/WorkerCursorLayer.swift`, `Views/Restyling/Screen/ScreenHoverControls.swift`

**Interfaces:**
- Consumes: `MockTask`, `MascotFace`, `RestylingMotion`.
- Produces: `@MainActor final class WorkerScreenWindowController: NSWindowController { init(task: MockTask, worker: MockWorker) }`, opened by "Watch" (Task 12) and by the inspector's screen slab (Task 7).

- [ ] **Step 1: Implement the window.** A standard `NSWindow` (`.titled`, `.closable`, `.miniaturizable`, `.resizable`), normal level, 16:10 content of 560 pt by default. `title` is the worker's name and `subtitle` the task text; a leading toolbar item shows the worker's face with its status dot; a trailing toolbar item is an icon button (SF Symbol `arrow.up.forward.app`, help "Open in Braus"). No steps in the title bar.
- [ ] **Step 2: Implement the screen.** `MockScreenView` draws a sample Pro Tools session (menu bar, four coloured tracks, a File menu and an Export AAF dialog that open on cue). `WorkerCursorLayer`: an arrow cursor with the worker's face attached, moving with 0.7 s ease-in-out between points of a looping script; each click leaves an amber ring that grows and fades in 0.5 s; a caption capsule at the bottom says the current action ("Opens the File menu", "Chooses Export › AAF", …).
- [ ] **Step 3: Implement the controls.** On hover over the screen, a row of small `Button`s fades in at the bottom: "Stop" enabled; "Take Control" and "Say Something" disabled with help "Coming later". The caption hides while they show.
- [ ] **Step 4: Look at it.** Run the mockup, open the window from "Watch", compare with `prototypes/schermo.html`.
- [ ] **Step 5: Commit** `git commit -m "Show the worker's screen in its own window"`.

### Task 16: Voice

**Files:**
- Create: `Model/Restyling/VoiceRings.swift`, `Model/Restyling/VoiceSession.swift`, `Views/Restyling/Voice/VoiceOrbView.swift`, `Views/Restyling/Voice/VoiceOrb.metal`, `Views/Restyling/Voice/VoicePanel.swift`, `Views/Restyling/Voice/VoiceHaloPanel.swift`, `Views/Restyling/Voice/VoiceTranscriptView.swift`
- Test: `BrausTests/Restyling/VoiceTests.swift`

**Interfaces:**
- Consumes: `MascotLayer`, `RingController` (the voice zone opens voice), `RingPlacement`, `RestylingMotion`.
- Produces: `struct VoiceLayer { let threshold: Double; let exponent: Double; let color: SIMD3<Float> }` with `static let all: [VoiceLayer]`; `struct VoiceRings { mutating func step(level: Double, dt: Double, isThinking: Bool, now: Double); var live: [Ring] }` where `struct Ring { let layer: Int; let born: Double; let energy: Double }`; `enum VoiceSession.State { case mutatingIn, listening, thinking, speaking, handingOff(MockWorker), leaving }` with `func shouldLeave(silence: Double) -> Bool`.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test("Each layer starts at its own threshold")
func thresholds() {
    #expect(VoiceLayer.all.map(\.threshold) == [0.05, 0.20, 0.35, 0.55])
    #expect(VoiceLayer.all.map(\.exponent) == [0.6, 1.0, 1.5, 2.2])
    #expect(VoiceLayer.all[3].energy(level: 0.5) == 0)
    #expect(VoiceLayer.all[0].energy(level: 0.5) > 0)
}

@Test("Rings live 2.2 seconds")
func lifetime() {
    var rings = VoiceRings()
    for i in 0..<20 { rings.step(level: 0.9, dt: 0.05, isThinking: false, now: Double(i) * 0.05) }
    #expect(!rings.live.isEmpty)
    rings.step(level: 0, dt: 0.05, isThinking: false, now: 10)
    #expect(rings.live.allSatisfy { 10 - $0.born < 2.2 })
}
```

  Also: `energy(level:) == pow(max(0, level - threshold) / (1 - threshold), exponent)`; while thinking, rings spawn at 0.4 of the normal rate (`0.5 + energy × 3.2` per second); `shouldLeave(silence: 4) == true` after a reply and `false` at 3.9. The colours are white (235, 240, 255), amber (255, 196, 140), blue (140, 180, 255), violet (205, 150, 255).
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement the orb.** `VoiceOrbView` is an `MTKView` 64 pt, transparent, drawn only while voice is open. `VoiceOrb.metal` shades a sphere of graphite satin glass: semi-transparent so the blurred background shows (the panel sits on an `NSVisualEffectView`), a soft top reflection, a bluish bottom bounce, a thin rim and an edge darkening; no liquid-metal look and no Apple-like horizon line. Inside, each live ring is drawn as a soft band of light expanding from the centre to the rim over its lifetime, its width growing and its alpha falling, in its layer's colour with additive blending; a small core light breathes with the level.
- [ ] **Step 4: Implement the panel.** `VoicePanel` (non-activating, top right of the pointer's screen, 40 pt from the edges). Entry: the mascot appears, its brows shrink to a point (scale 0.05 × 0.3, fade, 0.55 s), the point brightens, the body cross-fades into the orb (0.6 s); exit reverses it. `VoiceHaloPanel`: a click-through, transparent panel of 780 pt centred on the orb, below it, with a radial light whose opacity follows the level (0.18 + level × 0.45). `VoiceTranscriptView` to the orb's leading side: the person's words in a light bubble as they arrive, the state line ("Listening…", "Thinking…", "Braus is answering"), Braus's reply in dark glass with words fading in; on hand-off the worker's face flies from the orb into the reply with "<name> · Step 1 of 5". Leaves after 4 s of silence after the reply, on Esc or on a click outside. Simulated level and script as in `prototypes/voce.html`.
- [ ] **Step 5: Run the tests and see them pass.** Open voice from the ring; compare with `prototypes/voce.html`.
- [ ] **Step 6: Commit** `git commit -m "Add the voice orb as a mutation of the mascot"`.

### Task 17: Conversation motion

**Files:**
- Create: `Model/Restyling/MessageQueue.swift`, `Model/Restyling/MockConversation.swift`, `Views/Restyling/Chat/ChatTranscriptView.swift`, `Views/Restyling/Chat/BubbleFlight.swift`, `Views/Restyling/Chat/QueueStrip.swift`, `Views/Restyling/Chat/QuoteStrip.swift`, `Views/Restyling/Chat/AnswerBubble.swift`
- Modify: `Views/Restyling/House/HouseComposer.swift`, `Views/Restyling/House/HouseConversationView.swift`
- Test: `BrausTests/Restyling/MessageQueueTests.swift`

**Interfaces:**
- Consumes: `HouseComposer`, `MascotFace`, `ThinkingBlobView` (existing), `RestylingTiming`, `RestylingMotion`.
- Produces: `struct MessageQueue { private(set) var items: [String]; var page: Int; mutating func add(_ text: String); mutating func sendNow() -> String?; mutating func drop(); mutating func endOfTurn() -> String? }`; `@MainActor @Observable final class MockConversation { var messages: [Message]; var isAnswering: Bool; var quote: Message?; var queue: MessageQueue; func send(_ text: String) }`.

- [ ] **Step 1: Write the failing tests.** Adding three items sets `page` to 2 (the newest); `sendNow()` returns the paged item and removes it; `drop()` removes the paged item and keeps `page` in range; `endOfTurn()` returns the first item and removes it; on an empty queue `sendNow()` and `endOfTurn()` return nil.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement the models.**
- [ ] **Step 4: Implement the motion.**
  - Send: a flight layer with the text, from the field's frame to the new bubble's frame, background from clear to the bubble colour, corners from 27 to the bubble's radii, `CASpringAnimation` settling in `RestylingTiming.sendFlight`; the real bubble shows when it lands. While the field has text and the worker is idle, the hero's brows show `.listening`.
  - Queue: while `isAnswering`, a send flies into `QueueStrip` above the composer ("Queued · sends when the turn ends", the text, ‹ 2/3 › page buttons, "Send Now", a remove button). At the end of a turn the first item flies from the strip into the transcript and the worker answers again.
  - Quote: the reply button (SF Symbol `arrowshape.turn.up.left`) shows on hover of a bubble; choosing it nudges the bubble 6 pt, dims it briefly, and flies a copy into `QuoteStrip` over `RestylingTiming.quoteFlight`, animating frame and font size from 14.5 to 12.5 pt (never a scale that stretches text); the strip's text appears on landing. The remove button flies it back into its bubble. A sent bubble carries the quote at its top.
  - Answer: the hero prepares and turns busy; a bubble holding the existing `ThinkingBlobView` springs in from the leading edge; a tool line above it updates ("Opens Pro Tools", "Exports the stems", "Exported 12 stems"); the bubble widens into the reply and its words fade in from blurred, 45 ms apart.
  - Reduce Motion: flights become cross-fades, the nudge and word fades are off.
- [ ] **Step 5: Run the tests and see them pass.** Run the mockup and compare with `prototypes/chat.html`.
- [ ] **Step 6: Commit** `git commit -m "Animate sending, queueing, quoting and answering"`.

### Task 18: Accessibility, motion settings and rest cost

**Files:**
- Modify: any `Views/Restyling/` file that the checks below find wanting.
- Test: `BrausTests/Restyling/RestylingAccessibilityTests.swift`

- [ ] **Step 1: Write the failing test.** `@Test("Every ring zone and room has an accessibility label")`: building `RingLayerView` and `HouseRoomsGrid` for the sample house exposes one accessibility element per worker, dots ("All Workers") and voice ("Voice"), each with a non-empty label.
- [ ] **Step 2: Run it, fix what fails, run it again until it passes.**
- [ ] **Step 3: Check by hand with the system settings.** With Reduce Motion on: no travel, morph, bounce, flicker or breathing anywhere. With Reduce Transparency on: every glass is opaque. With VoiceOver on: Control-Option does not open the ring; "Open Ring" in the menu-bar menu does; every control is announced.
- [ ] **Step 4: Measure the rest cost.** Run the mockup with the house window open and nothing happening for 30 s; `top -l 6 -s 5 -pid <pid> -stats pid,cpu` must average under 1% CPU. Record the figures in the commit message.
- [ ] **Step 5: Commit** `git commit -m "Respect motion, transparency and VoiceOver settings in the mockup"`.

### Task 19: Room light on the M1 (person with the M1)

- [ ] **Step 1:** Build the mockup and copy `Braus.app` to the M1.
- [ ] **Step 2:** Run it with `BRAUS_RESTYLING=1 MTL_HUD_ENABLED=1` and confirm the HUD reports the precomputed path's frame only on changes (no continuous frames at rest).
- [ ] **Step 3:** Choose "Cycle Delivery's Status" in the menu-bar menu ten times and note the GPU time per render from the HUD; under 4 ms per render keeps the look. Record the numbers in `Design.md` under Open points and remove that point.
- [ ] **Step 4: Commit** `git commit -m "Record the room light cost without hardware ray tracing"`.
