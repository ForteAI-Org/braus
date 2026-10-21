//
//  HouseRoomCell.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit
import SwiftUI

/// HouseRoomCell is one worker's room, on the floor plan and as a row: the room lit by its worker,
/// the worker's brows over the sphere the room draws, the name under it and the badge in the top
/// trailing corner.
///
/// The selected worker has left for the conversation, so its room is empty: no sphere, no badge, a
/// lit door at the bottom in the status colour, the plaque "In chat with you" (`HouseAwayPlaque`)
/// hanging where the worker sat, and a white ring on its edge. Every room holds its plaque, hidden
/// while the worker is in, so that selecting it only shows the plaque. On the floor plan the room is
/// a button that calls `select`; as a row, with no `select`, the list selects it.
struct HouseRoomCell: View {
    let worker    : MockWorker
    let isSelected: Bool
    var select    : (() -> Void)?

    var body: some View {
        if let select {
            Button(action: select) { room }
                .buttonStyle(.plain)
                .modifier(Spoken(
                    worker    : worker,
                    isSelected: isSelected
                ))
        } else {
            room
                .accessibilityElement(children: .ignore)
                .modifier(Spoken(
                    worker    : worker,
                    isSelected: isSelected
                ))
        }
    }

    /// What VoiceOver says for `worker`'s room: its name and what it is doing, or that it is in chat.
    static func spokenLabel(
        for worker: MockWorker,
        isSelected: Bool
    ) -> String {
        isSelected ? "\(worker.name), \(HouseAwayPlaque.text.lowercased())" : "\(worker.name), \(worker.activity)"
    }

    private var room: some View {
        GeometryReader { proxy in
            ZStack {
                RoomLight(uniforms: RoomLightUniforms(
                    status     : worker.status,
                    shape      : worker.shape,
                    hasOccupant: !isSelected
                ))
                .allowsHitTesting(false)

                if !isSelected {
                    // The room draws the sphere at its centre, 34% of its short side across.
                    MascotFace(
                        shape           : worker.shape,
                        status          : worker.status,
                        brows           : BrowState(worker.status),
                        size            : 0.34 * min(proxy.size.width, proxy.size.height),
                        drawsBody       : false,
                        catchesRoomLight: true
                    )
                }

                HouseAwayPlaque(
                    brows    : BrowState(worker.status),
                    status   : worker.status,
                    isHanging: isSelected
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                label
                door(roomWidth: proxy.size.width)
                badge
                ring(roomSize: proxy.size)
            }
        }
        .contentShape(Rectangle())
    }

    private var label: some View {
        Text(worker.name)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
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

    /// Spoken gives a room its VoiceOver label, its badge as the value, and the selected trait.
    private struct Spoken: ViewModifier {
        let worker    : MockWorker
        let isSelected: Bool

        func body(content: Content) -> some View {
            content
                .accessibilityLabel(HouseRoomCell.spokenLabel(
                    for       : worker,
                    isSelected: isSelected
                ))
                .accessibilityValue(isSelected ? "" : worker.badge.map(HouseBadgeView.spokenText(for:)) ?? "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
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
