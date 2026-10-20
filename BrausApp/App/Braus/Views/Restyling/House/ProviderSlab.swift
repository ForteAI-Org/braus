//
//  ProviderSlab.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// ProviderSlab is the inspector's slab of the worker's provider: who answers, how, and, under a
/// divider, the way to every provider. A status dot appears only when the connection has trouble.
///
/// Its buttons are placeholders until provider management is part of the mockup.
struct ProviderSlab: View {

    /// Whether the worker's connection has trouble, the only time the slab shows a dot.
    var hasTrouble = false

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 12
        ) {
            Text("Provider")
                .font(.system(
                    size  : 10,
                    design: .monospaced
                ))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Button {} label: {
                provider
            }
            .buttonStyle(.plain)
            Divider()
            Button {} label: {
                HStack {
                    Text("All Providers · 3 Ready")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .modifier(SatinSlabStyle())
    }

    private var provider: some View {
        HStack(spacing: 12) {
            Text("A")
                .font(.system(
                    size  : 15,
                    weight: .bold
                ))
                .frame(
                    width : 34,
                    height: 34
                )
                .background(
                    LinearGradient(
                        colors    : [Color(white: 0.23), Color(white: 0.11)],
                        startPoint: UnitPoint(x: 0.33, y: 0),
                        endPoint  : UnitPoint(x: 0.67, y: 1)
                    ),
                    in: RoundedRectangle(
                        cornerRadius: 10,
                        style       : .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 10,
                        style       : .continuous
                    )
                    .strokeBorder(.white.opacity(0.1))
                }
            VStack(
                alignment: .leading,
                spacing  : 1
            ) {
                Text("Anthropic")
                    .font(.system(size: 14))
                Text("Subscription · Claude Code")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasTrouble {
                Circle()
                    .fill(HouseLayout.light(of: .busy))
                    .frame(
                        width : 8,
                        height: 8
                    )
                    .accessibilityLabel("Connection trouble")
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
