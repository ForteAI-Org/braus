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
/// Its root keeps one identity whichever worker it shows. Each conversation takes its worker's
/// identity, so its messages, draft and scroll position start afresh, but beneath that root: when
/// the root of a split view's column changes identity, SwiftUI rebuilds the column's toolbar items,
/// and at times adds the new ones before it removes the old, which lays them out for a few frames
/// in the middle of the toolbar.
///
/// A change of worker plays `HouseSwitch`. The conversation it leaves stays, under the new one, for
/// `HouseSwitch.crossFade`, told that it leaves; it is not removed with a transition, since SwiftUI
/// stops updating a view's body once it is being removed and the conversation's parts leave on
/// beats of their own. A worker chosen again while that conversation leaves takes the place at once.
struct HouseDetail: View {
    let worker           : MockWorker?
    let isComposerFocused: FocusState<Bool>.Binding

    /// The worker shown before the change of worker in progress, or the shown one once it settles.
    @State private var settled: MockWorker?

    var body: some View {
        ZStack {
            ForEach(
                shown,
                id: \.id
            ) { shown in
                HouseConversationView(
                    worker           : shown,
                    isComposerFocused: isComposerFocused
                )
                .environment(
                    \.houseSwitchLeaving,
                    shown.id != worker?.id
                )
            }
            if worker == nil {
                ContentUnavailableView(
                    "Choose a Room",
                    systemImage: "house",
                    description: Text("Pick a room to talk with its worker.")
                )
            }
        }
        .task(id: worker?.id) {
            try? await Task.sleep(for: .seconds(HouseSwitch.crossFade))
            guard !Task.isCancelled else { return }

            settled = worker
        }
    }

    /// The conversations in the column: the leaving one under the chosen one.
    private var shown: [MockWorker] {
        let leaving = settled.flatMap { $0.id == worker?.id ? nil : $0 }
        return [leaving, worker].compactMap { $0 }
    }
}
