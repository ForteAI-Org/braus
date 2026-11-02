//
//  ScreenStage.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit
import SwiftUI

/// ScreenStage puts the worker's held window on a `ScreenStageView` in its screen window: the live
/// view of the seat's stream, which the window fits one point to one point.
///
/// The caller mounts it only while `TeamModel.hasScreen` holds, as `WorkerScreenView` is mounted.
struct ScreenStage: NSViewRepresentable {

    /// Makes one view of the held window at a backing scale; nil when there is none to watch.
    typealias Picture = @MainActor (_ contentsScale: CGFloat) -> NSView?

    @Environment(\.displayScale) private var displayScale

    let team    : TeamModel
    let workerID: UUID

    /// What draws the window in place of the team's live view; the window check passes a still.
    var makePicture: Picture?

    /// Told the held window's size, once known and as it changes.
    var onPictureSize: (CGSize) -> Void = { _ in }

    func makeNSView(context: Context) -> ScreenStageView {
        let make = makePicture ?? { [team, workerID] scale in
            team.makeMainWindowView(
                of           : workerID,
                contentsScale: scale
            )
        }
        // The window is the picture's size, so no blurred backdrop shows around it.
        let stage = ScreenStageView(
            picture : make(displayScale) ?? NSView(),
            backdrop: nil
        )
        if stage.pictureSize == .zero {
            stage.pictureSize = team.mainWindow(of: workerID)?.frame.size ?? team.screenFrame(of: workerID).size
        }
        // The sharp picture is the screen's view in its own window, as `LiveScreenView`'s was.
        stage.onPictureSize = onPictureSize
        stage.movesWindow   = { [team, workerID] in
            !ScreenHoverControls.isUnderway(team.humanControls[workerID])
        }
        team.registerScreenView(
            stage.picture,
            in: .window
        )
        return stage
    }

    func updateNSView(
        _ stage: ScreenStageView,
        context: Context
    ) {
        stage.onPictureSize = onPictureSize
    }
}
