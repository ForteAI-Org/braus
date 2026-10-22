//
//  HouseBadgeView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseBadgeView is the mark on a room's or a row's corner: an exclamation mark in the busy light
/// when a worker needs attention, otherwise a white capsule with its unread count, "99+" beyond 99.
struct HouseBadgeView: View {
    let badge : HouseBadge
    let height: CGFloat

    var body: some View {
        switch badge {
        case .attention:
            Image(systemName: "exclamationmark")
                .font(.system(
                    size  : 13,
                    weight: .bold
                ))
                .foregroundStyle(HouseLayout.light(of: .busy))
                .frame(
                    minWidth : height,
                    minHeight: height
                )
                .accessibilityLabel(Self.spokenText(for: badge))
        case .unread(let count):
            Text(Self.countText(count))
                .font(.system(
                    size  : height * 0.58,
                    weight: .semibold
                ))
                .monospacedDigit()
                .foregroundStyle(.black)
                .padding(
                    .horizontal,
                    5
                )
                .frame(
                    minWidth : height,
                    minHeight: height
                )
                .background(
                    Color(white: 0.96),
                    in: Capsule()
                )
                .accessibilityLabel(Self.spokenText(for: badge))
        }
    }

    /// The unread count as the capsule shows it, capped as the team row's badge is (`TeamRow.badgeLimit`).
    static func countText(_ count: Int) -> String {
        count > TeamRow.badgeLimit ? "\(TeamRow.badgeLimit)+" : count.formatted()
    }

    /// What VoiceOver says for `badge`, also given as the value of the room or row that carries it.
    static func spokenText(for badge: HouseBadge) -> String {
        switch badge {
        case .attention        : "Needs attention"
        case .unread(let count): "\(count) unread"
        }
    }
}
