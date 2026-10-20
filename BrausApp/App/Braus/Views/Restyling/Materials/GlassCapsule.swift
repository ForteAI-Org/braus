//
//  GlassCapsule.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// GlassCapsule sets its content on the system's glass in a capsule: `.glassEffect` on macOS 26,
/// the regular material before it, and an opaque surface of the same dark tone under Reduce
/// Transparency (the asset catalogue's `RestylingOpaqueGlass`).
struct GlassCapsule: ViewModifier {

    func body(content: Content) -> some View {
        if RestylingMotion.reducesTransparency {
            content
                .background(
                    Color("RestylingOpaqueGlass"),
                    in: Capsule()
                )
                .overlay { edge }
        } else if #available(macOS 26, *) {
            content
                .glassEffect(
                    .regular,
                    in: Capsule()
                )
        } else {
            content
                .background(
                    .regularMaterial,
                    in: Capsule()
                )
                .overlay { edge }
        }
    }

    /// The capsule's faint rim, which the system's glass draws for itself.
    private var edge: some View {
        Capsule()
            .strokeBorder(.white.opacity(0.08))
    }
}
