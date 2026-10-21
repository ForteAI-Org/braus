//
//  HouseDetail.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import SwiftUI

/// HouseDetail is the house window's detail column: the conversation with `worker`, or the empty
/// state while no worker is chosen.
///
/// Its root keeps one identity whichever worker it shows. The conversation takes its worker's
/// identity, so its messages, draft and scroll position start afresh, but beneath that root: when
/// the root of a split view's column changes identity, SwiftUI rebuilds the column's toolbar items,
/// and at times adds the new ones before it removes the old, which lays them out for a few frames
/// in the middle of the toolbar.
struct HouseDetail: View {
    let worker           : MockWorker?
    let isComposerFocused: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            if let worker {
                HouseConversationView(
                    worker           : worker,
                    isComposerFocused: isComposerFocused
                )
                .id(worker.id)
            } else {
                ContentUnavailableView(
                    "Choose a Room",
                    systemImage: "house",
                    description: Text("Pick a room to talk with its worker.")
                )
            }
        }
    }
}
