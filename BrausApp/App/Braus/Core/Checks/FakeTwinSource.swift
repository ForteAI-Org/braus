//
//  FakeTwinSource.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import Observation

/// FakeTwinSource stands in for the seat's windows of a held application in the window check: the
/// windows the check gives and changes, each drawn as a card of its kind with its title, rounded and
/// clear at its corners on a black layer, as a stream of the window draws it (`MonitorLayer`): a
/// panel square as a Qt one, a small window a little round, the others as macOS rounds them.
@MainActor
@Observable
final class FakeTwinSource: TwinSource {
    var windows: [TwinWindow]

    init(windows: [TwinWindow]) {
        self.windows = windows
    }

    /// Takes any size the person gives, as an application without limits does.
    func resize(
        windowNumber: Int,
        to size     : CGSize
    ) -> CGSize? {
        guard let index = windows.firstIndex(where: { $0.windowNumber == windowNumber }) else { return nil }
        windows[index].frame.size = size
        return size
    }

    func makeView(
        windowNumber : Int,
        contentsScale: CGFloat
    ) -> NSView? {
        guard let window = windows.first(where: { $0.windowNumber == windowNumber }) else { return nil }
        let view = NSView()
        view.wantsLayer             = true
        view.layer?.contents        = Self.card(
            of   : window,
            scale: contentsScale
        )
        view.layer?.contentsGravity = .resizeAspect
        // Black behind the picture and clipped to the view, as the seat's stream layer is.
        view.layer?.backgroundColor = CGColor(
            gray : 0,
            alpha: 1
        )
        view.layer?.masksToBounds   = true
        return view
    }

    /// A window's card: rounded, in a grey of its kind, its title at the top.
    private static func card(
        of window: TwinWindow,
        scale    : CGFloat
    ) -> CGImage? {
        let size = window.frame.size
        guard let context = CGContext(
            data            : nil,
            width           : Int(size.width * scale),
            height          : Int(size.height * scale),
            bitsPerComponent: 8,
            bytesPerRow     : 0,
            space           : CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(
            x: scale,
            y: scale
        )
        let grey: CGFloat = switch window.kind {
        case .main  : 0.16
        case .dialog: 0.24
        case .panel : 0.2
        default     : 0.28
        }
        let corner: CGFloat = switch window.kind {
        case .panel: 0
        case .other: 6
        default    : NeonTube.windowCorner
        }
        context.addPath(NeonTube.rounded(
            CGRect(origin: .zero, size: size),
            corner: corner
        ))
        context.setFillColor(CGColor(
            gray : grey,
            alpha: 1
        ))
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context,
            flipped  : false
        )
        (window.title as NSString).draw(
            at            : CGPoint(
                x: 12,
                y: size.height - 26
            ),
            withAttributes: [
                .font           : NSFont.systemFont(
                    ofSize: 13,
                    weight: .semibold
                ),
                .foregroundColor: NSColor(
                    white: 0.9,
                    alpha: 1
                ),
            ]
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
