import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite
struct ReplayContractTests {
    @Test(arguments: try ReplayCorpus.load())
    @MainActor
    func recorded(_ item: ReplayCase) throws {
        let answer = try JSONDecoder().decode(JSONValue.self, from: Data(item.answer.utf8))
        let actual = violations(answer, item: item)
        let expected = try ReplayExceptions.load().recorded[item.id] ?? []
        #expect(ReplayExceptions.differences(actual: actual, expected: expected).isEmpty, "\(item.id): recorded contracts \(actual)")
    }

    @Test(arguments: try ReplayCorpus.load().filter { $0.input != nil })
    @MainActor
    func regenerated(_ item: ReplayCase) async throws {
        let input = try #require(item.input)
        let actual = violations(try await regenerate(input), item: item)
        let expected = try ReplayExceptions.load().regenerated[item.id] ?? []
        #expect(ReplayExceptions.differences(actual: actual, expected: expected).isEmpty, "\(item.id): regenerated contracts \(actual)")
    }

    @MainActor
    private func violations(_ answer: JSONValue, item: ReplayCase) -> Set<String> {
        let scenes = [item.before, item.after].compactMap { $0 }
            + (item.deliveries ?? []).map(\.scene)
            + (item.input.map { $0.prefix + [$0.outcome] } ?? []).compactMap(\.scene)
        let known = Set(AutomationTools.definitions(for: [.native, .web, .adapters]).compactMap { $0["name"].string })
        return MessageContract.violations(in: MessageContract.messages(in: answer), scenes: scenes, known: known)
    }

    @Test
    func syntheticMessages() {
        #expect(MessageContract.mentionsObserve("Observe before retrying"))
        #expect(!MessageContract.mentionsObserve("The observer is ready"))
        for word in ["perceive", "re-read", "look again", "describe_scene"] {
            #expect(MessageContract.mentionsObserve(word))
        }
        #expect(MessageContract.unknownToolNames(in: "Use describe_scene and type_text", known: ["type_text"])
                == ["describe_scene"])
        #expect(MessageContract.unknownToolNames(in: "Use observe", known: ["observe"]).isEmpty)
        #expect(MessageContract.overBudget(String(repeating: "a", count: 161)))
        #expect(!MessageContract.overBudget(String(repeating: "a", count: 160)))
        #expect(MessageContract.messages(in: .object(["status": .string("acted_noop"),
                                                     "message": .string("Done")])) == ["Done"])
        #expect(MessageContract.messages(in: .bool(true)).isEmpty)
        #expect(MessageContract.messages(in: .object(["limits": .array([.string("no_after_scene")])])).isEmpty)
        #expect(MessageContract.violations(in: ["Observe describe_scene"], scenes: [], known: [])
                == ["observe", "unknownTool:describe_scene"])
        #expect(MessageContract.violations(in: ["Done"], scenes: [], known: []).isEmpty)
    }

    @Test
    func syntheticValues() {
        var scene = ReplaySamples.scene()
        scene.elements[0].value = String(repeating: "abcdefghijk", count: 7) + "1234567"
        #expect(scene.elements[0].value?.count == 84)
        #expect(!MessageContract.leakedValues(in: "Value abcdefgh", scenes: [scene]).isEmpty)
        #expect(MessageContract.leakedValues(in: "Value abcdefg", scenes: [scene]).isEmpty)
        scene.elements[0].value = "short"
        #expect(MessageContract.leakedValues(in: "short", scenes: [scene]).isEmpty)
    }

    @Test
    func exceptionRatchet() throws {
        #expect(ReplayExceptions.differences(actual: ["new"], expected: []).contains("new"))
        #expect(ReplayExceptions.differences(actual: [], expected: ["stale"]).contains("stale"))
        #expect(ReplayExceptions.differences(actual: ["same"], expected: ["same"]).isEmpty)
        let cases = try ReplayCorpus.load()
        let ids = Set(cases.map(\.id))
        let regenerable = Set(cases.filter { $0.input != nil }.map(\.id))
        let measurable = Set(cases.filter(\.hasSceneMeasurements).map(\.id))
        let exceptions = try ReplayExceptions.load()
        #expect(Set(exceptions.regenerated.keys).isSubset(of: regenerable))
        #expect(Set(exceptions.historicalBudget.keys).isSubset(of: measurable))
        #expect(Set(exceptions.regeneratedBudget.keys).isSubset(of: regenerable.intersection(measurable)))
        for table in [exceptions.recorded, exceptions.regenerated,
                      exceptions.historicalBudget, exceptions.regeneratedBudget] {
            #expect(Set(table.keys).isSubset(of: ids))
            #expect(table.values.allSatisfy { !$0.isEmpty })
        }
    }
}
