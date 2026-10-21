//
//  HouseRoomCell.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import MetalKit
import SwiftUI

/// HouseRoomCell is one worker's room, on the floor plan and as a row: the room lit by its worker,
/// set into the column as an opening (`RoomOpeningView`), the worker's brows over the body the room
/// draws, its name and the badge.
///
/// On the floor plan and in the compact rows the worker stands at the room's centre, the name under
/// it and the badge in the top trailing corner. A wide row (`isBeside`) leans the room's composition
/// left: the worker stands larger at the left, the light spreads from it toward the right, and the name
/// and a subtitle (`HouseWorker.subtitle`) sit beside it, the badge at the trailing edge. A row turning
/// compact or wide animates the lean, so the worker, its light, its brows and the plaque travel
/// together while the name under the worker and the text beside it cross-fade. A row is given its
/// width (`rowWidth`), which the room follows frame by frame with the lean.
///
/// The selected worker has left for the conversation, so its room is empty: no body, no badge, a
/// lit door at the bottom in the status colour, the plaque "In chat with you" (`HouseAwayPlaque`)
/// hanging where the worker stood, and a white ring on its edge. In a tilted room the worker steps
/// out first and the plaque drops in after it (`RoomPassage`); coming back, it steps in once the plaque
/// has faded. Every room holds its plaque, hidden
/// while the worker is in, so that selecting it only shows the plaque. On the floor plan the room is
/// a button that calls `select`; as a row, with no `select`, the list selects it.
///
/// `camera` is how the room is seen: from above, or tilted into it, where the brows follow the
/// body's face through the room's camera and the plaque hangs in the room where the worker stood, and
/// the body moves a little in step with the brows (`RoomBodyLink`).
struct HouseRoomCell: View {
    let worker    : HouseWorker
    let isSelected: Bool
    var camera    = RoomCamera.top
    var isBeside  = false
    var rowWidth  : CGFloat?
    var select    : (() -> Void)?

    var body: some View {
        if let select {
            Button(action: select) { room }
                .buttonStyle(.plain)
                .modifier(Spoken(
                    label     : Self.spokenLabel(
                        for       : worker,
                        isSelected: isSelected
                    ),
                    worker    : worker,
                    isSelected: isSelected
                ))
        } else {
            room
                .accessibilityElement(children: .ignore)
                .modifier(Spoken(
                    label     : Self.spokenRowLabel(
                        for       : worker,
                        isSelected: isSelected
                    ),
                    worker    : worker,
                    isSelected: isSelected
                ))
        }
    }

    /// What VoiceOver says for `worker`'s room: its name and its subtitle, or that it is in chat.
    static func spokenLabel(
        for worker: HouseWorker,
        isSelected: Bool
    ) -> String {
        isSelected ? "\(worker.name), \(HouseAwayPlaque.text.lowercased())" : "\(worker.name), \(worker.subtitle)"
    }

    /// What VoiceOver says for `worker`'s row: its name and subtitle, and that it is in chat.
    static func spokenRowLabel(
        for worker: HouseWorker,
        isSelected: Bool
    ) -> String {
        let row = "\(worker.name), \(worker.subtitle)"
        return isSelected ? "\(row), \(HouseAwayPlaque.text.lowercased())" : row
    }

    /// How long the plaque waits before it drops in: in a tilted room, until the worker has stepped
    /// out (`RoomPassage`); from above, not at all.
    static func plaqueDelay(for camera: RoomCamera) -> TimeInterval {
        camera == .tilted ? RestylingTiming.roomExit : 0
    }

    /// The seed that makes `worker`'s brows live by its status in its room, or nil while it is away
    /// in the conversation and the room is empty.
    static func behaviourSeed(
        of worker : HouseWorker,
        isSelected: Bool
    ) -> UInt64? {
        isSelected ? nil : WorkerBehaviour.seed(for: worker.id)
    }

    private var room: some View {
        Stage(
            worker    : worker,
            isSelected: isSelected,
            camera    : camera,
            lean      : isBeside ? 1 : 0,
            width     : rowWidth.map(Double.init)
        )
        .contentShape(Rectangle())
    }

    /// Stage lays the room out for its composition's `lean`, which SwiftUI animates: the room's light,
    /// the brows over the body and the plaque all follow the worker's place as it moves, and the lean
    /// cross-fades the name under the worker with the text beside it.
    ///
    /// SwiftUI lays a reshaping row out once, at its final width, and only moves the frames in
    /// between, while the worker's place depends on the width and the lean together. So a row's stage
    /// animates its `width` with the lean and places every part of the room from the two at each
    /// frame, with no animation of their own, from the leading edge. On the floor plan, with no width,
    /// the room fills the stage and its centred parts move with their frames, as before.
    private struct Stage: View, Animatable {
        let worker    : HouseWorker
        let isSelected: Bool
        let camera    : RoomCamera
        var lean      : Double
        var width     : Double?

        /// Joins the room's renderer to the brows over the body.
        @State private var bodyLink = RoomBodyLink()

        /// Makes the brows follow the pointer while it is in the room.
        @State private var gaze = WorkerGaze()

        var animatableData: AnimatablePair<Double, Double> {
            get {
                AnimatablePair(
                    lean,
                    width ?? 0
                )
            }
            set {
                lean = newValue.first
                if width != nil { width = newValue.second }
            }
        }

        /// The room's trailing margin beside the name.
        private static let trailingMargin: CGFloat = 12

        /// The lean by which the name under the worker has faded out, and the one from which the text
        /// beside it fades in, so the two never overlap.
        private static let underFadesBy : Double = 0.4
        private static let besideFadesIn: Double = 0.4

        var body: some View {
            GeometryReader { proxy in
                let size  = CGSize(
                    width : width.map { CGFloat($0) } ?? proxy.size.width,
                    height: proxy.size.height
                )
                let shape = RoomLightUniforms.Shape(
                    size: size,
                    lean: Float(lean)
                )
                let bodyX = RoomLightUniforms.Shape.bodyX(
                    in  : size,
                    lean: Float(lean)
                )
                ZStack {
                    RoomLight(
                        uniforms: RoomLightUniforms(
                            status     : worker.status,
                            shape      : worker.shape,
                            hasOccupant: !isSelected,
                            camera     : camera,
                            lean       : Float(lean)
                        ),
                        bodyLink: bodyLink
                    )
                    .allowsHitTesting(false)

                    GazeTracker(
                        gaze     : gaze,
                        isEnabled: !isSelected
                    )
                    .allowsHitTesting(false)

                    // A tilted room keeps the brows while its worker is away, so they can step out with the body.
                    if !isSelected || camera == .tilted {
                        // The room draws the body where its composition stands it, a share of its short side across.
                        MascotFace(
                            shape           : worker.shape,
                            status          : worker.status,
                            brows           : BrowState(worker.status),
                            size            : CGFloat(2 * shape.sphereRadius),
                            drawsBody       : false,
                            catchesRoomLight: true,
                            projectedFace   : camera.face(
                                of  : worker.shape,
                                in  : size,
                                lean: Float(lean)
                            ),
                            behaviourSeed   : HouseRoomCell.behaviourSeed(
                                of        : worker,
                                isSelected: isSelected
                            ),
                            bodyLink        : bodyLink,
                            isAway          : isSelected,
                            gaze            : gaze
                        )
                        .offset(x: camera == .top ? bodyX - size.width / 2 : 0)
                    }

                    HouseAwayPlaque(
                        brows    : BrowState(worker.status),
                        status   : worker.status,
                        isHanging: isSelected,
                        camera   : camera,
                        lean     : Float(lean),
                        dropDelay: HouseRoomCell.plaqueDelay(for: camera)
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                    if lean > Self.besideFadesIn {
                        beside(leading: bodyX + CGFloat(shape.sphereRadius) + HouseLayout.nameGap)
                            .opacity((lean - Self.besideFadesIn) / (1 - Self.besideFadesIn))
                    }
                    if lean < Self.underFadesBy {
                        Group {
                            label
                            badge
                        }
                        .opacity(1 - lean / Self.underFadesBy)
                    }
                    door(
                        roomSize: size,
                        bodyX   : bodyX
                    )
                    ring(roomSize: size)
                }
                .frame(
                    width : size.width,
                    height: size.height
                )
                .transaction { transaction in
                    if width != nil { transaction.animation = nil }
                }
            }
        }

        /// The name under the worker, on the floor plan and in the compact rows.
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

        /// The name and subtitle beside the worker from `leading` points in, centred down the row as a
        /// pair, and the badge at the trailing edge.
        private func beside(leading: CGFloat) -> some View {
            HStack(spacing: 8) {
                VStack(
                    alignment: .leading,
                    spacing  : 2
                ) {
                    Text(worker.name)
                        .font(.system(
                            .headline,
                            weight: .semibold
                        ))
                        .foregroundStyle(.primary)
                    Text(worker.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
                .lineLimit(1)
                .frame(
                    maxWidth : .infinity,
                    alignment: .leading
                )
                if !isSelected, let badge = worker.badge {
                    HouseBadgeView(
                        badge : badge,
                        height: 17
                    )
                }
            }
            .padding(
                .leading,
                leading
            )
            .padding(
                .trailing,
                Self.trailingMargin
            )
            .frame(
                maxWidth : .infinity,
                maxHeight: .infinity
            )
            .accessibilityHidden(true)
        }

        /// The lit door of an empty room, at the bottom under the worker's place, 26% of that place's
        /// width: the room's whole width at the centre.
        @ViewBuilder
        private func door(
            roomSize: CGSize,
            bodyX   : CGFloat
        ) -> some View {
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
                    width : 0.26 * 2 * min(bodyX, roomSize.width - bodyX),
                    height: 4
                )
                .offset(x: bodyX - roomSize.width / 2)
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

        /// The badge in the top trailing corner, on the floor plan and in the compact rows.
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
    }

    /// Spoken gives a room its VoiceOver label, its badge as the value, and the selected trait.
    private struct Spoken: ViewModifier {
        let label     : String
        let worker    : HouseWorker
        let isSelected: Bool

        func body(content: Content) -> some View {
            content
                .accessibilityLabel(label)
                .accessibilityValue(isSelected ? "" : worker.badge.map(HouseBadgeView.spokenText(for:)) ?? "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    /// RoomLight hosts the room set into the column (`RoomOpeningView`), lit on the system's default
    /// GPU, and joins it to the brows through `bodyLink`. Without a GPU the room stays empty.
    private struct RoomLight: NSViewRepresentable {
        let uniforms: RoomLightUniforms
        let bodyLink: RoomBodyLink

        private static let device = MTLCreateSystemDefaultDevice()

        func makeNSView(context: Context) -> NSView {
            guard let device = Self.device else { return NSView() }
            let opening = RoomOpeningView(
                device  : device,
                uniforms: uniforms
            )
            bodyLink.room = opening.room
            return opening
        }

        func updateNSView(
            _ view : NSView,
            context: Context
        ) {
            guard let opening = view as? RoomOpeningView else { return }
            opening.uniforms = uniforms
            bodyLink.room    = opening.room
        }
    }
}
