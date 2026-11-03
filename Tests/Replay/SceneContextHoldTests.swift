import EngineCore
import Foundation
import Memory
import PerceptionCore
import Switches
import Testing
@testable import AutomationMCP

@MainActor
struct SceneContextHoldTests {
    @Test func compactionDropsOldBasesAndKeepsOneExplicitRevision() async {
        let policy = SceneTextPolicy()
        let session = Self.session()
        let first = await policy.answer(Self.scene(), session: session, shown: ValueMinimization())
        let hold = policy.contextHolds(after: .compaction, keeping: first.revision)
        #expect(hold.firstHeldRevision == first.revision + 1)
        let kept = await policy.answer(Self.scene(1), changesOnly: true, session: session, shown: ValueMinimization())
        #expect(kept.form == .changes(since: first.revision, base: .last))
        let dropped = policy.contextHolds(after: .compaction)
        #expect(dropped.firstHeldRevision == policy.revision + 1)
        let whole = await policy.answer(Self.scene(2), changesOnly: true, session: session, shown: ValueMinimization())
        #expect(whole.form == .whole(because: .compaction))
    }

    @Test func personHadAppAppliesOnceToEveryWindow() async {
        let policy = SceneTextPolicy()
        let session = Self.session()
        _ = await policy.answer(Self.scene(), session: session, shown: ValueMinimization())
        policy.contextHolds(after: .personHadApp)
        for number in [1, 2] {
            session.observedWindowNumber = number
            let first = await policy.answer(Self.scene(), changesOnly: true, session: session, shown: ValueMinimization())
            #expect(first.form == .whole(because: .personHadApp))
            #expect(first.text.hasPrefix("Whole scene: the person used the application since your last reading.\n"))
            let second = await policy.answer(Self.scene(1), changesOnly: true, session: session, shown: ValueMinimization())
            #expect(second.form == .changes(since: first.revision, base: .last))
            #expect(policy.latest?.revision == first.revision)
            #expect(policy.latest?.text.contains("the person used") == false)
            let whole = await policy.answer(Self.scene(2), session: session, shown: ValueMinimization())
            #expect(whole.form == .whole(because: nil))
            #expect(!whole.text.contains("the person used"))
        }
    }

    static func session() -> ReplaySession {
        let session = ReplaySession()
        session.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        session.observedWindowNumber = 1
        return session
    }

    static func scene(_ value: Int = 0) -> SceneSnapshot {
        SceneSnapshot(bundleID: "test.scene", appName: "Example", windowTitle: "Document",
            viewportPixelSize: .init(width: 1000, height: 800),
            elements: (0..<30).map { index in
                SceneElement(id: "row\(index)", kind: .control, label: "Setting \(index)",
                    bounds: .init(x: 0.1, y: Double(index) / 40, width: 0.4, height: 0.02),
                    value: index == 0 ? String(value) : nil, section: "Content")
            }, outOfViewFields: [.init(label: "Other", value: "é🙂", role: "AXTextField")],
            sections: [.init(name: "Content", bounds: .init(x: 0, y: 0, width: 1, height: 1))],
            commands: ["File > Open"])
    }
}

@MainActor
struct HybridRuleTests {
    @Test func alternatesAnchorAndLastAndNewWindowIsWhole() async {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["scene_text_policy": "hybrid75", "scene_text": "v2"])) {
            let policy = SceneTextPolicy()
            let session = SceneContextHoldTests.session()
            for value in 0..<6 {
                let answer = await policy.answer(SceneContextHoldTests.scene(value), changesOnly: true,
                                                session: session, shown: ValueMinimization())
                if value == 0 { #expect(answer.form == .whole(because: nil)) }
                else {
                    let base: SceneAnswer.Base = value % 2 == 1 ? .anchor : .last
                    let since = base == .anchor ? 1 : value
                    #expect(answer.form == .changes(since: since, base: base))
                    #expect(answer.text.hasPrefix("r\(value + 1) since r\(since) (\(base.rawValue))\n"))
                }
            }
            session.observedWindowNumber = 2
            let whole = await policy.answer(SceneContextHoldTests.scene(6), changesOnly: true,
                                            session: session, shown: ValueMinimization())
            #expect(whole.form == .whole(because: nil))
        }
    }

    @Test func thresholdAndChainedBoundaryAreStrict() {
        let scene = SceneContextHoldTests.scene()
        let baseline = SceneWindowBaselines.Reading(revision: 1, scene: scene)
        let baselines = SceneWindowBaselines(key: .init(session: nil, windowNumber: 1, bundleID: scene.bundleID),
                                            anchor: baseline, last: baseline, lastBase: nil)
        #expect(SceneDifferenceRule.chained.choose(baselines: baselines, wholeCharacters: 100, changes: { _ in 49 })
                == .changes(since: 1, base: .last))
        #expect(SceneDifferenceRule.chained.choose(baselines: baselines, wholeCharacters: 100, changes: { _ in 50 })
                == .whole(because: nil))
        #expect(SceneDifferenceRule.hybrid75.choose(baselines: baselines, wholeCharacters: 100, changes: { _ in 75 })
                == .changes(since: 1, base: .anchor))
        #expect(SceneDifferenceRule.hybrid75.choose(baselines: baselines, wholeCharacters: 100, changes: { _ in 76 })
                == .whole(because: nil))
    }
}

@MainActor
struct SceneAnswerPartsTests {
    @Test func partsCoverUTF8AndDescribeOrigins() async {
        let policy = SceneTextPolicy()
        policy.contextHolds(after: .personHadApp)
        let answer = await policy.answer(SceneContextHoldTests.scene(), session: SceneContextHoldTests.session(),
                                        shown: ValueMinimization())
        var offset = 0
        for part in answer.parts {
            #expect(part.utf8.lowerBound == offset)
            #expect(!part.utf8.isEmpty)
            offset = part.utf8.upperBound
        }
        #expect(offset == answer.text.utf8.count)
        #expect(answer.parts.first?.source == .braus)
        #expect(answer.parts.contains { $0.source == .outOfView && $0.job == .element })
        #expect(answer.parts.contains { $0.section == "Content" && $0.job == .element })
    }
}

@MainActor
struct PolicyConcurrencyTests {
    @Test func interleavedReadsAndHoldAreAtomic() async {
        let policy = SceneTextPolicy()
        let session = SceneContextHoldTests.session()
        let scene = SceneContextHoldTests.scene()
        async let first = policy.answer(scene, changesOnly: true, session: session, shown: ValueMinimization())
        async let second = policy.answer(scene, changesOnly: true, session: session, shown: ValueMinimization())
        await Task.yield()
        let hold = policy.contextHolds(after: .compaction)
        let answers = await [first, second].sorted { $0.revision < $1.revision }
        #expect(answers.map(\.revision) == [1, 2])
        for answer in answers where answer.revision >= hold.firstHeldRevision {
            if case .unchanged(let since) = answer.form { #expect(since >= hold.firstHeldRevision) }
            if case .changes(let since, _) = answer.form { #expect(since >= hold.firstHeldRevision) }
        }
    }
}

struct SceneChangesTypedTests {
    @Test @MainActor func typedRenderingMatchesExistingBytes() {
        let before = SceneContextHoldTests.scene()
        let after = SceneContextHoldTests.scene(1)
        let changes = SceneChanges.changes(from: before, to: after)
        #expect(changes.elements.count == 1)
        #expect(changes.text(since: 1) == SceneChanges.text(from: before, to: after, since: 1))
        #expect(SceneChanges.changes(from: before, to: before).isEmpty)
    }
}

extension SceneContextHoldTests {
    @Test func explicitHoldKeepsOnlyAnAnchorAndFailedCallCannotUndoIt() async {
        let policy = SceneTextPolicy()
        let session = Self.session()
        let whole = await policy.answer(Self.scene(), session: session, shown: ValueMinimization())
        _ = await policy.answer(Self.scene(1), changesOnly: true, session: session, shown: ValueMinimization())
        let checkpoint = policy.checkpoint()
        policy.contextHolds(SceneContextHold(firstHeldRevision: policy.revision + 1,
                                            keptRevision: whole.revision, reason: .sessionSwitch))
        policy.restore(checkpoint)
        let next = await policy.answer(Self.scene(2), changesOnly: true, session: session, shown: ValueMinimization())
        #expect(next.form == .changes(since: whole.revision, base: .last))
    }
}

extension HybridRuleTests {
    @Test func largeDifferenceReanchorsAndUnchangedHasRevisionHeader() async {
        await SwitchBoard.$testing.withValue(SwitchBoard(values: ["scene_text_policy": "hybrid75", "scene_text": "v2"])) {
            let policy = SceneTextPolicy()
            let session = SceneContextHoldTests.session()
            let first = SceneContextHoldTests.scene()
            _ = await policy.answer(first, session: session, shown: ValueMinimization())
            var replaced = first
            replaced.elements = replaced.elements.map { element in
                var changed = element
                changed.label = "Replacement " + changed.label
                return changed
            }
            let whole = await policy.answer(replaced, changesOnly: true, session: session, shown: ValueMinimization())
            #expect(whole.form == .whole(because: nil))
            let unchanged = await policy.answer(replaced, changesOnly: true, session: session, shown: ValueMinimization())
            #expect(unchanged.form == .unchanged(since: whole.revision))
            #expect(unchanged.text == "r3 unchanged since r2")
        }
    }
}


extension SceneContextHoldTests {
    @Test func retainedLastCannotDependOnADroppedIntermediateReading() async {
        let policy = SceneTextPolicy()
        let session = Self.session()
        _ = await policy.answer(Self.scene(), session: session, shown: ValueMinimization())
        _ = await policy.answer(Self.scene(1), changesOnly: true, session: session, shown: ValueMinimization())
        _ = await policy.answer(Self.scene(2), changesOnly: true, session: session, shown: ValueMinimization())
        policy.contextHolds(SceneContextHold(firstHeldRevision: 3, keptRevision: 1, reason: .sessionSwitch))
        let next = await policy.answer(Self.scene(3), changesOnly: true, session: session, shown: ValueMinimization())
        #expect(next.form == .changes(since: 1, base: .last))
    }
}


extension SceneContextHoldTests {
    @Test func personReasonDoesNotReturnAfterWindowBaseEviction() async {
        let policy = SceneTextPolicy()
        let session = Self.session()
        policy.contextHolds(after: .personHadApp)
        for number in 1...10 {
            session.observedWindowNumber = number
            let first = await policy.answer(Self.scene(), session: session, shown: ValueMinimization())
            #expect(first.form == .whole(because: .personHadApp))
        }
        session.observedWindowNumber = 1
        let again = await policy.answer(Self.scene(), session: session, shown: ValueMinimization())
        #expect(again.form == .whole(because: nil))
        #expect(!again.text.contains("the person used"))
        #expect(policy.latest?.parts.last?.utf8.upperBound == policy.latest?.text.utf8.count)
    }
}
