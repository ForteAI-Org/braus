#if DEBUG
import CoreGraphics
import Engine
import Foundation
import InteractionListener
import PerceptionCore
import Synchronization
import Testing
@testable import SeatBroker

@Suite struct PersonReplayTests {
    @Test(arguments: [false, true])
    func debugReplayHasNoPersonValue(useOwnerPolicy: Bool) async throws {
        let personal = "PersonReplayUniqueSentinel"
        let secret = "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890"
        let scene = SceneSnapshot(bundleID: "test", appName: personal, windowTitle: personal,
            viewportPixelSize: .init(width: 800, height: 600), elements: [
                .init(id: "field", kind: .control, label: personal,
                      bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXTextField", value: personal)
            ])
        var finding = try HumanSceneFinding(sequence: 1, kind: .keyframe,
            text: "Typed \(personal) \(secret)", readMilliseconds: 1, scenes: [7: scene], initialScenes: [7: scene])
        finding.recordedAction = .init(kind: .typing, processID: 1, windowNumber: 7,
            windowTitle: personal, role: "AXTextField", label: personal, isProtected: false,
            destination: personal, commandName: secret, lostCritical: 0)
        let intervention = try HumanInterventionConsumer.Intervention(maximumEvents: 10, maximumRetainedBytes: 100_000)
        let payload = HumanRecordedInteraction(event: .init(kind: .typing, timestamp: Date(), startedAt: 1,
            endedAt: 2, precedingRevision: 0, revision: 1, point: .zero, window: nil, processID: 1),
            element: nil, endElement: nil, commandName: nil, picture: nil)
        _ = try await intervention.record(payload, retainedBytes: payload.retainedBytes)
        let work = try #require(await intervention.next())
        try await intervention.complete(work, with: finding)
        let revision = try await intervention.endInput()
        let review = try await intervention.beginReview(revision, finalState: finding)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await HumanInterventionReplay.write(review, embeddingModel: useOwnerPolicy ? personal : "model@1", to: path,
            withholding: { useOwnerPolicy ? $0.replacingOccurrences(of: personal, with: "[withheld]") : $0 })
        let archive = try await HumanInterventionReplay.read(path)
        #expect(archive.findings.count == 1)
        #expect(try archive.findings.first?.text().contains(personal) == false)
        let restored = archive.finalState
        #expect(restored.kind == .keyframe)
        #expect(try restored.sceneEvidence().scenes.count == 1)
        #expect(restored.recordedAction != nil)
        let all = try restored.text() + String(decoding: JSONEncoder().encode(restored.sceneEvidence()), as: UTF8.self)
            + String(decoding: JSONEncoder().encode(restored.recordedAction), as: UTF8.self)
        #expect(!all.contains(personal))
        #expect(!all.contains(secret))
        #expect(!String(decoding: try Data(contentsOf: path.appendingPathComponent("review.json")), as: UTF8.self).contains(personal))
    }

    @Test
    @MainActor
    func replayProcessingRunsOffMainActor() async throws {
        let finding = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "Folder A", readMilliseconds: 1)
        let intervention = try HumanInterventionConsumer.Intervention(maximumEvents: 10, maximumRetainedBytes: 100_000)
        let revision = try await intervention.endInput()
        let review = try await intervention.beginReview(revision, finalState: finding)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { do { try FileManager.default.removeItem(at: path) } catch { Issue.record(error) } }
        let calls = Mutex(0)
        try await HumanInterventionReplay.write(review, to: path, withholding: { text in
            #expect(Thread.isMainThread)
            return text
        }, processing: {
            calls.withLock { $0 += 1 }
            #expect(!Thread.isMainThread)
        })
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func unreadableFindingIsCountedWithoutRetainingItsPayload() async throws {
        let finding = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "CorruptPersonSentinel",
                                            readMilliseconds: 1)
        let encoded = try JSONEncoder().encode(finding)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["compressed"] = Data("invalid compressed bytes".utf8).base64EncodedString()
        let corrupted = try JSONDecoder().decode(HumanSceneFinding.self,
            from: JSONSerialization.data(withJSONObject: object))
        let intervention = try HumanInterventionConsumer.Intervention(maximumEvents: 10, maximumRetainedBytes: 100_000)
        let revision = try await intervention.endInput()
        let review = try await intervention.beginReview(revision, finalState: corrupted)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try await HumanInterventionReplay.write(review, to: path)
        let archive = try await HumanInterventionReplay.read(path)
        #expect(archive.finalState.kind == .failed)
        #expect(try archive.finalState.text().isEmpty)
        let manifest = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: path.appendingPathComponent("review.json"))) as? [String: Any])
        #expect(manifest["omittedFindingCount"] as? Int == 1)
    }

}
#endif
