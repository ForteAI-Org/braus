import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
#if BRAUS_PHASES
import PhaseSignposts
#endif

/// SceneTextPolicy owns model scene text and its window bases on the main actor.
/// Rendering stays concurrent; an epoch check makes a reading retry if a hold or another reading interleaves.
final class SceneTextPolicy {
    private(set) var revision = 0
    private(set) var latest: SceneAnswer?
    private(set) var staleScene: UUID?

    /// A private adapter or command changed the held application without answering a scene.
    func markStale(_ id: UUID?) {
        guard let id else { return }
        staleScene = id
        epoch += 1
        resetEpoch += 1
        seen.removeAll { $0.key.session == id }
        if latest?.window.session == id { latest = nil }
    }

    /// Retains the private section reader on the T2 committed window baseline.
    func sectionReading(_ title: String, page: Int, session: any AutomationSessionOperating) async throws -> JSONValue {
        guard let id = session.id else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_text_policy.sectionReading.v1")))
        }
        guard staleScene != id else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_text_policy.sectionReading.v1.2")))
        }
        guard let baseline = seen.last(where: { $0.key.session == id }) else {
            throw AutomationFailure(ModelText.text(.init(rawValue: "scene_text_policy.sectionReading.v1")))
        }
        let read = try await Self.section(title, page: page, of: baseline.scene)
        var values: [String: JSONValue] = [
            "revision": .number(Double(baseline.last.revision)), "session": .string(id.uuidString),
            "section": .string(read.title), "scene": .string(read.text)
        ]
        if read.pages > 1 { values["page"] = .number(Double(page)); values["pages"] = .number(Double(read.pages)) }
        return .object(values)
    }

    @concurrent
    private static func section(_ title: String, page: Int,
                                of scene: SceneSnapshot) async throws -> (title: String, text: String, pages: Int) {
        try SceneAnswerBudget.safeSection(title, page: page, of: scene, lines: scene.textLines(cuts: .safe))
    }
    private(set) var seen: [SceneWindowBaselines] = []
    private var epoch = 0
    private var resetEpoch = 0
    private var reason: SceneContextReset?
    fileprivate struct ResetWindow: Hashable {
        let key: SceneWindowKey
        let title: String?
    }

    private var answeredSinceReset: Set<ResetWindow> = []
    private static let baselineLimit = 8

    /// Drops bases the model no longer holds. A carried revision becomes a self-contained base.
    func contextHolds(_ hold: SceneContextHold) {
        epoch += 1
        resetEpoch += 1
        reason = hold.reason
        answeredSinceReset.removeAll()
        seen = seen.compactMap { baseline in
            guard hold.reason != .personHadApp else { return nil }
            var kept = baseline
            if hold.keptRevision == baseline.last.revision {
                kept.anchor = baseline.last
                kept.lastBase = nil
                kept.lastDependencies = []
            } else if !hold.contains(baseline.anchor.revision) {
                return nil
            } else if !hold.contains(baseline.last.revision)
                        || !baseline.lastDependencies.allSatisfy(hold.contains) {
                kept.last = baseline.anchor
                kept.lastBase = nil
                kept.lastDependencies = []
            }
            return kept
        }
    }

    /// Builds and applies the boundary together, before another reading can advance the revision.
    @discardableResult
    func contextHolds(after reason: SceneContextReset, keeping keptRevision: Int? = nil) -> SceneContextHold {
        let hold = SceneContextHold(firstHeldRevision: revision + 1, keptRevision: keptRevision, reason: reason)
        contextHolds(hold)
        return hold
    }

    /// Writes a model reading, then commits its revision and bases without a suspension between them.
    /// The session is captured after minimization, as in the original reader. Concurrent work is retried if its
    /// captured bases changed, so a reset never resurrects a forgotten base or yields a half-applied hold.
    func answer(
        _ scene: SceneSnapshot,
        changesOnly: Bool = false,
        nested: Bool = false,
        session: any AutomationSessionOperating,
        shown: ValueMinimization,
        aim: (section: String?, target: String?) = (nil, nil)
    ) async -> SceneAnswer {
        #if BRAUS_PHASES
        let rendering = PhaseInterval.begin("render.scene")
        defer { rendering.end() }
        #endif
        let (scene, lines) = await Self.rendered(scene, minimizing: shown, cuts: .safe)
        while true {
            let capturedEpoch = epoch
            let key = SceneWindowKey(session: session.id, windowNumber: session.observedWindowNumber,
                                     bundleID: scene.bundleID)
            let known = key.session.flatMap { id in
                seen.lastIndex { $0.shows(scene, number: key.windowNumber, in: id) }
                    ?? seen.lastIndex { $0.mayShow(scene, number: key.windowNumber, in: id) }
            }
            let baseline = known.map { seen[$0] }
            let resetWindow = ResetWindow(key: key, title: key.windowNumber == nil ? scene.windowTitle : nil)
            let resetReason = baseline == nil
                && (reason != .personHadApp || !answeredSinceReset.contains(resetWindow)) ? reason : nil
            let (answer, base) = await Self.prepared(scene, lines: lines, baseline: baseline,
                key: key, revision: revision + 1, changesOnly: changesOnly, reason: resetReason, aim: aim)
            guard capturedEpoch == epoch else { continue }
            if reason == .personHadApp { answeredSinceReset.insert(resetWindow) }
            revision = answer.revision
            if staleScene == key.session { staleScene = nil }
            epoch += 1
            if let known { seen.remove(at: known) }
            let reading = SceneWindowBaselines.Reading(revision: revision, scene: scene)
            if key.session != nil {
                let anchor: SceneWindowBaselines.Reading
                if case .whole = answer.form { anchor = reading }
                else { anchor = baseline?.anchor ?? reading }
                let dependencies: Set<Int>
                if let baseline, base == .anchor {
                    dependencies = [baseline.anchor.revision]
                } else if let baseline, base == .last {
                    dependencies = baseline.lastDependencies.union([baseline.last.revision])
                } else { dependencies = [] }
                seen.append(SceneWindowBaselines(key: key, anchor: anchor, last: reading,
                                                  lastBase: base, lastDependencies: dependencies))
                if seen.count > Self.baselineLimit { seen.removeFirst() }
            }
            if case .whole = answer.form { latest = Self.sceneForState(answer) }
            return answer
        }
    }

    /// Checkpoint preserves only successfully delivered scenes when a tool fails, without undoing a later hold.
    struct Checkpoint {
        fileprivate let seen: [SceneWindowBaselines]
        fileprivate let latest: SceneAnswer?
        fileprivate let resetEpoch: Int
        fileprivate let answeredSinceReset: Set<ResetWindow>
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(seen: seen, latest: latest, resetEpoch: resetEpoch, answeredSinceReset: answeredSinceReset)
    }

    func restore(_ checkpoint: Checkpoint) {
        guard checkpoint.resetEpoch == resetEpoch else { return }
        seen = checkpoint.seen
        latest = checkpoint.latest
        answeredSinceReset = checkpoint.answeredSinceReset
        epoch += 1
    }

    /// Task state carries the whole scene, independently of the context reset notice delivered beside it.
    nonisolated private static func sceneForState(_ answer: SceneAnswer) -> SceneAnswer {
        guard case .whole(because: .personHadApp) = answer.form else { return answer }
        let notice = ModelText.text(.init(rawValue: "scene.personHadApp")) + "\n"
        let offset = notice.utf8.count
        return SceneAnswer(revision: answer.revision, form: .whole(because: nil), window: answer.window,
            scene: answer.scene, text: String(answer.text.dropFirst(notice.count)),
            parts: answer.parts.dropFirst().map {
                SceneTextPart(source: $0.source, job: $0.job,
                              utf8: ($0.utf8.lowerBound - offset)..<($0.utf8.upperBound - offset), section: $0.section)
            })
    }

    @concurrent
    private static func rendered(
        _ scene: SceneSnapshot,
        minimizing shown: ValueMinimization,
        cuts: SceneTextCuts
    ) async -> (SceneSnapshot, [SceneSnapshot.TextLine]) {
        let scene = shown.knowsNoText ? scene : shown.minimize(scene: scene)
        return (scene, scene.textLines(cuts: cuts))
    }

    @concurrent
    private static func prepared(
        _ scene: SceneSnapshot,
        lines whole: [SceneSnapshot.TextLine],
        baseline: SceneWindowBaselines?,
        key: SceneWindowKey,
        revision: Int,
        changesOnly: Bool,
        reason: SceneContextReset?,
        aim: (section: String?, target: String?)
    ) async -> (SceneAnswer, SceneAnswer.Base?) {
        var form = SceneAnswer.Form.whole(because: reason)
        let aimed = SceneAnswerBudget.aimedTitle(in: scene, section: aim.section, target: aim.target)
        var lines = SceneAnswerBudget.lines(whole, of: scene, aimed: aimed)
        var base: SceneAnswer.Base?
        if changesOnly, let baseline {
            let requestedBase: SceneAnswer.Base = baseline.lastBase != .anchor ? .anchor : .last
            let reading = requestedBase == .anchor ? baseline.anchor : baseline.last
            let changes = SceneChanges.changes(from: reading.scene, to: scene, cuts: .safe)
            let text = changes.text(since: reading.revision)
            let changesHeader = ModelText.render(.init(rawValue: "scene.changesHeader"),
                ["revision": .revision(revision), "since": .revision(reading.revision)])
            let unchangedHeader = ModelText.render(.init(rawValue: "scene.unchangedHeader"),
                ["revision": .revision(revision), "since": .revision(reading.revision)])
            let measured = changes.isEmpty ? unchangedHeader : changesHeader + text
            let choice = SceneDifferenceRule.choose(baselines: baseline, wholeCharacters: whole.reduce(0) { $0 + $1.text.count },
                                     changes: { _ in measured.count })
            if case .changes(let since, let chosenBase) = choice, measured.count <= SceneAnswerBudget.characters {
                base = chosenBase
                form = changes.isEmpty ? .unchanged(since: since) : choice
                lines = changes.isEmpty
                    ? [.init(text, source: .braus, job: .note)] : changes.lines
                // A difference has no trailing newline in the existing tool and human envelopes.
                if !changes.isEmpty {
                    lines = trimmed(lines)
                }
                if changes.isEmpty {
                    lines = [.init(unchangedHeader, source: .braus, job: .header)]
                } else {
                    lines.insert(.init(changesHeader, source: .braus, job: .header), at: 0)
                }
            }
        }
        if case .whole(because: .personHadApp) = form {
            lines.insert(.init(ModelText.text(.init(rawValue: "scene.personHadApp")) + "\n",
                               source: .braus, job: .note), at: 0)
        }
        var offset = 0
        let parts = lines.filter { !$0.text.isEmpty }.map { line in
            let start = offset
            offset += line.text.utf8.count
            return SceneTextPart(source: line.source,
                                 job: line.job,
                                 utf8: start..<offset, section: line.section)
        }
        return (SceneAnswer(revision: revision, form: form, window: key, scene: scene,
                            text: lines.map(\.text).joined(), parts: parts), base)
    }

    nonisolated private static func trimmed(_ lines: [SceneSnapshot.TextLine]) -> [SceneSnapshot.TextLine] {
        lines.enumerated().map { index, line in
            var text = line.text
            if index == 0 { text = String(text.drop(while: { $0.isNewline })) }
            if index == lines.count - 1 { text = String(text.reversed().drop(while: { $0.isNewline }).reversed()) }
            return .init(text, source: line.source, job: line.job, section: line.section)
        }
    }
}
