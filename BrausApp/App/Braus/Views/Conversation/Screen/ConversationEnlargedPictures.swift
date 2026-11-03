//
//  ConversationEnlargedPictures.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 03/11/2026.
//

import SwiftUI

/// ConversationEnlargedPictures hosts a tool line's pictures enlarged over the team window's content,
/// while `TeamModel.enlargedPictures` holds them.
///
/// It is placed by SwiftUI, as the worker's enlarged screen is (`ConversationEnlargedScreen`): a view
/// added to the window's hosting view by hand is not drawn, yet takes every click.
struct ConversationEnlargedPictures: NSViewRepresentable {

    let team       : TeamModel
    let enlargement: PicturesEnlargement

    @Environment(\.accessibilityReduceMotion)
    private var reducesMotion

    func makeNSView(context: Context) -> EnlargedScreenHostView {
        let screen = ToolPicturesScreenView(
            enlargement.images,
            pixelSizes: enlargement.sizes
        )
        return EnlargedScreenHostView(
            screen        : screen,
            nativeSize    : screen.nativeSize,
            opener        : enlargement.opener,
            reducesMotion : reducesMotion,
            label         : enlargement.label,
            copiesFrames  : false,
            onRequestClose: { [team] in team.closeEnlargedPictures() }
        )
    }

    func updateNSView(
        _ host : EnlargedScreenHostView,
        context: Context
    ) {
        host.reducesMotion = reducesMotion
        guard enlargement.isClosing else { return }

        host.close(into: enlargement.opener) { [team] in team.dismissEnlargedPictures() }
    }
}
