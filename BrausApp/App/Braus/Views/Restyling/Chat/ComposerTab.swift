//
//  ComposerTab.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// ComposerTab sets a strip above the composer as one block with it: a tab a little narrower than
/// the pill, rounded at the top, darker than the glass, whose foot tucks under the pill.
struct ComposerTab: ViewModifier {

    /// How far the tab's foot runs under the pill.
    static let tuck: CGFloat = 2

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius    : 20,
            bottomLeadingRadius : 0,
            bottomTrailingRadius: 0,
            topTrailingRadius   : 20,
            style               : .continuous
        )
        return content
            .padding(
                .top,
                9
            )
            .padding(
                .horizontal,
                14
            )
            .padding(
                .bottom,
                11 + Self.tuck
            )
            .background {
                shape
                    .fill(.white.opacity(0.035))
                    .overlay { shape.strokeBorder(.white.opacity(0.06)) }
            }
            .padding(
                .horizontal,
                14
            )
            .padding(
                .bottom,
                -Self.tuck
            )
    }
}

extension View {

    /// A strip's line as a plain button that runs `action`, filling the strip's width so a click
    /// anywhere on it lands; the line as it is when there is no action.
    @ViewBuilder
    func stripAction(
        _ action: (() -> Void)?,
        help    : String
    ) -> some View {
        if let action {
            Button(action: action) {
                self.frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        } else {
            self
        }
    }
}
