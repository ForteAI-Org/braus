//
//  RunningTurn.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation

/// RunningTurn is how far the newest turn has got while it runs, as the transcript's rows show it:
/// the step its tools are on, in its tool line's words (`TranscriptWording.toolSteps`), and whether
/// its answer has arrived.
///
/// The thinking bubble marks a running turn (`ConversationProjection`): with none, no turn runs, or
/// the window stops short of the newest message. A step that failed or a note is never the step.
nonisolated struct RunningTurn: Sendable, Equatable {

    /// The latest step of the turn's tools, "Opening Pro Tools…" while it runs and "Opened Pro Tools"
    /// once done; nil before the first.
    let step: String?

    /// Whether a reply block of the turn has arrived.
    let hasReplied: Bool

    /// The turn running in `items`, nil when none runs.
    init?(_ items: [TranscriptItem]) {
        guard case .thinking(_, let replies) = items.last(where: { $0.kind == .thinking })?.id else { return nil }

        let line = items.last { item in
            if case .toolRun(_, _, nil) = item.kind { true } else { false }
        }
        if case .toolRun(let lines, _, _) = line?.kind {
            let steps = ToolStep.steps(from: lines).filter { step in
                if case .failed = step.state { false } else { true }
            }
            step = TranscriptWording.toolSteps(
                steps,
                ending: nil
            ).last
        } else {
            step = nil
        }
        hasReplied = replies > 0
    }
}
