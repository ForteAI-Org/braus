//
//  HouseHero.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/10/2026.
//

import SwiftUI

/// HouseHero is the selected worker at the top of its conversation, standing in three quarters as its
/// room shows it (`HouseWorkerPortrait`), just over a small glass capsule that holds its name and its
/// subtitle (what it is doing or needs, or what it does while free or off). The capsule lights the
/// worker: a soft presentation light rises from it onto the worker's front face, warm white taking a
/// share of the status's colour (`HeroLight`), and leaves a faint glow along the capsule's top edge;
/// nothing lights the worker from behind. The kind of work shows on hover of the name, so the window
/// says the name once.
///
/// The conversation gives the moment's `status`, `brows` and `activity`, raises `preparation` when the
/// worker sets about a message, which the worker plays once, and gives the body's `action` through
/// the turn: it leans in to read, sways while it thinks, bobs at its screen while it works and hops
/// when its reply arrives, cross-fading from one to the next.
///
/// A change of worker plays `HouseSwitch`: the worker drops into its capsule and the next one hops out
/// of it. The capsule stays: an arriving hero's capsule starts from the previous worker's words and
/// light (`houseSwitchPrevious`) and writes its own in, and a leaving hero's hides at once beneath it.
/// The hero's frame is the same for every shape and every subtitle, so the transcript under it never
/// moves.
struct HouseHero: View {
    let worker     : HouseWorker
    let status     : WorkerStatus
    let brows      : BrowState
    let activity   : String
    let preparation: Int

    /// What the worker does with its body through a turn, in place of its idle loop; nil outside one.
    var action: WorkerAction?

    /// Where the hero is in a change of worker.
    var stage = HouseSwitch.Stage.present

    /// How far from its face the hero follows the pointer, in points.
    static let gazeRadius: CGFloat = 200

    /// Makes the hero's brows follow the pointer when it comes near.
    @State private var gaze = WorkerGaze(radius: HouseHero.gazeRadius)

    /// The worker whose capsule this hero takes over, read once, when the hero appears.
    @Environment(\.houseSwitchPrevious) private var previous

    /// Whether the capsule's light has moved on from the previous worker's status to this one's.
    @State private var hasTakenOver = false

    /// Whether the worker has hopped out of its capsule and stands in its place, so it may follow the
    /// pointer.
    @State private var hasLanded = false

    /// The side of the worker's sphere, in points.
    static let workerSize: CGFloat = 60

    /// The height the worker stands in: the tallest shape's, so every worker takes the same room.
    static let portraitHeight = WorkerShape.allCases.map { shape in
        HouseWorkerPortrait.silhouette(
            of  : shape,
            side: HouseWorkerPortrait.sceneSide(for: workerSize)
        ).boundingRect.height
    }.max() ?? workerSize

    /// The seed that makes the hero's brows live by `status`, or nil while `brows` is the conversation's
    /// own expression (listening, at work) rather than the status's, which the loop would override.
    static func behaviourSeed(
        of worker: HouseWorker,
        status   : WorkerStatus,
        brows    : BrowState
    ) -> UInt64? {
        brows == BrowState(status) ? WorkerBehaviour.seed(for: worker.id) : nil
    }

    var body: some View {
        VStack(spacing: 4) {
            HouseWorkerPortrait(
                shape       : worker.shape,
                status      : status,
                size        : Self.workerSize,
                brows       : brows,
                seed        : Self.behaviourSeed(
                    of    : worker,
                    status: status,
                    brows : brows
                ),
                gaze        : gaze,
                capsuleLight: HeroLight.capsuleLight(for: status),
                changeFade  : HeroLight.fade,
                preparation : preparation,
                switchStage : stage,
                action      : action,
                takesActions: true
            )
            .background {
                GazeTracker(
                    gaze     : gaze,
                    isEnabled: stage == .present && hasLanded,
                    outset   : Self.gazeRadius
                )
            }
            .frame(
                height   : Self.portraitHeight,
                alignment: .bottom
            )
            .accessibilityHidden(true)
            HouseHeroCaption(
                HouseHeroCaption.Words(
                    name    : worker.name,
                    activity: activity
                ),
                help: role,
                from: previous.map { previous in
                    HouseHeroCaption.Words(
                        name    : previous.name,
                        activity: previous.subtitle
                    )
                }
            )
            .padding(
                .horizontal,
                12
            )
            .padding(
                .vertical,
                4
            )
            .modifier(GlassCapsule(cornerRadius: 40))
            .overlay(alignment: .top) {
                // The light the capsule gives the worker, where it leaves the glass.
                HeroLight(status: hasTakenOver ? status : previous?.status ?? status)
                    .frame(height: 10)
                    .padding(
                        .horizontal,
                        14
                    )
                    .offset(y: -4)
                    .allowsHitTesting(false)
            }
            // The arriving hero's capsule stands in the same place, so the leaving one goes at once.
            .opacity(stage == .leaving ? 0 : 1)
            .animation(
                nil,
                value: stage
            )
        }
        .onAppear {
            hasTakenOver = true
            Task {
                try? await Task.sleep(for: .seconds(HouseSwitch.entryDelay + HouseSwitch.hop))
                hasLanded = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(role)
    }

    /// The mock worker's role, after the kind of app it drives.
    private var role: String {
        switch worker.category {
        case .audio  : "Audio engineer"
        case .video  : "Video editor"
        case .design : "Designer"
        case .web    : "Web researcher"
        case .files  : "File organizer"
        case .general: "Assistant"
        }
    }
}
