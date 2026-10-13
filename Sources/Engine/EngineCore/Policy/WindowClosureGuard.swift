//
//  WindowClosureGuard.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import CoreGraphics

/// WindowClosureGuard is the broker's reading of what closing the window an action targets would
/// do to its application, and where that window's own close and cancel buttons are. Only the
/// brokered path computes it; the default closes nothing.
public struct WindowClosureGuard: Sendable, Equatable, Codable {

    /// Closing the window may end the application: it is its only window, with nothing open over it.
    public var mayEndTheApplication: Bool

    /// The screen rectangles of the window's `AXCancelButton` and `AXCloseButton`: a click inside
    /// one is the window's own closing control, whatever the scene calls it.
    public var controlFrames: [CGRect]

    public init(mayEndTheApplication: Bool = false, controlFrames: [CGRect] = []) {
        self.mayEndTheApplication = mayEndTheApplication
        self.controlFrames        = controlFrames
    }
}
