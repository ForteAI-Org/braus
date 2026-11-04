@testable import AutomationMCP
@testable import AutomationRuntime
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// Exercises row delivery through the actual plan facade. A generic part may keep a mixed-app
/// version eligible, but that does not grant its concrete children access to a different app's row.
@MainActor
@Suite("Recall keeps each offered part within the row's app", .serialized)
struct RecallPartScopeTests {
    typealias P = ProcedureLearningTests
    typealias L = RecallLifecycleTests

    @Test("a generic nil-app part stays eligible without admitting its Preview child into a TextEdit row")
    func genericOfferDoesNotAdmitDifferentAppChild() async throws {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        do {
            // Real producer/qualification/storage/index; the session replaces only the applications.
            let (_, routeID) = try await L.learnPhoto(session)
            let service = RecallService.shared(for: memory)
            let source = try #require(try await memory.perform { try await $0.recall.sources([routeID]) }.first)
            let generic = try #require(source.parts.first { $0.kind == .procedure && $0.bundleID == nil && $0.isOffered })
            let preview = try #require(source.parts.first {
                $0.kind == .step && $0.bundleID == P.preview && $0.isOffered && $0.label?.contains("Choose") == true
            })
            let genericLabel = try #require(generic.label)
            let previewLabel = try #require(preview.label)

            // Keep the learned hierarchy intact. Retiring concrete children can invalidate the
            // generic parent's derived admission, so it would remove this test's positive control.
            let entries = try await service.cachedEntries()
            let indexed = Set(entries.map(\.partID))
            try #require(indexed.contains(generic.partID) && indexed.contains(preview.partID),
                         "Both independently judged parts must be genuinely indexed")

            let textEdit = "com.apple.TextEdit"
            let positive = P.tools(session, stream: "part-scope-positive", profile: SessionProfile.app.replacing(memory: .read))
            let positiveAnswer = try await positive.call("plan", .object([
                "request": .string("Recall the generic method"),
                "rows": .array([.object(["title": .string(genericLabel), "app": .string(textEdit)])]),
            ])).payload
            try #require(positiveAnswer["status"].string == "planned", "\(positiveAnswer)")
            #expect(try delivered(in: session, stream: "part-scope-positive").contains(generic.partID),
                    "The nil-app generic part remains an actual delivered positive control")
            _ = try await positive.call("end", .object(["outcome": .string("abandoned")]))

            let negative = P.tools(session, stream: "part-scope-negative", profile: SessionProfile.app.replacing(memory: .read))
            let negativeAnswer = try await negative.call("plan", .object([
                "request": .string("Recall only a method available in TextEdit"),
                "rows": .array([.object(["title": .string(previewLabel), "app": .string(textEdit)])]),
            ])).payload
            try #require(negativeAnswer["status"].string == "planned", "\(negativeAnswer)")

            // Independent preconditions: the generic slot admits this route, while the Preview
            // child's text has a score high enough to expose a route-to-part filtering mistake.
            let current = try #require(negative.openTask)
            let request = try RecallRequest(taskID: current.taskID, attemptID: current.attemptID,
                revision: current.revision, reason: .initial, remainingWork: previewLabel,
                needs: [try RecallNeed(text: previewLabel, bundleID: textEdit)])
            let prepared = try await service.prepare(request, access: negative.profile.memoryAccess,
                availableChannels: negative.dispatcher.registry.channelKeys)
            try #require(prepared.considered > 0 && prepared.eligibleRoutes.first?.contains(routeID) == true,
                         "A nil-app slot must genuinely keep this mixed route eligible for TextEdit")
            let ranked = service.ranked(prepared, need: 0, limit: entries.count)
            let childScore = try #require(ranked.first { $0.partID == preview.partID }?.score)
            let genericScore = try #require(ranked.first { $0.partID == generic.partID }?.score)
            try #require(childScore >= 0.68 && childScore > genericScore,
                         "The excluded child must exceed its own threshold and outrank the generic part: child=\(childScore), generic=\(genericScore)")

            let scores = Dictionary(uniqueKeysWithValues: ranked.map { ($0.partID, $0.score) })
            let aboveThreshold = source.parts.filter { part in
                part.isOffered && (scores[part.partID] ?? -.infinity) >= (part.kind == .step ? 0.68 : 0.60)
            }.sorted {
                let left = scores[$0.partID] ?? -.infinity
                let right = scores[$1.partID] ?? -.infinity
                return left == right ? $0.partID < $1.partID : left > right
            }
            let leading = try #require(aboveThreshold.first)
            let incompatible = Set(source.parts.filter {
                $0.bundleID != nil && $0.bundleID != textEdit
            }.map(\.partID))
            try #require(incompatible.contains(leading.partID),
                         "Without a per-part app check, the route's highest offered score must choose an incompatible concrete part: \(leading.partID), score=\(scores[leading.partID] ?? -.infinity)")

            let actual = try delivered(in: session, stream: "part-scope-negative")
            #expect(Set(actual).isDisjoint(with: incompatible),
                    "A TextEdit row must receive no concrete part from another app: \(negativeAnswer); delivered IDs: \(actual); incompatible IDs: \(incompatible)")
            _ = try await negative.call("end", .object(["outcome": .string("abandoned")]))

            // The excluded concrete method is still deliverable when the row names its actual app.
            let sameApp = P.tools(session, stream: "part-scope-same-app", profile: SessionProfile.app.replacing(memory: .read))
            let sameAppAnswer = try await sameApp.call("plan", .object([
                "request": .string("Recall a method available in Preview"),
                "rows": .array([.object(["title": .string(previewLabel), "app": .string(P.preview)])]),
            ])).payload
            try #require(sameAppAnswer["status"].string == "planned", "\(sameAppAnswer)")
            let sameAppDelivered = try delivered(in: session, stream: "part-scope-same-app")
            let previewParts = Set(source.parts.filter { $0.bundleID == P.preview }.map(\.partID))
            #expect(!Set(sameAppDelivered).isDisjoint(with: previewParts),
                    "The same real method must reach a row in its app: \(sameAppAnswer); delivered IDs: \(sameAppDelivered)")
            _ = try await sameApp.call("end", .object(["outcome": .string("abandoned")]))
        } catch {
            await L.close(session)
            throw error
        }
        await L.close(session)
    }

    /// Reads the exact parts that survived the real plan's shared rendering budget and were recorded delivered.
    private func delivered(in session: LearningSession, stream: String) throws -> [String] {
        try P.rows("""
            SELECT p.part_uuid FROM memory_recall_calibration c
            JOIN memory_procedure_parts p ON p.part_id = c.part_id
            JOIN memory_recall_queries q ON q.query_id = c.query_id
            WHERE q.source_stream_id = '\(stream)' AND c.delivered = 1 ORDER BY p.part_uuid
            """, in: session)
    }
}
