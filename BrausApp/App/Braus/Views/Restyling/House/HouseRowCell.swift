//
//  HouseRowCell.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseRowCell is one worker's row: the mascot with its status light behind it as a halo, the name,
/// the activity and, at the trailing edge, the badge. In the compact sidebar it is a tile with the
/// mascot and the name, the badge in its corner.
struct HouseRowCell: View {
    let worker   : MockWorker
    let isCompact: Bool

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 5) {
                    face
                    Text(worker.name)
                        .font(.system(
                            size  : 11,
                            weight: .medium
                        ))
                        .lineLimit(1)
                }
                .frame(
                    maxWidth : .infinity,
                    minHeight: 72
                )
                .overlay(alignment: .topTrailing) { badge }
            } else {
                HStack(spacing: 11) {
                    face
                    VStack(
                        alignment: .leading,
                        spacing  : 1
                    ) {
                        Text(worker.name)
                            .font(.system(
                                size  : 13,
                                weight: .semibold
                            ))
                        Text(worker.activity)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    badge
                }
                .frame(minHeight: 52)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(worker.name), \(worker.activity)")
        .accessibilityValue(worker.badge.map(HouseBadgeView.spokenText(for:)) ?? "")
    }

    /// The 30 point mascot over a radial halo of its status light, 110 points across.
    private var face: some View {
        MascotFace(
            appearance: worker.appearance,
            status    : worker.status,
            brows     : BrowState(worker.status),
            size      : 30
        )
        .background {
            RadialGradient(
                colors     : [
                    HouseLayout.light(of: worker.status).opacity(0.26 * worker.status.lightStrength),
                    .clear,
                ],
                center     : .center,
                startRadius: 0,
                endRadius  : 41
            )
            .frame(
                width : 110,
                height: 110
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let badge = worker.badge {
            HouseBadgeView(
                badge : badge,
                height: 18
            )
        }
    }
}
