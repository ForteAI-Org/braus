import AutomationRuntime
import EngineCore
import PerceptionCore
import Testing

@MainActor
@Suite("Independent D2 review: cancellation during initial native perception", .serialized)
struct D2BeforePerceptionCancellationReviewTests {
    @Test("cancellation of the initial perception must propagate before the command can dispatch a gesture")
    func cancellationBeforeDispatch() async throws {
        var commandEntered = false
        do {
            _ = try await PerceivedCommand.perform(bundleID: "com.example.Review", recorder: nil,
                                                  perceive: { throw CancellationError() }) { _ in
                commandEntered = true
                return ActOutcome(.foundActed, "simulated command dispatched")
            }
            Issue.record("the cancellation was swallowed and the command returned normally")
        } catch is CancellationError {
            // Expected: cancellation before dispatch.
        } catch {
            Issue.record("the cancellation was replaced by another error: \(error)")
        }
        #expect(!commandEntered, "the initial perception was cancelled, but the native command still ran")
    }
    @Test("a task cancelled while its initial perception checks cancellation must dispatch no command")
    func cancelledTaskBeforeDispatch() async {
        let result = await Task { @MainActor in
            var commandEntered = false
            var cancelledReachedCaller = false
            do {
                _ = try await PerceivedCommand.perform(bundleID: "com.example.Review", recorder: nil,
                                                      perceive: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                    return LearningSession.perceived(ProcedureLearningTests.Preview.export, of: "com.example.Review")
                }) { _ in
                    commandEntered = true
                    return ActOutcome(.foundActed, "simulated command dispatched")
                }
            } catch is CancellationError {
                cancelledReachedCaller = true
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            return (commandEntered, cancelledReachedCaller)
        }.value
        #expect(!result.0, "a genuinely cancelled task still entered the native command")
        #expect(result.1, "the caller did not receive cancellation")
    }

    @Test("a task cancelled during a perception that returns normally must also dispatch no command")
    func cancellationFlagBeforeDispatch() async {
        let result = await Task { @MainActor in
            var commandEntered = false
            var cancelledReachedCaller = false
            do {
                _ = try await PerceivedCommand.perform(bundleID: "com.example.Review", recorder: nil,
                                                      perceive: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return LearningSession.perceived(ProcedureLearningTests.Preview.export, of: "com.example.Review")
                }) { _ in
                    commandEntered = true
                    return ActOutcome(.foundActed, "simulated command dispatched")
                }
            } catch is CancellationError {
                cancelledReachedCaller = true
            } catch {
                Issue.record("unexpected error: \(error)")
            }
            return (commandEntered, cancelledReachedCaller)
        }.value
        #expect(!result.0, "a cancelled task still entered the command after perception returned")
        #expect(result.1, "the cancellation flag was ignored")
    }

    @Test("an ordinary missing initial perception retains the existing policy and can run the command")
    func ordinaryMissingPerception() async throws {
        struct MissingPerception: Error {}
        var commandEntered = false
        _ = try await PerceivedCommand.perform(bundleID: "com.example.Review", recorder: nil,
                                              perceive: { throw MissingPerception() }) { _ in
            commandEntered = true
            return ActOutcome(.foundActed, "simulated command dispatched")
        }
        #expect(commandEntered)
    }
}
