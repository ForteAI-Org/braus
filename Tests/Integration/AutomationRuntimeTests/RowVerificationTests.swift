import Foundation
import AutomationRuntime
import EngineCore
import Memory
import Testing
@testable import AutomationMCP

struct RowVerificationTests {
    typealias C = TaskResultCheck

    @Test func aPreviousRowsWriteDoesNotProveThisRow() {
        let facts = C.FileFacts(exists: true, modifiedAtMS: 9_000, digest: "old")
        let expected = C.Expectation.fileWritten(path: "/output")
        #expect(C.judge(expected, attemptID: "a", openedAtMS: 10_000,
                        before: facts, now: facts, window: .row).verdict == .failed)
        #expect(C.judge(expected, attemptID: "a", openedAtMS: 10_000,
                        before: nil, now: facts, window: .row).verdict == .unknown)
        #expect(C.judge(expected, attemptID: "a", openedAtMS: 10_000,
                        before: nil, now: facts).verdict == .passed)
    }

    @Test func rowWritesNeedTheirOwnEvidence() {
        let old = C.FileFacts(exists: true, modifiedAtMS: 1_000, digest: "old")
        let new = C.FileFacts(exists: true, modifiedAtMS: 1_000, digest: "new")
        for expected in [C.Expectation.fileWritten(path: "/a"), .fileChanged(path: "/a")] {
            #expect(C.judge(expected, attemptID: "a", openedAtMS: 10_000,
                            before: old, now: new, window: .row).verdict == .passed)
            #expect(C.judge(expected, attemptID: "a", openedAtMS: 10_000,
                            before: old, now: old, window: .row).verdict == .failed)
        }
        #expect(C.judge(.fileWritten(path: "/a"), attemptID: "a", openedAtMS: 10_000,
                        before: .missing, now: new, window: .row).verdict == .passed)
    }

    @Test func baselineDependentPredicatesStayUnknown() {
        let source = C.FileFacts(exists: true, digest: "same")
        for expected in [C.Expectation.fileMoved(from: "/a", to: "/b"), .fileCopied(from: "/a", to: "/b"),
                         .fileUnchanged(path: "/a"), .fileChanged(path: "/a"), .noOtherFiles(folder: "/", named: [])] {
            #expect(C.judge(expected, attemptID: "a", openedAtMS: 10_000,
                            before: nil, now: source, other: source, window: .row).verdict == .unknown)
        }
        #expect(C.judge(.fileMoved(from: "/a", to: "/b"), attemptID: "a", openedAtMS: 10_000,
                        before: source, now: .missing, other: source, window: .row).verdict == .passed)
        #expect(C.judge(.noOtherFiles(folder: "/", named: []), attemptID: "a", openedAtMS: 10_000,
                        before: .init(exists: true, listing: []), now: .init(exists: true, listing: ["stray"]),
                        window: .row).verdict == .failed)
    }
}

@MainActor
struct RowVerificationRuntimeTests {
    @Test func subprocedureExpectationIsCheckedAtRowBoundary() async throws {
        let directory = URL.temporaryDirectory.appending(path: "es8-row-\(UUID().uuidString)")
        let session = LearningSession(directory: directory)
        session.windows["test.app"] = .init(elements: [LearningSession.button("Export")])
        _ = try await session.open(application: "test.app", window: nil)
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Export", status: .inProgress,
            expected: .element(app: nil, label: "Export", expect: .present))
        handler.todo = Todo(taskID: "t", revision: 1, rows: [row])
        let expected = try #require(row.expected)
        handler.rowChecks[row.id] = .init(read: expected, kept: expected)
        #expect(handler.currentRowExpectations == [expected])
        let memory = MemoryService.shared(for: directory)
        let task = OpenTask(taskID: "t", attemptID: "a", revision: 1)
        let owner = try TaskProducer(source: .app, streamID: "test")
        #expect(try await handler.rowVerdict(row, task: task, owner: owner, memory: memory) == .passed)
        session.windows["test.app"] = .init(elements: [])
        #expect(try await handler.rowVerdict(row, task: task, owner: owner, memory: memory) == .failed)
        session.windows.removeAll()
        #expect(try await handler.rowVerdict(row, task: task, owner: owner, memory: memory) == .unknown)
        #expect(session.gestures.isEmpty)
        await memory.close()
    }
    @Test func eachOpeningReadsItsOwnFileBaseline() async throws {
        let directory = URL.temporaryDirectory.appending(path: "es8-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record(error) }
        }
        let file = directory.appending(path: "output.txt")
        try Data("first".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 9)], ofItemAtPath: file.path)
        let session = LearningSession(directory: directory.appending(path: "archive"))
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        let expected = TaskResultCheck.Expectation.fileWritten(path: file.path)
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Write", status: .inProgress, expected: expected)
        let next = TodoRow(id: .init(rawValue: "r2"), title: "Write again", status: .inProgress, expected: expected)
        let memory = MemoryService.shared(for: session.directory)
        let task = OpenTask(taskID: "t", attemptID: "a", revision: 1)
        let owner = try TaskProducer(source: .app, streamID: "test")
        handler.rowOpenings[row.id] = await handler.readRowOpening(row, at: 10_000)
        #expect(try await handler.rowVerdict(row, task: task, owner: owner, memory: memory) == .failed)
        try Data("second".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 11)], ofItemAtPath: file.path)
        #expect(try await handler.rowVerdict(row, task: task, owner: owner, memory: memory) == .passed)
        handler.rowOpenings[next.id] = await handler.readRowOpening(next, at: 12_000)
        #expect(try await handler.rowVerdict(next, task: task, owner: owner, memory: memory) == .failed)
        handler.rowOpenings.removeValue(forKey: next.id)
        handler.rowExpectationTimes[next.id] = 12_000
        #expect(try await handler.rowVerdict(next, task: task, owner: owner, memory: memory) == .unknown)
        #expect(session.gestures.isEmpty)
        await memory.close()
    }

}

extension RowVerificationRuntimeTests {
    @Test func memoryReadFailureLeavesRowUnknown() async throws {
        let directory = URL.temporaryDirectory.appending(path: "row-read-" + UUID().uuidString)
        let session = LearningSession(directory: directory)
        let secrets = ProducerSecrets()
        let sceneText = SceneTextPolicy()
        let formatter = ResultFormatter(session: session, secrets: secrets, sceneText: sceneText)
        let handler = TaskCycleHandler(session: session, secrets: secrets, formatter: formatter)
        let memory = MemoryService.shared(for: directory)
        await memory.close()
        let row = TodoRow(id: .init(rawValue: "r1"), title: "Write", status: .inProgress,
            expected: .fileWritten(path: "/missing-output"))
        #expect(try await handler.rowVerdict(row, task: OpenTask(taskID: "t", attemptID: "a", revision: 1),
            owner: TaskProducer(source: .app, streamID: "test"), memory: memory) == .unknown)
        #expect(handler.stoppedTaskNotice?.contains("Row expectation could not be read") == true)
        withExtendedLifetime((secrets, sceneText, formatter)) {}
    }
}
