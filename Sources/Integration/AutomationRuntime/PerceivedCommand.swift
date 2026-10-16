//
//  PerceivedCommand.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// PerceivedCommand gives a native command with no engine cycle of its own (a menu bar command, a
/// dialog's button pressed by its title) the perceptions every other operation records: the window as it
/// was before the command and as it is after, as the call's own `before` and `after` samples, through the
/// call's recorder. The command's check compares the application's windows
/// (`MenuBarCommand.windowSignature`), which is no scene and is never taken for one; when they did not
/// change, the two perceptions judge the command on its own window (`checkedInWindow`). The samples are
/// what the Brain's relations read the command's states from. A command that reached no gesture (a refusal, a
/// miss, a listing) records nothing; a perception that failed leaves its sample out, and the relation
/// the call teaches says why. The command stays one operation: nothing is recorded for its inner steps.
///
/// A command asks for the window after it (`observe`) only once its gesture was dispatched, as
/// `MenuBarCommand` and `DialogButtonPress` do. So a command that throws after asking for it (its
/// perception failed, the call was cancelled, anything else after the gesture) still leaves the call the
/// samples already perceived, the window before it and, when it was perceived, the window after it, and
/// the error goes on to the caller, which ends the call with it. A command that throws before asking for
/// it reached no gesture that this can know of, and records nothing. No sample is ever made up.
///
/// A cancellation is no failed perception. A call cancelled before the command, already, while the window
/// before it is perceived, or as that perception ends, never starts the command: the cancellation goes to
/// the caller, which ends the call cancelled, and nothing is recorded. A perception before it that fails
/// for any other reason only leaves its sample out, and the command goes on, as it always did.
public enum PerceivedCommand {

    /// Performs `command`, perceiving the window before it and handing it the perception after it as its
    /// observation, then records both for the call and returns the outcome with its scene enriched in the
    /// state the window after it is in.
    public static func perform(
        bundleID: String,
        recorder: CallRecorder?,
        perceive: @escaping () async throws -> PerceivedWindow,
        command : (_ observe: () async throws -> SceneSnapshot) async throws -> ActOutcome
    ) async throws -> ActOutcome {
        try Task.checkCancellation()
        let before: PerceivedWindow?
        do {
            before = try await perceive()
        } catch let error as CancellationError {
            throw error
        } catch {
            before = nil
        }
        // The last moment before any gesture: a cancellation that arrived while the window was perceived,
        // whatever the perception answered, ends the call here.
        try Task.checkCancellation()
        var after: PerceivedWindow?
        var dispatched = false
        let outcome: ActOutcome
        do {
            outcome = try await command {
                dispatched = true
                let window = try await perceive()
                after = window
                return window.scene
            }
        } catch {
            if dispatched, let recorder { await recorder.record(before: before, menu: nil, after: after, bundleID: bundleID) }
            throw error
        }
        guard outcome.check != nil else { return outcome }
        // A census change can invalidate a completed perception; it is not evidence for this command.
        if outcome.check?.limits.contains(.noAfterScene) == true { after = nil }
        let checked = checkedInWindow(outcome, before: before, after: after)
        guard let recorder else { return checked }
        await recorder.record(before: before, menu: nil, after: after, bundleID: bundleID)
        guard let scene = checked.scene else { return checked }
        return checked.with(scene: await recorder.enrich(scene))
    }

    /// A command whose windows did not change, judged again on its own window. The application's windows
    /// miss what happens inside one: a sheet attached to it, a dialog an application draws in its window
    /// (PhotoCraft's Image Size and save prompt), a panel that slides in. On PhotoCraft 21 of 28 menu
    /// commands stayed unknown that way (14 October 2026), so no procedure that opened a file or saved a
    /// copy could ever be admitted. When the gesture went out as requested and both perceptions exist, the
    /// difference of the two scenes decides: an attributable change is a structural effect, passed, said as
    /// found anywhere in the window and with no expectation; no change leaves the window check unknown as
    /// it was, since a command may act where no scene shows it (a document's pixels). So does a capture
    /// that was not read in full (M2).
    static func checkedInWindow(_ outcome: ActOutcome, before: PerceivedWindow?, after: PerceivedWindow?) -> ActOutcome {
        guard let check = outcome.check, check.condition == .windowSetChanged, check.verdict == .unknown,
              check.performed == .requested, !check.limits.contains(.deliveryUncertain),
              let before, let after,
              // A capture that says it is not whole compares to nothing (M2): the window check stays unknown.
              ActVerification.comparable(before: before.capture, after: after.capture),
              let effect = SceneDifference.effect(before: before.scene, after: after.scene, targetID: nil)
        else { return outcome }
        let inWindow = OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .passed,
                                      expected: "a change in the window", observed: effect.family,
                                      limits: [.windowWide, .noExpectation], performed: .requested)
        let pressed = outcome.message.components(separatedBy: MenuBarCommand.unchangedWindows).first ?? outcome.message
        return ActOutcome(.foundActed, "\(pressed): no window opened or closed, the window changed in place (\(effect.summary))",
                          scene: outcome.scene, check: inWindow)
    }
}
