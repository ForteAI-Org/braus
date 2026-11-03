import AutomationRuntime
import Foundation
import Testing
import Turn

@MainActor
@Suite("Person episode lifetime", .serialized)
struct DB2DPersonEpisodeTests {
    @Test func releasedRunnerClosesItsPersonEpisode() throws {
        let before = MemoryService.PersonEpisodes.anyOpen
        var runner: TurnRunner? = testTurnRunner(host: TestTurnHost(), root: try testTurnRoot())
        weak var retained = runner
        _ = try runner?.suspend()
        #expect(MemoryService.PersonEpisodes.anyOpen)
        runner = nil
        #expect(retained == nil)
        #expect(MemoryService.PersonEpisodes.anyOpen == before)
    }

    @Test func everyReleasePathClosesAdmission() async throws {
        for release in ["end", "stop", "retire", "close"] {
            let runner = testTurnRunner(host: TestTurnHost(), root: try testTurnRoot())
            let before = MemoryService.PersonEpisodes.anyOpen
            let token = try runner.suspend()
            #expect(MemoryService.PersonEpisodes.anyOpen)
            #expect(try runner.suspend() == token)
            switch release {
            case "end": try runner.end(token)
            case "stop": runner.stop(marksTaskInterrupted: false); await runner.waitForCleanup()
            case "retire": await runner.retire()
            default: try await runner.close()
            }
            #expect(MemoryService.PersonEpisodes.anyOpen == before)
            try await runner.close()
        }
    }
}
