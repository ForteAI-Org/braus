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
/// beats of their own. The arriving conversation learns which worker it follows
/// (`houseSwitchPrevious`), so its capsule takes over from that worker's. Changed again meanwhile,
/// the column lets the worker it was showing leave and drops the one leaving before it.
struct HouseDetail: View {
    let worker           : MockWorker?
    let isComposerFocused: FocusState<Bool>.Binding

    /// The worker the column showed last, which `worker` replaces once its change has been seen.
    @State private var lastShown: MockWorker?

    /// The worker whose conversation is leaving, until `HouseSwitch.crossFade` has passed.
    @State private var departing: MockWorker?

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
                .environment(
                    \.houseSwitchPrevious,
                    shown.id == worker?.id ? leaving : nil
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
        .onAppear { lastShown = worker }
        .onChange(of: worker?.id) {
            departing = leaving
            lastShown = worker
        }
        .task(id: worker?.id) {
            try? await Task.sleep(for: .seconds(HouseSwitch.crossFade))
            guard !Task.isCancelled else { return }

            departing = nil
        }
    }

    /// The worker whose conversation leaves: the one shown last, from the frame that changes worker,
    /// before `onChange` has seen it.
    private var leaving: MockWorker? {
        let leaving = lastShown?.id != worker?.id ? lastShown : departing
        return leaving?.id == worker?.id ? nil : leaving
    }

    /// The conversations in the column: the leaving one under the chosen one.
    private var shown: [MockWorker] {
        [leaving, worker].compactMap { $0 }
    }
}
