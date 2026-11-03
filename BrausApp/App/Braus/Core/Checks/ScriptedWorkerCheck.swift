//
//  ScriptedWorkerCheck.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppKit
import AutomationRuntime
import ModelTransports
import SeatBroker
import SwiftUI

/// ScriptedWorkerCheck starts one real conversation with a fixed message when BRAUS_SCRIPTED_CHECK=1
/// in a valid isolated run. BRAUS_SCRIPTED_CHECK_QUIT=1 closes hosts and exits after writing the
/// report; otherwise the real conversation stays open. SIGTERM awaits its hosts, Seat and memory before exit.
@MainActor
enum ScriptedWorkerCheck {

    static var isRequested: Bool {
        guard case .isolated = LaunchIsolation.current else { return false }
        return ProcessInfo.processInfo.environment["BRAUS_SCRIPTED_CHECK"] == "1"
    }

    private static var window: NSWindow?
    private static var termination: (any DispatchSourceSignal)?
    private static var isShuttingDown = false

    private struct ShutdownReport: Encodable {
        let completed : Bool
        let errors    : [String]
        let exitStatus: Int32
    }

    private struct Report: Encodable {
        let passed              : Bool
        let roundsPlayed        : Int
        let errors              : [String]
        let windowID            : Int
        let launchToFirstToolMs  : Double?
    }

    static func run(delegate: SeatReleasingDelegate) async {
        guard case .isolated(let support) = LaunchIsolation.current else { return }
        var outcome = ScriptedWorkerRun.Report()
        var team: TeamModel?
        do {
            guard try ScriptedWorkerRun.scriptURL(
                isolation  : .current,
                environment: ProcessInfo.processInfo.environment
            ) != nil else {
                throw AutomationFailure("BRAUS_SCRIPTED_CHECK needs BRAUS_SCRIPTED_WORKER.")
            }
            let model = AppModel()
            delegate.model = model
            let store = try await WorkspaceStore.openingOffMain(in: support)
            let worker = try await store.createWorker(
                name      : "Scripted Worker",
                role      : "Isolated tool check",
                appearance: WorkerAppearance(
                    seed   : 3,
                    palette: "dusk"
                )
            )
            // A CLI selection proves the override reaches the real loop regardless of provider.
            try await store.configure(
                worker   : worker.id,
                selection: ModelSelection(
                    provider: .codex,
                    model   : "scripted",
                    effort  : .low
                )
            )
            let made = TeamModel(
                store      : store,
                connections: model.settings,
                broker     : model.broker
            )
            team = made
            delegate.teams.add(made)
            await made.load()
            made.selection = worker.id
            await made.openSelectedConversation()
            AppDefaults.current.set(
                true,
                forKey: AppPreferences.chatOpensToolSteps
            )
            show(team: made)
            signal(
                SIGTERM,
                SIG_IGN
            )
            let source = DispatchSource.makeSignalSource(
                signal: SIGTERM,
                queue : .main
            )
            source.setEventHandler {
                Task {
                    await shutdown(
                        team  : made,
                        model : model,
                        status: 0
                    )
                }
            }
            source.resume()
            termination = source

            made.draft = "Run the isolated scripted tool check."
            await made.send()
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while made.isAnswering(worker.id) {
                guard ContinuousClock.now < deadline else {
                    throw AutomationFailure("The scripted turn did not finish within 90 seconds.")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let conversation = made.conversation,
                  let report = made.agentContext(of: conversation.id)?.host.scriptedReport else {
                throw AutomationFailure("The worker did not complete a scripted turn.")
            }
            outcome = report
            if let problem = made.problem { outcome.errors.append(String(describing: problem)) }
        } catch {
            outcome.errors.append(String(describing: error))
        }

        let report = Report(
            passed             : outcome.completed && outcome.errors.isEmpty,
            roundsPlayed       : outcome.roundsPlayed,
            errors             : outcome.errors,
            windowID           : window?.windowNumber ?? 0,
            launchToFirstToolMs : outcome.launchToFirstToolMs
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to     : support.appending(path: "scripted-check.json"),
                options: .atomic
            )
        } catch {
            FileHandle.standardError.write(Data("Scripted check could not write its report: \(error)\n".utf8))
            await shutdown(
                team  : team,
                model : delegate.model,
                status: 1
            )
        }
        if ProcessInfo.processInfo.environment["BRAUS_SCRIPTED_CHECK_QUIT"] == "1" {
            await shutdown(
                team  : team,
                model : delegate.model,
                status: report.passed ? 0 : 1
            )
        }
    }

    /// Avoids AppKit's modal termination loop, which can hold the main queue while cleanup needs it.
    private static func shutdown(
        team  : TeamModel?,
        model : AppModel?,
        status: Int32
    ) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        // The turn report already contains its problem; only new cleanup failures belong here.
        team?.problem = nil
        await team?.closeAgentHosts()
        var errors = team?.problem.map { [String(describing: $0)] } ?? []
        await model?.broker.queue.shutdown()
        await MemoryService.closeAll()
        if !AppDefaults.current.synchronize() {
            errors.append("The isolated preferences could not be synchronized.")
        }
        let exitStatus: Int32 = errors.isEmpty ? status : 1
        do {
            guard case .isolated(let support) = LaunchIsolation.current else {
                throw AutomationFailure("Scripted shutdown requires an isolated run.")
            }
            let report = ShutdownReport(
                completed : errors.isEmpty,
                errors    : errors,
                exitStatus: exitStatus
            )
            try JSONEncoder().encode(report).write(
                to     : support.appending(path: "scripted-shutdown.json"),
                options: .atomic
            )
        } catch {
            FileHandle.standardError.write(Data("Scripted shutdown could not write its receipt: \(error)\n".utf8))
            exit(1)
        }
        exit(exitStatus)
    }

    private static func show(team: TeamModel) {
        let hosting = NSHostingView(rootView: HouseShellView(
            team                : team,
            isInspectorRequested: .constant(false)
        ))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(
            contentRect: NSRect(
                x     : 100,
                y     : 100,
                width : 1100,
                height: 740
            ),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing    : .buffered,
            defer      : false
        )
        window.title                = "Braus, isolated scripted worker"
        window.isRestorable         = false
        window.isReleasedWhenClosed = false
        window.contentView          = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}
