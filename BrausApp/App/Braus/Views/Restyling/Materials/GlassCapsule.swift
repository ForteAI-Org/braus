//
//  GlassCapsule.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// GlassCapsule sets its content on the system's glass in a capsule: `.glassEffect` on macOS 26,
/// the regular material before it, and an opaque surface of the same dark tone under Reduce
/// Transparency (the asset catalogue's `HouseOpaqueGlass`).
///
/// Its ends keep `cornerRadius`, half its height on one row, so a capsule that grows taller keeps
/// its shape's ends instead of rounding into a lozenge.
struct GlassCapsule: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if HouseMotion.reducesTransparency {
            content
                .background(
                    Color("HouseOpaqueGlass"),
                    in: shape
                )
                .overlay { edge }
        } else if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular,
                    in: shape
                )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: shape
                )
                .overlay { edge }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: cornerRadius,
            style       : .continuous
        )
    }

    /// The capsule's faint rim, which the system's glass draws for itself.
    private var edge: some View {
        shape
            .strokeBorder(.white.opacity(0.08))
    }
}
