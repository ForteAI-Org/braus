//
//  CanvasFixture.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit

/// CanvasFixture supplies opaque drawing surfaces surrounded by readable native controls.
/// Lane numbers are one-based; still captures freeze both the meter and the playhead caret. With
/// `--meter-two-levels` the meter and the caret change only on `stepNotification`, between the meter's two
/// extremes, so a test's captures each see the other one: a timer's period would alias with their cadence.
@main
@MainActor
final class CanvasFixture: NSObject, NSApplicationDelegate {

    /// The distributed notification that moves a `--meter-two-levels` meter to its other extreme.
    static let stepNotification = Notification.Name("dev.forte.CanvasFixture.step")

    private var window: NSWindow?
    private var timer: Timer?
    private var stepObserver: NSObjectProtocol?

    struct Options {
        var still = false
        var meterTwoLevels = false
        var meterPhase = 0.0
        var offsets = [Int: CGFloat]()

        init(arguments: [String]) throws {
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                index += 1
                if flag == "--still" {
                    still = true
                    continue
                }
                if flag == "--meter-two-levels" {
                    meterTwoLevels = true
                    continue
                }
                guard index < arguments.count else { throw Failure.argument(flag) }
                let value = arguments[index]
                index += 1
                switch flag {
                case "--meter-phase":
                    guard let phase = Double(value), phase.isFinite, (0...1).contains(phase) else {
                        throw Failure.argument(value)
                    }
                    meterPhase = phase
                case "--clip-offset":
                    let parts = value.split(separator: ":")
                    guard parts.count == 2, let lane = Int(parts[0]), (1...4).contains(lane),
                        let offset = Double(parts[1]), offset.isFinite
                    else { throw Failure.argument(value) }
                    offsets[lane] = offset
                default:
                    throw Failure.argument(flag)
                }
            }
        }
    }

    enum Failure: Error {
        case argument(String)
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = CanvasFixture()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options: Options
        do {
            options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs(
                "Invalid canvas fixture arguments: \(error)\n",
                stderr
            )
            exit(2)
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let content = Surface(
            frame: NSRect(
                x     : 0,
                y     : 0,
                width : 1100,
                height: 700
            )
        )
        content.kind = .background
        content.setAccessibilityElement(false)
        let window = FixtureWindow(
            contentRect: content.bounds,
            styleMask  : [.titled, .closable, .miniaturizable],
            backing    : .buffered,
            defer      : false
        )
        window.title = "Canvas Fixture"
        window.allowsFocus = !options.still
        // An explicit 8-bit sRGB backing avoids display-profile rounding differences between launches.
        window.colorSpace = .sRGB
        window.depthLimit = .twentyfourBitRGB
        window.setDynamicDepthLimit(false)
        window.contentView = content
        window.animationBehavior = .none
        window.setFrameTopLeftPoint(
            NSPoint(
                x: 80,
                y: (NSScreen.main?.frame.maxY ?? 1000) - 80
            )
        )
        window.isReleasedWhenClosed = false
        self.window = window

        let play = NSButton(
            title : "Play",
            target: nil,
            action: nil
        )
        play.frame = NSRect(
            x     : 24,
            y     : 28,
            width : 90,
            height: 32
        )
        play.bezelStyle = .rounded
        content.addSubview(play)

        let search = NSSearchField(
            frame: NSRect(
                x     : 140,
                y     : 28,
                width : 260,
                height: 32
            )
        )
        search.placeholderString = "Search"
        search.setAccessibilityLabel("Search")
        content.addSubview(search)

        let zoom = NSPopUpButton(
            frame: NSRect(
                x     : 440,
                y     : 28,
                width : 150,
                height: 32
            ),
            pullsDown: false
        )
        zoom.addItems(withTitles: ["100%", "200%", "400%"])
        zoom.setAccessibilityLabel("Zoom")
        content.addSubview(zoom)

        for lane in 1...4 {
            addLabel(
                "Track \(lane)",
                frame: NSRect(
                    x     : 28,
                    y     : 166 + (lane - 1) * 80,
                    width : 110,
                    height: 24
                ),
                to: content
            )
        }
        for seconds in stride(
            from   : 0,
            through: 30,
            by     : 5
        ) {
            addLabel(
                String(
                    format: "00:%02d",
                    seconds
                ),
                frame: NSRect(
                    x     : 160 + seconds * 27,
                    y     : 108,
                    width : 70,
                    height: 24
                ),
                to: content
            )
        }

        let timeline = surface(
            .timeline,
            frame: NSRect(
                x     : 160,
                y     : 140,
                width : 900,
                height: 320
            ),
            identifier: "canvas.timeline",
            in        : content
        )
        timeline.phase = options.meterPhase
        timeline.offsets = options.offsets
        _ = surface(
            .picture,
            frame: NSRect(
                x     : 160,
                y     : 500,
                width : 620,
                height: 160
            ),
            identifier: "canvas.image",
            in        : content
        )
        _ = surface(
            .empty,
            frame: NSRect(
                x     : 820,
                y     : 500,
                width : 240,
                height: 160
            ),
            identifier: "canvas.empty",
            in        : content
        )
        window.makeFirstResponder(content)
        if options.still {
            window.orderFrontRegardless()
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if options.meterTwoLevels {
            stepObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.stepNotification,
                object : nil,
                queue  : .main
            ) { [weak timeline] _ in
                MainActor.assumeIsolated {
                    guard let timeline else { return }
                    timeline.phase = timeline.phase < 0.5 ? 1 : 0
                    timeline.caretVisible.toggle()
                    timeline.needsDisplay = true
                }
            }
        } else if !options.still {
            timer = Timer.scheduledTimer(
                withTimeInterval: 0.15,
                repeats         : true
            ) { [weak timeline] _ in
                MainActor.assumeIsolated {
                    guard let timeline else { return }
                    timeline.phase = (timeline.phase + 0.13).truncatingRemainder(dividingBy: 1)
                    timeline.caretVisible.toggle()
                    timeline.needsDisplay = true
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func addLabel(
        _ text: String,
        frame: NSRect,
        to view: NSView
    ) {
        let label = NSTextField(labelWithString: text)
        label.frame = frame
        label.font = .monospacedSystemFont(
            ofSize: 13,
            weight: .regular
        )
        label.textColor = .init(
            white: 0.82,
            alpha: 1
        )
        view.addSubview(label)
    }

    private func surface(
        _ kind: Surface.Kind,
        frame     : NSRect,
        identifier: String,
        in parent: NSView
    ) -> Surface {
        let view = Surface(frame: frame)
        view.kind = kind
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(kind == .picture ? .image : .group)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel("")
        view.setAccessibilityChildren([])
        parent.addSubview(view)
        return view
    }

    /// Still windows cannot acquire key appearance between captures when another process activates.
    final class FixtureWindow: NSWindow {
        var allowsFocus = true
        override var canBecomeKey: Bool { allowsFocus }
        override var canBecomeMain: Bool { allowsFocus }
    }

    /// Surface draws all clip captions as pixels. Its only AX facts are role, identifier and frame.
    final class Surface: NSView {
        enum Kind { case background, timeline, picture, empty }

        var kind: Kind = .empty
        var phase = 0.0
        var caretVisible = true
        var offsets = [Int: CGFloat]()
        private var draggedLane: Int?
        private var dragStartX: CGFloat = 0
        private var dragStartOffset: CGFloat = 0

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(
                white: kind == .background ? 0.10 : 0.16,
                alpha: 1
            ).setFill()
            bounds.fill()
            switch kind {
            case .timeline: drawTimeline()
            case .picture: drawPicture()
            default: break
            }
        }

        private func clipFrame(lane: Int) -> NSRect {
            NSRect(
                x     : 40 + CGFloat(lane - 1) * 55 + (offsets[lane] ?? 0),
                y     : CGFloat(lane - 1) * 80 + 20,
                width : 185,
                height: 44
            )
        }

        private func drawTimeline() {
            let colours: [NSColor] = [.systemTeal, .systemOrange, .systemPurple, .systemBlue]
            for lane in 1...4 {
                NSColor(
                    white: lane.isMultiple(of: 2) ? 0.14 : 0.18,
                    alpha: 1
                ).setFill()
                NSRect(
                    x     : 0,
                    y     : (lane - 1) * 80,
                    width : 900,
                    height: 80
                ).fill()
                let clip = clipFrame(lane: lane)
                colours[lane - 1].withAlphaComponent(0.85).setFill()
                NSBezierPath(
                    roundedRect: clip,
                    xRadius    : 4,
                    yRadius    : 4
                ).fill()
                let caption = "Clip \(lane)"
                caption.draw(
                    at: NSPoint(
                        x: clip.minX + 10,
                        y: clip.minY + 12
                    ),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: 13,
                            weight: .medium
                        ),
                        .foregroundColor: NSColor.white,
                    ]
                )
            }
            NSColor(
                white: 0.4,
                alpha: 1
            ).setFill()
            for x in stride(
                from: 0,
                to  : 900,
                by  : 135
            ) {
                NSRect(
                    x     : x,
                    y     : 0,
                    width : 1,
                    height: 320
                ).fill()
            }
            NSColor.white.setFill()
            NSRect(
                x     : 425,
                y     : 0,
                width : 2,
                height: 320
            ).fill()
            if caretVisible {
                NSRect(
                    x     : 420,
                    y     : 0,
                    width : 12,
                    height: 7
                ).fill()
            }

            let meter = NSRect(
                x     : bounds.maxX - 78,
                y     : 8,
                width : 68,
                height: 48
            )
            NSColor(
                white: 0.06,
                alpha: 1
            ).setFill()
            meter.fill()
            NSColor.systemGreen.setFill()
            for bar in 0..<6 {
                let height =
                    4 + min(
                        1,
                        phase * 0.7 + Double(bar) * 0.04
                    ) * 36
                NSRect(
                    x     : meter.minX + 5 + CGFloat(bar) * 10,
                    y     : meter.maxY - 4 - height,
                    width : 7,
                    height: height
                ).fill()
            }
        }

        /// A small quantized landscape keeps captures deterministic and the eight PNGs compact.
        private func drawPicture() {
            for y in 0..<40 {
                for x in 0..<155 {
                    let u = Double(x) / 155
                    let v = Double(y) / 40
                    let noise = Double((x * 31 + y * 17 + x * y * 13) % 7) / 120
                    let mountain = 0.48 + sin(u * 15) * 0.12 + cos(u * 31) * 0.05
                    let sky = v < mountain
                    let colour = NSColor(
                        red  : sky ? 0.35 + v * 0.4 + noise : 0.12 + noise,
                        green: sky ? 0.48 + v * 0.3 + noise : 0.25 + (1 - v) * 0.25 + noise,
                        blue : sky ? 0.7 + v * 0.15 : 0.26 + (1 - v) * 0.3 + noise,
                        alpha: 1
                    )
                    colour.setFill()
                    NSRect(
                        x     : x * 4,
                        y     : y * 4,
                        width : 4,
                        height: 4
                    ).fill()
                }
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard kind == .timeline else { return }
            let point = convert(
                event.locationInWindow,
                from: nil
            )
            draggedLane = (1...4).first { clipFrame(lane: $0).contains(point) }
            dragStartX = point.x
            dragStartOffset = draggedLane.flatMap { offsets[$0] } ?? 0
        }

        override func mouseDragged(with event: NSEvent) {
            guard let lane = draggedLane else { return }
            let offset =
                dragStartOffset
                + convert(
                    event.locationInWindow,
                    from: nil
                ).x - dragStartX
            let baseX = 40 + CGFloat(lane - 1) * 55
            offsets[lane] = min(
                max(
                    offset,
                    -baseX
                ),
                bounds.width - baseX - 185
            )
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) { draggedLane = nil }
    }
}
