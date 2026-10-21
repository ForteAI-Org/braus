//
//  HouseFoot.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseFoot is the sidebar's foot, where the rooms end: the app has no account of its own, so it
/// holds nothing but its ground. The archive is in the sidebar's toolbar (`HouseArchiveButton`).
///
/// It floats over the rooms, which scroll under it to the window's edge. It has no box of its own:
/// its ground is the sidebar's colour, solid at the bottom margin and fading to clear over
/// `fadeHeight` above it, so a room passing under dissolves with no edge. The fade lets clicks
/// through to the rooms. Its height, fade included, is the inset the rooms scroll clear of.
struct HouseFoot: View {

    /// The height over which the foot's ground fades to clear.
    static let fadeHeight: CGFloat = 32

    var body: some View {
        Color.clear
            .frame(
                maxWidth : .infinity,
                minHeight: HouseLayout.margin,
                maxHeight: HouseLayout.margin
            )
            .padding(
                .top,
                Self.fadeHeight
            )
            .background { ground }
    }

    private var ground: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors    : [Color("RestylingSidebar").opacity(0), Color("RestylingSidebar")],
                startPoint: .top,
                endPoint  : .bottom
            )
            .frame(height: Self.fadeHeight)
            .allowsHitTesting(false)
            Color("RestylingSidebar")
        }
    }
}
