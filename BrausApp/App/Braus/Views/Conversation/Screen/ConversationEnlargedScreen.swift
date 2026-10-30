//
//  ConversationEnlargedScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import SwiftUI

/// ConversationEnlargedScreen hosts the worker's screen enlarged over the
/// team window's content, while `TeamModel.enlargedScreen` names this worker.
///
/// The overlay is an AppKit view (`EnlargedScreenHostView`) so its grow and
/// shrink run in Core Animation. SwiftUI only decides when it exists: a request
/// to close reaches it through `updateNSView`, and the model drops the state
/// when the shrink has landed. It is removed at once, with no animation, when
/// the worker or its window goes away.
struct ConversationEnlargedScreen: NSViewRepresentable {

    let team       : TeamModel
    let worker     : WorkerSnapshot
    let enlargement: ScreenEnlargement

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    func makeNSView(context: Context) -> EnlargedScreenHostView {
        Self.makeHost(team: team, workerID: worker.id, origin: enlargement.origin,
                      reducesMotion: reducesMotion, label: "\(worker.name)’s screen")
    }

    static func makeHost(team: TeamModel, workerID: UUID, origin: ScreenPlace,
                         reducesMotion: Bool, label: String) -> EnlargedScreenHostView {
        let screen = NSHostingView(rootView: LiveScreenView(team: team, workerID: workerID))
        screen.sizingOptions = []
        let host = EnlargedScreenHostView(
            screen        : screen,
            nativeSize    : team.screenFrame(of: workerID).size,
            opener        : team.screenView(in: origin),
            reducesMotion : reducesMotion,
            label         : label,
            onRequestClose: { [team] in team.closeEnlargedScreen() }
        )
        screen.rootView = LiveScreenView(team: team, workerID: workerID,
                                        onPictureSize: { [weak host] in host?.nativeSize = $0 })
        return host
    }

    func updateNSView(
        _ host : EnlargedScreenHostView,
        context: Context
    ) {
        host.reducesMotion = reducesMotion
        guard enlargement.isClosing else { return }

        let place = enlargement.destination(showsInConversation: team.showsScreenInConversation)
        host.close(into: team.screenView(in: place)) { [team] in team.dismissEnlargedScreen() }
    }
}
