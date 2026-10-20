//
//  BrainCoverageTests.swift
//  Braus
//
//  Created by Ronaldo Zefi on 19/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// What an observation could see decides what it may conclude: every observation is evidence of
/// presence, only a complete capture of a structural surface read natively or by the Seat is
/// evidence of absence, and an anchor seen only by another representation is bound only by an
/// exact label and kind. An observation without coverage is ingested as before.
@Suite("The brain's coverage: presence from any capture, absence from comparable ones, equivalence on evidence")
struct BrainCoverageTests {

    typealias Coverage = BrainObservationCoverage

    private let t0 = Fixtures.t0

    private static let completeNative  = Coverage(completeness: .complete, surface: .window, representation: .native, spatialScope: .wholeSurface)
    private static let completeDesktop = Coverage(completeness: .complete, surface: .window, representation: .desktop, spatialScope: .wholeSurface)

    /// Every coverage that cannot attest absence: a capture that did not read everything, a
    /// surface nobody classified or two windows in one picture, a web viewport, an unknown reader.
    private static let presenceOnly: [Coverage] = [
        Coverage(completeness: .partial, surface: .window, representation: .native, spatialScope: .wholeSurface),
        Coverage(completeness: .failed, surface: .window, representation: .native, spatialScope: .wholeSurface),
        Coverage(completeness: .unknown, surface: .window, representation: .desktop, spatialScope: .wholeSurface),
        Coverage(completeness: .complete, surface: .popupUnion, representation: .desktop, spatialScope: .wholeSurface),
        Coverage(completeness: .complete, surface: .unknown, representation: .native, spatialScope: .wholeSurface),
        Coverage(completeness: .complete, surface: .window, representation: .web),
        Coverage(completeness: .complete, surface: .dialog, representation: .web),
        Coverage(completeness: .complete, surface: .window, representation: .unknown),
    ]

    /// Every coverage that attests absence.
    private static let comparable: [Coverage] = [
        completeNative, completeDesktop,
        Coverage(completeness: .complete, surface: .dialog, representation: .native, spatialScope: .wholeSurface),
        Coverage(completeness: .complete, surface: .sheet, representation: .desktop, spatialScope: .wholeSurface),
    ]

    private func scene(_ labels: [String], x: Double = 0.5) -> [BrainDetection] {
        labels.enumerated().map { Fixtures.detection(.control, $0.element, x: x, y: 0.1 + 0.05 * Double($0.offset)) }
    }

    private func block(_ n: Int) -> Date { t0.addingTimeInterval(Double(n) * UIBrain.observationBlock) }

    /// A deterministic key sequence, so two runs of one sequence name the same objects.
    private func sequentialKeys() -> BrainKeys {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let anchors = Counter(), groups = Counter()
        return BrainKeys(
            anchorKey: { "anchor-\(anchors.next())" },
            groupID  : { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", groups.next()))! }
        )
    }

    // MARK: Coverage classification

    @Test("only a complete capture of a window, dialog or sheet read natively or by the Seat attests absence")
    func attestation() {
        #expect(Self.comparable.allSatisfy { $0.attestsAbsence })
        #expect(!Self.presenceOnly.contains { $0.attestsAbsence })
        let full = CaptureQuality(walkCompleted: true, windowFound: true)
        #expect(Coverage(capture: full, surface: .sheet, route: .native) == Coverage(
            completeness: .complete, surface: .sheet, representation: .native))
        #expect(Coverage(capture: CaptureQuality(walkCompleted: false), surface: .window, route: .desktop).completeness == .partial)
        #expect(Coverage(capture: full, surface: .window, route: nil).representation == .unknown)
        let inconsistent = CaptureQuality(walkCompleted: true, stoppedBy: .deadline, windowFound: true)
        #expect(Coverage(capture: inconsistent, surface: .window, route: .native).completeness == .unknown,
                "an inconsistent quality has no meaningful status")
    }

    @Test("complete visible captures after scrolling never age offscreen anchors")
    func visibleIsNotWholeSurface() {
        let visible = Coverage(completeness: .complete, surface: .window, representation: .native)
        #expect(!visible.attestsAbsence)
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Offscreen", "Mix", "Edit"]), into: &brain, now: block(0), window: "main", coverage: visible)
        for n in 1...40 {
            _ = BrainUpdater.ingest(scene(["Mix", "Edit", "Other"]), into: &brain, now: block(n), window: "main", coverage: visible)
        }
        #expect(brain.objects.contains { $0.label == "Offscreen" })
        #expect(brain.ingestEpoch == 0)
    }

    // MARK: Absence needs comparable coverage

    @Test("repeated partial captures never age or retire what they do not show, while complete captures still do")
    func partialNeverAges() throws {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0, window: "bounce",
                                coverage: Self.completeNative)
        let bounce = try #require(brain.objects.first { $0.label == "Bounce" })
        let partial = Coverage(completeness: .partial, surface: .window, representation: .native, spatialScope: .wholeSurface)
        for i in 1...200 {
            let stats = BrainUpdater.ingest(scene(["Mix", "Edit", "Save"]), into: &brain, now: block(i), window: "bounce",
                                            coverage: partial)
            #expect(stats.decay == nil, "no decay runs on a partial capture")
        }
        #expect(brain.ingestEpoch == 1 && brain.windowEpochs["bounce"] == 1, "the clock did not move")
        #expect(brain.unseenFor(window: "bounce", stamp: bounce.lastSeenEpoch) == 0)
        #expect(brain.objects.contains { $0.anchorKey == bounce.anchorKey })
        #expect(brain.object(withKey: bounce.anchorKey)?.seenCount == 1)

        var ticks = 0
        for i in 201...212 {
            let stats = BrainUpdater.ingest(scene(["Mix", "Edit", "Other"]), into: &brain, now: block(i), window: "bounce",
                                            coverage: Self.completeNative)
            if stats.decay != nil { ticks += 1 }
        }
        #expect(ticks == 12 && brain.ingestEpoch == 13)
        #expect(!brain.objects.contains { $0.anchorKey == bounce.anchorKey }, "twelve comparable absences retire a transient")
        #expect(brain.objects.first { $0.label == "Save" }?.seenCount == 200, "what the partial captures showed stays")
    }

    @Test("a partial capture refreshes the presence of what it shows and creates what is new, without ticking", arguments: [
        Coverage(completeness: .partial, surface: .window, representation: .native, spatialScope: .wholeSurface),
        Coverage(completeness: .complete, surface: .popupUnion, representation: .desktop, spatialScope: .wholeSurface),
    ])
    func partialRecordsPresence(_ coverage: Coverage) throws {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["A", "B", "C"]), into: &brain, now: t0, window: "main", coverage: Self.completeNative)
        let later = block(3)
        let stats = BrainUpdater.ingest(scene(["A", "B", "D"]), into: &brain, now: later, window: "main", coverage: coverage)
        #expect(stats.updated == 2 && stats.created == 1 && stats.decay == nil)
        let a = try #require(brain.objects.first { $0.label == "A" })
        #expect(a.seenCount == 2 && a.lastSeen == later && a.lastSeenEpoch == brain.windowEpochs["main"])
        let c = try #require(brain.objects.first { $0.label == "C" })
        #expect(c.seenCount == 1 && c.lastSeen == t0)
        let d = try #require(brain.objects.first { $0.label == "D" })
        #expect(d.seenCount == 1 && d.firstSeen == later)
        #expect(brain.ingestEpoch == 1 && brain.lastEpochAdvance == t0)
    }

    @Test("no presence-only capture ages anything, whatever the number of blocks: partial, failed, unknown, pop-up union, web, unknown reader",
          arguments: presenceOnly)
    func presenceOnlyNeverAges(_ coverage: Coverage) {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0, window: "w", coverage: Self.completeNative)
        let before = Set(brain.objects.map(\.anchorKey))
        for i in 1...160 {
            let stats = BrainUpdater.ingest(scene(["Tracks", "Clips", "Save"]), into: &brain, now: block(i), window: "w",
                                            coverage: coverage)
            #expect(stats.decay == nil)
        }
        #expect(brain.ingestEpoch == 1 && brain.windowEpochs["w"] == 1)
        #expect(before.isSubset(of: Set(brain.objects.map(\.anchorKey))), "nothing the first scene showed was retired")
    }

    @Test("every comparable capture ages what it does not show, as an observation without coverage does",
          arguments: comparable.map(Optional.some) + [nil])
    func comparableAges(_ coverage: Coverage?) {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Bounce", "Mix", "Edit"]), into: &brain, now: t0, window: "w", coverage: coverage)
        for i in 1...12 {
            _ = BrainUpdater.ingest(scene(["Mix", "Edit", "Other"]), into: &brain, now: block(i), window: "w", coverage: coverage)
        }
        #expect(brain.ingestEpoch == 13)
        #expect(!brain.objects.contains { $0.label == "Bounce" })
    }

    @Test("an observation without coverage is ingested exactly as before coverage existed")
    func legacyUnchanged() {
        typealias Step = (labels: [String], window: String?, block: Int)
        let opening: [Step] = [
            (["Bounce", "Mix", "Edit"], "bounce", 0), (["Mix", "Edit", "Save"], "bounce", 1), (["Lone"], nil, 2),
            (["Tracks", "Clips", "Save"], "edit", 3),
        ]
        let sequence = opening + (4...30).map { n -> Step in (["Mix", "Edit", "Other \(n % 3)"], "bounce", n) }
        var legacy = UIBrain(), explicit = UIBrain()
        let legacyKeys = sequentialKeys(), explicitKeys = sequentialKeys()
        for step in sequence {
            let a = BrainUpdater.ingest(scene(step.labels), into: &legacy, now: block(step.block), window: step.window,
                                        keys: legacyKeys)
            let b = BrainUpdater.ingest(scene(step.labels), into: &explicit, now: block(step.block), window: step.window,
                                        coverage: nil, keys: explicitKeys) { _ in [.web] }
            #expect(a == b)
        }
        #expect(legacy == explicit)
        #expect(legacy.ingestEpoch == 30)
    }

    // MARK: Equivalence across representations

    /// An unlabeled switch column: only the ordinal slot of its group can bind it again.
    private func unlabeledColumn() -> [BrainDetection] {
        (0..<6).map { Fixtures.detection(.control, "", x: 0.236, y: 0.18 + Double($0) * 0.036) }
    }

    @Test("an unlabeled column seen natively is bound positionally by the same representation, never by another")
    func positionalAcrossRepresentations() {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(unlabeledColumn(), into: &brain, now: t0, coverage: Self.completeNative)
        #expect(brain.objects.count == 6 && brain.groups.count == 1)
        let native = Set(brain.objects.map(\.anchorKey))
        func seen(by representations: Set<Coverage.Representation>) -> (String) -> Set<Coverage.Representation> {
            { key in native.contains(key) ? representations : [] }
        }

        var same = brain
        let again = BrainUpdater.ingest(unlabeledColumn(), into: &same, now: block(1), coverage: Self.completeNative,
                                        provenance: seen(by: [.native]))
        #expect(again.updated == 6 && again.created == 0)

        var other = brain
        let refused = BrainUpdater.ingest(unlabeledColumn(), into: &other, now: block(1), coverage: Self.completeDesktop,
                                          provenance: seen(by: [.native]))
        #expect(refused.updated == 0 && refused.created == 6, "the Seat's column is its own until an exact match ties them")
        #expect(other.objects.filter { native.contains($0.anchorKey) }.allSatisfy { $0.seenCount == 1 })

        var both = brain
        #expect(BrainUpdater.ingest(unlabeledColumn(), into: &both, now: block(1), coverage: Self.completeDesktop,
                                    provenance: seen(by: [.native, .desktop])).updated == 6)
        var unknownAnchors = brain
        #expect(BrainUpdater.ingest(unlabeledColumn(), into: &unknownAnchors, now: block(1), coverage: Self.completeDesktop,
                                    provenance: seen(by: [])).updated == 6,
                "an anchor seen only before coverage existed has no known representation to differ from")
        var unknownReader = brain
        #expect(BrainUpdater.ingest(unlabeledColumn(), into: &unknownReader, now: block(1),
                                    coverage: Coverage(completeness: .complete, surface: .window, representation: .unknown),
                                    provenance: seen(by: [.native])).created == 6,
                "an observation of unknown representation binds a known anchor only exactly")
        var legacy = brain
        #expect(BrainUpdater.ingest(unlabeledColumn(), into: &legacy, now: block(1), coverage: nil,
                                    provenance: seen(by: [.native])).updated == 6,
                "an observation without coverage matches as before")
    }

    @Test("a model-named anchor takes another label as an alias from its own representation; another representation needs the exact label")
    func aliasAcrossRepresentations() throws {
        var brain = UIBrain()
        _ = BrainUpdater.ingest(scene(["Export", "Mix", "Edit"]), into: &brain, now: t0, coverage: Self.completeNative)
        let export = try #require(brain.objects.first { $0.label == "Export" }).anchorKey
        #expect(BrainUpdater.setName("Render", anchorKey: export, into: &brain, now: t0))
        let renamed = scene(["Bounce", "Mix", "Edit"])
        let nativeOnly: (String) -> Set<Coverage.Representation> = { _ in [.native] }

        var same = brain
        _ = BrainUpdater.ingest(renamed, into: &same, now: block(1), coverage: Self.completeNative, provenance: nativeOnly)
        #expect(same.object(withKey: export)?.aliases.contains("Bounce") == true)
        #expect(same.objects.count == 3)

        var other = brain
        let refused = BrainUpdater.ingest(renamed, into: &other, now: block(1), coverage: Self.completeDesktop,
                                          provenance: nativeOnly)
        #expect(refused.created == 1 && refused.updated == 2)
        #expect(other.object(withKey: export)?.aliases.contains("Bounce") == false, "no alias from a weak match across representations")
        #expect(other.object(withKey: export)?.seenCount == 1)

        var exact = brain
        let matched = BrainUpdater.ingest(scene(["Render", "Mix", "Edit"]), into: &exact, now: block(1),
                                          coverage: Self.completeDesktop, provenance: nativeOnly)
        #expect(matched.updated == 3 && matched.created == 0)
        #expect(exact.object(withKey: export)?.seenCount == 2, "the exact label and kind bind across representations")
        var observedName = brain
        _ = BrainUpdater.ingest(scene(["Export", "Mix", "Edit"]), into: &observedName, now: block(1),
                                coverage: Self.completeDesktop, provenance: nativeOnly)
        #expect(observedName.object(withKey: export)?.seenCount == 2, "an alias the anchor already holds is exact too")
    }
    @Test("presence-only captures retain the capacity bound without absence-based decay")
    func presenceCapacity() {
        let anchors = (0..<3001).map { number in
            ObjectAnchor(anchorKey: "a-\(number)", kind: .control, label: "Item \(number)",
                         boundsTypical: Fixtures.rect(0.5, 0.5), firstSeen: t0, lastSeen: t0,
                         lastSeenEpoch: 0, window: "main")
        }
        var brain = UIBrain(objects: anchors)
        let coverage = Coverage(completeness: .complete, surface: .window, representation: .native)
        let outcome = BrainUpdater.ingest([], into: &brain, now: block(40), window: "main", coverage: coverage)
        #expect(brain.ingestEpoch == 0)
        #expect(brain.objects.count == 3000)
        #expect(outcome.decay?.anchors.count == 1)
        #expect(outcome.decay?.anchors.values.allSatisfy { $0 == .cap } == true)
    }

}
