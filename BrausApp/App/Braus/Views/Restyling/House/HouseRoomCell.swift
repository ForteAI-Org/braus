//
//  HouseRoomCell.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit
import SwiftUI

/// HouseRoomCell is one worker's room on the floor plan: the room lit by its worker, the worker's
/// brows over the sphere the room draws, the name under it and the badge in the top trailing corner.
///
/// The selected worker has left for the conversation, so its room is empty: no sphere, no badge, a
/// lit door at the bottom in the status colour, the label "With you" and a white ring on its edge.
struct HouseRoomCell: View {
    let worker    : MockWorker
    let isSelected: Bool
    let select    : () -> Void

    var body: some View {
        Button(action: select) {
            GeometryReader { proxy in
                ZStack {
                    RoomLight(uniforms: RoomLightUniforms(
                        status     : worker.status,
                        tint       : MascotImages.color(for: worker.appearance),
                        hasOccupant: !isSelected
                    ))
                    .allowsHitTesting(false)

                    if !isSelected {
                        // The room draws the sphere at its centre, 34% of its short side across.
                        MascotFace(
                            appearance      : worker.appearance,
                            status          : worker.status,
                            brows           : BrowState(worker.status),
                            size            : 0.34 * min(proxy.size.width, proxy.size.height),
                            drawsBody       : false,
                            catchesRoomLight: true
                        )
                    }

                    label
                    door(roomWidth: proxy.size.width)
                    badge
                    ring(roomSize: proxy.size)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(worker.name), \(worker.activity)")
        .accessibilityValue(worker.badge.map(HouseBadgeView.spokenText(for:)) ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var label: some View {
        Text(isSelected ? "With you" : worker.name)
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .lineLimit(1)
            .padding(
                .horizontal,
                8
            )
            .padding(
                .bottom,
                9
            )
            .frame(
                maxWidth : .infinity,
                maxHeight: .infinity,
                alignment: .bottom
            )
            .accessibilityHidden(true)
    }

    /// The lit door of an empty room, at the bottom, 26% of the room's width.
    @ViewBuilder
    private func door(roomWidth: CGFloat) -> some View {
        if isSelected {
            let light = HouseLayout.light(of: worker.status)
            UnevenRoundedRectangle(
                topLeadingRadius : 3,
                topTrailingRadius: 3
            )
            .fill(light.opacity(0.85))
            .shadow(
                color : light.opacity(0.9),
                radius: 6
            )
            .frame(
                width : 0.26 * roomWidth,
                height: 4
            )
            .frame(
                maxWidth : .infinity,
                maxHeight: .infinity,
                alignment: .bottom
            )
        }
    }

    /// The selected room's ring, on the room's own rounded edge: the radius follows
    /// `RoomLightUniforms.Shape`, 14 points for a room 104 points tall.
    @ViewBuilder
    private func ring(roomSize: CGSize) -> some View {
        if isSelected {
            RoundedRectangle(
                cornerRadius: CGFloat(RoomLightUniforms.Shape(size: roomSize).cornerRadius),
                style       : .continuous
            )
            .strokeBorder(
                .white.opacity(0.55),
                lineWidth: 1.5
            )
        }
    }

    @ViewBuilder
    private var badge: some View {
        if !isSelected, let badge = worker.badge {
            HouseBadgeView(
                badge : badge,
                height: 17
            )
            .padding(7)
            .frame(
                maxWidth : .infinity,
                maxHeight: .infinity,
                alignment: .topTrailing
            )
        }
    }

    /// RoomLight hosts the room's `RoomLightView`, on the system's default GPU. Without one the room
    /// stays empty.
    private struct RoomLight: NSViewRepresentable {
        let uniforms: RoomLightUniforms

        private static let device = MTLCreateSystemDefaultDevice()

        func makeNSView(context: Context) -> NSView {
            guard let device = Self.device else { return NSView() }
            return RoomLightView(
                device  : device,
                uniforms: uniforms
            )
        }

        func updateNSView(
            _ view : NSView,
            context: Context
        ) {
            (view as? RoomLightView)?.uniforms = uniforms
        }
    }
}
