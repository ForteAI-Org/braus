import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite
struct ReplayBudgetTests {
    @Test(arguments: try ReplayCorpus.load().filter(\.hasSceneMeasurements))
    func recorded(_ item: ReplayCase) throws {
        let expected = try ReplayExceptions.load().historicalBudget[item.id] ?? []
        let actual = try #require(try SceneBudget.historical(item))
        #expect(ReplayExceptions.differences(actual: actual, expected: expected).isEmpty)
    }

    @Test(arguments: try ReplayCorpus.load().filter { $0.input != nil && $0.hasSceneMeasurements })
    @MainActor
    func regenerated(_ item: ReplayCase) async throws {
        let trace = try await regenerateTrace(#require(item.input))
        let expected = try ReplayExceptions.load().regeneratedBudget[item.id] ?? []
        let actual = try #require(try SceneBudget.regenerated(trace, item: item))
        #expect(ReplayExceptions.differences(actual: actual, expected: expected).isEmpty,
                "\(item.id): regenerated budget \(actual)")
    }

    @Test
    func depthAndResets() throws {
        let full = ReplaySamples.delivery(1)
        let second = ReplaySamples.delivery(2, since: 1)
        let third = ReplaySamples.delivery(3, since: 2)
        #expect(try SceneBudget.depths([full, second, third]) == [0, 1, 2])
        #expect(try SceneBudget.depths([full, second, third, ReplaySamples.delivery(4, since: 3)]).last == 3)
        #expect(try SceneBudget.depths([full, second, ReplaySamples.delivery(3),
                                        ReplaySamples.delivery(4, since: 3)]) == [0, 1, 0, 1])
        #expect(try SceneBudget.depths([full, ReplaySamples.delivery(2, window: "second"),
                                        ReplaySamples.delivery(3, since: 1),
                                        ReplaySamples.delivery(4, since: 2, window: "second")]) == [0, 0, 1, 1])
        #expect(throws: ReplayFailure.self) { try SceneBudget.depths([ReplaySamples.delivery(1, since: 8)]) }
        #expect(throws: ReplayFailure.self) {
            try SceneBudget.depths([full, ReplaySamples.delivery(2, since: 1, window: "second")])
        }
        #expect(throws: ReplayFailure.self) {
            try SceneBudget.depths([full, ReplaySamples.delivery(2, since: 1, session: nil)])
        }
        #expect(throws: ReplayFailure.self) { try SceneBudget.depths([full, full]) }
        #expect(throws: ReplayFailure.self) { try SceneBudget.depths([ReplaySamples.delivery(0)]) }
    }

    @Test
    func thresholdAndCharacters() {
        #expect(!SceneBudget.exceeds(103, saved: 100))
        #expect(SceneBudget.exceeds(104, saved: 100))
        #expect(!SceneBudget.exceeds(0, saved: 0))
        #expect(SceneBudget.exceeds(1, saved: 0))
        #expect(!SceneBudget.exceeds(Int.max, saved: Int.max))
        #expect("👨‍👩‍👧‍👦e\u{301}".count == 2)
    }

    @Test
    func rendering() throws {
        let full = ReplaySamples.delivery(1)
        let diff = ReplaySamples.delivery(2, since: 1)
        #expect(try SceneBudget.rendered([full, diff]) == [full.scene.text(), "Unchanged since revision 1."])
        #expect(throws: ReplayFailure.self) { try SceneBudget.rendered([diff]) }
    }

    @Test
    func traceAccounting() throws {
        let delivery = ReplaySamples.delivery(1, text: "👨‍👩‍👧‍👦e\u{301}")
        let item = ReplayCase(schemaVersion: 1, id: "characters", tool: "act", answer: "{}",
                              before: delivery.scene, after: delivery.scene, savedSceneCharacters: 2,
                              deliveries: [delivery], input: nil)
        let value = JSONValue.object([
            "message": .string(String(repeating: "m", count: 200)),
            "observation": .object(["revision": .number(1), "scene": .string(delivery.savedText)])])
        #expect(try SceneBudget.regenerated([value], item: item) == [])
        let longer = JSONValue.object(["observation": .object([
            "revision": .number(1), "scene": .string(delivery.savedText + "!")])])
        #expect(try SceneBudget.regenerated([longer], item: item) == ["sceneBudget"])
        #expect(throws: ReplayFailure.self) { try SceneBudget.regenerated([], item: item) }
        #expect(throws: ReplayFailure.self) {
            try SceneBudget.regenerated([.object(["observation": .object([
                "revision": .number(1), "changes": .string("Unchanged")])])], item: item)
        }
    }

    @Test
    func unavailableMeasurements() throws {
        let item = try JSONDecoder().decode(ReplayCase.self, from: Data(
            #"{"id":"missing","schemaVersion":1,"tool":"act","answer":"{}"}"#.utf8))
        #expect(!item.hasSceneMeasurements)
        #expect(try SceneBudget.historical(item) == nil)
        #expect(try SceneBudget.regenerated([], item: item) == nil)
        let empty = try JSONDecoder().decode(ReplayCase.self, from: Data(
            #"{"id":"empty","schemaVersion":1,"tool":"act","answer":"{}","deliveries":[],"savedSceneCharacters":0}"#.utf8))
        #expect(empty.hasSceneMeasurements)
        #expect(try SceneBudget.historical(empty) == [])
        #expect(try SceneBudget.regenerated([], item: empty) == [])
    }

    @Test
    func reportCounts() throws {
        let cases = try ReplayCorpus.load()
        let exceptions = try ReplayExceptions.load()
        let measured = cases.filter(\.hasSceneMeasurements).count
        print("Replay report: \(cases.count) cases, \(cases.filter { $0.input != nil }.count) regenerable, "
              + "\(measured) measurable, \(cases.count - measured) unmeasurable; "
              + "recorded contracts \(exceptions.recorded.values.reduce(0) { $0 + $1.count }), "
              + "regenerated contracts \(exceptions.regenerated.values.reduce(0) { $0 + $1.count }), "
              + "historical budget \(exceptions.historicalBudget.values.reduce(0) { $0 + $1.count }), "
              + "regenerated budget \(exceptions.regeneratedBudget.values.reduce(0) { $0 + $1.count })")
    }
}
