//
//  BubblePath.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SwiftUI

/// BubblePath is the outline of one bubble, in flipped coordinates, so fill,
/// focus outline and selection all follow one shape.
nonisolated enum BubblePath {

    /// The corners: round, and the tight one at the bottom on the author's side.
    static let houseRadius     : CGFloat = 21
    static let houseTightRadius: CGFloat = 8

    /// The bubble in `surface`, in flipped coordinates, with continuous corners: its
    /// bottom trailing corner tight for the person's, its bottom leading one for the worker's.
    static func housePath(
        surface      : CGRect,
        tightTrailing: Bool
    ) -> CGPath {
        UnevenRoundedRectangle(
            topLeadingRadius    : houseRadius,
            bottomLeadingRadius : tightTrailing ? houseRadius : houseTightRadius,
            bottomTrailingRadius: tightTrailing ? houseTightRadius : houseRadius,
            topTrailingRadius   : houseRadius,
            style               : .continuous
        )
        .path(in: surface)
        .cgPath
    }
}
