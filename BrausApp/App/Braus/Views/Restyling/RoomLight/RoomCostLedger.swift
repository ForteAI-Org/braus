//
//  RoomCostLedger.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import Foundation
import Metal
import os
import QuartzCore

/// RoomCostLedger adds up the GPU time of the rooms' submissions by kind for `RoomCostCheck`, and
/// records nothing unless that check runs.
nonisolated enum RoomCostLedger {

    /// Kind is what a room submitted: a live frame, a preview, a full render with its pulse, a pose of
    /// the body, or the passage's frames.
    enum Kind: String, CaseIterable, Sendable {
        case live
        case preview
        case full
        case body
        case passage
    }

    /// Total is the submissions of one kind and their GPU time, in seconds.
    struct Total: Sendable {
        var count = 0
        var gpu   = 0.0
    }

    /// Ledger is everything recorded since the last `take()`.
    struct Ledger: Sendable {
        var totals       : [Kind: Total] = [:]
        var submitted    = 0
        var completed    = 0
        var lastCompleted: CFTimeInterval = 0
    }

    static let isRecording = ProcessInfo.processInfo.environment["BRAUS_ROOM_COSTS"] != nil

    private static let ledger = OSAllocatedUnfairLock(initialState: Ledger())

    /// Records `commandBuffer`'s GPU time as `kind` once it completes. Call it before the commit.
    static func track(
        _ commandBuffer: MTLCommandBuffer,
        as kind        : Kind
    ) {
        guard isRecording else { return }
        ledger.withLock { $0.submitted += 1 }
        commandBuffer.addCompletedHandler { buffer in
            let seconds = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
            let now     = CACurrentMediaTime()
            ledger.withLock { ledger in
                ledger.totals[kind, default: Total()].count += 1
                ledger.totals[kind, default: Total()].gpu   += seconds
                ledger.completed     += 1
                ledger.lastCompleted  = now
            }
        }
    }

    /// What was recorded so far, without clearing it.
    static var current: Ledger { ledger.withLock { $0 } }

    /// What was recorded so far, which starts again from nothing.
    static func take() -> Ledger {
        ledger.withLock { ledger in
            let taken = ledger
            ledger.totals    = [:]
            ledger.submitted = ledger.submitted - ledger.completed
            ledger.completed = 0
            return taken
        }
    }
}
