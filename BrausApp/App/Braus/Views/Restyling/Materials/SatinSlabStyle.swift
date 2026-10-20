//
//  SatinSlabStyle.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// SatinSlabStyle sets its content on the design's satin metal slab, as the inspector's blocks are:
/// a dark diagonal gradient in a 22 point rounded rectangle, a faint edge light, a highlight on the
/// top edge and a soft shadow under it.
///
/// The slab is opaque, so Reduce Transparency leaves it as it is.
struct SatinSlabStyle: ViewModifier {

    func body(content: Content) -> some View {
        content
            .padding(15)
            .frame(
                maxWidth : .infinity,
                alignment: .leading
            )
            .background(
                metal,
                in: shape
            )
            .overlay {
                shape.strokeBorder(.white.opacity(0.08))
            }
            .overlay {
                shape.strokeBorder(topEdge)
            }
            .shadow(
                color : .black.opacity(0.5),
                radius: 20,
                y     : 18
            )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: 22,
            style       : .continuous
        )
    }

    /// The prototype's 160 degree gradient: light at the top left, darkest at the bottom right.
    private var metal: LinearGradient {
        LinearGradient(
            stops     : [
                .init(color: Color(white: 0.165), location: 0),
                .init(color: Color(white: 0.08), location: 0.45),
                .init(color: Color(white: 0.112), location: 0.7),
                .init(color: Color(white: 0.048), location: 1),
            ],
            startPoint: UnitPoint(x: 0.33, y: 0),
            endPoint  : UnitPoint(x: 0.67, y: 1)
        )
    }

    /// The highlight along the top edge, fading out before the sides go down.
    private var topEdge: LinearGradient {
        LinearGradient(
            stops     : [
                .init(color: .white.opacity(0.14), location: 0),
                .init(color: .clear, location: 0.12),
            ],
            startPoint: .top,
            endPoint  : .bottom
        )
    }
}
