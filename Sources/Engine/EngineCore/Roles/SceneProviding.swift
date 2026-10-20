//
//  SceneProviding.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// SceneProviding supplies the current scene of a process's interaction window: a fresh perception
/// at every call, never a cache, because an action is resolved against this instant's positions.
///
/// It also reports the window the scene was taken from, in global points, so the engine can turn a
/// normalized element into the point a gesture is delivered at.
public protocol SceneProviding: Sendable {

    func currentScene(of processID: pid_t) async throws -> PerceivedWindow
}

/// PerceivedWindow is a scene together with the global frame of the window it describes, the
/// quality of the accessibility read behind it and the surface the capture was taken of.
///
/// Quality and surface describe this one capture. A provider states them from what it measured:
/// the pipeline's capture quality, the pop-up it saw open, the role and subrole the tree reported.
/// A provider that did not read a tree leaves both `unknown`; nothing here is inferred from the
/// scene's elements or its title.
public struct PerceivedWindow: Sendable, Equatable {

    public let scene: SceneSnapshot
    public let frame: CGRect
    public let capture: CaptureQuality
    public let surface: CaptureSurface
    /// The physical identity its provider attests for each element of this capture, by the element's id in
    /// this scene. The id only finds the element here; the identity is the proof. A provider fills it only
    /// where it also says which fields are secure, and leaves out an element whose id two elements share.
    public let identities: [String: TargetIdentity]

    public init(
        scene     : SceneSnapshot,
        frame     : CGRect,
        capture   : CaptureQuality = .unknown,
        surface   : CaptureSurface = .unknown,
        identities: [String: TargetIdentity] = [:]
    ) {
        self.scene      = scene
        self.frame      = frame
        self.capture    = capture
        self.surface    = surface
        self.identities = identities
    }

    /// The global point at the center of an element of this scene.
    public func globalPoint(of element: SceneElement) -> CGPoint {
        CGPoint(
            x: frame.minX + element.bounds.midX * frame.width,
            y: frame.minY + element.bounds.midY * frame.height
        )
    }
}
