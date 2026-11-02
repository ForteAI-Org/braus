//
//  HumanInterventionReplayCaseTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

#if DEBUG
import Foundation
import Testing
@testable import SeatBroker

/// Each recorded intervention that carries an `expected.json` is replayed and held to it, besides the invariants every
/// report keeps. Archives come from BRAUS_REPLAY_DIR (see ReplayArchives).
@Suite
struct HumanInterventionReplayCaseTests {
    private static let cases = ReplayArchives.names.filter { ReplayArchives.expectation($0) != nil }

    @Test(.enabled(if: !cases.isEmpty), arguments: cases)
    func replay(_ name: String) async throws {
        let url = try #require(ReplayArchives.url(name))
        let expected = try #require(ReplayArchives.expectation(name))
        let digest = try await HumanInterventionReplay.replay(url)
        print("REPLAY_\(name)_BEGIN bytes=\(digest.text.utf8.count)\n\(digest.text)\nREPLAY_END")
        digest.checkInvariants(name)
        digest.check(expected, name)
    }
}
#endif
