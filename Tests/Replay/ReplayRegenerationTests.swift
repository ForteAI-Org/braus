import EngineCore
import Foundation
import LocalMCP
import Testing

@Suite
struct ReplayRegenerationTests {
    @Test(arguments: try ReplayCorpus.load().filter { $0.input != nil })
    @MainActor
    func golden(_ item: ReplayCase) async throws {
        let actual = try await replayBytes(regenerateModelAnswer(#require(item.input), tool: item.tool))
        let file = ReplayCorpus.fixtures.appending(path: "golden/current-delivery/\(item.id).txt")
        if ProcessInfo.processInfo.environment["BRAUS_RECORD_REPLAY_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: file)
        }
        let expected = try Data(contentsOf: file)
        #expect(actual == expected, "\(item.id): golden bytes differ")
    }

    @Test
    @MainActor
    func formatterMutationIsVisible() async throws {
        let item = try #require(ReplayCorpus.load().first { $0.id == "refused-01" })
        let input = try #require(item.input)
        let changed = ReplayInput(kind: .foundActed, message: input.message, scene: input.scene,
                                  check: input.check, session: input.session,
                                  windowNumber: input.windowNumber, prefix: input.prefix)
        let expected = try Data(contentsOf: ReplayCorpus.fixtures.appending(path: "golden/current-delivery/\(item.id).txt"))
        #expect(try await replayBytes(regenerateModelAnswer(changed, tool: item.tool)) != expected)
    }

    @Test
    func independentGuards() throws {
        let original = JSONValue.object(["message": .string("Done"), "scene": .string(String(repeating: "a", count: 100))])
        let changed = JSONValue.object(["message": .string("Done!"), "scene": .string(String(repeating: "a", count: 102))])
        #expect(try replayBytes(original) != replayBytes(changed))
        #expect(!SceneBudget.exceeds(102, saved: 100))
        #expect(try replayBytes(.object(["b": .number(1), "a": .string("é")]))
                == Data(#"{"a":"é","b":1}"#.utf8))
    }

    @Test
    func checkConversion() throws {
        let source = #"{"condition":"value_read_back","method":"control_value","methodVersion":"test-1","verdict":"failed","expected":"expected","observed":null,"limits":["no_after_scene","delivery_uncertain"],"performed":"substitute","substitute":"dismiss","target":{"elementID":"row0","role":"AXButton","label":"Close","section":null}}"#
        let dto = try JSONDecoder().decode(ReplayCheck.self, from: Data(source.utf8))
        let check = try dto.converted()
        #expect(check.condition == .valueReadBack)
        #expect(check.method == .controlValue)
        #expect(check.methodVersion == "test-1")
        #expect(check.verdict == .failed)
        #expect(check.expected == "expected" && check.observed == nil)
        #expect(check.limits == [.noAfterScene, .deliveryUncertain])
        #expect(check.performed == .substitute && check.substitute == "dismiss")
        #expect(check.target?.elementID == "row0" && check.target?.section == nil)
        for (old, new) in [("value_read_back", "bad_condition"), ("control_value", "bad_method"),
                           ("failed", "bad_verdict"), ("delivery_uncertain", "bad_limit"),
                           ("substitute\",", "bad_performed\",")] {
            let invalid = source.replacingOccurrences(of: old, with: new)
            #expect(throws: ReplayFailure.self) {
                try JSONDecoder().decode(ReplayCheck.self, from: Data(invalid.utf8)).converted()
            }
        }
    }

    @Test
    func invalidFixtures() throws {
        let source = #"{"schemaVersion":1,"id":"invalid","tool":"act","answer":"{}","input":{"kind":"refused","message":"No","prefix":[]}}"#
        for invalid in [source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
                        source.replacingOccurrences(of: "refused", with: "invalid_kind")] {
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(ReplayCase.self, from: Data(invalid.utf8)).validate()
            }
        }
        let invalidCheck = #"{"condition":"invalid","method":"none","methodVersion":"v1","verdict":"unknown","limits":[],"performed":"none"}"#
        #expect(throws: ReplayFailure.self) {
            try JSONDecoder().decode(ReplayCheck.self, from: Data(invalidCheck.utf8)).converted()
        }
    }
}
