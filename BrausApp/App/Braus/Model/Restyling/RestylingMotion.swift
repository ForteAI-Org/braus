//
//  RestylingMotion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import AppKit

/// RestylingMotion tells every mockup animation whether the person asked the
/// system to reduce motion or transparency.
///
/// The overrides are process-wide and main-actor isolated, for tests only; a
/// test that sets one resets it to `nil` when it ends.
enum RestylingMotion {

    /// When set, `reducesMotion` returns it instead of the system setting.
    static var overrideReducesMotion: Bool?

    /// When set, `reducesTransparency` returns it instead of the system setting.
    static var overrideReducesTransparency: Bool?

    /// Whether travel, morph and bounce become a cross-fade or a cut, and
    /// ambient breathing and flicker stop.
    static var reducesMotion: Bool {
        overrideReducesMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Whether every glass becomes an opaque surface of the same tone.
    static var reducesTransparency: Bool {
        overrideReducesTransparency ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}
