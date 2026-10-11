//
//  ProcedureLearningCostTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// ProcedureLearningCostTests measure what learning costs on a declared load, through the same entry as
/// the procedure tests (`AutomationTools` over `LearningSession`, the real SQLite archive). They run only
/// with `MECUM_MEMORY_MEASURE=1` and print one `measure:` line per quantity; they assert the load was
/// learned, never a duration, so a slow machine fails nothing. Bootstrap and migration are measured
/// apart from the learning they precede.
///
/// The load: one application whose window takes `states` structural states, each with `tools` toolbar
/// buttons, a panel of its own roles, a field and one button leading to the next state; `tasks` tasks of `steps` clicks each,
/// alternating a toolbar button (a self-loop) and the button to the next state; then `probes` reads of
/// a state, of its relations and of the engine's expectation, a catalogue page, and one interpretation
/// of a whole task's candidate. The scene a model reads is measured as it is enriched (its part of the
/// projection, the state and its relations), on this load and on a projection of `screens` screens of
/// ten labels; the part read is set beside the whole projection. The archive is then brought back to
/// schema 2 and to schema 3 and opened: the migration with its verified copy, then the relation recovery
/// the service runs on its own, until it is over.
@MainActor
@Suite("The cost of learning on a declared load", .serialized)
struct ProcedureLearningCostTests {

    nonisolated static let enabled = ProcessInfo.processInfo.environment["MECUM_MEMORY_MEASURE"] == "1"
    static let bundle  = "com.example.Load"
    static let states = 20, tools = 22, tasks = 4, steps = 100, probes = 1_000, screens = 400

    typealias Learning = ProcedureLearningTests

    /// The roles a state's panel draws from: state `k` shows the roles of the bits of `k + 1`, so two
    /// states always differ by a role, which is what makes the matcher place them apart (two states that
    /// differ only by a caption stay uncertain and teach nothing).
    static let panelRoles = ["AXCheckBox", "AXSlider", "AXPopUpButton", "AXRadioButton", "AXComboBox"]

    static func window(_ state: Int) -> LearningSession.Window {
        var elements = (0..<tools).map { LearningSession.button("Tool \($0)", x: 0.02 + Double($0) * 0.04, container: "toolbar") }
        for (bit, role) in panelRoles.enumerated() where (state + 1) & (1 << bit) != 0 {
            elements.append(SceneElement(id: "panel|\(role)", kind: .control, label: "Option \(bit)",
                                         bounds: NormalizedRect(x: 0.1 + Double(bit) * 0.1, y: 0.6, width: 0.08, height: 0.04),
                                         role: role, container: "panel", labelOrigin: .title))
        }
        elements.append(LearningSession.field("document \(state).txt", x: 0.3))
        elements.append(LearningSession.button("Go \((state + 1) % states)", x: 0.5, container: "footer"))
        return LearningSession.Window(elements: elements, title: "State \(state)")
    }

    static func percentiles(_ samples: [Duration]) -> String {
        let sorted = samples.map { Double($0.components.attoseconds) / 1e12 + Double($0.components.seconds) * 1e6 }.sorted()
        guard !sorted.isEmpty else { return "n=0" }
        func at(_ p: Double) -> String { String(format: "%.0f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]) }
        return "n=\(sorted.count) p50us=\(at(0.5)) p95us=\(at(0.95)) maxus=\(String(format: "%.0f", sorted.last!))"
    }

    static func measured(_ body: () async throws -> Void) async rethrows -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try await body()
        return clock.now - start
    }

    static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// The scene of a window enriched as a model reads it, and its part of the projection set beside the
    /// whole one: `rounds` reads of each, the anchors each holds, and whether the part names as the whole.
    static func enrichment(_ memory: MemoryService, _ windows: [PerceivedWindow], rounds: Int, label: String) async throws {
        let brain = W.brain(memory)
        var enriched: [Duration] = [], parts: [Duration] = [], wholes: [Duration] = []
        var read = 0, held = 0, same = true
        for index in 0..<rounds {
            let window = windows[index % windows.count]
            enriched.append(await Self.measured { _ = await brain.enrich(window.scene, window: window) })
            let detections = window.scene.elements.filter { $0.kind == .control || $0.kind == .icon }.map(BrainDetection.init)
            var part: UIBrain?, whole: UIBrain?
            parts.append(try await Self.measured { part = try await memory.projection(of: window.scene.bundleID, for: detections) })
            // The whole projection as the repository reads it: the service's cache of it serves only the
            // command line, and any write empties it.
            let bundleID = window.scene.bundleID
            wholes.append(try await Self.measured { whole = try await memory.perform { try await $0.brains.brain(of: bundleID) } })
            if index < windows.count, let part, let whole {
                read = max(read, part.objects.count)
                held = whole.objects.count
                same = same && part.enrich(window.scene.elements, affordances: false) == whole.enrich(window.scene.elements, affordances: false)
            }
        }
        print("measure: \(label) scene enriched as the model reads it \(Self.percentiles(enriched))")
        print("measure: \(label) part of the projection \(Self.percentiles(parts)) anchors<=\(read)")
        print("measure: \(label) whole projection \(Self.percentiles(wholes)) anchors=\(held)")
        #expect(same, "the part names every scene as the whole")
    }

    @Test("learning and reading on the declared load", .enabled(if: enabled))
    func declaredLoad() async throws {
        print("measure: load states=\(Self.states) toolbar=\(Self.tools) tasks=\(Self.tasks) steps=\(Self.steps) probes=\(Self.probes)")
        let session = LearningSession(directory: try W.directory())
        for state in 0..<Self.states {
            session.script["act|Go \((state + 1) % Self.states)"] = LearningSession.Outcome(
                effect: .elementsAppeared(labels: ["Go \((state + 2) % Self.states)"]), next: Self.window((state + 1) % Self.states))
        }
        for tool in 0..<Self.tools {
            session.script["act|Tool \(tool)"] = LearningSession.Outcome(effect: .elementsAppeared(labels: ["Tool \(tool) panel"]))
        }
        session.windows[Self.bundle] = Self.window(0)

        // Bootstrap: the first open of a new archive, apart from the learning.
        let memory = MemoryService.shared(for: session.directory)
        let bootstrap = try await Self.measured { _ = try await memory.ready() }
        print("measure: bootstrap new archive ms=\(bootstrap.components.seconds * 1000 + bootstrap.components.attoseconds / 1_000_000_000_000_000)")

        let tools = Learning.tools(session)
        let id = session.id!.uuidString
        var calls: [Duration] = [], flushes: [Duration] = [], ends: [Duration] = []
        var lastCandidate = ""
        for task in 0..<Self.tasks {
            _ = try await Learning.task(tools, #"{"operation":"begin","goal":"Walk the states, round \#(task)"}"#)
            _ = try await Learning.call(tools, "open_session", #"{"app":"\#(Self.bundle)"}"#)
            var state = 0
            for step in 0..<Self.steps {
                let target = step % 2 == 0 ? "Tool \((step / 2 + task) % Self.tools)" : "Go \((state + 1) % Self.states)"
                calls.append(try await Self.measured {
                    _ = try await Learning.call(tools, "act", #"{"session":"\#(id)","target":"\#(target)"}"#)
                })
                if step % 2 == 1 { state = (state + 1) % Self.states }
            }
            var answer = JSONValue.null
            ends.append(try await Self.measured {
                answer = try await Learning.task(tools, #"{"operation":"end","outcome":"completed"}"#)
            })
            lastCandidate = answer["candidate"]["id"].string ?? ""
            #expect(answer["candidate"]["steps"].array?.count == Self.steps)
            flushes.append(await Self.measured { #expect(await memory.flush(within: .seconds(60))) })
            session.windows[Self.bundle] = Self.window(0)
        }
        print("measure: act call through the tools \(Self.percentiles(calls))")
        print("measure: task end with a \(Self.steps)-step candidate \(Self.percentiles(ends))")
        print("measure: derived queue drained after each task \(Self.percentiles(flushes))")

        let steps = (1...Self.steps).map { #"{"step":\#($0),"label":"Step \#($0)"}"# }.joined(separator: ",")
        var interpreted = JSONValue.null
        let interpretation = try await Self.measured {
            interpreted = try await Learning.task(tools, #"""
                {"operation":"interpret","candidate":"\#(lastCandidate)","procedure":{"label":"Walk the states"},"steps":[\#(steps)]}
                """#)
        }
        #expect(interpreted["status"].string == "interpreted", "\(interpreted)")
        print("measure: interpretation of \(Self.steps) steps \(Self.percentiles([interpretation]))")

        // Reads: a state from a new capture, its relations, the engine's expectation, a catalogue page.
        let brain = W.brain(memory)
        let perceived = (0..<Self.states).map { LearningSession.perceived(Self.window($0), of: Self.bundle) }
        let skeletons = perceived.map { SceneSkeleton(sample: CaptureSample(key: CaptureSampleKey(eventID: "probe", phase: .current), of: $0,
                                                                          sessionRevision: nil)) }
        var stateIDs: [String] = []
        var stateReads: [Duration] = [], relationReads: [Duration] = [], expectations: [Duration] = [], catalogue: [Duration] = []
        for index in 0..<Self.probes {
            let which = index % Self.states
            var found: String?
            stateReads.append(try await Self.measured {
                found = try await memory.state(of: skeletons[which], isComplete: true, in: Self.bundle)
            })
            if index < Self.states { stateIDs.append(found ?? "") }
        }
        #expect(stateIDs.allSatisfy { !$0.isEmpty } && Set(stateIDs).count == Self.states, "every state is recognized, each its own")
        let go = "control|footer|AXButton|go"
        for index in 0..<Self.probes {
            let which = index % Self.states
            let keys = ["\(go)\((which + 1) % Self.states)", "control|toolbar|AXButton|tool\(index % Self.tools)"]
            relationReads.append(try await Self.measured {
                _ = try await memory.relations(from: stateIDs[which], in: Self.bundle, elementKeys: keys, includingContext: false)
            })
            let element = perceived[which].scene.elements.last!
            expectations.append(await Self.measured { _ = await brain.expectedEffect(of: .click, on: element, in: perceived[which]) })
        }
        for _ in 0..<20 {
            catalogue.append(try await Self.measured { _ = try await memory.perform { try await $0.procedures.catalogue(limit: 100) } })
        }
        print("measure: state of a new capture \(Self.percentiles(stateReads))")
        print("measure: relations of a state and two elements \(Self.percentiles(relationReads))")
        print("measure: engine expectation (state and relations) \(Self.percentiles(expectations))")
        print("measure: catalogue page of 100 \(Self.percentiles(catalogue))")
        try await Self.enrichment(memory, perceived, rounds: Self.probes, label: "load")
        let relations = try await memory.perform { try await $0.relations.relations(of: Self.bundle) }
        let rows = try ["memory_agent_actions", "brain_anchors", "brain_anchor_label_keys", "brain_scenes", "brain_relations",
                        "brain_relation_evaluations", "brain_relation_evidence", "memory_procedure_parts"].map {
            "\($0)=\(try rawRows("SELECT count(*) FROM \($0)", at: memory.url).first ?? "?")"
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: memory.url.path)[.size] as? NSNumber)?.intValue ?? 0
        print("measure: archive \(rows.joined(separator: " ")) exposed=\(relations.filter { $0.standing == .exposed }.count) bytes=\(bytes)")
        #expect(relations.count >= Self.states)
        await memory.close()
        MemoryService.forget(session.directory)

        // Migrations: the same archive brought back to schema 2 (its D2 rows dropped) and to schema 3 (as the
        // first D2 delivery wrote it), each opened: the migration with its verified copy, then the recovery the
        // service runs on its own when its queue is empty, timed until it is over.
        let learned = Dictionary(uniqueKeysWithValues: relations.map { ($0.relationID, $0.supports) })
        for from in [2, 3] {
            let copy = try W.directory()
            try FileManager.default.copyItem(at: session.directory.appendingPathComponent("memory.sqlite"),
                                             to: copy.appendingPathComponent("memory.sqlite"))
            if from == 2 { try downgradeToSchema2(copy.appendingPathComponent("memory.sqlite")) }
            else { try downgradeToSchema3(copy.appendingPathComponent("memory.sqlite")) }
            let migrating = MemoryService.shared(for: copy)
            let migration = try await Self.measured { _ = try await migrating.ready() }
            let shapes = try rawRows("SELECT (SELECT count(*) FROM brain_scene_shapes) || '/' || (SELECT count(*) FROM brain_scenes)",
                                     at: migrating.url)
            print("measure: migration \(from)→\(SQLiteMemorySchema.version) with its verified copy ms=\(Self.ms(migration)) "
                  + "shapes/scenes=\(shapes.first ?? "?")")
            #expect(try rawRows("PRAGMA user_version", at: migrating.url) == ["\(SQLiteMemorySchema.version)"])
            var drained = false
            let recovery = await Self.measured { drained = await migrating.flush(within: .seconds(300)) }
            let report = await migrating.status().relationRecovery
            let calls = report.total
            print("measure: relation recovery after the migration from \(from) calls=\(calls) recovered=\(report.recovered) "
                  + "reevaluated=\(report.reevaluated) reconsidered=\(report.reconsidered) associated=\(report.associated) "
                  + "totalms=\(Self.ms(recovery)) perCallus=\(calls == 0 ? 0 : Self.ms(recovery) * 1000 / Int64(calls))")
            let pending = await migrating.status().relationRecoveryPending
            #expect(drained && !pending)
            #expect(from == 2 ? report.recovered == Self.tasks * Self.steps : report.reevaluated == Self.tasks * Self.steps, "\(report)")
            let again = try await migrating.perform { try await $0.relations.relations(of: Self.bundle) }
            #expect(Dictionary(uniqueKeysWithValues: again.map { ($0.relationID, $0.supports) }) == learned,
                    "the relations the recovery gives from the facts are the ones learned while acting")
            let idle = try await migrating.perform { try await $0.relations.catchUp(at: 2_000_000, associate: { _ in }) }
            #expect(idle.total == 0 && !idle.remaining, "a pass after the recovery finds nothing left")
            await migrating.close()
            MemoryService.forget(copy)
        }

        // A larger projection: `screens` screens of ten labels each, then the scenes of ten of them read.
        let large = MemoryService.shared(for: try W.directory())
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let ingest = try await Self.measured {
            for screen in 0..<Self.screens {
                let detections = (0..<10).map {
                    BrainDetection(kind: .control, label: "Screen \(screen) item \($0)",
                                   bounds: NormalizedRect(x: 0.3, y: 0.1 + 0.05 * Double($0), width: 0.05, height: 0.02), state: nil)
                }
                _ = try await large.perform { repositories in
                    try await repositories.brains.ingest(detections, into: Self.bundle,
                                                         now: try BrainClock.canonical(base.addingTimeInterval(Double(screen))),
                                                         window: "screen \(screen)")
                }
            }
        }
        print("measure: projection of \(Self.screens) screens ingested ms=\(Self.ms(ingest))")
        let screensRead = (0..<10).map { screen -> PerceivedWindow in
            let elements = (0..<10).map {
                SceneElement(id: "s\(screen)-\($0)", kind: .control, label: "Screen \(screen * 37) item \($0)",
                             bounds: NormalizedRect(x: 0.3, y: 0.1 + 0.05 * Double($0), width: 0.05, height: 0.02))
            }
            return LearningSession.perceived(LearningSession.Window(elements: elements, title: "Screen \(screen * 37)"), of: Self.bundle)
        }
        try await Self.enrichment(large, screensRead, rounds: 200, label: "large")
        // The same scenes with an unlabeled control in a column's slot: the ordinal rescue reads the members
        // of every group of its kind, the one read the label keys do not bound.
        let withUnlabeled = screensRead.map { window -> PerceivedWindow in
            var elements = window.scene.elements
            elements.append(SceneElement(id: "unlabeled", kind: .control, label: "",
                                         bounds: NormalizedRect(x: 0.3, y: 0.1 + 0.05 * 10, width: 0.05, height: 0.02), isUnlabeled: true))
            return LearningSession.perceived(LearningSession.Window(elements: elements, title: window.scene.windowTitle), of: Self.bundle)
        }
        try await Self.enrichment(large, withUnlabeled, rounds: 200, label: "large+unlabeled")
        let groups = try rawRows("SELECT count(*) || '/' || (SELECT count(*) FROM brain_group_members) FROM brain_groups", at: large.url)
        print("measure: large projection groups/members=\(groups.first ?? "?")")
        await large.close()
        MemoryService.forget(large.directory)
    }
}
