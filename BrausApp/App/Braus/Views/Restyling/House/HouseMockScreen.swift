//
//  HouseMockScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseMockScreen is the worker's live screen as the mockup draws it: a 16:10 mock of the app it
/// drives, a few tracks under a menu bar, with the worker's amber pointer wandering, in a rounded clip.
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

    /// The prototype's tracks: top, start and width as fractions of the screen, and the clip colour.
    private static let tracks: [(top: Double, start: Double, width: Double, color: Color)] = [
        (0.18, 0.04, 0.60, Color(red: 0x5B / 255.0, green: 0x8D / 255.0, blue: 0xEF / 255.0)),
        (0.38, 0.20, 0.50, Color(red: 0xE0 / 255.0, green: 0xA3 / 255.0, blue: 0x46 / 255.0)),
        (0.58, 0.08, 0.75, Color(red: 0x58 / 255.0, green: 0xC4 / 255.0, blue: 0x8D / 255.0)),
        (0.78, 0.30, 0.40, Color(red: 0xC4 / 255.0, green: 0x6F / 255.0, blue: 0xD6 / 255.0)),
    ]

    private var screen: some View {
        Color(
            red  : 0x1D / 255.0,
            green: 0x1E / 255.0,
            blue : 0x22 / 255.0
        )
        .aspectRatio(
            16.0 / 10.0,
            contentMode: .fit
        )
        .overlay {
            GeometryReader { proxy in
                let size = proxy.size
                Color(
                    red  : 0x2A / 255.0,
                    green: 0x2B / 255.0,
                    blue : 0x30 / 255.0
                )
                .frame(height: size.height * 0.09)
                ForEach(
                    Self.tracks.indices,
                    id: \.self
                ) { index in
                    track(
                        Self.tracks[index],
                        in: size
                    )
                }
                WanderingPointer()
            }
        }
        .clipShape(RoundedRectangle(
            cornerRadius: 8,
            style       : .continuous
        ))
    }

    private func track(
        _ track: (top: Double, start: Double, width: Double, color: Color),
        in size: CGSize
    ) -> some View {
        let lane = CGSize(
            width : size.width * 0.9,
            height: size.height * 0.13
        )
        return RoundedRectangle(
            cornerRadius: 4,
            style       : .continuous
        )
        .fill(Color(
            red  : 0x26 / 255.0,
            green: 0x27 / 255.0,
            blue : 0x2C / 255.0
        ))
        .overlay(alignment: .leading) {
            RoundedRectangle(
                cornerRadius: 3,
                style       : .continuous
            )
            .fill(track.color.opacity(0.75))
            .frame(
                width : lane.width * track.width,
                height: lane.height * 0.6
            )
            .offset(x: lane.width * track.start)
        }
        .frame(
            width : lane.width,
            height: lane.height
        )
        .offset(
            x: size.width * 0.05,
            y: size.height * track.top
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
