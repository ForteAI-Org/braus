//
//  HumanInterventionStructureTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore
import Testing
@testable import SeatBroker

/// Structural reads (archive version 3) certify what viewport reads cannot: a removal or creation inside a collection
/// read whole, a rename by its identifier, an order; content another process hosts that refused is stated unobserved.
@Suite
struct HumanInterventionStructureTests {
    private typealias Read = InteractionStructuralRead

    private func members(_ names: [String], identifiers: Bool = false) -> [Read.Member] {
        names.enumerated().map { .init(index: $0.offset, name: $0.element, identifier: identifiers ? "id-\($0.element.prefix(1))" : nil) }
    }

    private func structure(_ names: [String], coverage: Read.Coverage = .complete, identifiers: Bool = false,
                           hosted: [Read.Region] = []) -> Read {
        var window = Read.Window(number: 7, title: "Folder")
        window.collections = [.init(role: "AXList", name: "icon view", identifier: nil, count: names.count,
                                    members: members(names, identifiers: identifiers), coverage: coverage, visible: [])]
        window.hosted = hosted
        return Read(processID: 42, interval: .init(start: 1, end: 1.1), windows: [window])
    }

    /// One action, its read, and the final read, each carrying a structural read of window 7.
    private func digest(_ before: Read, _ after: Read, action: HumanRecordedInteraction.SummaryAction) throws -> HumanInterventionSummary.Digest {
        let scene = SceneSnapshot(bundleID: "test", appName: "Files", windowTitle: "Folder", viewportPixelSize: .init(width: 800, height: 600),
                                  elements: [.init(id: "control|view", kind: .control, label: "View", bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXButton")])
        var first = try HumanSceneFinding(sequence: 1, kind: .changes, text: "", readMilliseconds: 1, scenes: [7: scene])
        first.recordedAction = action
        first.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "textOnly", structure: before)])
        var final = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "", readMilliseconds: 1, scenes: [7: scene], initialScenes: [7: scene])
        final.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "full", structure: after)])
        var second = try HumanSceneFinding(sequence: 2, kind: .changes, text: "", readMilliseconds: 1, scenes: [7: scene])
        second.recordedAction = action
        second.provenance = final.provenance
        return HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [first, second], finalState: final))
    }

    private func key(_ command: String) -> HumanRecordedInteraction.SummaryAction {
        .init(kind: .shortcut, processID: 42, windowNumber: 7, windowTitle: "Folder", role: "AXList", label: "icon view",
              isProtected: false, destination: nil, commandName: command, lostCritical: 0)
    }

    @Test func aMemberLeavingACollectionReadWholeIsRemoved() throws {
        let digest = try digest(structure(["Alpha", "Beta", "Gamma"]), structure(["Alpha", "Gamma"]), action: key("⌘Delete"))
        #expect(digest.text.contains("\nDelete: − Beta.\n"))
        digest.checkInvariants("structural removal")
    }

    @Test func aViewportReadCertifiesNothing() throws {
        let digest = try digest(structure(["Alpha", "Beta", "Gamma"], coverage: .viewport), structure(["Alpha", "Gamma"], coverage: .viewport),
                                action: key("⌘Delete"))
        #expect(!digest.text.contains("Beta"))
    }

    @Test func membersPastARangeAreNotClaimed() throws {
        // Both reads cover the first two members only: Gamma's absence past them claims nothing.
        let digest = try digest(structure(["Alpha", "Beta", "Gamma"], coverage: .range(first: 0, last: 1)),
                                structure(["Alpha", "Beta"], coverage: .range(first: 0, last: 1)), action: key("⌘Delete"))
        #expect(!digest.text.contains("Gamma"))
    }

    @Test func aMemberKeepingItsIdentifierUnderAnotherNameIsRenamedAndAnOrderIsStated() throws {
        let renamed = try digest(structure(["Alpha", "Beta", "Gamma"], identifiers: true),
                                 structure(["Alpha", "Bravo", "Gamma"], identifiers: true), action: key("Return"))
        #expect(renamed.text.contains("\nRename: Beta → Bravo.\n"))
        let sorted = try digest(structure(["Epsilon", "Delta", "Gamma", "Beta", "Alpha"]),
                                structure(["Alpha", "Beta", "Gamma", "Delta", "Epsilon"]), action: key("⌘1"))
        #expect(sorted.text.contains("Re-sorted: icon view"))
    }

    /// A read of window 7 holding `collections`, each (role, name, member names), read whole.
    private func lists(_ collections: [(role: String, name: String?, members: [String?], roles: [String]?)]) -> Read {
        var window = Read.Window(number: 7, title: "Folder")
        window.collections = collections.map { collection in
            .init(role: collection.role, name: collection.name, identifier: nil, count: collection.members.count,
                  members: collection.members.enumerated().map {
                      .init(index: $0.offset, name: $0.element, role: collection.roles?[$0.offset])
                  }, coverage: .complete, visible: [])
        }
        return Read(processID: 42, interval: .init(start: 1, end: 1.1), windows: [window])
    }

    /// A page's lists without names or identifiers that did not change are not compared by their order: each continues
    /// the one it shares members with, so nothing is claimed (Safari: an untouched page gave +58, −17, 7 renames).
    @Test func unnamedListsAreComparedWithTheListTheyContinue() throws {
        let page = [("AXList", nil, ["Session", "Axis"], nil), ("AXList", nil, ["Method", "Model", "Archive"], nil),
                    ("AXTable", nil, ["Thread", "What the person did"], nil)] as [(role: String, name: String?, members: [String?], roles: [String]?)]
        let same = try digest(lists(page), lists(Array(page.reversed())), action: key("⌘R"))
        #expect(!same.text.contains("Added") && !same.text.contains("Removed") && !same.text.contains("Rename"))
        // A list a page shows instead of another shares nothing with it: no claim either.
        let other = try digest(lists([("AXList", nil, ["Apple", "iCloud"], nil)]), lists([("AXList", nil, ["Google", "Images"], nil)]),
                               action: key("⌘L"))
        #expect(!other.text.contains("Apple") && !other.text.contains("Google"))
    }

    /// A collection grouped into sections states the sections it now has, the files inside them unchanged.
    @Test func aCollectionGroupedIntoSectionsStatesItsGroups() throws {
        let before = lists([("AXList", "icon view", [nil], ["AXList"]), ("AXList", nil, ["Archive", "Notes.md", "Report.pdf"], nil)])
        let after = lists([("AXList", "icon view", ["Folders", "Documents", "PDF Documents"], ["AXList", "AXList", "AXList"]),
                           ("AXList", "Folders", ["Archive"], nil), ("AXList", "Documents", ["Notes.md"], nil),
                           ("AXList", "PDF Documents", ["Report.pdf"], nil)])
        let digest = try digest(before, after, action: key("⌃⌘2"))
        #expect(digest.text.contains("icon view groups: none → Folders, Documents, PDF Documents."))
        #expect(!digest.text.contains("Added") && !digest.text.contains("Removed"))
        digest.checkInvariants("grouped into sections")
        // A section never read as a collection of its own carries a name borrowed from its first item: no group.
        let borrowed = lists([("AXList", "icon view", ["Drafts, 2 items"], ["AXList"])])
        let unread = try self.digest(lists([("AXList", "icon view", [nil], ["AXList"])]), borrowed, action: key("⌃⌘2"))
        #expect(!unread.text.contains("groups"))
    }

    /// A read of window 7 holding level controls, each (name, value).
    private func levels(_ controls: [(name: String, value: String?)]) -> Read {
        var window = Read.Window(number: 7, title: "Displays")
        window.fields = controls.map { .init(role: "AXSlider", name: $0.name, identifier: nil, value: $0.value) }
        return Read(processID: 42, interval: .init(start: 1, end: 1.1), windows: [window])
    }

    /// A level only the structural read shows (a slider whose value is where its thumb sits) is stated when it
    /// changed; two levels of one name are told apart by nothing, so neither is compared.
    @Test func aLevelOnlyAStructuralReadShowsIsStated() throws {
        let changed = try digest(levels([("Brightness", "1")]), levels([("Brightness", "0.47")]), action: key("F1"))
        #expect(changed.text.contains("Brightness: 1 → 0.47."))
        changed.checkInvariants("level")
        let same = try digest(levels([("Brightness", "0.47")]), levels([("Brightness", "0.47")]), action: key("F1"))
        #expect(!same.text.contains("Brightness"))
        let twins = try digest(levels([("Volume", "0.2"), ("Volume", "0.8")]), levels([("Volume", "0.5"), ("Volume", "0.8")]),
                               action: key("F1"))
        #expect(!twins.text.contains("Volume"))
    }

    /// A read of window 7 holding one output selector per track: the name carries the value on its second line.
    private func selectors(_ outputs: [(track: String, output: String)]) -> Read {
        var window = Read.Window(number: 7, title: "Edit")
        window.fields = outputs.map {
            .init(role: "AXPopUpButton", name: "Audio Output Path selector\n\($0.output) (Stereo)", identifier: nil,
                  value: $0.output, container: "\($0.track) / Audio IO")
        }
        return Read(processID: 42, interval: .init(start: 1, end: 1.1), windows: [window])
    }

    /// The read taken when control passed is the "before" of a choice no action read reached (a track off screen):
    /// selectors of one name are told apart by their track, and only the one that changed is stated.
    @Test func theInitialReadIsTheBeforeOfAChoiceNoActionReadReached() throws {
        let scene = SceneSnapshot(bundleID: "test", appName: "Mixer", windowTitle: "Edit", viewportPixelSize: .init(width: 800, height: 600),
                                  elements: [.init(id: "control|view", kind: .control, label: "View", bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1), role: "AXButton")])
        var first = try HumanSceneFinding(sequence: 1, kind: .changes, text: "", readMilliseconds: 1, scenes: [7: scene])
        first.recordedAction = key("⌘1")
        first.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "textOnly")])
        var final = try HumanSceneFinding(sequence: 0, kind: .keyframe, text: "", readMilliseconds: 1, scenes: [7: scene], initialScenes: [7: scene])
        final.provenance = .init(surfaces: [.init(processID: 42, windowNumber: 7, mode: "full",
                                                  structure: selectors([("Vocals", "Output"), ("Drums", "ROUGH MIX")]))])
        final.provenance?.initialStructure = selectors([("Vocals", "Output"), ("Drums", "Output")])
        let digest = HumanInterventionSummary.digest(HumanInterventionEvidence(findings: [first], finalState: final))
        #expect(digest.text.contains("Audio Output Path selector on Drums / Audio IO: Output → ROUGH MIX."))
        #expect(!digest.text.contains("Vocals"))
        digest.checkInvariants("initial read")
    }

    @Test func contentAnotherProcessHostsThatRefusedIsStatedUnobserved() throws {
        let refused = Read.Region(processID: 99, host: "Displays Service", role: nil, name: nil, read: false)
        let digest = try digest(structure(["Alpha"], hosted: [refused]), structure(["Alpha"], hosted: [refused]), action: key("F1"))
        #expect(digest.text.contains("Unobserved: a pane hosted by Displays Service."))
    }
}
