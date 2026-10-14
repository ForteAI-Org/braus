//
//  MenuItemCommands.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// MenuItemCommands is `MenuCommanding` over a session's own menu command, the one its menu tool
/// runs, so a format toggle's menu item is pressed the way that application's menus are pressed
/// (in front for an application whose menus go stale in the background).
public struct MenuItemCommands: MenuCommanding {

    /// The session's menu command: the path, the application, and the observation after its press.
    public typealias Command = @MainActor @Sendable (
        _ path     : String,
        _ processID: pid_t,
        _ observe  : () async throws -> SceneSnapshot
    ) async throws -> ActOutcome

    private let command       : Command
    private let broughtForward: String?

    /// `inFront` names the application when the session presses its menus with it brought forward
    /// for a moment, which a clean press then says; nil when they are pressed in the background.
    public init(_ command: @escaping Command, inFront application: String? = nil) {
        self.command        = command
        self.broughtForward = application
    }

    public func performMenuItem(
        _ path      : String,
        in processID: pid_t,
        observe     : @Sendable () async throws -> SceneSnapshot
    ) async -> ActOutcome? {
        do {
            guard let outcome = Self.dispatched(try await command(path, processID, observe)) else { return nil }
            // Only a clean press says so: a troubled handback already names the moment in front,
            // and a failed press reads uncertain and keeps its own answer.
            guard let broughtForward, outcome.check?.performed == .requested else { return outcome }
            return outcome.with(message: outcome.message
                + " \(broughtForward) was brought forward for a moment to press the menu item.")
        } catch {
            // The press may have gone out before the error, so the click is not sent after it.
            return ActOutcome(.actedUnverified, "\(path) failed: \(error). Observe before more input.",
                              check: .unchecked(performed: .uncertain, limits: [.deliveryUncertain]))
        }
    }

    /// The menu command's outcome, or nil when it reached no press: a miss, a refusal (a disabled
    /// item included) or a listing, which carry no check. One that may have acted always answers.
    static func dispatched(_ outcome: ActOutcome) -> ActOutcome? {
        let notSent: [ActOutcomeKind] = [.honestMiss, .refused, .ambiguous, .actedNoop]
        return outcome.check == nil && notSent.contains(outcome.kind) ? nil : outcome
    }
}
