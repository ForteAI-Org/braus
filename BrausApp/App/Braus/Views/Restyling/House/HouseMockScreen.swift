//
//  HouseMockScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseMockScreen is the worker's live screen as the mockup draws it: a 16:10 miniature of the
/// app's window it drives (title bar, toolbar, tracks with clips and a playhead), with the worker's
/// amber pointer wandering over it.
///
/// The inspector shows it only while the worker is busy. Its click will open the worker's screen
/// window; until that window exists it does nothing.
struct HouseMockScreen: View {
    let worker: MockWorker

    var body: some View {
        screen
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Self.appName(of: worker)) screen")
    }

    /// The app the mock worker drives, after its kind.
    static func appName(of worker: MockWorker) -> String {
        switch worker.category {
        case .audio  : "Pro Tools"
        case .video  : "DaVinci Resolve"
        case .design : "Photoshop"
        case .web    : "Safari"
        case .files,
             .general: "Finder"
        }
    }

    /// The clips' colours, one per lane, after the prototype's tracks.
    private static let laneColors: [Color] = [
        Color(red: 0x5B / 255.0, green: 0x8D / 255.0, blue: 0xEF / 255.0),
        Color(red: 0xE0 / 255.0, green: 0xA3 / 255.0, blue: 0x46 / 255.0),
        Color(red: 0x58 / 255.0, green: 0xC4 / 255.0, blue: 0x8D / 255.0),
        Color(red: 0xC4 / 255.0, green: 0x6F / 255.0, blue: 0xD6 / 255.0),
    ]

    /// Each lane's clips, as start and end fractions of the timeline.
    private static let clips: [[(start: Double, end: Double)]] = [
        [(0.02, 0.46), (0.52, 0.88)],
        [(0.18, 0.70)],
        [(0.06, 0.34), (0.40, 0.95)],
        [(0.30, 0.62), (0.68, 0.80)],
    ]

    /// A miniature of the app's window, drawn once per size: title bar with traffic lights, a
    /// toolbar strip, track headers and a timeline of clips with a playhead, in a rounded clip
    /// with a soft shadow, the pointer wandering over it.
    private var screen: some View {
        let shape = RoundedRectangle(
            cornerRadius: 7,
            style       : .continuous
        )
        return Canvas { context, size in
            draw(
                in  : &context,
                size: size
            )
        }
        .aspectRatio(
            16.0 / 10.0,
            contentMode: .fit
        )
        .overlay { WanderingPointer() }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.1)) }
        .shadow(
            color : .black.opacity(0.45),
            radius: 8,
            y     : 4
        )
        .padding(
            .vertical,
            4
        )
    }

    private func draw(
        in context: inout GraphicsContext,
        size      : CGSize
    ) {
        let titleHeight   = size.height * 0.1
        let toolbarHeight = size.height * 0.09
        let headerWidth   = size.width * 0.2
        let top           = titleHeight + toolbarHeight

        fill(
            CGRect(origin: .zero, size: size),
            with: Color(white: 0.12),
            in  : &context
        )
        drawTitleBar(
            in    : &context,
            width : size.width,
            height: titleHeight
        )
        fill(
            CGRect(x: 0, y: titleHeight, width: size.width, height: toolbarHeight),
            with: Color(white: 0.16),
            in  : &context
        )
        // The toolbar's buttons, the middle one a wider segmented control.
        for (start, width) in [(0.03, 0.06), (0.11, 0.06), (0.42, 0.16), (0.82, 0.06), (0.9, 0.06)] {
            fill(
                CGRect(
                    x     : size.width * start,
                    y     : titleHeight + toolbarHeight * 0.25,
                    width : size.width * width,
                    height: toolbarHeight * 0.5
                ),
                with  : Color(white: width > 0.1 ? 0.28 : 0.24),
                radius: toolbarHeight * 0.2,
                in    : &context
            )
        }

        let laneHeight = (size.height - top) / CGFloat(Self.laneColors.count)
        for (lane, color) in Self.laneColors.enumerated() {
            drawLane(
                lane,
                color      : color,
                in         : &context,
                frame      : CGRect(x: 0, y: top + CGFloat(lane) * laneHeight, width: size.width, height: laneHeight),
                headerWidth: headerWidth
            )
        }

        fill(
            CGRect(x: headerWidth + (size.width - headerWidth) * 0.47, y: top, width: 1, height: size.height - top),
            with: Color(white: 0.9).opacity(0.8),
            in  : &context
        )
    }

    /// The title bar: the traffic lights at the leading edge and the document's title centred.
    private func drawTitleBar(
        in context: inout GraphicsContext,
        width     : CGFloat,
        height    : CGFloat
    ) {
        fill(
            CGRect(x: 0, y: 0, width: width, height: height),
            with: Color(white: 0.2),
            in  : &context
        )
        let light = height * 0.38
        for (index, color) in [Color.red, Color.yellow, Color.green].enumerated() {
            context.fill(
                Path(ellipseIn: CGRect(
                    x     : height * 0.35 + CGFloat(index) * light * 1.6,
                    y     : (height - light) / 2,
                    width : light,
                    height: light
                )),
                with: .color(color.opacity(0.85))
            )
        }
        context.draw(
            Text("\(Self.appName(of: worker)) — Delivery")
                .font(.system(size: max(5, height * 0.42)))
                .foregroundStyle(Color(white: 0.7)),
            at: CGPoint(x: width / 2, y: height / 2)
        )
    }

    /// One track: its header with a name bar, its clips with a waveform, and the line under it.
    private func drawLane(
        _ lane     : Int,
        color      : Color,
        in context : inout GraphicsContext,
        frame      : CGRect,
        headerWidth: CGFloat
    ) {
        fill(
            CGRect(x: frame.minX, y: frame.minY, width: headerWidth, height: frame.height - 1),
            with: Color(white: 0.15),
            in  : &context
        )
        fill(
            CGRect(
                x     : headerWidth * 0.12,
                y     : frame.minY + frame.height * 0.35,
                width : headerWidth * 0.55,
                height: frame.height * 0.18
            ),
            with  : Color(white: 0.32),
            radius: 1,
            in    : &context
        )
        fill(
            CGRect(x: headerWidth, y: frame.maxY - 1, width: frame.width, height: 1),
            with: Color(white: 0.17),
            in  : &context
        )
        let timeline = frame.width - headerWidth
        for clip in Self.clips[lane] {
            let rect = CGRect(
                x     : headerWidth + timeline * clip.start,
                y     : frame.minY + frame.height * 0.15,
                width : timeline * (clip.end - clip.start),
                height: frame.height * 0.7
            )
            fill(
                rect,
                with  : color.opacity(0.35),
                radius: 2,
                in    : &context
            )
            // A waveform of thin bars, the same on every draw.
            var bars = Path()
            var x    = rect.minX + 1.5
            while x < rect.maxX - 1.5 {
                let swing  = 0.25 + 0.7 * abs(sin(x * 0.37 + CGFloat(lane)) * cos(x * 0.11))
                let height = rect.height * 0.8 * swing
                bars.addRect(CGRect(x: x, y: rect.midY - height / 2, width: 0.8, height: height))
                x += 1.8
            }
            context.fill(
                bars,
                with: .color(color.opacity(0.9))
            )
        }
    }

    private func fill(
        _ rect    : CGRect,
        with color: Color,
        radius    : CGFloat = 0,
        in context: inout GraphicsContext
    ) {
        context.fill(
            Path(
                roundedRect : rect,
                cornerRadius: radius
            ),
            with: .color(color)
        )
    }

    /// WanderingPointer is the worker's amber pointer moving over its screen, a Core Animation
    /// keyframe loop that costs no rendering at rest. Under Reduce Motion it stays at its first stop.
    private struct WanderingPointer: NSViewRepresentable {

        func makeNSView(context: Context) -> PointerView { PointerView() }

        func updateNSView(
            _ view : PointerView,
            context: Context
        ) {}

        /// PointerView holds the pointer layer and moves it over its whole bounds.
        final class PointerView: NSView {

            /// The prototype's stops, as fractions of the screen from its top left, one loop every 5 s.
            private static let stops: [CGPoint] = [
                CGPoint(x: 0.30, y: 0.40),
                CGPoint(x: 0.62, y: 0.28),
                CGPoint(x: 0.48, y: 0.70),
                CGPoint(x: 0.30, y: 0.40),
            ]

            private static let loopSeconds = 5.0

            private let pointer = CALayer()

            private var laidOutSize = CGSize.zero

            override var isFlipped: Bool { true }

            override init(frame: NSRect) {
                super.init(frame: frame)
                wantsLayer = true

                // A 9 point amber dot inside a 2 point dark rim.
                let dot = CALayer()
                dot.frame           = CGRect(x: 2, y: 2, width: 9, height: 9)
                dot.cornerRadius    = 4.5
                dot.backgroundColor = CGColor(
                    srgbRed: 1,
                    green  : 176.0 / 255,
                    blue   : 72.0 / 255,
                    alpha  : 1
                )
                pointer.bounds          = CGRect(x: 0, y: 0, width: 13, height: 13)
                pointer.cornerRadius    = 6.5
                pointer.backgroundColor = CGColor(gray: 0, alpha: 0.5)
                pointer.addSublayer(dot)
                layer?.addSublayer(pointer)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { nil }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func layout() {
                super.layout()
                guard bounds.size != laidOutSize else { return }

                laidOutSize = bounds.size
                let points = Self.stops.map { CGPoint(
                    x: $0.x * bounds.width,
                    y: $0.y * bounds.height
                ) }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                pointer.position = points[0]
                CATransaction.commit()

                guard !RestylingMotion.reducesMotion else {
                    pointer.removeAnimation(forKey: "wander")
                    return
                }
                let wander = CAKeyframeAnimation(keyPath: "position")
                wander.values          = points.map { NSValue(point: $0) }
                wander.keyTimes        = [0, 1.0 / 3, 2.0 / 3, 1].map { NSNumber(value: $0) }
                wander.timingFunctions = Array(
                    repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                    count    : 3
                )
                wander.duration        = Self.loopSeconds
                wander.repeatCount     = .infinity
                pointer.add(
                    wander,
                    forKey: "wander"
                )
            }
        }
    }
}
