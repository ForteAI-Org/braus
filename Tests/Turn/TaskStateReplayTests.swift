import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore
import Testing
import Turn

@Suite("TaskState offline sizes")
struct TaskStateReplayTests {
    @Test func sizesFromManualInputs() {
        var sizes: [Int] = []
        var durations: [Double] = []
        for inputs in TaskStateFixtures.tasks {
            var state = TaskState()
            for input in inputs {
                let start = ContinuousClock.now
                state.apply(input)
                let rendered = state.rendered()
                let problems = state.check(latestSceneRevision: nil)
                let elapsed = start.duration(to: .now).components
                sizes.append(AutomationRuntime.TokenEstimate.tokens(in: rendered))
                durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                #expect(problems.isEmpty)
            }
        }
        sizes.sort()
        durations.sort()
        let percentile = max(0, Int(ceil(Double(sizes.count) * 0.95)) - 1)
        print("TaskState manual: \(sizes.count) inputs, p95 \(sizes[percentile]) tokens, "
            + "max \(sizes.last!) tokens, update and checks p95 \(durations[percentile]) ms")
    }

    private struct Sample: Decodable {
        let id: String
        let tool: String
        let input: Input?

        struct Input: Decodable {
            let kind: ActOutcomeKind
            let scene: SceneSnapshot?
            let check: Check?
            let prefix: [Result]
        }

        struct Result: Decodable {
            let kind: ActOutcomeKind
            let scene: SceneSnapshot?
            let check: Check?
        }

        struct Check: Decodable {
            let condition: String
            let method: String
            let verdict: String
            let limits: [String]
            let performed: String
            let observed: String?
            let target: Target?

            struct Target: Decodable { let label: String }

            func converted() throws -> OperationCheck {
                try .init(condition: #require(.init(rawValue: condition)),
                          method: #require(.init(rawValue: method)),
                          verdict: #require(.init(rawValue: verdict)), observed: observed,
                          limits: limits.map { try #require(.init(rawValue: $0)) },
                          performed: #require(.init(rawValue: performed)))
            }
        }
    }

    @Test func sizesFromOfflineInputs() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Replay/Fixtures/cases")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var sizes: [Int] = []
        var durations: [Double] = []
        var skipped: [String] = []
        for file in files {
            let sample = try JSONDecoder().decode(Sample.self, from: Data(contentsOf: file))
            guard let input = sample.input else { skipped.append(sample.id); continue }
            var state = TaskState()
            var revision = 0
            let results = input.prefix + [.init(kind: input.kind, scene: input.scene, check: input.check)]
            for (index, result) in results.enumerated() {
                let number = index + 1
                let outcome = Outcome.converting(result.kind, check: try result.check?.converted(),
                    notSent: nil, noop: nil, sceneAttached: result.scene != nil)
                let fact = TaskStateInput(fact: .callFinished(tool: sample.tool,
                    subject: result.check?.target?.label, outcome: outcome), origin: .dispatcher,
                    sequence: number, key: "c\(number).finished")
                let scene = result.scene.map { TaskStateScene(revision: revision + 1, text: $0.text()) }
                let start = ContinuousClock.now
                state.apply(fact)
                if let scene { revision = scene.revision; state.setScene(scene) }
                let rendered = state.rendered()
                let problems = state.check(latestSceneRevision: revision)
                let elapsed = start.duration(to: .now).components
                durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                sizes.append(AutomationRuntime.TokenEstimate.tokens(in: rendered))
                #expect(problems.isEmpty, "\(sample.id), input \(number): \(problems)")
                print("TaskState offline \(sample.id) input \(number): \(rendered.utf8.count) bytes, \(sizes.last!) tokens")
            }
        }
        #expect(!sizes.isEmpty)
        sizes.sort()
        durations.sort()
        let percentile = max(0, Int(ceil(Double(sizes.count) * 0.95)) - 1)
        print("TaskState offline: \(sizes.count) inputs, p95 \(sizes[percentile]) tokens, max \(sizes.last!) tokens, update and checks p95 \(durations[percentile]) ms; no typed input: \(skipped)")
    }
}
