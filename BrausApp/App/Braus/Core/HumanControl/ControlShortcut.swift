//
//  ControlShortcut.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import Carbon.HIToolbox
import Observation
import OSLog
import SeatBroker

/// ControlShortcut is ⌃⌥Tab, which switches who holds the lent application from anywhere, Braus
/// in front or not: a press takes control while the worker holds it, and hands it back while the
/// person holds it (`ControlToggle`). The key is registered only while a worker holds an
/// application or has one lent, and never while VoiceOver runs, where VO-Tab passes the next key
/// to the application. Every press logs one line: what it did, or why it did nothing.
final class ControlShortcut {

    /// The shortcut as help text writes it.
    static let label = "⌃⌥Tab"

    /// Asked of a worker's screen window by a press: take control as its button does. The number
    /// tells two asks for the same worker apart.
    struct Request: Equatable {
        let workerID: UUID
        let number  : Int
    }

    private weak var team: TeamModel?
    private var hotKey   : SystemHotKey?
    private var voiceOver: NSKeyValueObservation?

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "HumanControl"
    )

    init(team: TeamModel) {
        self.team = team
        hotKey = SystemHotKey(
            keyCode  : kVK_Tab,
            modifiers: controlKey | optionKey
        ) { [weak self] in self?.pressed() }
        voiceOver = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
        follow()
    }

    // MARK: Registration

    /// Registers the key while some worker holds an application or has one lent, VoiceOver off.
    private func update() {
        guard let team, let hotKey else { return }
        let wanted = !NSWorkspace.shared.isVoiceOverEnabled
            && Self.states(of: team).values.contains(where: \.isCandidate)
        if wanted != hotKey.isRegistered {
            hotKey.isRegistered = wanted
            Self.log.notice("\(Self.label, privacy: .public): \(wanted ? "registered" : "unregistered", privacy: .public)")
        }
    }

    private func follow() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }

    // MARK: Press

    private func pressed() {
        guard let team else { return }
        let states = Self.states(of: team)
        let (target, reason) = ControlToggle.target(
            among    : states,
            frontmost: Self.frontmostScreen(among: Set(states.keys))
        )
        guard let target, let state = states[target] else {
            Self.log.notice("\(Self.label, privacy: .public): ignored, \(reason, privacy: .public)")
            return
        }
        switch ControlToggle.decide(state) {
        case .ignore(let why):
            Self.log.notice("\(Self.label, privacy: .public): ignored for \(target, privacy: .public), \(why, privacy: .public)")
        case .act(.takeControl):
            Self.log.notice("\(Self.label, privacy: .public): Take Control for \(target, privacy: .public), \(reason, privacy: .public)")
            if WorkerScreenWindowController.openWindows[target] != nil {
                team.askTakeControl(target)
            } else {
                team.beginHumanControl(target)
            }
        case .act(.handBack):
            Self.log.notice("\(Self.label, privacy: .public): hand back for \(target, privacy: .public), \(reason, privacy: .public)")
            team.lendingCompanion(of: target)?.finishRequested()
        }
    }

    /// Each worker's handover, for the workers that hold an application or have a human control.
    private static func states(of team: TeamModel) -> [UUID: ControlToggle.State] {
        let workers = Set(team.screenHolders)
            .union(team.humanControls.keys)
            .union(team.handingBack)
        return Dictionary(uniqueKeysWithValues: workers.map { workerID in
            (workerID, state(of: workerID, in: team))
        })
    }

    static func state(
        of workerID: UUID,
        in team    : TeamModel
    ) -> ControlToggle.State {
        let control   = team.humanControls[workerID]
        let companion = team.lendingCompanion(of: workerID)
        return ControlToggle.State(
            holdsApplication : team.hasScreen(workerID),
            isUnderway       : control.map { !$0.isFinished && ($0.hasStarted || $0.isBlocked) } ?? false,
            isFinishing      : control?.isFinishing ?? false,
            isBlocked        : control?.isBlocked ?? false,
            isRefused        : control?.lendingRefused ?? false,
            isLent           : control?.lentWindow != nil,
            hasLanded        : companion?.hasLanded ?? false,
            asksHandBack     : companion?.asksHandBack ?? false,
            isHandingBack    : team.handingBack.contains(workerID),
            isReadingHandBack: WorkerScreenWindowController.openWindows[workerID]?.isReading ?? false
        )
    }

    /// The worker among `workers` whose screen window is the frontmost of Braus's windows.
    private static func frontmostScreen(among workers: Set<UUID>) -> UUID? {
        for window in NSApp.orderedWindows {
            if let pair = WorkerScreenWindowController.openWindows.first(where: { $0.value.window === window }),
               workers.contains(pair.key) {
                return pair.key
            }
        }
        return nil
    }
}
