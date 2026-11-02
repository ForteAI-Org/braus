//
//  HumanControlCompletion.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation
import OSLog

/// HumanControlCompletion orders handback, reconstruction and a drained worker's new turn.
/// A failed take-back is evidence for the worker, never a reason to strand human control.
@MainActor
struct HumanControlCompletion {
    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")

    let takeBack: () async throws -> String?
    let review: (String?) async -> String
    let drain: () async -> Void
    let resume: (String) async throws -> Void
    let close: () async -> Void
    /// Why control ended without the person handing it back: the summary's first line, so the worker knows.
    var ending: String? = nil

    func run(_ end: HumanControlEnd) async throws {
        let started = ContinuousClock.now
        func step(_ name: String) {
            Self.log.notice("human handoff: \(name, privacy: .public), elapsed \(ContinuousClock.now - started, privacy: .public)")
        }
        guard end == .resumingWorker else {
            await close()
            step("session closed; no resume")
            return
        }
        step("take-back started")
        let note: String?
        do { note = try await takeBack() }
        catch { note = "Take-back failed. The lent app or window may no longer be available. Inspect the current state before acting." }
        step("take-back finished")
        let reviewed = await review(note)
        let summary = ending.map { $0 + "\n" + reviewed } ?? reviewed
        step("input ended; final review and summary ready")
        Self.log.notice("human handoff summary: \(summary.utf8.count, privacy: .public) bytes; \(summary.split(separator: "\n").prefix(3).joined(separator: "\n"), privacy: .public)")
        await drain()
        step("old worker run drained")
        try await resume(summary)
        step("new turn scheduled")
    }
}
