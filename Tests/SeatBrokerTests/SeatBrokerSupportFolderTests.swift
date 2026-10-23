//
//  SeatBrokerSupportFolderTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 23/10/2026.
//

import AutomationRuntime
import Foundation
import SeatBroker
import Testing

/// The seat keeps its run records under the same support folder as the Knowledge, so a run that moves that folder
/// (`BRAUS_APP_SUPPORT_DIR`) takes the seat's records with it and leaves the person's own Braus alone.
@Suite("SeatBroker support folder")
struct SeatBrokerSupportFolderTests {

    @Test("with the variable set, both folders are under it")
    func underTheVariable() {
        let configuration = SeatBrokerConfiguration(environment: [KnowledgeLocation.supportOverride: "/tmp/braus-isolated-support"])
        #expect(configuration.perceptionStoreDirectory.path == "/tmp/braus-isolated-support/Perception")
        #expect(configuration.recordingDirectory.path == "/tmp/braus-isolated-support/Runs")
    }

    @Test("with it unset or empty, both are under the default support folder")
    func underTheDefault() {
        let support = KnowledgeLocation.support(environment: [:])
        for environment in [[String: String](), [KnowledgeLocation.supportOverride: ""]] {
            let configuration = SeatBrokerConfiguration(environment: environment)
            #expect(configuration.perceptionStoreDirectory == support.appendingPathComponent("Perception", isDirectory: true))
            #expect(configuration.recordingDirectory == support.appendingPathComponent("Runs", isDirectory: true))
        }
    }

    @Test("an explicit directory is used as given")
    func explicitWins() {
        let runs = URL(fileURLWithPath: "/tmp/elsewhere/Runs", isDirectory: true)
        let configuration = SeatBrokerConfiguration(recordingDirectory: runs,
                                                    environment: [KnowledgeLocation.supportOverride: "/tmp/braus-isolated-support"])
        #expect(configuration.recordingDirectory == runs)
    }
}
