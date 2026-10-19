//
//  AdapterApprovals.swift
//  Braus
//

import AppAdapters
import Foundation
import Observation

/// AdapterApprovals holds the irreversible adapter calls waiting for the person's yes or no (`AdapterApprover`), one
/// confirmation per call, in the order they were asked.
///
/// The team window shows the first one (`AdapterApprovalSheet`); the sheet answers through `respond`, which ignores
/// answers for `answerDelay` after a request appears, so a key or a click meant for something else cannot answer it.
/// `answer` resolves a request at once with the person's answer. A request nobody answers within `timeout` is
/// refused, so a call from an external client while no window is open cannot wait forever; a cancelled wait and
/// quitting refuse it too. A refusal does nothing.
///
/// Isolation: main actor, as the window that shows it.
@MainActor
@Observable
final class AdapterApprovals {

    /// Pending is one call waiting for an answer.
    struct Pending: Identifiable, Equatable {
        let id     : UUID
        let consent: AdapterConsent
    }

    /// How long a request waits before it is refused.
    static let timeout: Duration = .seconds(120)

    /// How long a request shown ignores the person's answers after it appears. One second.
    static let answerDelay: Duration = .seconds(1)

    /// The requests waiting, oldest first; the sheet shows the first.
    private(set) var pending: [Pending] = []

    /// When the first request became the one shown; nil while none waits.
    private(set) var shownAt: ContinuousClock.Instant?

    @ObservationIgnored
    private var answers: [UUID: CheckedContinuation<Bool, Never>] = [:]

    private let timeout    : Duration
    private let answerDelay: Duration

    @ObservationIgnored
    private let now: @MainActor () -> ContinuousClock.Instant

    /// `now` reads the clock answers are timed with; tests pass their own.
    init(
        timeout    : Duration = AdapterApprovals.timeout,
        answerDelay: Duration = AdapterApprovals.answerDelay,
        now        : @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.timeout     = timeout
        self.answerDelay = answerDelay
        self.now         = now
    }

    /// Waits for the person's answer to `consent`: true only when they allowed it; false after `timeout` or when
    /// the waiting task is cancelled.
    func ask(_ consent: AdapterConsent) async -> Bool {
        let id = UUID()
        let deadline = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.answer(
                id,
                allowed: false
            )
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                answers[id] = continuation
                pending.append(Pending(
                    id     : id,
                    consent: consent
                ))
                if pending.count == 1 { shownAt = now() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answer(
                    id,
                    allowed: false
                )
            }
        }
    }

    /// Answers the request `id`; an id already answered is ignored.
    func answer(
        _ id   : UUID,
        allowed: Bool
    ) {
        guard let continuation = answers.removeValue(forKey: id) else { return }
        let wasShown = pending.first?.id == id
        pending.removeAll { $0.id == id }
        if wasShown { shownAt = pending.isEmpty ? nil : now() }
        continuation.resume(returning: allowed)
    }

    /// When the person's answers to `id` start to count: `answerDelay` after it became the request shown;
    /// nil while it is not the one shown.
    func answerableAt(_ id: UUID) -> ContinuousClock.Instant? {
        guard pending.first?.id == id, let shownAt else { return nil }
        return shownAt.advanced(by: answerDelay)
    }

    /// Answers the request shown, as the sheet's buttons and keys do; ignored while `id` is not the request
    /// shown, or before `answerableAt`.
    func respond(
        _ id   : UUID,
        allowed: Bool
    ) {
        guard let answerableAt = answerableAt(id), now() >= answerableAt else { return }
        answer(
            id,
            allowed: allowed
        )
    }

    /// Refuses every waiting request, as when the app quits.
    func refuseAll() {
        for id in answers.keys {
            answer(
                id,
                allowed: false
            )
        }
    }
}
