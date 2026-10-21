//
//  ToolbarUsageCapsule.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 13/10/2026.
//

import ModelTransports
import SwiftUI

/// ToolbarUsageCapsule is the toolbar's usage item: the context ring while the
/// conversation is open and the context's window is known, then the token counter.
///
/// It is a view of its own so the conversation and the turn state it reads are
/// tracked here and not by `TeamShellView`: a draft saved while typing changes
/// the conversation, and on macOS 26 every new evaluation of the shell's body
/// vends the toolbar's items again.
struct ToolbarUsageCapsule: View {

    @Bindable
    var team: TeamModel

    let worker: WorkerSnapshot
    let usage : WorkerUsage

    var body: some View {
        HStack(spacing: 0) {
            if team.conversation != nil,
               let context = UsageWording.ringContext(of: usage) {
                ConversationContextButton(
                    context        : context,
                    worker         : worker.name,
                    isCompacting   : team.isCompacting(worker.id),
                    waitReason     : team.isAnswering(worker.id)
                        ? UsageWording.actionsWait(
                            worker      : worker.name,
                            isCompacting: team.isCompacting(worker.id)
                        )
                        : nil,
                    compact        : { team.compactContext(of: worker.id) },
                    startFresh     : { Task { await team.startFreshContext(of: worker.id) } },
                    isShowingDetail: $team.showsContext
                )
            }

            TokenCounterButton(
                workerName     : worker.name,
                provider       : worker.configuration?.provider,
                usage          : usage,
                isShowingDetail: $team.showsUsage
            )
        }
    }
}
