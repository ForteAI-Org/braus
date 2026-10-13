//
//  ConversationEnlargedScreen.swift
//  Mecum
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
        let host = EnlargedScreenHostView(
            screen        : team.makeScreenView(
                of           : worker.id,
                contentsScale: NSScreen.main?.backingScaleFactor ?? 2
            ) ?? NSView(),
            nativeSize    : team.screenFrame(of: worker.id).size,
            opener        : team.screenView(in: enlargement.origin),
            reducesMotion : reducesMotion,
            label         : "\(worker.name)’s screen",
            onRequestClose: { [team] in team.closeEnlargedScreen() }
        )
        return host
    }

    func updateNSView(
        _ host : EnlargedScreenHostView,
        context: Context
    ) {
        host.nativeSize    = team.screenFrame(of: worker.id).size
        host.reducesMotion = reducesMotion
        guard enlargement.isClosing else { return }

        let place = enlargement.destination(showsInConversation: team.showsScreenInConversation)
        host.close(into: team.screenView(in: place)) { [team] in team.dismissEnlargedScreen() }
    }
}
