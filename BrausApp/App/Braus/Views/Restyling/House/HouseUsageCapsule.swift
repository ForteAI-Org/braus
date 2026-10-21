//
//  HouseUsageCapsule.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import ModelTransports
import SwiftUI

/// HouseUsageCapsule is the house toolbar's usage item, as `ToolbarUsageCapsule` is the team
/// window's: the app's context ring (`ConversationContextButton`) while the context's window is
/// known, then its token counter (`TokenCounterButton`), on `MockTeam`'s values.
///
/// A context the worker's last turn left at 90% or more is compacted on its own a moment after
/// the worker is shown, standing in for the end of the turn that would trigger it in the app.
struct HouseUsageCapsule: View {
    let worker: HouseWorker

    @Bindable var team: MockTeam

    /// How long a full context shows before it is compacted on its own.
    static let fullContextShows = Duration.seconds(2)

    var body: some View {
        let usage = team.usage(of: worker)

        HStack(spacing: 0) {
            if let context = UsageWording.ringContext(of: usage) {
                ConversationContextButton(
                    context        : context,
                    worker         : worker.name,
                    isCompacting   : team.isCompacting(worker),
                    waitReason     : team.isAnswering(worker)
                        ? UsageWording.actionsWait(
                            worker      : worker.name,
                            isCompacting: team.isCompacting(worker)
                        )
                        : nil,
                    compact        : { team.compact(worker) },
                    startFresh     : { team.startFresh(worker) },
                    isShowingDetail: $team.showsContext
                )
            }

            TokenCounterButton(
                workerName     : worker.name,
                provider       : team.selection(of: worker).provider,
                usage          : usage,
                isShowingDetail: $team.showsUsage
            )
        }
        .task(id: worker.id) {
            do { try await Task.sleep(for: Self.fullContextShows) } catch { return }
            team.compactIfFull(worker)
        }
    }
}
