//
//  ProjectionSliceTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The enrichment of a scene reads the part of an application's projection its labels, kinds and groups
/// can match (review F08), by the anchors' label keys of schema 4, and names the scene exactly as the
/// whole projection does: by label, by a taught name's position, by a group's ordinal slot. The keys are
/// written with the anchors, and filled by the migration for the anchors an earlier schema kept.
@Suite("A part of the projection names a scene as the whole projection does")
struct ProjectionSliceTests {

    typealias F = BrainFixtures

    /// A projection of many screens, a column of switches the detector groups, and an icon a model named.
    static func populated() async throws -> (F.Memory, iconKey: String) {
        let memory = try await F.open()
        for screen in 0..<40 {
            let labels = (0..<10).map { "Screen \(screen) item \($0)" }
            _ = try await memory.brain.ingest(F.scene(labels, x: 0.3), into: F.bundle, now: try F.clock(Double(screen)), window: "w\(screen)")
        }
        for (step, states) in [[ControlState.off, .off, .on, .off, .off, .off, .off, .off],
                               [.off, .on, .off, .off, .off, .off, .off, .off]].enumerated() {
            _ = try await memory.brain.ingest(F.switchColumn(states: states), into: F.bundle, now: try F.clock(100 + Double(step)),
                                              window: "settings")
        }
        // A column of unlabeled icons, which a captioned icon at one of its slots is named by.
        for step in 0..<2 {
            let column = (0..<4).map { F.det(.icon, "", x: 0.9, y: 0.3 + 0.05 * Double($0)) }
            _ = try await memory.brain.ingest(column, into: F.bundle, now: try F.clock(150 + Double(step)), window: "palette")
        }
        let icon = F.det(.icon, "", x: 0.8, y: 0.05)
        _ = try await memory.brain.ingest([icon], into: F.bundle, now: try F.clock(200), window: "toolbar")
        let brain = try #require(try await memory.load())
        let iconKey = try #require(brain.objects.first { $0.kind == .icon && abs($0.boundsTypical.x - 0.8) < 0.01 }?.anchorKey)
        #expect(try await memory.brain.setName("Mixer", anchorKey: iconKey, in: F.bundle, now: try F.clock(201)))
        return (memory, iconKey)
    }

    /// A scene of one screen's labels, the switches unlabeled at their slots, the named icon unlabeled, and
    /// labels the projection never saw.
    static func scene() -> [SceneElement] {
        var elements = (0..<10).map { F.element("s3-\($0)", "Screen 3 item \($0)", x: 0.3, y: 0.1 + 0.05 * Double($0)) }
        elements += (0..<8).map { slot in
            SceneElement(id: "switch-\(slot)", kind: .control, label: "", bounds: F.rect(0.236, 0.18 + Double(slot) * 0.036),
                         state: .off, isUnlabeled: true)
        }
        elements.append(SceneElement(id: "icon", kind: .icon, label: "icon", bounds: F.rect(0.8, 0.05), isUnlabeled: true))
        elements.append(SceneElement(id: "captioned", kind: .icon, label: "Brush", bounds: F.rect(0.9, 0.35)))
        elements += ["Never seen", "Neither"].enumerated().map { F.element("new-\($0.offset)", $0.element, x: 0.6, y: 0.1 * Double($0.offset + 1)) }
        return elements
    }

    @Test("the part read by a scene's keys names its elements exactly as the whole projection: labels, groups' slots, a taught name")
    func partNamesAsTheWhole() async throws {
        let (memory, _) = try await Self.populated()
        let whole = try #require(try await memory.load())
        #expect(!whole.groups.isEmpty, "the switches form a group")
        let elements = Self.scene()
        let detections = elements.filter { $0.kind == .control || $0.kind == .icon }.map(BrainDetection.init)
        let part = try #require(try await memory.brain.projection(of: F.bundle, for: detections))
        #expect(part.objects.count * 4 < whole.objects.count, "\(part.objects.count) of \(whole.objects.count) anchors read")
        let byPart = part.enrich(elements, affordances: false), byWhole = whole.enrich(elements, affordances: false)
        #expect(byPart == byWhole)
        // The scene's order: ten labels, eight switches, the named icon, the captioned icon, two new labels.
        #expect(byPart[18].label == "Mixer" && byPart[18].isRecalled, "the taught name is recalled")
        #expect(byPart[10..<18].contains { $0.group != nil }, "a switch is placed in its group")
        #expect(byPart[19].label == "Brush" && byPart[19].group != nil, "a captioned icon takes its unlabeled slot in the palette")
        let keys = try await memory.integers("SELECT count(*) FROM brain_anchor_label_keys").first ?? nil
        #expect(keys == Int64(whole.objects.reduce(0) { $0 + SQLiteBrainRows.labelKeys(label: $1.label, aliases: $1.aliases).count }),
                "every active anchor's labels are keyed as it is written")
        await memory.store.close()
    }

    @Test("an archive of schema 1 gets its anchors' label keys in its migration, and the part it reads names as the whole")
    func migrationFillsTheKeys() async throws {
        let (memory, _) = try await Self.populated()
        let url = memory.url
        await memory.store.close()
        let raw = try SQLiteConnection(path: url.path)
        try SchemaShape.downgrade(raw, to: 1)
        raw.close()
        let migrated = try await F.open(at: url)
        #expect(try await migrated.store.diagnostics().migration?.fromVersion == 1)
        let whole = try #require(try await migrated.load())
        let keys = try await migrated.integers("SELECT count(*) FROM brain_anchor_label_keys").first ?? nil
        #expect(keys == Int64(whole.objects.reduce(0) { $0 + SQLiteBrainRows.labelKeys(label: $1.label, aliases: $1.aliases).count }))
        let elements = Self.scene()
        let detections = elements.filter { $0.kind == .control || $0.kind == .icon }.map(BrainDetection.init)
        let part = try #require(try await migrated.brain.projection(of: F.bundle, for: detections))
        #expect(part.enrich(elements, affordances: false) == whole.enrich(elements, affordances: false))
        await migrated.store.close()
    }
}
