//
//  AXPassSignpostTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import Foundation
@testable import SeatSession
import Testing

private func runsOnMainThread() -> Bool { Thread.isMainThread }

/// The signpost must be transparent: the pass runs once, on the caller's thread,
/// and its result comes back untouched. The interval itself is read in Instruments.
@Suite("AX pass signpost")
struct AXPassSignpostTests {

    @Test("measure runs the pass once on the calling thread and returns its result")
    func measureIsTransparent() async {
        var runs = 0
        let expected = runsOnMainThread()
        let result = AXPassSignpost.measure("testPass") { () -> Bool in
            runs += 1
            return runsOnMainThread()
        }
        #expect(runs == 1)
        #expect(result == expected)

        let detached = await Task.detached {
            AXPassSignpost.measure("testPass") { runsOnMainThread() }
        }.value
        #expect(detached == false)
    }
}
