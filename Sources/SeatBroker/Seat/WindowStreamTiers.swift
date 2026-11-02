//
//  WindowStreamTiers.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import CoreGraphics

/// The pixels per point and the frame rate one held window streams at.
nonisolated struct WindowStreamQuality: Equatable, Sendable {
    var scale          : CGFloat
    var framesPerSecond: Int

    func pixelSize(of size: CGSize) -> CGSize {
        CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}

/// WindowStreamTiers decides how every held window streams, from the windows alone: the main window
/// at 30 fps capped to 1080p-class pixels, the others at the top tier until all streams together pass
/// a pixel or a frame budget, then stepped down one tier at a time, the costliest and furthest back
/// first.
///
/// Measured (M4, 1512×982 pt at 2x): the process and replayd cost follow the frames
/// delivered, about 0.03% of a core per frame a second each, not the pixels; pixels cost surface
/// memory and bandwidth. Every number to tune after trying it live is here.
nonisolated enum WindowStreamTiers {

    /// Window streams a seat runs at once, the main window's included and the observation's not.
    /// ScreenCaptureKit ran 24 at once in one process; past about 28 on this Mac new ones went silent.
    /// Twelve plus the observation's fit two workers under that, and a burst of twelve starts fits the
    /// kit's bound on framework calls in flight (a burst of 16 had 4 refused).
    static let streamLimit = 12

    /// The main window's frame rate, and the pixels its stream never goes past (either orientation).
    static let mainFramesPerSecond = 30
    static let mainPixelCap        = CGSize(width: 1920, height: 1080)

    /// The steps a secondary window goes down, top first: the share of the view's scale it keeps
    /// and its frame rate. Never below 1 pixel per point: half of it left a panel's twin black
    /// (89×533 pt captured at 44×266), and text below 1x stops being legible.
    static let tiers: [(scaleShare: CGFloat, framesPerSecond: Int)] = [
        (1.0, 10),
        (0.75, 8),
        (0.5, 5),
    ]

    /// Pixels and frames per second all window streams may deliver together before secondaries step
    /// down. The main window counts toward both but never steps down. 100 fps is the untiered cost of a
    /// main window and seven secondaries at 10 fps (3.3% CPU here, plus replayd 2.5%).
    static let pixelRateBudget: Double = 75_000_000
    static let frameRateBudget         = 100

    /// One held window: its size in points, the scale of the view that shows it, whether it is the
    /// main window, and whether it is fresh (in front, or the last one opened), which keeps it on top.
    struct Window: Equatable, Sendable {
        let number   : Int
        let size     : CGSize
        let viewScale: CGFloat
        let isMain   : Bool
        let isFresh  : Bool
    }

    /// The main window's quality at `viewScale`: 30 fps, capped to `mainPixelCap` and never under 1x.
    static func mainQuality(size: CGSize, viewScale: CGFloat) -> WindowStreamQuality {
        let long  = max(size.width, size.height)
        let short = min(size.width, size.height)
        let cap   = long > 0 && short > 0
            ? min(mainPixelCap.width / long, mainPixelCap.height / short)
            : viewScale
        return WindowStreamQuality(
            scale          : min(viewScale, max(cap, floorScale(viewScale))),
            framesPerSecond: mainFramesPerSecond
        )
    }

    /// Each window's quality, `windows` front to back.
    static func qualities(for windows: [Window]) -> [Int: WindowStreamQuality] {
        var tier: [Int: Int] = [:]
        func quality(_ window: Window) -> WindowStreamQuality {
            if window.isMain { return mainQuality(size: window.size, viewScale: window.viewScale) }
            let step = tiers[tier[window.number] ?? 0]
            return WindowStreamQuality(
                scale          : max(floorScale(window.viewScale), window.viewScale * step.scaleShare),
                framesPerSecond: step.framesPerSecond
            )
        }
        func cost(_ window: Window) -> Double {
            let pixels = quality(window).pixelSize(of: window.size)
            return Double(pixels.width * pixels.height) * Double(quality(window).framesPerSecond)
        }
        let secondaries = windows.filter { !$0.isMain }
        var total  = windows.reduce(0) { $0 + cost($1) }
        var frames = windows.reduce(0) { $0 + quality($1).framesPerSecond }
        while total > pixelRateBudget || frames > frameRateBudget {
            // Cost weighted by how far back the window sits among the secondaries.
            let candidates = secondaries.enumerated().filter { !$0.element.isFresh && (tier[$0.element.number] ?? 0) < tiers.count - 1 }
            guard let pick = candidates.max(by: { cost($0.element) * Double($0.offset + 1) < cost($1.element) * Double($1.offset + 1) })?.element
            else { break }
            let before = (cost(pick), quality(pick).framesPerSecond)
            tier[pick.number, default: 0] += 1
            total  += cost(pick) - before.0
            frames += quality(pick).framesPerSecond - before.1
        }
        return Dictionary(uniqueKeysWithValues: windows.map { ($0.number, quality($0)) })
    }

    private static func floorScale(_ viewScale: CGFloat) -> CGFloat { min(1, viewScale) }
}
