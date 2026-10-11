import CoreGraphics
import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

@Suite("D2 independent review: relation identity and context delivery")
struct D2IndependentReviewTests {
    private let bundle = "com.example.ReviewEditor"

    private func field(_ id: String, value: String, x: Double) -> SceneElement {
        SceneElement(id: id, kind: .control, label: value,
                     bounds: NormalizedRect(x: x, y: 0.3, width: 0.2, height: 0.04),
                     role: "AXTextField", labelOrigin: .value)
    }

    private func scene(_ elements: [SceneElement]) -> SceneSnapshot {
        SceneSnapshot(bundleID: bundle, appName: "Review Editor", windowTitle: "Export",
                      viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
    }

    private func relation(element: String?, verb: BrainVerb, outcome: BrainRelationOutcome = .effect,
                          arguments: String = "") -> BrainRelation {
        let key = BrainRelationKey(bundleID: bundle, contextID: nil, fromSceneID: "S", elementKey: element,
                                   verb: verb, argumentsKey: arguments, toSceneID: "S", outcome: outcome,
                                   effectKind: outcome == .effect ? "textSelectionChanged" : nil)
        return BrainRelation(relationID: key.relationID, key: key, firstSeenMS: 0, lastSeenMS: 1,
                             supports: 2, contradictions: 0)
    }

    @Test("two physically distinct fields must not receive the same learned relation")
    func distinctFieldsDoNotShareKnowledge() async throws {
        let filename = field("filename", value: "photo.png", x: 0.1)
        let destination = field("destination", value: "/tmp/export", x: 0.6)
        let filenameCapture = try #require(CaptureElement(filename))
        let destinationCapture = try #require(CaptureElement(destination))
        let filenameKey = try #require(SceneElementKey.key(of: filenameCapture))
        let destinationKey = try #require(SceneElementKey.key(of: destinationCapture))
        let relations = RelationsDouble(state: "S")
        await relations.set([relation(element: filenameKey, verb: .typeText, outcome: .valueSet)])
        let store = InMemoryBrainStore()
        let brain = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        let enriched = await brain.enrich(scene([filename, destination]), state: "S")
        // Adapted after the review: the two fields carry nothing stable that tells them apart (their labels
        // are their values, their places are positions), so their template identifies neither, and what
        // was learned on that template is attributed to neither, as the review's correction asks. The
        // original expectation that the filename field keeps it needs a signal, given below.
        #expect(enriched.elements[0].does == nil && enriched.elements[1].does == nil,
                "only the filename field was taught, but destination key=\(destinationKey), filename key=\(filenameKey)")
        let identities = SceneElementKey.identities(in: [filenameCapture, destinationCapture])
        #expect(identities.allSatisfy { if case .indistinct = $0 { true } else { false } })

        // The same two fields named by their accessibility descriptions: each is its own instance, and only the
        // taught one shows the relation, whatever their values.
        var named = filename, other = destination
        named.label = "File name"; named.labelOrigin = .description
        other.label = "Destination"; other.labelOrigin = .description
        let namedCapture = try #require(CaptureElement(named))
        let namedKey = try #require(SceneElementKey.key(of: namedCapture))
        await relations.set([relation(element: namedKey, verb: .typeText, outcome: .valueSet)])
        let distinct = await brain.enrich(scene([named, other]), state: "S")
        #expect(distinct.elements[0].does != nil)
        #expect(distinct.elements[1].does == nil)
    }

    @Test("a target matching two controls remains ambiguous even when their structural keys collide")
    func duplicateTargetsAreAmbiguous() throws {
        let first = field("first", value: "same value", x: 0.1)
        let second = field("second", value: "same value", x: 0.6)
        let sample = [try #require(CaptureElement(first)), try #require(CaptureElement(second))]
        let keys = SceneElementKey.keys(matching: "AXTextField", label: "same value", in: sample)
        #expect(keys.count != 1, "two physical candidates must not become a unique target through Set deduplication")
    }

    @Test("a qualified window shortcut must be delivered with the current scene")
    func contextShortcutIsDelivered() async throws {
        let original = scene([field("filename", value: "photo.png", x: 0.1)])
        let relations = RelationsDouble(state: "S")
        await relations.set([relation(element: nil, verb: .pressKey, arguments: "key=a;modifiers=command")])
        #expect(try await relations.relations(from: "S", in: bundle, elementKeys: [], includingContext: true).count == 1)
        let store = InMemoryBrainStore()
        let brain = BrainMemory(brains: store, applications: store, relations: relations, clock: { Fixtures.t0 })
        let enriched = await brain.enrich(original, state: "S")
        #expect(enriched != original, "a stored and exposed shortcut is silently absent from the delivered context")
        #expect(enriched.token == original.token)
    }
}
