import Foundation
import PerceptionCore
import Testing
@testable import SeatBroker

@Suite
struct HumanInterventionIdentityTests {
    @Test func countsTimesAndDatesAreNeverNames() {
        for text in ["6 notes", ", 71 notes", "2 items", "15:18", "24/08/2026", "Yesterday at 14:04", "19 Oct 2026 at 14:28",
                     "30 October 2026 at 15:18", "Oct 19, 2026", "2025", ""] {
            #expect(HumanInterventionIdentity.isNameless(text), "\(text)")
        }
        for text in ["Audio 13", "Bass 1", "9 Setup guide.pdf", "Mix 3B", "Draft 20 2", "Report 2026", "Tom 1"] {
            #expect(!HumanInterventionIdentity.isNameless(text), "\(text)")
        }
    }

    @Test func markersMostMembersShareAreStateNotName() {
        let names = ["Shown. Drums folder", "Shown. Kick 1", "Hidden. Snare fill", "Shown. Audio. Keys 1", "Master"]
        let stripped = HumanInterventionIdentity.strippingMarkers(names) { _ in false }
        #expect(stripped.map(\.name) == ["Drums folder", "Kick 1", "Snare fill", "Audio. Keys 1", "Master"])
        #expect(stripped.map(\.state) == ["Shown", "Shown", "Hidden", "Shown", nil])
        // A prefix another read shows as part of the name stays in it, as does one only a few members carry.
        #expect(HumanInterventionIdentity.strippingMarkers(names) { $0 == "Shown. Kick 1" }.map(\.name) == names)
        #expect(HumanInterventionIdentity.strippingMarkers(["Audio. Keys 1", "Audio 2", "Bass 1"]) { _ in false }.map(\.name)
            == ["Audio. Keys 1", "Audio 2", "Bass 1"])
    }

    @Test func repeatedControlNamesStayInTheirOwnContainers() {
        let before = scene([element("Gain", container: "A", value: "1")])
        let after = scene([element("Gain", container: "B", value: "2")])
        let pairs = HumanInterventionChanges.pairs(before, after)
        #expect(!pairs.contains { $0.before != nil && $0.after != nil })
    }

    @Test func aRecycledPixelSlotDoesNotEstablishRename() {
        let before = scene([element("Audio 1", container: "Tracks")])
        let after = scene([element("Audio 8", container: "Tracks")])
        #expect(!HumanInterventionChanges.pairs(before, after).contains { $0.before != nil && $0.after != nil })
    }

    @Test func duplicateContentLeavesAmbiguousCorrespondenceUnresolved() {
        let item = element("Same", container: "Tracks")
        let pairs = HumanInterventionChanges.pairs(scene([item, item]), scene([item, item]))
        // A repeated key pairs equal labels in reading order, so unchanged duplicates are unchanged.
        #expect(pairs.count == 2 && pairs.allSatisfy { $0.before != nil && $0.after != nil })
    }

    @Test func uniqueContentSurvivesReorderAndInsertion() {
        let a = element("A", container: "Tracks")
        var b = element("B", container: "Tracks")
        b.bounds.y = 0.2
        var moved = a
        moved.bounds.y = 0.3
        let pairs = HumanInterventionChanges.pairs(scene([a, b]), scene([b, moved]))
        #expect(pairs.filter { $0.before != nil && $0.after != nil }.count == 2)
        #expect(pairs.allSatisfy { $0.before?.label == $0.after?.label })
    }

    @Test func containerRenameCanMoveWithUniqueIndependentChildren() {
        let before = named("A", offset: 0)
        let after = named("B", offset: 0.2)
        let matches = HumanInterventionChanges.renamedContainers(before, after)
        #expect(matches.count == 1)
        #expect(matches.first?.before?.value == "A")
        #expect(matches.first?.after?.value == "B")
    }

    @Test(arguments: ["AXRow", "AXStaticText", "AXCell", "AXTextField", nil] as [String?])
    func reusedOrdinalOrPixelSlotIsNotIndependentIdentity(role: String?) {
        var before = element("A", container: "Collection")
        before.id = "row-index-0"
        before.role = role
        var after = before
        after.label = "B"
        #expect(!HumanInterventionChanges.pairs(scene([before]), scene([after])).contains {
            $0.before != nil && $0.after != nil
        })
    }

    @Test(arguments: ["AppKit view", "NSCell", "outline", "SwiftUI", "Catalyst", "Qt", "Chromium", "CEP", "UXP", "JUCE", "Swing", "OCR"])
    func retainedFrameworkShapesDoNotTurnReuseIntoIdentity(family: String) {
        var old = element("Record 1", container: "Collection / row 0")
        old.id = "control|record1"
        var new = old
        switch family {
        case "AppKit view", "NSCell", "Swing":
            old.id = "row-index-0"
            new.id = old.id
            new.label = "Record 2"
        case "outline":
            let matches = HumanInterventionChanges.pairs(scene([old]), scene([]))
            #expect(matches.first?.reason == .outsideCoverage)
            return
        case "SwiftUI":
            old.role = "AXGroup"
            new.role = "AXGroup"
            new.id = "control|record1selected"
            new.label = "Record 1, selected"
        case "Chromium", "CEP", "UXP", "Catalyst":
            new.container = "Replacement subtree / row 0"
        case "JUCE", "OCR":
            old.role = nil
            new.role = nil
            old.kind = .text
            new.kind = .text
            new.id = "text|record7"
            new.label = "Record 7"
        case "Qt":
            new.bounds.y = 0.6
            let matches = HumanInterventionChanges.pairs(scene([old]), scene([new]))
            #expect(matches.first?.before?.label == "Record 1")
            #expect(matches.first?.after?.label == "Record 1")
            return
        default: break
        }
        #expect(!HumanInterventionChanges.pairs(scene([old]), scene([new])).contains {
            $0.before != nil && $0.after != nil
        })
    }

    private func named(_ name: String, offset: Double) -> SceneSnapshot {
        let labels = ["Name \"\(name)\"", "Mute", "Solo"]
        return scene(labels.enumerated().map { index, label in
            .init(id: index == 0 ? "control|name" + name : "control|" + label,
                  kind: .control, label: label,
                  bounds: .init(x: 0.1 + offset, y: 0.1 + Double(index) * 0.1, width: 0.2, height: 0.1),
                  role: index == 0 ? "AXPopUpButton" : "AXButton", value: index == 0 ? name : nil,
                  container: name)
        })
    }

    private func element(_ name: String, container: String, value: String? = nil) -> PerceptionCore.SceneElement {
        .init(id: "control|" + name.lowercased(), kind: .control, label: name,
              bounds: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
              role: "AXRow", value: value, container: container)
    }

    private func scene(_ elements: [PerceptionCore.SceneElement]) -> SceneSnapshot {
        .init(bundleID: "test", appName: "Test", windowTitle: "Document",
              viewportPixelSize: .init(width: 800, height: 600), elements: elements)
    }
}
