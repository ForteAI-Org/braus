//
//  ActionSettle.swift
//  Braus
//
//  Created by Codex on 01/11/2026.
//

import EngineCore
import Foundation

/// Waits for action effects and records how each wait ended.
extension ActionEngine {

    /// Waits for a gesture's effect before it is judged: the settling role's wait, capped at the click
    /// settle, when the composition gave one, and otherwise the click settle itself.
    func settle(_ processID: pid_t) async {
        guard let settling = dependencies.settling else { return await pause(timing.clickSettle) }
        Self.settleTrail?.note(await settling.settle(in: processID, cap: timing.clickSettle))
    }

    /// How the waits of the action performed in this task ended, the last one kept: what was read after it judges.
    final class SettleTrail: @unchecked Sendable {
        private let lock = NSLock()
        private var ended: SettleResult?
        private var fromScene = false

        var last: SettleResult? { lock.withLock { ended } }

        /// Whether the read-back that judged the action came from the scene's element, not from the control.
        var readBackFromScene: Bool { lock.withLock { fromScene } }

        func note(_ result: SettleResult) { lock.withLock { ended = result } }

        func noteReadBackFromScene() { lock.withLock { fromScene = true } }
    }

    /// The trail of the waits of the action being performed in this task, when one is.
    @TaskLocal static var settleTrail: SettleTrail?
}
