//
//  ScreenWorkerPresence.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import SeatBroker
import SwiftUI

/// ScreenWorkerPresence fills the panel on a worker's screen window's top-right corner
/// (`WorkerScreenWindowController`): the worker as the house shows it now, and what it says
/// (`ScreenPresenceView`), as its latest turn reports it (`WorkerSpeech`). While the person has its
/// application, the bubble says how their control stands, refusals included, as the control bar's
/// line said before. Once the application is on its way to the person, the worker dives away and
/// pops out on their screen instead, until control ends.
struct ScreenWorkerPresence: View {
    let team  : TeamModel
    let worker: HouseWorker

    /// What the worker says in place of what the team reports; the window check passes a state.
    var makeSpeech: (() -> WorkerSpeech?)?

    /// Opens the worker's conversation in Braus, from the bubble while it says something.
    let open: () -> Void

    var body: some View {
        Presence(
            worker: HouseRoster.workers(of: team).first { $0.id == worker.id } ?? worker,
            speech: speech,
            isAway: isAway,
            open  : open
        )
        .frame(
            width : ScreenPresenceView.size.width,
            height: ScreenPresenceView.size.height
        )
    }

    /// From Take Control until it ends, unless the lend was refused or blocked, and through the
    /// hand-back after Yes: the worker is with the person until its window has it again.
    private var isAway: Bool {
        if team.handingBack.contains(worker.id) { return true }
        guard let lending = team.humanControls[worker.id], lending.hasStarted else { return false }

        return !lending.isFinishing
            && !lending.isFinished
            && !lending.lendingRefused
            && !lending.isBlocked
    }

    private var speech: WorkerSpeech? {
        if let makeSpeech { return makeSpeech() }
        if let lending = team.humanControls[worker.id], ScreenHoverControls.isUnderway(lending) {
            return .saying(lending.status)
        }
        return WorkerSpeech(
            report     : team.turnReports[worker.id],
            isAnswering: team.isAnswering(worker.id)
        )
    }

    /// Presence hosts the worker's AppKit view.
    private struct Presence: NSViewRepresentable {
        let worker: HouseWorker
        let speech: WorkerSpeech?
        let isAway: Bool
        let open  : () -> Void

        func makeNSView(context: Context) -> ScreenPresenceView {
            ScreenPresenceView(worker: worker)
        }

        func updateNSView(
            _ view : ScreenPresenceView,
            context: Context
        ) {
            view.onOpen = open
            view.show(
                worker: worker,
                speech: speech
            )
            if isAway { view.diveAway() } else { view.comeBack() }
        }
    }
}
