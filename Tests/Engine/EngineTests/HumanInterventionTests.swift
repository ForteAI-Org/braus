import Engine
import Testing

@Suite("Human intervention lifecycle")
struct HumanInterventionTests {

    private typealias Session = HumanIntervention<String, String>

    @Test func findingBytesShareThePayloadBudgetAndRefusalPreservesTheLease() async throws {
        let session = try session()
        try await session.record("action", retainedBytes: 40)
        let item = try #require(await session.next())
        await #expect(throws: Session.Failure.capacityExceeded) {
            try await session.complete(item, with: "too large", retainedBytes: 61)
        }
        #expect(await session.status().phase == .collecting)
        #expect(await session.status().analyzedCount == 0)
        try await session.complete(item, with: "compressed", retainedBytes: 30)
        #expect(await session.status().retainedBytes == 70)
        let revision = try await session.endInput()
        await #expect(throws: Session.Failure.capacityExceeded) {
            try await session.beginReview(revision, finalState: "too large", retainedBytes: 31)
        }
        #expect(await session.status().phase == .reconstructing)
        _ = try await session.beginReview(revision, finalState: "final", retainedBytes: 30)
        #expect(await session.status().retainedBytes == 100)
        try await session.resolve(revision, as: .resume)
        #expect(await session.status().retainedBytes == 100)
        await session.finishResumedTurn()
        #expect(await session.status().retainedBytes == 0)
    }

    @Test func emptyInputCanHaveAnExplicitFinalStateReview() async throws {
        let session = try session()
        let revision = try await session.endInput()
        let review = try await session.beginReview(revision, finalState: "current window", retainedBytes: 10)
        #expect(review.payloads.isEmpty)
        #expect(review.findings.isEmpty)
        #expect(await session.status().phase == .evaluating)
    }

    private func session() throws -> Session {
        try Session(
            maximumEvents       : 4,
            maximumRetainedBytes: 100
        )
    }

    @Test
    func movementDoesNotStartAnIntervention() async throws {
        let session = try session()
        await session.noteActivity()
        let status = await session.status()
        #expect(status.phase == .observing)
        #expect(status.allowsAgentInput)
        #expect(status.recordedCount == 0)
    }

    @Test
    func theFirstInputBlocksTheAgentAndKeepsItsHistoricalPayload() async throws {
        let session = try session()
        let sequence = try await session.record(
            "Save at (20, 30), frame A",
            retainedBytes: 20
        )
        #expect(sequence == 1)
        let status = await session.status()
        #expect(status.phase == .collecting)
        #expect(!status.allowsAgentInput)
        let item = try #require(await session.next())
        #expect(item.payload == "Save at (20, 30), frame A")
        #expect(item.sequence == 1)
    }

    @Test
    func producersCanAppendWhileTheOnlyConsumerHoldsAnEvent() async throws {
        let session = try session()
        try await session.record(
            "first frame",
            retainedBytes: 10
        )
        let first = try #require(await session.next())
        try await session.record(
            "second frame",
            retainedBytes: 20
        )
        #expect(await session.next() == nil)
        try await session.complete(
            first,
            with: "opened menu"
        )
        let second = try #require(await session.next())
        #expect(second.sequence == 2)
        #expect(second.payload == "second frame")
        try await session.complete(
            second,
            with: "selected PDF"
        )
        #expect(await session.next() == nil)
        let revision = try await session.endInput()
        let review = try await session.beginReview(
            revision,
            finalState: "PDF selected"
        )
        #expect(review.payloads == ["first frame", "second frame"])
        #expect(review.findings == ["opened menu", "selected PDF"])
        #expect(review.finalState == "PDF selected")
        #expect(!(await session.status()).allowsAgentInput)
    }

    @Test
    func aDrainedQueueDoesNotEndTheHumanIntervention() async throws {
        let session = try session()
        try await session.record(
            "click",
            retainedBytes: 10
        )
        let item = try #require(await session.next())
        try await session.complete(
            item,
            with: "no verified effect"
        )
        let status = await session.status()
        #expect(status.phase == .collecting)
        #expect(status.analyzedCount == 1)
        #expect(!status.allowsAgentInput)
    }

    @Test
    func reviewRequiresEveryInputToBeReconstructed() async throws {
        let session = try session()
        try await session.record(
            "click",
            retainedBytes: 10
        )
        let revision = try await session.endInput()
        await #expect(throws: Session.Failure.analysisPending) {
            try await session.beginReview(
                revision,
                finalState: "too early"
            )
        }
        #expect(!(await session.status()).allowsAgentInput)
        let item = try #require(await session.next())
        try await session.complete(
            item,
            with: "opened dialog"
        )
        let review = try await session.beginReview(
            revision,
            finalState: "dialog visible"
        )
        #expect(review.findings == ["opened dialog"])
    }

    @Test
    func inputDuringReconstructionKeepsTheEpisodeAndInvalidatesItsBoundary() async throws {
        let session = try session()
        try await session.record(
            "first",
            retainedBytes: 10
        )
        let first = try #require(await session.next())
        let old = try await session.endInput()
        try await session.record(
            "second",
            retainedBytes: 10
        )
        try await session.complete(
            first,
            with: "first effect"
        )
        await #expect(throws: Session.Failure.staleRevision) {
            try await session.beginReview(
                old,
                finalState: "old state"
            )
        }
        let second = try #require(await session.next())
        try await session.complete(
            second,
            with: "second effect"
        )
        let current = try await session.endInput()
        let review = try await session.beginReview(
            current,
            finalState: "current state"
        )
        #expect(review.findings == ["first effect", "second effect"])
    }

    @Test
    func activityDuringReviewInvalidatesResumeEvenWithoutAnotherClick() async throws {
        let session = try session()
        let review = try await readyReview(session)
        await session.noteActivity()
        await #expect(throws: Session.Failure.staleRevision) {
            try await session.resolve(
                review.revision,
                as: .resume
            )
        }
        let status = await session.status()
        #expect(status.phase == .collecting)
        #expect(status.recordedCount == 1)
        #expect(!status.allowsAgentInput)
    }

    @Test
    func inputDuringEvaluationInvalidatesTheOldAgentDecision() async throws {
        let session = try session()
        let old = try await readyReview(session)
        try await session.record(
            "another click",
            retainedBytes: 10
        )
        await #expect(throws: Session.Failure.staleRevision) {
            try await session.resolve(
                old.revision,
                as: .resume
            )
        }
        #expect(!(await session.status()).allowsAgentInput)
    }

    @Test
    func clarificationKeepsTheBlockAndResumeRetainsHistoryUntilTheTurnEnds() async throws {
        let session = try session()
        let review = try await readyReview(session)
        try await session.resolve(
            review.revision,
            as: .needsClarification
        )
        let waiting = await session.status()
        #expect(waiting.phase == .awaitingClarification)
        #expect(!waiting.allowsAgentInput)
        #expect(waiting.retainedBytes == 10)
        try await session.resolve(
            review.revision,
            as: .resume
        )
        let resumed = await session.status()
        #expect(resumed.phase == .resumed)
        #expect(resumed.allowsAgentInput)
        #expect(resumed.retainedBytes == 10)
        #expect(resumed.recordedCount == 1)
        #expect(resumed.analyzedCount == 1)
        #expect(review.payloads == ["frame"])
        await session.finishResumedTurn()
        await session.finishResumedTurn()
        let finished = await session.status()
        #expect(finished.phase == .resumed)
        #expect(finished.allowsAgentInput)
        #expect(finished.retainedBytes == 0)
        #expect(finished.recordedCount == 0)
        #expect(finished.analyzedCount == 0)
        await #expect(throws: Session.Failure.invalidPhase) {
            try await session.record("next episode", retainedBytes: 10)
        }
    }

    @Test
    func finishingBeforeResumePreservesHistoryAndTheReview() async throws {
        let session = try session()
        let review = try await readyReview(session)
        await session.finishResumedTurn()
        #expect(await session.status().retainedBytes == 10)
        #expect(await session.status().recordedCount == 1)
        #expect(await session.status().phase == .evaluating)
        try await session.resolve(review.revision, as: .resume)
        #expect(await session.status().retainedBytes == 10)
    }

    @Test
    func closingAfterResumeReleasesHistoryAndInvalidatesTheReview() async throws {
        let session = try session()
        let review = try await readyReview(session)
        try await session.resolve(review.revision, as: .resume)
        await session.close()
        await session.finishResumedTurn()
        let closed = await session.status()
        #expect(closed.phase == .closed)
        #expect(closed.recordedCount == 0)
        #expect(closed.analyzedCount == 0)
        #expect(closed.retainedBytes == 0)
        #expect(!closed.allowsAgentInput)
        await #expect(throws: Session.Failure.staleRevision) {
            try await session.resolve(review.revision, as: .resume)
        }
    }

    @Test
    func taskCompletionDoesNotAuthorizeMoreAgentActions() async throws {
        let session = try session()
        let review = try await readyReview(session)
        try await session.resolve(
            review.revision,
            as: .taskCompleted
        )
        let status = await session.status()
        #expect(status.phase == .taskCompleted)
        #expect(!status.allowsAgentInput)
        #expect(status.retainedBytes == 0)
    }

    @Test
    func duplicateAndForeignAnalysisCompletionsAreRefused() async throws {
        let firstSession = try session()
        let secondSession = try session()
        try await firstSession.record(
            "first",
            retainedBytes: 10
        )
        try await secondSession.record(
            "second",
            retainedBytes: 10
        )
        let first = try #require(await firstSession.next())
        let second = try #require(await secondSession.next())
        await #expect(throws: Session.Failure.invalidWorkItem) {
            try await secondSession.complete(
                first,
                with: "wrong effect"
            )
        }
        try await secondSession.complete(
            second,
            with: "right effect"
        )
        await #expect(throws: Session.Failure.invalidWorkItem) {
            try await secondSession.complete(
                second,
                with: "duplicate"
            )
        }
        #expect((await secondSession.status()).analyzedCount == 1)
    }

    @Test
    func anotherSessionsReviewCannotResumeThisSession() async throws {
        let first = try session()
        let second = try session()
        let foreign = try await readyReview(first)
        _ = try await readyReview(second)
        await #expect(throws: Session.Failure.staleRevision) {
            try await second.resolve(
                foreign.revision,
                as: .resume
            )
        }
        #expect(!(await second.status()).allowsAgentInput)
    }

    @Test
    func capacityExhaustionBlocksInsteadOfDroppingHistory() async throws {
        let session = try Session(
            maximumEvents       : 1,
            maximumRetainedBytes: 20
        )
        try await session.record(
            "first",
            retainedBytes: 10
        )
        let item = try #require(await session.next())
        try await session.complete(
            item,
            with: "first effect"
        )
        await #expect(throws: Session.Failure.capacityExceeded) {
            try await session.record(
                "would be lost",
                retainedBytes: 10
            )
        }
        let status = await session.status()
        #expect(status.phase == .blocked)
        #expect(status.recordedCount == 1)
        #expect(status.analyzedCount == 1)
        #expect(!status.allowsAgentInput)
        await #expect(throws: Session.Failure.invalidPhase) {
            try await session.endInput()
        }
    }

    @Test
    func byteCapacityIsCheckedWithoutIntegerOverflow() async throws {
        let session = try session()
        try await session.record(
            "first",
            retainedBytes: 10
        )
        await #expect(throws: Session.Failure.capacityExceeded) {
            try await session.record(
                "huge frame",
                retainedBytes: Int.max
            )
        }
        #expect((await session.status()).retainedBytes == 10)
        #expect((await session.status()).phase == .blocked)
    }

    @Test
    func invalidCostsAndLimitsAreRefusedWithoutStartingAnEpisode() async throws {
        #expect(throws: Session.Failure.invalidLimit) {
            try Session(
                maximumEvents       : 0,
                maximumRetainedBytes: 10
            )
        }
        let session = try session()
        await #expect(throws: Session.Failure.invalidCost) {
            try await session.record(
                "invalid",
                retainedBytes: -1
            )
        }
        #expect((await session.status()).phase == .observing)
    }

    @Test
    func aFailedConsumerCannotProduceAPartialSuccess() async throws {
        let session = try session()
        try await session.record(
            "unreadable frame",
            retainedBytes: 10
        )
        let item = try #require(await session.next())
        try await session.fail(item)
        let status = await session.status()
        #expect(status.phase == .blocked)
        #expect(!status.allowsAgentInput)
        #expect(await session.next() == nil)
        await #expect(throws: Session.Failure.invalidPhase) {
            try await session.endInput()
        }
    }

    @Test
    func closingInvalidatesPendingWorkAndReleasesStorageWithoutResuming() async throws {
        let session = try session()
        try await session.record(
            "frame",
            retainedBytes: 10
        )
        let item = try #require(await session.next())
        await session.close()
        await #expect(throws: Session.Failure.invalidWorkItem) {
            try await session.complete(
                item,
                with: "late result"
            )
        }
        let status = await session.status()
        #expect(status.phase == .closed)
        #expect(status.retainedBytes == 0)
        #expect(!status.allowsAgentInput)
        await #expect(throws: Session.Failure.invalidPhase) {
            try await session.record(
                "late input",
                retainedBytes: 10
            )
        }
    }

    private func readyReview(_ session: Session) async throws -> Session.Review {
        try await session.record(
            "frame",
            retainedBytes: 10
        )
        let item = try #require(await session.next())
        try await session.complete(
            item,
            with: "observed effect"
        )
        let revision = try await session.endInput()
        return try await session.beginReview(
            revision,
            finalState: "current scene"
        )
    }
}
