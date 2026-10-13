//
//  PerceivedCommand.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import PerceptionCore

/// PerceivedCommand gives a native command with no engine cycle of its own (a menu bar command, a
/// dialog's button pressed by its title) the perceptions every other operation records: the window as it
/// was before the command and as it is after, as the call's own `before` and `after` samples, through the
/// call's recorder. The command's check is unchanged: it compares the application's windows
/// (`MenuBarCommand.windowSignature`), which is no scene and is never taken for one; the samples are what
/// the Brain's relations read the command's states from. A command that reached no gesture (a refusal, a
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
        guard let recorder else { return outcome }
        await recorder.record(before: before, menu: nil, after: after, bundleID: bundleID)
        guard let scene = outcome.scene else { return outcome }
        return outcome.with(scene: await recorder.enrich(scene))
    }
}
