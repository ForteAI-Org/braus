//
//  MockScreenView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// MockScreenView is the worker's screen as its window shows it: a sample Pro Tools session (menu
/// bar, four coloured tracks) where a looping script has the worker open the File menu, choose
/// Export › AAF, set the format and export, its pointer (`WorkerCursorLayer`) travelling and
/// clicking on cue, and a caption capsule saying the current action in plain words.
///
/// While the pointer is over the screen, or one of its buttons has the keyboard, the caption gives
/// way to `ScreenHoverControls`. Stop ends the script where it is. The screen keeps 16:10.
struct MockScreenView: View {
    let worker: HouseWorker

    @State private var scene   = Scene.session
    @State private var pointer = CGPoint(
        x: 0.5,
        y: 0.6
    )
    @State private var clicks     = 0
    @State private var caption    = ""
    @State private var isHovering = false
    @State private var isStopped  = false

    @FocusState private var focusedControl: ScreenHoverControls.Control?

    /// Scene is what the session shows over its tracks.
    enum Scene: Equatable {
        case session
        case fileMenu(choosesExport: Bool)
        case exportDialog(isStereo: Bool)
    }

    /// Step is one cue of the script, at `time` seconds into the loop: where the pointer goes,
    /// whether it clicks, the caption and the scene from then on.
    private struct Step {
        let time    : Double
        var pointer : CGPoint?
        var clicks  = false
        var caption : String?
        var scene   : Scene?
    }

    private static let loopSeconds = 9.2

    // After the prototype's script; the points land on the File menu, its Export item, the dialog's
    // Format row and its Export button as `session`, `fileMenu` and `exportDialog` draw them.
    private static let script: [Step] = [
        Step(time: 0,   pointer: CGPoint(x: 0.50, y: 0.60), caption: "Looks over the session", scene: .session),
        Step(time: 1.2, pointer: CGPoint(x: 0.18, y: 0.035), caption: "Opens the File menu"),
        Step(time: 2.0, clicks: true, scene: .fileMenu(choosesExport: false)),
        Step(time: 2.8, pointer: CGPoint(x: 0.22, y: 0.27)),
        Step(time: 3.5, clicks: true, caption: "Chooses Export › AAF", scene: .fileMenu(choosesExport: true)),
        Step(
            time   : 4.2,
            pointer: CGPoint(x: 0.60, y: 0.43),
            caption: "Sets stereo interleaved",
            scene  : .exportDialog(isStereo: false)
        ),
        Step(time: 5.1, clicks: true, scene: .exportDialog(isStereo: true)),
        Step(time: 6.0, pointer: CGPoint(x: 0.62, y: 0.60), caption: "Exports to the Delivery folder"),
        Step(time: 6.8, clicks: true, scene: .session),
        Step(time: 7.6, pointer: CGPoint(x: 0.45, y: 0.50), caption: "Checks the file is there"),
    ]

    /// The clips, one per track, as start and width fractions of the track.
    private static let clips: [(start: Double, width: Double)] = [
        (0.04, 0.60),
        (0.20, 0.50),
        (0.08, 0.75),
        (0.30, 0.40),
    ]

    private static let menuItems = ["New Session…", "Open Session…", "Save", "Export ›", "Close Session"]

    private var showsControls: Bool { isHovering || focusedControl != nil }

    private var isFileMenuOpen: Bool {
        if case .fileMenu = scene { true } else { false }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                session(size)
                switch scene {
                case .session:
                    EmptyView()
                case .fileMenu(let choosesExport):
                    fileMenu(
                        size,
                        choosesExport: choosesExport
                    )
                case .exportDialog(let isStereo):
                    exportDialog(
                        size,
                        isStereo: isStereo
                    )
                }
                Cursor(
                    worker : worker,
                    pointer: pointer,
                    clicks : clicks
                )
                .accessibilityHidden(true)
            }
            .font(.system(size: max(9, size.width * 0.02)))
            .foregroundStyle(Color(white: 0.85))
            .animation(
                RestylingMotion.reducesMotion ? nil : .easeOut(duration: 0.2),
                value: scene
            )
        }
        .background(Color(red: 0x1D / 255.0, green: 0x1E / 255.0, blue: 0x22 / 255.0))
        .overlay {
            Rectangle()
                .strokeBorder(HouseLayout.light(of: worker.status).opacity(0.45))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            ZStack {
                Text(caption)
                    .font(.system(size: 11.5))
                    .padding(
                        .horizontal,
                        12
                    )
                    .padding(
                        .vertical,
                        5
                    )
                    .background(
                        .regularMaterial,
                        in: Capsule()
                    )
                    .opacity(showsControls ? 0 : 1)
                ScreenHoverControls(
                    focus: $focusedControl,
                    stop : stop
                )
                .padding(6)
                .background(
                    .regularMaterial,
                    in: Capsule()
                )
                .opacity(showsControls ? 1 : 0)
            }
            .padding(
                .bottom,
                12
            )
            .animation(
                .easeInOut(duration: 0.25),
                value: showsControls
            )
        }
        .onHover { isHovering = $0 }
        .task(id: isStopped) {
            guard !isStopped else { return }
            await play()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(worker.name)'s screen")
        .accessibilityValue(caption)
    }

    /// Plays the script in a loop until the view goes or the person stops it.
    private func play() async {
        while !Task.isCancelled {
            var elapsed = 0.0
            for step in Self.script {
                guard await wait(step.time - elapsed) else { return }
                elapsed = step.time
                apply(step)
            }
            guard await wait(Self.loopSeconds - elapsed) else { return }
        }
    }

    /// Waits `seconds`, and says whether the script should go on.
    private func wait(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return true
        } catch {
            return false
        }
    }

    private func apply(_ step: Step) {
        if let point = step.pointer { pointer = point }
        if step.clicks { clicks += 1 }
        if let text = step.caption { caption = text }
        if let next = step.scene { scene = next }
    }

    private func stop() {
        isStopped = true
        caption   = "Stopped"
    }

    /// The session behind everything: the menu bar and four tracks with a clip each.
    private func session(_ size: CGSize) -> some View {
        let menuBar = size.height * 0.07
        return VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Color(red: 0x2A / 255.0, green: 0x2B / 255.0, blue: 0x30 / 255.0)
                ForEach(
                    Array(["Pro Tools", "File", "Edit", "View", "Track"].enumerated()),
                    id: \.offset
                ) { index, title in
                    Text(title)
                        .fontWeight(index == 0 ? .semibold : .regular)
                        .padding(
                            .horizontal,
                            4
                        )
                        .background(
                            index == 1 && isFileMenuOpen ? Color(white: 0.3) : .clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                        .fixedSize()
                        .offset(x: size.width * [0.02, 0.155, 0.23, 0.30, 0.37][index])
                }
            }
            .frame(height: menuBar)
            VStack(spacing: size.height * 0.03) {
                ForEach(
                    Array(Self.clips.enumerated()),
                    id: \.offset
                ) { lane, clip in
                    GeometryReader { track in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(HouseMockScreen.laneColors[lane].opacity(0.75))
                            .frame(
                                width : track.size.width * clip.width,
                                height: track.size.height * 0.7
                            )
                            .offset(
                                x: track.size.width * clip.start,
                                y: track.size.height * 0.15
                            )
                    }
                    .background(
                        Color(red: 0x26 / 255.0, green: 0x27 / 255.0, blue: 0x2C / 255.0),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
            }
            .padding(
                .horizontal,
                size.width * 0.03
            )
            .padding(
                .vertical,
                size.height * 0.04
            )
        }
        .frame(
            width : size.width,
            height: size.height
        )
    }

    /// The File menu under its title, with Export highlighted once the worker chooses it.
    private func fileMenu(
        _ size       : CGSize,
        choosesExport: Bool
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 0
        ) {
            ForEach(
                Self.menuItems,
                id: \.self
            ) { item in
                let isChosen = choosesExport && item == "Export ›"
                Text(item)
                    .foregroundStyle(isChosen ? .white : Color(white: 0.87))
                    .padding(
                        .leading,
                        size.width * 0.02
                    )
                    .frame(
                        width    : size.width * 0.32,
                        height   : size.height * 0.055,
                        alignment: .leading
                    )
                    .background(isChosen ? Color(red: 0x3D / 255.0, green: 0x6F / 255.0, blue: 0xD6 / 255.0) : .clear)
            }
        }
        .padding(
            .vertical,
            size.height * 0.012
        )
        .background(
            Color(red: 50 / 255.0, green: 51 / 255.0, blue: 58 / 255.0).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .shadow(
            color : .black.opacity(0.5),
            radius: 15,
            y     : 10
        )
        .offset(
            x: size.width * 0.15,
            y: size.height * 0.07
        )
        .transition(.opacity)
    }

    /// The Export AAF dialog: its Format and Folder rows and its Export button, where the script
    /// clicks them.
    private func exportDialog(
        _ size  : CGSize,
        isStereo: Bool
    ) -> some View {
        let row = Color(red: 0x2A / 255.0, green: 0x2B / 255.0, blue: 0x30 / 255.0)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0x34 / 255.0, green: 0x35 / 255.0, blue: 0x3C / 255.0))
                .shadow(
                    color : .black.opacity(0.6),
                    radius: 25,
                    y     : 20
                )
                .frame(
                    width : size.width * 0.40,
                    height: size.height * 0.40
                )
            Text("Export AAF")
                .fontWeight(.semibold)
                .offset(
                    x: size.width * 0.02,
                    y: size.height * 0.025
                )
            ForEach(
                [("Format", isStereo ? "Stereo interleaved" : "Multiple mono", 0.115), ("Folder", "Delivery", 0.195)],
                id: \.0
            ) { label, value, top in
                HStack {
                    Text(label)
                    Spacer()
                    Text(value)
                }
                .padding(
                    .horizontal,
                    size.width * 0.015
                )
                .frame(
                    width : size.width * 0.36,
                    height: size.height * 0.07
                )
                .background(
                    row,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .offset(
                    x: size.width * 0.02,
                    y: size.height * top
                )
            }
            Text("Export")
                .foregroundStyle(.white)
                .frame(
                    width : size.width * 0.136,
                    height: size.height * 0.06
                )
                .background(
                    Color(red: 0x3D / 255.0, green: 0x6F / 255.0, blue: 0xD6 / 255.0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .offset(
                    x: size.width * 0.25,
                    y: size.height * 0.29
                )
        }
        .offset(
            x: size.width * 0.30,
            y: size.height * 0.28
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Cursor hosts the worker's pointer layer over the whole screen and passes it the script's
    /// moves and clicks.
    private struct Cursor: NSViewRepresentable {
        let worker : HouseWorker
        let pointer: CGPoint
        let clicks : Int

        func makeNSView(context: Context) -> HostView {
            let view = HostView()
            view.cursor.face.shape  = worker.shape
            view.cursor.face.status = worker.status
            view.cursor.face.show(
                BrowState(worker.status),
                animated: false
            )
            view.cursor.move(to: pointer)
            view.clicks = clicks
            return view
        }

        func updateNSView(
            _ view : HostView,
            context: Context
        ) {
            if view.cursor.target != pointer { view.cursor.move(to: pointer) }
            if view.clicks != clicks {
                view.clicks = clicks
                view.cursor.click()
            }
        }

        /// HostView holds the cursor layer over its whole bounds and lets every click through.
        final class HostView: NSView {
            let cursor = WorkerCursorLayer()

            /// The clicks the cursor has played.
            var clicks = 0

            override init(frame: NSRect) {
                super.init(frame: frame)
                wantsLayer = true
                layer?.addSublayer(cursor)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { nil }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidChangeBackingProperties() {
                super.viewDidChangeBackingProperties()
                cursor.contentsScale = window?.backingScaleFactor ?? 2
            }

            override func layout() {
                super.layout()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                cursor.frame = bounds
                CATransaction.commit()
            }
        }
    }
}
