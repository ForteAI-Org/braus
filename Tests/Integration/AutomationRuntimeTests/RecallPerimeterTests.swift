//
//  RecallPerimeterTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// RecallPerimeterTests prove the search's perimeter on catalogues learned through the tools: a need bound to an
/// application excludes the parts of other applications before the candidates are cut, so a method found only in
/// that application is read whatever outranks it elsewhere; and a search that leaves relevant versions unread says
/// so, whatever the number of relevant parts. A cut inside the search never stands for the absence of knowledge.
@MainActor
@Suite("The Recall's search perimeter: certain exclusions before the cuts, the version limit declared", .serialized)
struct RecallPerimeterTests {

    typealias G = RecallScaleTests

    static func service(_ directory: URL) -> (MemoryService, RecallService) {
        let memory = MemoryService.shared(for: directory)
        let service = RecallService(memory: memory, configuration: RecallCycleTests.configuration(.lexical))
        RecallService.install(service)
        return (memory, service)
    }

    static func close(_ directory: URL, _ memory: MemoryService) async {
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(directory)
    }

    static func request(_ text: String, app: String? = nil) throws -> RecallRequest {
        try RecallRequest(taskID: "t", attemptID: "a", revision: 1, reason: .initial, remainingWork: text,
                          needs: [try RecallNeed(text: text, bundleID: app)],
                          values: [try TaskValue(name: "output_name", kind: .text, content: .text("fattura_9"), source: .request)])
    }

    @Test("a method found only in the imposed application is selected behind sixty more relevant ones in other applications")
    func rareMethodInImposedApplication() async throws {
        let directory = try W.directory()
        let (memory, service) = Self.service(directory)
        for index in 0..<60 {
            try await G.learnGenerated(index, verb: "Export", object: "invoice", qualifier: "for the team", app: "com.example.App\(index % 40)",
                                       directory: directory)
        }
        try await G.learnGenerated(60, verb: "Export", object: "invoice", qualifier: "now", app: "com.example.Ledger", directory: directory)
        #expect(await service.waitUntilIdle(within: .seconds(120)))
        let text = "Export the invoice for the team with a new name"
        let unbound = try await service.prepare(try Self.request(text))
        let others = try #require(service.scored(unbound)).first ?? []
        #expect(!others.contains { $0.source.steps.first?.bundleID == "com.example.Ledger" },
                "unbound, the Ledger's method is outranked and not read: \(others.count) versions")
        let prepared = try await service.prepare(try Self.request(text, app: "com.example.Ledger"))
        let outcome = try #require(service.outcomes(prepared).first)
        let selected = try #require(outcome.selected, "the Ledger's method, read before any cut: \(outcome)")
        #expect(prepared.sources.first { $0.routeID == selected.routeID }?.steps.first?.bundleID == "com.example.Ledger")
        #expect(prepared.searchStatus == .completed, "\(prepared.notes)")
        await Self.close(directory, memory)
    }

    @Test("more relevant versions than the twelve a need reads, with fewer than 48 relevant parts: the search is limited and says so")
    func versionLimitDeclared() async throws {
        let directory = try W.directory()
        let (memory, service) = Self.service(directory)
        for index in 0..<15 {
            try await G.learnGenerated(index, verb: "Archive", object: "report", qualifier: "by date", app: "com.example.App\(index)",
                                       directory: directory)
        }
        #expect(await service.waitUntilIdle(within: .seconds(120)))
        let prepared = try await service.prepare(try Self.request("Archive the report by date with a new name"))
        let thresholds = service.configuration.thresholds(for: prepared.channel)
        let relevant = service.ranked(prepared, need: 0, limit: 1000).filter { $0.score >= thresholds.absolute }
        #expect(relevant.count < RecallContract.candidateLimit, "\(relevant.count) relevant parts")
        #expect(Set(relevant.map(\.routeID)).count == 15)
        #expect(prepared.sources.count == 12)
        #expect(prepared.searchStatus == .limited)
        #expect(prepared.notes.contains { $0.contains("15 versions were relevant") }, "\(prepared.notes)")
        #expect(!prepared.notes.contains { $0.contains("more parts were relevant") })
        await Self.close(directory, memory)
    }
}
