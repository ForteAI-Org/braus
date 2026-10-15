//
//  ProcedureFamiliesTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// Procedures share their phases (14 October 2026): the parts of different procedures that hold one method form a family,
/// which a consolidation would keep once, and a new candidate is told which runs of its steps are phases learned before.
@MainActor
@Suite("Phases procedures share", .serialized)
struct ProcedureFamiliesTests {

    typealias P = ProcedureLearningTests

    static func member(_ route: String, _ kind: PartKind, _ label: String?, _ method: [String]) -> ProcedureFamilies.Member {
        ProcedureFamilies.Member(routeID: route, partID: "\(route)/\(label ?? "x")", kind: kind, label: label, firstPosition: 0,
                                 lastPosition: method.count - 1, method: method)
    }

    @Test("parts of one method form a family with the label most of them share; a candidate's run of that method is a known phase")
    func families() {
        let open = ["app|menu|path#0=file > open", "app|act|target#0=item:AXRow|verb#0=click", "app|act|target#0=open|verb#0=click"]
        let save = ["app|menu|path#0=file > save a copy", "app|type_text|replace#0=true|target#0=item:AXTextField|text#0=text",
                    "app|act|target#0=save|verb#0=click"]
        let families = ProcedureFamilies.families(of: [
            Self.member("v1", .subprocedure, "Apri l'immagine", open), Self.member("v2", .subprocedure, "Apri l'immagine", open),
            Self.member("v3", .subprocedure, "Aprire l'immagine", open), Self.member("v1", .subprocedure, "Salva una copia", save),
            Self.member("v1", .step, "Apri il menu", [open[0]]), Self.member("v2", .step, "Apri il menu File", [open[0]]),
        ])
        let phases = families.filter { $0.kind == .subprocedure }
        #expect(phases.count == 2)
        #expect(phases.first?.members.count == 3 && phases.first?.procedures == 3)
        #expect(phases.first?.label == "Apri l'immagine" && phases.first?.labels.map(\.count) == [2, 1])
        #expect(families.filter { $0.kind == .step }.count == 1, "one step family across two procedures")
        let candidate = ["app|menu|path#0=image > invert"] + open + ["app|menu|path#0=image > rotate"] + save
        let known = ProcedureFamilies.knownPhases(in: candidate, families: families)
        #expect(known.map { [$0.firstPosition, $0.lastPosition] } == [[1, 3], [5, 7]])
        #expect(known.map(\.label) == ["Apri l'immagine", "Salva una copia"])
    }

    @Test("a second task's candidate is told the phase it shares with a learned procedure, and the consolidation counts it once")
    func knownPhaseInTheCandidate() async throws {
        let directory = try W.directory()
        let session = ProcedureMethodTests.session(directory)
        let first = P.tools(session, stream: "first")
        _ = try await P.task(first, ProcedureMethodTests.begin("foto_web"))
        try await ProcedureMethodTests.run(first, session, name: "foto_web", mistakes: false)
        let ended = try await P.task(first, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_web")))
        let firstCandidate = try #require(ended["candidate"]["id"].string)
        let interpreted = try await P.task(first, ProcedureMethodTests.interpretation(firstCandidate, mistakes: false))
        #expect((interpreted["parts"].array ?? []).allSatisfy { $0["admitted"].bool == true }, "\(interpreted)")
        #expect(ended["candidate"]["known_phases"] == .null, "nothing was learned before the first task")

        let second = P.tools(session, stream: "second")
        _ = try await P.task(second, ProcedureMethodTests.begin("foto_mail"))
        try await ProcedureMethodTests.run(second, session, name: "foto_mail", mistakes: false)
        let secondEnd = try await P.task(second, ProcedureMethodTests.end(result: try ProcedureMethodTests.written(directory, "foto_mail")))
        let known = secondEnd["candidate"]["known_phases"].array ?? []
        #expect(known.count == 1, "\(secondEnd["candidate"])")
        #expect(RecallCycleTests.int(known.first?["from"] ?? .null) == 2 && RecallCycleTests.int(known.first?["to"] ?? .null) == 5)
        #expect(known.first?["label"].string == "Export it as <name>.jpg in JPEG")

        let memory = MemoryService.shared(for: directory)
        let families = try await memory.perform { try await $0.procedures.families() }
        #expect(families.filter { $0.kind == .procedure }.count == 1 && families.filter { $0.kind == .subprocedure }.count == 2,
                "one procedure, its two phases: \(families.map { "\($0.kind) \($0.members.count)" })")
        await memory.close()
    }
}
