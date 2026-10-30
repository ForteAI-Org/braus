//
//  ScreenWindowCheck.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import IOSurface
import Observation
import os
import SeatBroker

/// ScreenWindowCheck opens a worker's screen window over a still picture instead of a live seat,
/// when the app is launched with BRAUS_SCREEN_CHECK=1, so the window can be looked at and captured.
/// No workspace opens: the team is an empty one in a temporary store.
///
/// BRAUS_SCREEN_CHECK_FRAME is the PNG of a window to show, the held window's stand-in, and
/// BRAUS_SCREEN_CHECK_FRAME_SCALE its pixels per point (2 by default). BRAUS_SCREEN_CHECK_SIZE is
/// the window's content size as `<width>x<height>` (the window's own default otherwise), and
/// BRAUS_SCREEN_CHECK_SECONDS how long it stays before the check quits (20 by default). The check
/// prints the window's number, which `screencapture -l` takes. BRAUS_SCREEN_CHECK_BUFFER=<w>x<h>
/// draws the PNG at the top left of a larger buffer, the picture showing only that part, as a
/// stream capped below a 2x screen's pixels carries a window from the seat's 1x display.
/// BRAUS_SCREEN_CHECK_DISPLAY=<index> centres the window on that display (0 holds the menu bar).
///
/// BRAUS_SCREEN_CHECK_WORKER_STATE is what the worker on the corner says (`WorkerSpeech`):
/// `thinking`, `acting:<line>`, `saying:<line>`, or `idle` for nothing, the default; several joined
/// by `|` take turns every two seconds, to watch the bubble change. The worker's light follows the
/// first: busy while it thinks or acts, waiting while it says something, free when idle.
/// BRAUS_SCREEN_CHECK_EDGE=right puts the window against the screen's right edge, and `top-right`
/// in its top-right corner, where the worker's panel is moved in to stay on screen. The check also
/// prints the region the window and the panel cover, in the points `screencapture -R` takes, and
/// whether Braus may record the screen, without which the worker's backdrop is not sampled.
/// In a Debug build BRAUS_SCREEN_CHECK_SWEEP=<steps per second> moves the window back and forth
/// across where the panel is moved in, for BRAUS_SCREEN_CHECK_SECONDS, and prints how far the panel
/// stood from its place.
///
/// BRAUS_SCREEN_CHECK_CURTAIN=<seconds> plays the curtain that covers the picture while control is
/// taken (`TakeControlCurtain`) one second after the window opens, and the worker on the corner
/// dives away, as the window's neon turns from the worker's amber to the person's blue. The curtain
/// fades off the picture on its beat (`TakeControlBeats`); on the swap's, a
/// still of the picture covers the window (`LendStill`), which steps aside, and the picture's surface
/// is blanked, as the stream draws into it again. The still fades that many seconds after the
/// curtain began, as it would into the lent window. A second later the window plays the hand-back
/// where the still was: dark at once, then its curtain fades as the worker comes back.
///
/// In a Debug build BRAUS_SCREEN_CHECK_MOTION=<seconds> feeds the picture 30 times a second while
/// it moves the window 4 points every 60th of a second for that many seconds, then resizes it as
/// often between two sizes as the held window would, printing the process's CPU for each, for a
/// profiler attached to the check to read; BRAUS_SCREEN_CHECK_NEON=off takes the neon and the
/// shadow out of the window's margin, and `none` the margin itself, and BRAUS_SCREEN_CHECK_MASCOT=off
/// the worker on its corner, to compare.
/// BRAUS_SCREEN_CHECK_TWINS=1 plays an application with several windows, each with a twin
/// (`twinCases`).
/// BRAUS_SCREEN_CHECK_RESIZE=1 plays the ways the window's size changes (`resizeCases`).
/// BRAUS_SCREEN_CHECK_HOP=1 moves the window to the other display and back, twice, printing its
/// frame, scale and margin every 25 ms after each move.
///
/// BRAUS_SCREEN_CHECK_WAIT=<seconds> holds that curtain that long past its beat saying the worker
/// is finishing its step, as a long drain does, before it says the person is in control and lifts.
///
/// BRAUS_SCREEN_CHECK_READING=<seconds> has the report take that long after the application left in
/// that hand-back, while the curtain says Braus reads what the person did.
///
/// BRAUS_SCREEN_CHECK_CPU=<seconds> hands both pictures a new surface 30 times a second, as the
/// stream does, and prints the process's CPU over that many seconds for each arrangement: the sharp
/// picture alone, as the window drew before the stage, with the backdrop unblurred, blurred, and
/// alone again. The window server's share is for a sampler outside the process to read.
@MainActor
enum ScreenWindowCheck {

    static var isRequested: Bool { ProcessInfo.processInfo.environment["BRAUS_SCREEN_CHECK"] == "1" }

    /// The views the window made, in the order the stage asks for them: the sharp one first.
    private static var pictures: [StillPicture] = []

    static func runAndQuit() async {
        let environment = ProcessInfo.processInfo.environment
        guard let path   = environment["BRAUS_SCREEN_CHECK_FRAME"],
              let image  = NSImage(contentsOfFile: path)?.cgImage(
                  forProposedRect: nil,
                  context        : nil,
                  hints          : nil
              ),
              case let buffer = environment["BRAUS_SCREEN_CHECK_BUFFER"]?.split(separator: "x").compactMap({ Int($0) }),
              let first  = surface(of: image, in: buffer),
              let second = surface(of: image, in: buffer)
        else {
            FileHandle.standardError.write(Data("screen check: BRAUS_SCREEN_CHECK_FRAME is not a readable PNG\n".utf8))
            exit(1)
        }
        let surfaces = [first, second]
        // The part of the surface the picture shows, from its top left, as the live view's.
        let shown    = CGRect(
            x     : 0,
            y     : 0,
            width : Double(image.width) / Double(first.width),
            height: Double(image.height) / Double(first.height)
        )
        let scale    = environment["BRAUS_SCREEN_CHECK_FRAME_SCALE"].flatMap(Double.init) ?? 2
        let size     = CGSize(
            width : Double(image.width) / scale,
            height: Double(image.height) / scale
        )
        let seconds  = environment["BRAUS_SCREEN_CHECK_SECONDS"].flatMap(Double.init) ?? 20
        let states   = (environment["BRAUS_SCREEN_CHECK_WORKER_STATE"] ?? "idle")
            .split(separator: "|")
            .map { Self.speech(String($0)) }
        let speech   = Said(speech: states.first ?? nil)
        let store    = URL.temporaryDirectory.appending(
            path         : "BrausScreenCheck-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )

        do {
            let team = TeamModel(
                store      : try WorkspaceStore.opening(in: store),
                connections: ModelSettingsStore(),
                broker     : SeatBroker()
            )
            let controller = WorkerScreenWindowController(
                worker     : HouseWorker(
                    id        : UUID(),
                    name      : "Atlas",
                    status    : Self.status(saying: speech.speech),
                    activity  : "Using Pro Tools",
                    role      : "",
                    shape     : .hexagon,
                    badge     : nil,
                    usesScreen: true
                ),
                team       : team,
                makePicture: { _ in
                    let picture = StillPicture(
                        surface: surfaces[0],
                        shown  : shown,
                        size   : size
                    )
                    pictures.append(picture)
                    return picture
                },
                makeSpeech : { speech.speech }
            )
            guard let window = controller.window else { exit(1) }

            if let requested = environment["BRAUS_SCREEN_CHECK_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
               requested.count == 2 {
                window.setContentSize(CGSize(
                    width : requested[0],
                    height: requested[1]
                ))
                window.center()
            }
            if let index = environment["BRAUS_SCREEN_CHECK_DISPLAY"].flatMap(Int.init),
               NSScreen.screens.indices.contains(index) {
                let visible = NSScreen.screens[index].visibleFrame
                window.setFrameOrigin(CGPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2
                ))
            }
            if let edge = environment["BRAUS_SCREEN_CHECK_EDGE"], ["right", "top-right"].contains(edge),
               let visible = window.screen?.visibleFrame {
                // The picture against the edge, the window's margin past it.
                window.setFrameOrigin(CGPoint(
                    x: visible.maxX - window.frame.width + ScreenWindowFrame.margin,
                    y: edge == "top-right"
                        ? visible.maxY - window.frame.height + ScreenWindowFrame.margin
                        : window.frame.minY
                ))
            }
            // Floating, so Stage Manager leaves it on screen where `screencapture -l` can take it.
            window.level = .floating
            controller.showWindow(nil)
            print("screen check: window \(window.windowNumber), content \(window.frame.size), picture \(size)")
            let covered = window.frame.union(controller.presencePanel.frame)
            let top     = (NSScreen.screens.first?.frame.maxY ?? 0) - covered.maxY
            print(String(
                format: "screen check: region %.0f,%.0f,%.0f,%.0f; screen recording %@",
                covered.minX,
                top,
                covered.width,
                covered.height,
                CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed"
            ))
            // Out at once, so a script waiting for the number can capture the window while it is up.
            fflush(stdout)
            let turns = Task {
                var index = 0
                while states.count > 1 {
                    try await Task.sleep(for: .seconds(2))
                    index = (index + 1) % states.count
                    speech.speech = states[index]
                }
            }
            defer { turns.cancel() }

            if let cpuSeconds = environment["BRAUS_SCREEN_CHECK_CPU"].flatMap(Double.init), cpuSeconds > 0 {
                try await Task.sleep(for: .seconds(2))
                await measure(
                    over    : cpuSeconds,
                    surfaces: surfaces
                )
            }
            var swept = false
            #if DEBUG
            if environment["BRAUS_SCREEN_CHECK_MASCOT"] == "off" {
                window.removeChildWindow(controller.presencePanel)
                controller.presencePanel.orderOut(nil)
            }
            if ["off", "none"].contains(environment["BRAUS_SCREEN_CHECK_NEON"]) {
                (window.contentView as? ScreenWindowFrame)?.showsMargin(false)
            }
            if environment["BRAUS_SCREEN_CHECK_TWINS"] == "1" {
                try await twinCases(
                    controller: controller,
                    size      : size
                )
                swept = true
            }
            if environment["BRAUS_SCREEN_CHECK_RESIZE"] == "1" {
                try await resizeCases(
                    controller: controller,
                    size      : size
                )
                swept = true
            }
            if environment["BRAUS_SCREEN_CHECK_HOP"] == "1", let frame = window.contentView as? ScreenWindowFrame {
                for _ in 0..<4 {
                    try await Task.sleep(for: .seconds(2))
                    guard let target = NSScreen.screens.first(where: { $0 != window.screen })?.visibleFrame
                    else { break }
                    window.setFrameOrigin(CGPoint(
                        x: target.midX - window.frame.width / 2,
                        y: target.midY - window.frame.height / 2
                    ))
                    for tick in 0..<12 {
                        print("screen check: hop +\(tick * 25) ms: window \(window.frame) scale \(window.backingScaleFactor), \(frame.margins)")
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    fflush(stdout)
                }
                swept = true
            }
            if let motion = environment["BRAUS_SCREEN_CHECK_MOTION"].flatMap(Double.init), motion > 0 {
                try await Task.sleep(for: .seconds(2))
                await move(
                    controller: controller,
                    size      : size,
                    surfaces  : surfaces,
                    over      : motion
                )
                swept = true
            }
            if let rate = environment["BRAUS_SCREEN_CHECK_SWEEP"].flatMap(Double.init), rate > 0 {
                try await Task.sleep(for: .seconds(1))
                await sweep(
                    window        : window,
                    panel         : controller.presencePanel,
                    stepsPerSecond: rate,
                    over          : seconds,
                    vertically    : environment["BRAUS_SCREEN_CHECK_EDGE"] == "top-right"
                )
                swept = true
            }
            #endif
            if let hold = environment["BRAUS_SCREEN_CHECK_CURTAIN"].flatMap(Double.init) {
                let content = controller.pictureView
                try await Task.sleep(for: .seconds(1))
                // With BRAUS_SCREEN_CHECK_WAIT=<seconds> the worker's step drains that long first.
                let wait    = environment["BRAUS_SCREEN_CHECK_WAIT"].flatMap(Double.init) ?? 0
                let curtain = TakeControlCurtain(
                    title  : wait > 0 ? TakeControlCurtain.waitingTitle : TakeControlCurtain.controlTitle,
                    picture: pictures.first
                )
                curtain.frame            = content.frame
                curtain.autoresizingMask = [.width, .height]
                curtain.onGone           = {
                    print("screen check: curtain gone")
                    curtain.removeFromSuperview()
                }
                // Over the hosting view, whose own drawing would cover a subview.
                content.superview?.addSubview(
                    curtain,
                    positioned: .above,
                    relativeTo: content
                )
                curtain.play()
                // The neon turns to the person as the application starts on its way.
                if wait == 0 { controller.neon.recolour(to: .person) }
                presenceView(in: controller.presencePanel.contentView)?.diveAway()
                print("screen check: curtain playing, held \(hold) s")
                fflush(stdout)
                try await Task.sleep(for: .seconds(TakeControlBeats.revealStart))
                if wait > 0 {
                    try await Task.sleep(for: .seconds(wait))
                    curtain.retitle(TakeControlCurtain.controlTitle)
                    controller.neon.recolour(to: .person)
                    print("screen check: the lend began")
                    fflush(stdout)
                }
                curtain.release()
                print("screen check: curtain released")
                try await Task.sleep(for: .seconds(
                    wait > 0 ? TakeControlCurtain.lateReveal : TakeControlBeats.swap - TakeControlBeats.revealStart
                ))
                let still = pictures.first.flatMap { LendStill(picture: $0) }
                // Copied ahead, as the lend does.
                await still?.prepare()
                still?.show()
                try await Task.sleep(for: .milliseconds(30))
                controller.stepAside()
                // The stream draws into the surface again as the window leaves the seat: the still
                // must not change with it.
                surfaces[0].lock(
                    options: [],
                    seed   : nil
                )
                // Opaque black, as a frame of the window gone from the seat's display draws.
                let pixels = surfaces[0].baseAddress.bindMemory(
                    to      : UInt32.self,
                    capacity: surfaces[0].allocationSize / 4
                )
                for index in 0..<(surfaces[0].allocationSize / 4) { pixels[index] = 0xFF00_0000 }
                surfaces[0].unlock(
                    options: [],
                    seed   : nil
                )
                try await Task.sleep(for: .seconds(max(0, hold - TakeControlBeats.swap)))
                still?.land()
                // The hand-back: the window comes back dark where the application was left, then the
                // application leaves the person's screen behind it.
                try await Task.sleep(for: .seconds(1))
                // With BRAUS_SCREEN_CHECK_READING=<seconds> the report takes that long after the
                // application left: the curtain says Braus reads what the person did meanwhile.
                let reading = environment["BRAUS_SCREEN_CHECK_READING"].flatMap(Double.init) ?? 0
                let ready   = ContinuousClock.now + .seconds(1 + reading)
                controller.endsControl = { ContinuousClock.now >= ready }
                controller.handBack(at: still?.frame)
                try await Task.sleep(for: .seconds(1))
                controller.handedBack()
                if reading > 0 {
                    print("screen check: reading for \(reading) s")
                    fflush(stdout)
                    try await Task.sleep(until: ready)
                    controller.reportMayBeReady()
                    print("screen check: the report is ready")
                    fflush(stdout)
                }
                try await Task.sleep(for: .seconds(WorkerScreenWindowController.handBackHold + 1.5))
                print("screen check: still landed")
                fflush(stdout)
            }
            if !swept { try await Task.sleep(for: .seconds(seconds)) }
            controller.close()
        } catch {
            FileHandle.standardError.write(Data("screen check failed: \(error)\n".utf8))
            exit(1)
        }
        do { try FileManager.default.removeItem(at: store) } catch {}
        exit(0)
    }

    /// The worker's view on the window's corner, under `view`.
    private static func presenceView(in view: NSView?) -> ScreenPresenceView? {
        guard let view else { return nil }
        return view as? ScreenPresenceView ?? view.subviews.lazy.compactMap { presenceView(in: $0) }.first
    }

    /// Said is what the worker says now, which the corner's view follows.
    @Observable
    final class Said {
        var speech: WorkerSpeech?

        init(speech: WorkerSpeech?) {
            self.speech = speech
        }
    }

    /// What `state` asks the worker to say: `thinking`, `acting:<line>`, `saying:<line>`, or
    /// nothing for `idle` or anything else.
    private static func speech(_ state: String) -> WorkerSpeech? {
        let parts = state.split(
            separator                : ":",
            maxSplits                : 1,
            omittingEmptySubsequences: false
        ).map(String.init)
        switch (parts.first, parts.count == 2 ? parts[1] : nil) {
        case ("thinking", _)      : return .thinking
        case ("acting", let line?): return .acting(line)
        case ("saying", let line?): return .saying(line)
        default                   : return nil
        }
    }

    /// The status a worker saying `speech` shows.
    private static func status(saying speech: WorkerSpeech?) -> WorkerStatus {
        switch speech {
        case .thinking?, .acting?: .busy
        case .saying?            : .waiting
        case nil                 : .free
        }
    }

    /// Feeds the pictures at the stream's rate and prints the CPU of each arrangement.
    private static func measure(
        over seconds: Double,
        surfaces    : [IOSurface]
    ) async {
        guard pictures.count == 2 else {
            print("screen check: the stage made \(pictures.count) pictures, not 2")
            return
        }
        let sharp    = pictures[0]
        let backdrop = pictures[1]
        let blur     = backdrop.layer?.filters
        let arrangements: [(name: String, fed: [StillPicture], setUp: () -> Void)] = [
            ("sharp picture alone", [sharp], { backdrop.isHidden = true }),
            ("with the backdrop unblurred", [sharp, backdrop], {
                backdrop.isHidden      = false
                backdrop.layer?.filters = nil
            }),
            ("with the backdrop blurred", [sharp, backdrop], { backdrop.layer?.filters = blur }),
            // Alone again, so a drift of the machine's load shows against the first reading.
            ("sharp picture alone again", [sharp], { backdrop.isHidden = true }),
        ]
        for arrangement in arrangements {
            arrangement.setUp()
            let feeding = Task { @MainActor in
                var index = 0
                while !Task.isCancelled {
                    index = 1 - index
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    for picture in arrangement.fed { picture.layer?.contents = surfaces[index] }
                    CATransaction.commit()
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            try? await Task.sleep(for: .seconds(1))
            let share = await HumanControlCheck.idleCPU(over: seconds)
            feeding.cancel()
            print(String(
                format: "screen check: %@ at 30 fps: %.2f%% of one core over %.0f s",
                arrangement.name,
                share,
                seconds
            ))
        }
    }

    #if DEBUG
    /// Plays an application with several windows: a dialog over the main window, a palette beside it
    /// and a small window at its corner, each with a twin; then a window moving, one closing, another
    /// opening in front, the order changing, the person moving a twin and its window growing. Prints a
    /// line to capture the screen at after each step, and where each window would land on Take Control.
    private static func twinCases(
        controller: WorkerScreenWindowController,
        size      : CGSize
    ) async throws {
        func window(
            _ number: Int,
            _ kind  : TwinWindow.Kind,
            _ title : String,
            _ frame : CGRect,
            order   : Int
        ) -> TwinWindow {
            TwinWindow(
                windowNumber      : number,
                processID         : 1,
                frame             : frame,
                level             : 0,
                kind              : kind,
                parentWindowNumber: kind == .main ? nil : 1,
                title             : title,
                order             : order
            )
        }
        let source = FakeTwinSource(windows: [
            window(1, .main, "Main", CGRect(x: 400, y: 300, width: size.width, height: size.height), order: 3),
            window(2, .dialog, "Dialog", CGRect(x: 580, y: 440, width: 360, height: 200), order: 0),
            window(3, .panel, "Palette", CGRect(x: 400 + size.width + 20, y: 300, width: 180, height: 420), order: 1),
            window(4, .other, "Small", CGRect(x: 250, y: 320, width: 140, height: 90), order: 2),
        ])
        func step(_ name: String) async throws {
            let twins = controller.twins?.twins ?? [:]
            let lines = twins.keys.sorted().map { "\($0): \(twins[$0]?.pictureFrame ?? .zero)" }
            print("screen check: twins \(name); main \(controller.pictureFrame ?? .zero); \(lines.joined(separator: ", "))")
            fflush(stdout)
            try await Task.sleep(for: .seconds(1.5))
        }
        try await Task.sleep(for: .seconds(1))
        controller.showTwins(of: source)
        try await step("shown")
        source.windows[2].frame.origin.y += 120
        try await step("the palette moved down")
        source.windows.remove(at: 3)
        try await step("the small window closed")
        source.windows = source.windows.map {
            var window = $0
            window.order += 1
            return window
        } + [window(5, .dialog, "Second dialog", CGRect(x: 520, y: 720, width: 300, height: 160), order: 0)]
        try await step("a second dialog opened in front")
        if let index = source.windows.firstIndex(where: { $0.windowNumber == 3 }) {
            source.windows[index].order = -1
        }
        try await step("the palette came to the front")
        if let twin = controller.twins?.twins[2] {
            twin.panel.setFrameOrigin(CGPoint(
                x: twin.panel.frame.minX + 160,
                y: twin.panel.frame.minY - 60
            ))
        }
        try await step("the person moved the dialog's twin")
        if let index = source.windows.firstIndex(where: { $0.windowNumber == 2 }) {
            source.windows[index].frame.size = CGSize(
                width : 420,
                height: 240
            )
        }
        try await step("the dialog grew")
        // Dropped on the other display, the palette's twin asks for its stream at that one's scale.
        if let twin = controller.twins?.twins[3],
           let other = NSScreen.screens.first(where: { $0 != twin.panel.screen }) {
            let back = twin.panel.frame.origin
            twin.panel.setFrameOrigin(CGPoint(
                x: other.visibleFrame.midX,
                y: other.visibleFrame.midY
            ))
            try await step("the palette's twin went to \(other.localizedName)")
            twin.panel.setFrameOrigin(back)
            try await step("the palette's twin came back")
        }
        let landing = controller.twins?.lendingFrames() ?? [:]
        print("screen check: twins land on Take Control at \(landing)")
        fflush(stdout)
        // The swap: a still on each twin as the twins step aside, fading once the windows stand still.
        let stills = controller.twins?.stepAside(because: "the windows come to the person") ?? [:]
        try await step("stepped aside under \(stills.count) stills")
        stills.values.forEach { $0.land() }
        try await step("the stills faded into the windows")
        // The hand-back: each twin back where the person left its window, 40 points to the right.
        controller.twins?.comeBack(at: landing.mapValues { $0.offsetBy(dx: 40, dy: 0) })
        controller.twins?.show(because: "the application is handed back")
        try await step("handed back where the person left the windows")
    }

    /// Plays the ways the window's size changes, printing the picture's frame after each: the
    /// application resizing itself, the person resizing it while lent and handing it back while the
    /// application reports a stale size and then theirs, and the window reaching another display with
    /// a held window larger than that display's visible frame.
    private static func resizeCases(
        controller: WorkerScreenWindowController,
        size      : CGSize
    ) async throws {
        guard let window = controller.window else { return }
        func report(_ step: String) {
            print("screen check: resize \(step): picture \(controller.pictureFrame ?? .zero), window \(window.frame)")
            fflush(stdout)
        }
        try await Task.sleep(for: .seconds(1))
        let grown = CGSize(
            width : size.width + 160,
            height: size.height + 100
        )
        controller.fit(
            to  : grown,
            from: .application
        )
        report("the application grew to \(grown)")
        try await Task.sleep(for: .seconds(1))

        // Lent, resized by the person, and handed back.
        guard let picture = controller.pictureFrame else { return }
        let personal = picture.insetBy(
            dx: -40,
            dy: -30
        )
        controller.stepAside()
        try await Task.sleep(for: .seconds(1))
        controller.handBack(at: personal)
        report("handed back at the person's \(personal)")
        controller.fit(
            to  : grown,
            from: .application
        )
        report("the application reported its stale \(grown) during the hand-back")
        try await Task.sleep(for: .milliseconds(300))
        controller.fit(
            to  : personal.size,
            from: .application
        )
        try await Task.sleep(for: .seconds(1))
        controller.handedBack()
        try await Task.sleep(for: .seconds(WorkerScreenWindowController.handBackHold + 1))
        report("the hand-back ended")

        // Larger than the other display's visible frame, then over to it and back.
        guard let other = NSScreen.screens.first(where: { $0 != window.screen }) else { return }
        let large = CGSize(
            width : max(other.visibleFrame.width, window.screen?.visibleFrame.width ?? 0) - 100,
            height: min(other.visibleFrame.height, window.screen?.visibleFrame.height ?? 0) - 40
        )
        controller.fit(
            to  : large,
            from: .application
        )
        report("the application grew to \(large)")
        for screen in [other, window.screen ?? other] {
            try await Task.sleep(for: .seconds(1))
            window.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.minX + 20,
                y: screen.visibleFrame.minY + 20
            ))
            try await Task.sleep(for: .milliseconds(500))
            report("moved to \(screen.localizedName)")
        }
    }

    /// Feeds the picture at the stream's rate while the window moves for `seconds`, then while it
    /// resizes between the held window's `size` and a larger one, printing the CPU of each.
    private static func move(
        controller  : WorkerScreenWindowController,
        size        : CGSize,
        surfaces    : [IOSurface],
        over seconds: Double
    ) async {
        guard let window = controller.window, let picture = pictures.first else { return }
        let feeding = Task { @MainActor in
            var index = 0
            while !Task.isCancelled {
                index = 1 - index
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                picture.layer?.contents = surfaces[index]
                CATransaction.commit()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
        defer { feeding.cancel() }
        let larger = CGSize(
            width : size.width + 80,
            height: size.height + 50
        )
        for resizes in [false, true] {
            let start = window.frame.origin
            let moves = Task { @MainActor in
                var step = 0
                while !Task.isCancelled {
                    step += 1
                    if resizes {
                        controller.fit(to: step % 2 == 0 ? size : larger)
                    } else {
                        window.setFrameOrigin(CGPoint(
                            x: start.x + CGFloat(step % 40 < 20 ? step % 20 : 20 - step % 20) * 4,
                            y: start.y
                        ))
                    }
                    try? await Task.sleep(for: .milliseconds(16))
                }
                return step
            }
            let share = await HumanControlCheck.idleCPU(over: seconds)
            moves.cancel()
            let steps = await moves.value
            print(String(
                format: "screen check: %@ with the neon %@, picture at 30 fps: %.2f%% of one core over %.0f s, %d steps",
                resizes ? "resizing" : "moving",
                (window.contentView as? ScreenWindowFrame)?.showsNeon == true ? "on" : "off",
                share,
                seconds,
                steps
            ))
            fflush(stdout)
        }
    }

    /// Moves `window` back and forth across where its worker's panel is moved in to stay on screen,
    /// `stepsPerSecond` steps a second for `seconds`, and `vertically` too, while `PanelOffsets` reads
    /// both frames from the window server; then prints how far the panel stood from where the
    /// window's frame puts it, apart for the samples where the panel is moved in.
    private static func sweep(
        window        : NSWindow,
        panel         : NSPanel,
        stepsPerSecond: Double,
        over seconds  : Double,
        vertically    : Bool
    ) async {
        guard let visible = window.screen?.visibleFrame else { return }
        let size    = window.frame.size
        let reach   = ScreenPresenceView.overhang.width + ScreenPresenceView.margin.right
        // Window origins that bring the picture's corner, the window's margin in, to the edges.
        let inset   = ScreenWindowFrame.margin
        let xs      = (visible.maxX - size.width + inset - reach - 60)...(visible.maxX - size.width + inset + 40)
        let ys      = (visible.maxY - size.height + inset - 60)...(visible.maxY - size.height + inset)
        let offsets = PanelOffsets(
            window: window.windowNumber,
            panel : panel.windowNumber
        )
        var origin  = CGPoint(
            x: xs.lowerBound,
            y: vertically ? ys.lowerBound : window.frame.minY
        )
        var step    = CGVector(
            dx: 4,
            dy: vertically ? 2 : 0
        )
        let end     = CACurrentMediaTime() + seconds
        var steps   = 0
        var longest : CFTimeInterval = 0
        var stepped = CACurrentMediaTime()
        while CACurrentMediaTime() < end {
            origin.x += step.dx
            origin.y += step.dy
            if !xs.contains(origin.x) { step.dx = -step.dx }
            if vertically, !ys.contains(origin.y) { step.dy = -step.dy }
            window.setFrameOrigin(origin)
            steps  += 1
            longest = max(longest, CACurrentMediaTime() - stepped)
            stepped = CACurrentMediaTime()
            try? await Task.sleep(for: .seconds(1 / stepsPerSecond))
        }
        // The panel's last move lands before the reads stop.
        try? await Task.sleep(for: .milliseconds(100))
        let errors  = offsets.stop(
            visible      : visible,
            menuBarScreen: NSScreen.screens.first?.frame ?? .zero
        )
        print(String(
            format: "screen check: sweep of %d steps over %.0f s, longest step %.0f ms; %@",
            steps,
            seconds,
            longest * 1000,
            errors
        ))
    }

    /// PanelOffsets reads the screen window's and its panel's frames from the window server together,
    /// every 4 ms on a thread of its own; once stopped it says how far the panel stood from where the
    /// window's frame puts it (`ScreenPresenceView.panelFrame`), apart for where the panel is moved in.
    private nonisolated final class PanelOffsets: Sendable {

        private struct Samples: Sendable {
            var running = true
            var frames  : [(window: CGRect, panel: CGRect)] = []
        }

        private let samples = OSAllocatedUnfairLock(initialState: Samples())

        init(
            window: Int,
            panel : Int
        ) {
            let thread = Thread { [self] in
                read(
                    window: window,
                    panel : panel
                )
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        /// Stops the reads and describes the errors of the frames read, all in window-server space.
        @MainActor
        func stop(
            visible      : CGRect,
            menuBarScreen: CGRect
        ) -> String {
            let frames = samples.withLock {
                $0.running = false
                return $0.frames
            }
            var free   : [Double] = []
            var movedIn: [Double] = []
            for frame in frames {
                let shown  = WorkerScreenWindowController.picture(in: LendingCompanion.appKitFrame(
                    frame.window,
                    menuBarScreen: menuBarScreen
                ))
                let placed = LendingCompanion.appKitFrame(
                    frame.panel,
                    menuBarScreen: menuBarScreen
                )
                let wanted = ScreenPresenceView.panelFrame(
                    around: shown,
                    in    : visible
                )
                let error  = hypot(
                    placed.minX - wanted.minX,
                    placed.minY - wanted.minY
                )
                let isFree = wanted.origin == ScreenPresenceView.panelFrame(
                    around: shown,
                    in    : .infinite
                ).origin
                if isFree { free.append(error) } else { movedIn.append(error) }
            }
            return "panel off its place where free \(Self.describe(free)); where moved in \(Self.describe(movedIn))"
        }

        private static func describe(_ errors: [Double]) -> String {
            guard !errors.isEmpty else { return "no samples" }
            let sorted = errors.sorted()
            return String(
                format: "%d samples, mean %.2f pt, p95 %.2f pt, max %.2f pt, %.0f%% over 1 pt",
                sorted.count,
                sorted.reduce(0, +) / Double(sorted.count),
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                sorted.last ?? 0,
                Double(sorted.count(where: { $0 > 1 })) * 100 / Double(sorted.count)
            )
        }

        private func read(
            window: Int,
            panel : Int
        ) {
            let ids = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 2)
            defer { ids.deallocate() }
            ids[0] = UnsafeRawPointer(bitPattern: UInt(window))
            ids[1] = UnsafeRawPointer(bitPattern: UInt(panel))
            let array = CFArrayCreate(
                nil,
                ids,
                2,
                nil
            )
            while samples.withLock({ $0.running }) {
                let rows     = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
                let byNumber = Dictionary(
                    rows.compactMap { row -> (Int, CGRect)? in
                        guard let number = row[kCGWindowNumber as String] as? Int,
                              let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
                        return (number, frame)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                if let shown = byNumber[window], let placed = byNumber[panel] {
                    samples.withLock { $0.frames.append((shown, placed)) }
                }
                Thread.sleep(forTimeInterval: 0.004)
            }
        }
    }
    #endif

    /// `image` drawn once into a surface of its own, as the stream's frames arrive: at the top left of
    /// a `buffer` (`[width, height]`) when one is given, transparent around it.
    private static func surface(
        of image : CGImage,
        in buffer: [Int]? = nil
    ) -> IOSurface? {
        let width  = buffer?.count == 2 ? max(buffer?[0] ?? 0, image.width) : image.width
        let height = buffer?.count == 2 ? max(buffer?[1] ?? 0, image.height) : image.height
        guard let surface = IOSurface(properties: [
            .width          : width,
            .height         : height,
            .bytesPerElement: 4,
            .pixelFormat    : kCVPixelFormatType_32BGRA,
        ]) else { return nil }

        surface.lock(
            options: [],
            seed   : nil
        )
        defer {
            surface.unlock(
                options: [],
                seed   : nil
            )
        }
        guard let context = CGContext(
            data            : surface.baseAddress,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : surface.bytesPerRow,
            space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.clear(CGRect(
            x     : 0,
            y     : 0,
            width : width,
            height: height
        ))
        // The context counts y up from the bottom: the image's top meets the buffer's.
        context.draw(
            image,
            in: CGRect(
                x     : 0,
                y     : height - image.height,
                width : image.width,
                height: image.height
            )
        )
        return surface
    }

    /// StillPicture stands in for the live view: a flipped view whose layer shows the `shown` part of
    /// a surface, at the held window's size.
    private final class StillPicture: NSView {
        private let size: CGSize

        init(
            surface: IOSurface,
            shown  : CGRect,
            size   : CGSize
        ) {
            self.size = size
            super.init(frame: .zero)
            wantsLayer = true
            layer?.contents        = surface
            layer?.contentsRect    = shown
            layer?.contentsGravity = .resizeAspect
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override var intrinsicContentSize: NSSize { size }

        override func makeBackingLayer() -> CALayer { CALayer() }
    }
}
