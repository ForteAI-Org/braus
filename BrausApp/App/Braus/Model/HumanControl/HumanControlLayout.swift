//
//  HumanControlLayout.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import CoreGraphics
import SwiftUI

/// HumanControlLayout places the overlay that floats over an app the person has taken control of:
/// the worker at the top-right corner of a visible frame, standing as the house shows it outside its
/// room (`HouseWorkerPortrait`), its speech balloon to its left with a trail of small bubbles leading
/// to the worker, the Yes and No buttons under the balloon, and the ground its entrance and exit open
/// a hole in.
///
/// Everything is in points. Frames on screen are in AppKit's screen space, y up from the bottom of the
/// main screen; frames in the panel are in the panel's own space, y up from its bottom-left corner.
/// Main-actor isolated only because the worker's silhouette comes from `HouseWorkerPortrait`.
enum HumanControlLayout {

    /// The side of the worker's sphere, as `HouseWorkerPortrait` takes it.
    static let sphere: CGFloat = 76

    /// The room between the worker and the visible frame's right edge.
    static let margin: CGFloat = 16

    /// The room between the worker and the menu bar; the jumps rise into it.
    static let headroom: CGFloat = 36

    /// How far the jumps rise above the standing worker.
    static let jump: CGFloat = sphere * 0.45

    /// The standing body of `shape` as the portrait shows it with a sphere of `side`: its
    /// silhouette's size.
    static func figureSize(
        of shape   : WorkerShape,
        sphere side: CGFloat = sphere
    ) -> CGSize {
        HouseWorkerPortrait.silhouette(
            of  : shape,
            side: HouseWorkerPortrait.sceneSide(for: side)
        ).boundingRect.size
    }

    /// The standing body's silhouette in its own box, y up, with a sphere of `side`, for the shadow
    /// it casts.
    static func outline(
        of shape   : WorkerShape,
        sphere side: CGFloat = sphere
    ) -> CGPath {
        let silhouette = HouseWorkerPortrait.silhouette(
            of  : shape,
            side: HouseWorkerPortrait.sceneSide(for: side)
        )
        let bounds = silhouette.boundingRect
        // The silhouette's y points down from the scene's top; the box's up from its foot.
        var flip = CGAffineTransform(
            a : 1,
            b : 0,
            c : 0,
            d : -1,
            tx: -bounds.minX,
            ty: bounds.maxY
        )
        return silhouette.cgPath.copy(using: &flip) ?? silhouette.cgPath
    }

    /// The box that holds every shape's standing body, the widest and the tallest, in whole points so
    /// everything placed from it lands on whole points too.
    static let figure = CGSize(
        width : (WorkerShape.allCases.map { figureSize(of: $0).width }.max() ?? sphere).rounded(.up),
        height: (WorkerShape.allCases.map { figureSize(of: $0).height }.max() ?? sphere).rounded(.up)
    )

    /// The hole the worker comes out of and leaves through, and the soft pool of shadow it casts on
    /// the ground, across and deep, a little right of its foot, away from the room's lamp on its left.
    static let hole = CGSize(
        width : figure.width * 1.3,
        height: figure.width * 0.3
    )
    static let contactShadow = CGSize(
        width : figure.width * 1.15,
        height: figure.width * 0.24
    )
    static let contactShift: CGFloat = 4

    /// The dark core right under the worker's foot, where the ground meets it and no light reaches.
    static let occlusion = CGSize(
        width : figure.width * 0.7,
        height: figure.width * 0.09
    )

    /// The shadow the worker casts on the screen behind it, lit by the room's lamp above and to its
    /// left: its silhouette moved right and down by `offset`, blurred by `blur`, darkest near the ground.
    static let castShadow = (
        offset : CGSize(
            width : 7,
            height: -3
        ),
        blur   : CGFloat(7),
        opacity: Float(0.5)
    )

    /// The balloon's width, its height as a question and with a countdown, and its corner.
    static let balloonWidth   : CGFloat = 160
    static let questionHeight : CGFloat = 40
    static let countdownHeight: CGFloat = 58
    static let balloonCorner  : CGFloat = 14

    /// The balloon's soft shadow, and how far beyond the balloon it reaches.
    static let balloonShadow = (radius: CGFloat(7), offset: CGFloat(-3))
    static let shadowReach   = 2 * balloonShadow.radius + abs(balloonShadow.offset)

    /// The point of the balloon it springs open from and closes to, in its unit square: the right
    /// side where the trail leaves it.
    static let balloonAnchor = CGPoint(
        x: 1,
        y: 0.35
    )

    /// The room between the balloon and the worker that the trail of bubbles crosses, and the
    /// bubbles' radii, from the balloon to the worker.
    static let trailRoom : CGFloat = 30
    static let trailRadii: [CGFloat] = [4.5, 3.25, 2.25]

    /// The buttons under the balloon: the gap above them, their height and widths, the gap between
    /// them, and how far they slide up as they come in. Yes, reading I'm done, is the wider one.
    static let buttonGap   : CGFloat = 8
    static let buttonHeight: CGFloat = 24
    static let yesWidth    : CGFloat = 74
    static let noWidth     : CGFloat = 50
    static let buttonSpace : CGFloat = 8
    static let buttonSlide : CGFloat = 6

    /// Where the worker's face sits below the top of its box, as a share of the box's height.
    private static let faceShare: CGFloat = 0.42

    // Offsets down from the panel's top, in whole points, from which the panel's size follows.
    private static let faceDown       = (headroom + figure.height * faceShare).rounded()
    private static let balloonMidDown = faceDown - 6
    private static let buttonsDown    = balloonMidDown + countdownHeight / 2 + buttonGap + buttonHeight
        + buttonSlide
    private static let groundRoomDown = headroom + figure.height + hole.height / 2 + 6

    /// The room left of the balloon: its shadow, and the spring's peak about its anchor.
    private static let balloonLeftRoom = (
        balloonWidth * balloonAnchor.x * (BalloonSpring.opening.peak - 1) + shadowReach
    ).rounded(.up) + 2

    /// The panel's size: the worker with its headroom and hole, and the balloon with its shadow, its
    /// opening spring, its buttons and its trail to its left.
    static let panelSize = CGSize(
        width : balloonLeftRoom + balloonWidth + trailRoom + figure.width + margin,
        height: (max(buttonsDown, groundRoomDown) + 6).rounded(.up)
    )

    /// The box the standing worker fills, in the panel, its foot on the ground; clicks on it are
    /// clicks on the worker.
    static let mascotCell = CGRect(
        x     : panelSize.width - margin - figure.width,
        y     : panelSize.height - headroom - figure.height,
        width : figure.width,
        height: figure.height
    )

    /// The worker's face, about where it looks from and where the trail leads, in the panel.
    static let mascotCentre = CGPoint(
        x: mascotCell.midX,
        y: panelSize.height - faceDown
    )

    /// The halo behind the worker while the pointer is over it, in the panel: the ellipse within this
    /// box, well past the worker's sides so the blur is whole beside it, and a little past its top
    /// and foot. The screen's edge cuts its right side (`CompanionHalo`).
    static let haloFrame = mascotCell.insetBy(
        dx: -44,
        dy: -20
    )

    /// Where the worker stands, and where the hole opens.
    static let ground = CGPoint(
        x: mascotCell.midX,
        y: mascotCell.minY
    )

    /// The panel's frame on a screen whose visible frame, below the menu bar and beside the Dock,
    /// is `visibleFrame`: flush with its top-right corner, so the margins above set the room.
    static func panelFrame(in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x     : visibleFrame.maxX - panelSize.width,
            y     : visibleFrame.maxY - panelSize.height,
            width : panelSize.width,
            height: panelSize.height
        )
    }

    /// The balloon in the panel, `height` tall: left of the trail's room, level with the face, on
    /// whole points so its text is drawn crisply.
    static func balloonFrame(height: CGFloat) -> CGRect {
        CGRect(
            x     : mascotCell.minX - trailRoom - balloonWidth,
            y     : (panelSize.height - balloonMidDown - height / 2).rounded(),
            width : balloonWidth,
            height: height
        )
    }

    /// The balloon scaled by `scale` about its anchor: where it reaches while it springs.
    static func balloon(
        _ balloon: CGRect,
        scaledBy scale: CGFloat
    ) -> CGRect {
        let anchor = CGPoint(
            x: balloon.minX + balloonAnchor.x * balloon.width,
            y: balloon.minY + balloonAnchor.y * balloon.height
        )
        return CGRect(
            x     : anchor.x + (balloon.minX - anchor.x) * scale,
            y     : anchor.y + (balloon.minY - anchor.y) * scale,
            width : balloon.width * scale,
            height: balloon.height * scale
        )
    }

    /// One bubble of the trail: its centre and radius.
    struct TrailBubble: Equatable {
        let centre: CGPoint
        let radius: CGFloat
    }

    /// The trail from `balloon` to the worker's face: bubbles of decreasing size along the line from
    /// the balloon's anchor to just short of the worker.
    static func trail(from balloon: CGRect) -> [TrailBubble] {
        let start = CGPoint(
            x: balloon.maxX,
            y: balloon.minY + balloonAnchor.y * balloon.height
        )
        let end   = CGPoint(
            x: mascotCell.minX - 2,
            y: mascotCentre.y
        )
        let steps: [CGFloat] = [0.26, 0.58, 0.86]
        return zip(steps, trailRadii).map { step, radius in
            TrailBubble(
                centre: CGPoint(
                    x: start.x + (end.x - start.x) * step,
                    y: start.y + (end.y - start.y) * step
                ),
                radius: radius
            )
        }
    }

    /// The No and Yes buttons under `balloon`, side by side and centred on it, Yes on the right, on
    /// whole points.
    static func buttonFrames(under balloon: CGRect) -> (no: CGRect, yes: CGRect) {
        let row  = noWidth + buttonSpace + yesWidth
        let left = (balloon.midX - row / 2).rounded()
        let top  = balloon.minY - buttonGap
        return (
            no : CGRect(
                x     : left,
                y     : top - buttonHeight,
                width : noWidth,
                height: buttonHeight
            ),
            yes: CGRect(
                x     : left + noWidth + buttonSpace,
                y     : top - buttonHeight,
                width : yesWidth,
                height: buttonHeight
            )
        )
    }

    /// Where the worker looks while the pointer is over Yes or No under `balloon`: the button's centre.
    static func gazeTarget(
        yes          : Bool,
        under balloon: CGRect
    ) -> CGPoint {
        let buttons = buttonFrames(under: balloon)
        let button  = yes ? buttons.yes : buttons.no
        return CGPoint(
            x: button.midX,
            y: button.midY
        )
    }

    /// The thought bubble over the worker's head while it ponders: three circles rising from just
    /// above the head toward the upper left, and the small cloud they lead to, in the panel's
    /// headroom and clear of the balloon.
    static let thoughtCircles: [TrailBubble] = [
        (34.0, 3.0, 1.4),
        (25.0, 7.0, 1.9),
        (15.0, 11.0, 2.4),
    ].map {
        TrailBubble(
            centre: CGPoint(
                x: mascotCell.minX + $0.0,
                y: mascotCell.maxY + $0.1
            ),
            radius: $0.2
        )
    }
    static let thoughtCloud = CGRect(
        x     : mascotCell.minX - 19,
        y     : mascotCell.maxY + 15.5,
        width : 32,
        height: 17
    )

    /// How far from the worker's face the pointer makes it look.
    static let lookRadius: CGFloat = 240

    /// Whether `pointer`, on screen, is near enough to the face of the worker in a panel at
    /// `panelOrigin` for it to look.
    static func isNear(
        _ pointer  : CGPoint,
        panelOrigin: CGPoint
    ) -> Bool {
        hypot(
            pointer.x - panelOrigin.x - mascotCentre.x,
            pointer.y - panelOrigin.y - mascotCentre.y
        ) <= lookRadius
    }

    /// The border's gap from the window it marks, its neon tube, and the room around the tube for its
    /// bloom.
    static let borderGap : CGFloat = 2
    static let borderLine: CGFloat = 2
    static let borderHalo: CGFloat = 48

    /// The border's frame around a window's `frame`: the gap, the tube and the halo outside it.
    static func borderFrame(around frame: CGRect) -> CGRect {
        frame.insetBy(
            dx: -(borderGap + borderLine + borderHalo),
            dy: -(borderGap + borderLine + borderHalo)
        )
    }

    /// The window's frame in its border, and the rect the tube is stroked on, centred on it.
    static let borderWindowInset = borderGap + borderLine + borderHalo
    static let borderLineInset   = borderHalo + borderLine / 2
}
