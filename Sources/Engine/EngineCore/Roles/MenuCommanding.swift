//
//  MenuCommanding.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import Foundation
import PerceptionCore

/// MenuCommanding carries out one item of the application's menu bar by its path, as the menu tool
/// does, for a control whose command the engine sends through the menu instead of a click: a text
/// format toggle (`ActVerification.formatMenuPath`).
public protocol MenuCommanding: Sendable {

    /// Presses the item `path` names ("Format > Font > Bold") in the menu bar of `processID` and
    /// answers that command's own outcome, its scene read through `observe` after the press. Nil
    /// when nothing was dispatched: no such item, or one that is disabled or refused.
    func performMenuItem(
        _ path      : String,
        in processID: pid_t,
        observe     : @Sendable () async throws -> SceneSnapshot
    ) async -> ActOutcome?
}
