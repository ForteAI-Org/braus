//
//  AXPassSignpost.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import Dispatch
import Foundation
import OSLog

/// AXPassSignpost wraps one synchronous native surface pass in an `os_signpost`
/// interval that ends with the thread it ran on and its duration.
///
/// A pass that ran on the main thread for longer than `mainThreadNoticeMilliseconds`
/// also leaves a `.notice` in the unified log, the evidence of an interface stall.
/// Signposts cost almost nothing while no tool listens, so this is always compiled in.
nonisolated package enum AXPassSignpost {

    package static let mainThreadNoticeMilliseconds: UInt64 = 50

    private static let signposter = OSSignposter(
        subsystem: "dev.forte.AgentSeatKit",
        category : "AXPass"
    )
    private static let log = Logger(
        subsystem: "dev.forte.AgentSeatKit",
        category : "AXPass"
    )

    package static func measure<Result>(
        _ name: StaticString,
        _ body: () -> Result
    ) -> Result {

        let onMain  = Thread.isMainThread
        let started = DispatchTime.now().uptimeNanoseconds
        let state   = signposter.beginInterval(
            name,
            id: signposter.makeSignpostID(),
            "main=\(onMain, privacy: .public)"
        )
        let result = body()
        let milliseconds = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        signposter.endInterval(
            name,
            state,
            "main=\(onMain, privacy: .public) ms=\(milliseconds, privacy: .public)"
        )
        if onMain, milliseconds > mainThreadNoticeMilliseconds {
            log.notice(
                "\(name, privacy: .public) held the main thread for \(milliseconds, privacy: .public) ms"
            )
        }
        return result
    }
}
