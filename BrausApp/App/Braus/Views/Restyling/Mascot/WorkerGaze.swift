//
//  WorkerGaze.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit

/// WorkerGaze turns the pointer's place into where a worker's brows look. A `GazeTracker` hands it the
/// pointer in window coordinates; it works out yaw and pitch from the pointer relative to the face
/// (`MascotLayer.faceCenter`), clamped, and calls `MascotLayer.gaze(yaw:pitch:)`. When the pointer
/// leaves, or goes beyond `radius`, the brows keep looking for `releaseDelay` and then go back to
/// their behaviour (`MascotLayer.endGaze()`). `MascotLayer`'s own 0.2 s look timing smooths it.
@MainActor
final class WorkerGaze {

    /// How long the brows keep looking after the pointer leaves.
    static let releaseDelay = 0.4

    /// The pointer's distance from the face, in faces, at which the brows look all the way.
    static let reachInFaces = 2.5

    /// The host whose mascot looks.
    weak var host: MascotFace.HostView?

    /// How far from the face the pointer is followed, or nil to follow it everywhere the tracker sees.
    var radius: CGFloat?

    /// False while the worker has nobody to look with (away in the chat, or switching): nothing looks.
    var isEnabled = true {
        didSet {
            if !isEnabled { pointerLeft(after: 0) }
        }
    }

    private var release: DispatchWorkItem?

    init(radius: CGFloat? = nil) {
        self.radius = radius
    }

    /// The yaw and pitch, each -1...1, of a look from `face` toward `pointer`, both in one space with
    /// y up: positive yaw with the pointer to the right, positive pitch with it below.
    static func direction(
        from face  : CGPoint,
        to pointer : CGPoint,
        reach      : CGFloat
    ) -> (yaw: Double, pitch: Double) {
        let reach = max(1, reach)
        return (
            yaw  : Double(max(-1, min(1, (pointer.x - face.x) / reach))),
            pitch: Double(max(-1, min(1, (face.y - pointer.y) / reach)))
        )
    }

    /// The pointer is at `point` in window coordinates: looks at it, or lets go when it is beyond `radius`.
    func pointerMoved(toWindow point: CGPoint) {
        guard isEnabled, let host else { return }
        let mascot = host.mascot
        let center = host.convert(
            CGPoint(
                x: mascot.frame.minX + mascot.faceCenter.x,
                y: mascot.frame.minY + mascot.faceCenter.y
            ),
            to: nil
        )
        if let radius, hypot(point.x - center.x, point.y - center.y) > radius {
            if release == nil { pointerLeft() }
            return
        }
        release?.cancel()
        release = nil
        let look = Self.direction(
            from : center,
            to   : point,
            reach: mascot.faceSide * Self.reachInFaces
        )
        mascot.gaze(
            yaw  : look.yaw,
            pitch: look.pitch
        )
    }

    /// The pointer left: the brows go back to their behaviour after `delay`.
    func pointerLeft(after delay: Double = WorkerGaze.releaseDelay) {
        release?.cancel()
        release = nil
        guard let mascot = host?.mascot else { return }
        guard delay > 0 else {
            mascot.endGaze()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.release = nil
                self?.host?.mascot.endGaze()
            }
        }
        release = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute : work
        )
    }
}
