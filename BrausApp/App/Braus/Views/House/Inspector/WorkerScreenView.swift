//
//  WorkerScreenView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import SeatBroker
import SwiftUI

/// WorkerScreenView hosts the live view of the window a worker drives: the
/// seat's frames arrive straight into its layer, with no copy through SwiftUI.
///
/// The caller mounts it only while `TeamModel.hasScreen` holds and gives it the
/// worker's id as its identity, so another worker, or the same seat given to
/// another worker, always gets a view of its own.
///
/// A view made for a `place` is the small one the team model keeps for the
/// enlarged screen to grow from and shrink into. While `isPaused` the stream
/// draws nothing into it and it keeps its last frame.
struct WorkerScreenView: NSViewRepresentable {

    let team    : TeamModel
    let workerID: UUID
    let place   : ScreenPlace
    let isPaused: Bool

    /// Told the shape of the picture the view draws, which can differ from the view's own.
    var onPictureAspect: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = team.makeScreenView(
            of           : workerID,
            contentsScale: NSScreen.main?.backingScaleFactor ?? 2
        ) ?? NSView()
        (view as? LivePreviewView)?.onPictureAspect = onPictureAspect
        team.registerScreenView(
            view,
            in: place
        )
        return view
    }

    func updateNSView(
        _ view : NSView,
        context: Context
    ) {
        (view as? LivePreviewView)?.isPaused = isPaused
    }
}
