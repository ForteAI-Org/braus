//
//  InteractionStructuralReaderTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import Testing
@testable import InteractionObservation

/// The structural reader on fake accessibility trees: node 1 is the application, windows answer "windowNumber".
@Suite
struct InteractionStructuralReaderTests {
    private final class Tree: InteractionSemanticReading {
        var nodes: [Int: [String: InteractionSemanticProbe.Value<Int>]] = [:]
        var owners: [Int: Int32] = [:]
        var clock = 0.0
        /// Seconds every message costs on the fake clock.
        var cost = 0.0
        /// Nodes whose values answer only every other time, as a live element that changes between two reads.
        var flicker: Set<Int> = []
        private var asked: [Int: Int] = [:]
        func same(_ first: Int, _ second: Int) -> Bool { first == second }
        func read(_ node: Int, _ attribute: String, limit: Int) -> InteractionSemanticProbe.Value<Int> {
            clock += cost
            guard case .nodes(let list, let complete)? = nodes[node]?[attribute] else { return nodes[node]?[attribute] ?? .unsupported }
            return list.count > limit ? .nodes(Array(list.prefix(limit)), complete: false) : .nodes(list, complete: complete)
        }
        func values(_ node: Int, _ attributes: [String]) -> [InteractionSemanticProbe.Value<Int>] {
            clock += cost
            if flicker.contains(node) {
                asked[node, default: 0] += 1
                if asked[node, default: 0].isMultiple(of: 2) { return attributes.map { _ in .unsupported } }
            }
            return attributes.map { nodes[node]?[$0] ?? .unsupported }
        }
        func owner(_ node: Int) -> Int32? { owners[node] ?? 42 }

        func add(_ node: Int, role: String, title: String? = nil, children: [Int] = [], _ extra: [String: InteractionSemanticProbe.Value<Int>] = [:]) {
            var values: [String: InteractionSemanticProbe.Value<Int>] = ["AXRole": .string(role), "AXChildren": .nodes(children, complete: true)]
            if let title { values["AXTitle"] = .string(title) }
            nodes[node] = values.merging(extra) { _, new in new }
        }
    }

    private func window(_ tree: Tree, _ node: Int, number: Int, children: [Int]) {
        tree.add(node, role: "AXWindow", title: "Window \(number)", children: children, ["windowNumber": .integer(number)])
    }

    private func capture(_ tree: Tree, windows: Set<Int>, seconds: Double = 0.15,
                         isReserved: @escaping (String) -> Bool = { _ in false }) -> InteractionStructuralRead {
        InteractionStructuralReader.capture(reader: tree, application: 1, processID: 42, windows: windows, seconds: seconds,
                                            now: { tree.clock }, hostName: { $0 == 99 ? "Displays Service" : nil },
                                            isReserved: isReserved)
    }

    @Test func iconViewChildrenOfAnyRoleAreReadWholeWithTheirViewport() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXScrollArea", children: [12])
        tree.add(12, role: "AXList", title: "icon view", children: [13, 14, 15],
                 ["AXVisibleChildren": .nodes([13, 14], complete: true)])
        tree.add(13, role: "AXImage", title: "Report.pdf")
        tree.add(14, role: "AXGroup", title: "Drafts")
        tree.add(15, role: "AXImage", ["AXFilename": .string("Notes.md")])
        let read = capture(tree, windows: [7])
        let collection = try #require(read.windows.first?.collections.first)
        #expect(collection.role == "AXList" && collection.name == "icon view" && collection.coverage == .complete)
        #expect(collection.members.map { $0.name ?? $0.document } == ["Report.pdf", "Drafts", "Notes.md"])
        #expect(collection.visible == [0, 1] && collection.count == 3)
        #expect(read.unread.isEmpty && read.windows.first?.quality == .init())
    }

    @Test func aListPastTheCapIsReadByRange() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        let rows = Array(1000..<3500)
        tree.add(11, role: "AXTable", title: "Files", children: [], ["AXRows": .nodes(rows, complete: true)])
        // Rows name themselves in their first cell, as a table's name column does.
        for row in rows {
            tree.add(row, role: "AXRow", children: [row + 10_000])
            tree.add(row + 10_000, role: "AXCell", ["AXValue": .string("File \(row)")])
        }
        let read = capture(tree, windows: [7], seconds: 10)
        let collection = try #require(read.windows.first?.collections.first)
        #expect(collection.count == 2_500 && collection.members.count == 2_000)
        #expect(collection.coverage == .range(first: 0, last: 1_999))
        #expect(collection.members.first?.name == "File 1000" && collection.members.last?.name == "File 2999")
    }

    @Test func theTimeBoxEndsTheReadAndSaysSo() throws {
        let tree = Tree()
        tree.cost = 0.001
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        let rows = Array(1000..<1500)
        tree.add(11, role: "AXTable", title: "Files", ["AXRows": .nodes(rows, complete: true)])
        for row in rows { tree.add(row, role: "AXRow", title: "Row \(row)") }
        let read = capture(tree, windows: [7])
        let collection = try #require(read.windows.first?.collections.first)
        #expect(read.windows.first?.quality.deadline == true)
        #expect(collection.members.count < 500)
        if case .range(0, let last) = collection.coverage { #expect(last == collection.members.count - 1) } else { Issue.record("not a range") }
    }

    @Test func contentAnotherProcessHostsIsReadOrStatedUnobserved() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11, 20])
        // A pane hosted by another process that refuses every attribute.
        tree.nodes[11] = [:]
        tree.owners[11] = 99
        // One that answers is read as part of the window.
        tree.add(20, role: "AXGroup", title: "Extension", children: [21])
        tree.owners[20] = 77
        tree.owners[21] = 77
        tree.add(21, role: "AXTextField", title: "Search", ["AXValue": .string("query")])
        let read = capture(tree, windows: [7])
        let window = try #require(read.windows.first)
        #expect(window.hosted.contains { $0.processID == 99 && $0.host == "Displays Service" && !$0.read })
        #expect(window.hosted.contains { $0.processID == 77 && $0.read })
        #expect(window.fields == [.init(role: "AXTextField", name: "Search", identifier: nil, value: "query", container: "Extension")])
    }

    /// Fields of one name, one per track, are told apart by their named ancestors (the window itself excluded).
    @Test func aFieldCarriesItsNamedAncestors() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXGroup", title: "Tracks", children: [12, 13])
        for (track, popup, name) in [(12, 14, "Vocals"), (13, 15, "Drums")] {
            tree.add(track, role: "AXGroup", title: name, children: [track + 10])
            tree.add(track + 10, role: "AXGroup", title: "Audio IO", children: [popup])
            tree.add(popup, role: "AXPopUpButton", ["AXDescription": .string("Audio Output Path selector\nOutput (Stereo)"),
                                                    "AXValue": .string("Output")])
        }
        let fields = try #require(capture(tree, windows: [7]).windows.first?.fields)
        #expect(fields.map(\.container) == ["Vocals / Audio IO", "Drums / Audio IO"])
    }

    @Test func anInPlaceEditorWindowIsReadAndSecretsNeverAre() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10, 30], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXSecureTextField", ["AXSubrole": .string("AXSecureTextField"), "AXValue": .string("hunter2")])
        tree.add(12, role: "AXTextField", ["AXSubrole": .string("AXSecureTextField"), "AXValue": .string("hunter2")])
        tree.nodes[11]?["AXChildren"] = .nodes([12], complete: true)
        // The small window a rename types into, closed right after: read while it exists.
        window(tree, 30, number: 8, children: [31])
        tree.add(31, role: "AXTextField", ["AXValue": .string("Setup_guide.pdf")])
        let read = capture(tree, windows: [7, 8, 9], isReserved: { $0.contains("secret") })
        #expect(read.windows.map(\.number) == [7, 8])
        #expect(read.windows.last?.fields.map(\.value) == ["Setup_guide.pdf"])
        #expect(read.windows.first?.fields.isEmpty == true)
        #expect(read.unread == [9])
        let encoded = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(!encoded.contains("hunter2"))
    }
    /// A slider that answers "no value" (System Settings' brightness, read live) is read from where its thumb
    /// sits along its track: the frames of that live read give 0.47, the half the person had left it at.
    @Test func aSliderWithoutAValueIsReadFromItsThumb() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11, 13])
        tree.add(11, role: "AXSlider", children: [12], [
            "AXDescription": .string("Brightness"), "AXOrientation": .string("AXHorizontalOrientation"),
            "AXPositionX": .integer(-1208), "AXPositionY": .integer(-220), "AXSizeWidth": .integer(199), "AXSizeHeight": .integer(16)
        ])
        tree.add(12, role: "AXValueIndicator", ["AXPositionX": .integer(-1123), "AXPositionY": .integer(-220),
                                                 "AXSizeWidth": .integer(20), "AXSizeHeight": .integer(16)])
        // Vertical: the bottom is 0, a thumb at the top is 1.
        tree.add(13, role: "AXSlider", children: [14], [
            "AXDescription": .string("Volume"), "AXOrientation": .string("AXVerticalOrientation"),
            "AXPositionX": .integer(0), "AXPositionY": .integer(100), "AXSizeWidth": .integer(16), "AXSizeHeight": .integer(120)
        ])
        tree.add(14, role: "AXValueIndicator", ["AXPositionX": .integer(0), "AXPositionY": .integer(100),
                                                 "AXSizeWidth": .integer(16), "AXSizeHeight": .integer(20)])
        let fields = try #require(capture(tree, windows: [7]).windows.first?.fields)
        #expect(fields.map(\.value) == ["0.47", "1"])
    }

    /// A collection its share cut short gets the time the rest of the window did not need (a note list: a fourth of its
    /// rows read with half the box unused).
    @Test func theTimeTheWalkLeavesGoesBackToACollectionCutShort() throws {
        let tree = Tree()
        tree.cost = 0.001
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        let rows = Array(1000..<1100)
        tree.add(11, role: "AXTable", title: "Notes", ["AXRows": .nodes(rows, complete: true)])
        for row in rows { tree.add(row, role: "AXRow", title: "Note \(row)") }
        let collection = try #require(capture(tree, windows: [7]).windows.first?.collections.first)
        #expect(collection.coverage == .complete && collection.members.map(\.index) == Array(0..<100))
        #expect(collection.members.last?.name == "Note 1099")
    }

    @Test func aSlowCollectionLeavesTimeForTheRestOfTheWindow() throws {
        let tree = Tree()
        tree.cost = 0.001
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11, 20])
        let rows = Array(1000..<1300)
        tree.add(11, role: "AXOutline", title: "Sidebar", ["AXRows": .nodes(rows, complete: true)])
        for row in rows { tree.add(row, role: "AXRow") }
        // The pane beside the sidebar: a level another process hosts, and the slider in it.
        tree.add(20, role: "AXGroup", children: [21])
        tree.owners[20] = 99
        tree.owners[21] = 99
        tree.add(21, role: "AXSlider", title: "Brightness", ["AXLevel": .string("0.5")])
        let read = capture(tree, windows: [7])
        let window = try #require(read.windows.first)
        if case .range(0, let last) = window.collections.first?.coverage { #expect(last < rows.count - 1) } else { Issue.record("not a range") }
        #expect(window.hosted.contains { $0.processID == 99 && $0.read })
        #expect(window.fields == [.init(role: "AXSlider", name: "Brightness", identifier: nil, value: "0.5")])
    }

    @Test func theFocusedFieldIsReadFirstAndTheRestIsCounted() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true), "AXFocusedUIElement": .node(139)]
        let fields = Array(100..<140)
        window(tree, 10, number: 7, children: fields)
        for field in fields { tree.add(field, role: "AXTextField", title: "Comments \(field)", ["AXValue": .string("v\(field)")]) }
        tree.nodes[139]?["AXParent"] = .node(10)
        // The box ends once the walk is done: every field is known, few values fit.
        var calls = 0
        let read = InteractionStructuralReader.capture(reader: tree, application: 1, processID: 42, windows: [7], seconds: 1,
                                                       now: { calls += 1; return calls > 48 ? 2 : 0 })
        let window = try #require(read.windows.first)
        #expect(window.fields.first?.name == "Comments 139")
        #expect(window.fields.count + (window.quality.skippedFields ?? 0) == fields.count)
        #expect((window.quality.skippedFields ?? 0) > 0)
    }

    @Test func aRowIsNamedByTheTextBesideItsIcon() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXOutline", title: "list view", ["AXRows": .nodes([12], complete: true)])
        tree.add(12, role: "AXRow", children: [13])
        tree.add(13, role: "AXCell", children: [14, 15])
        tree.add(14, role: "AXImage")
        tree.add(15, role: "AXTextField", ["AXValue": .string("Setup_guide.pdf")])
        let read = capture(tree, windows: [7])
        #expect(read.windows.first?.collections.first?.members.map(\.name) == ["Setup_guide.pdf"])
    }

    /// An icon view grouped into sections is a list of lists: each section is read as a collection of its own, and a
    /// section is never named by its first item (the files were never read, only "Drafts, 2 items").
    @Test func sectionsOfACollectionAreReadAsCollections() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXList", title: "icon view", children: [12, 13])
        tree.add(12, role: "AXList", title: "Folders", children: [20])
        tree.add(13, role: "AXList", children: [21, 22])
        tree.add(20, role: "AXGroup", title: "Archive")
        tree.add(21, role: "AXGroup", children: [30])
        tree.add(22, role: "AXGroup", title: "Setup_guide.pdf")
        tree.add(30, role: "AXImage", ["AXDescription": .string("Letter.pdf")])
        let collections = try #require(read(capture(tree, windows: [7])))
        #expect(collections.map(\.name) == ["icon view", "Folders", nil])
        #expect(collections[0].members.map(\.name) == ["Folders", nil])
        #expect(collections[0].members.map(\.role) == ["AXList", "AXList"])
        #expect(collections[1].members.map(\.name) == ["Archive"])
        #expect(collections[2].members.map(\.name) == ["Letter.pdf", "Setup_guide.pdf"])
    }

    /// A row whose cell holds a view with its texts is named by the first text with a letter in that view: the title,
    /// not the time beside it (Notes: every note row was read without a name).
    @Test func aRowIsNamedByTheTitleInsideItsCellView() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXTable", title: "notes", ["AXRows": .nodes([12, 13], complete: true)])
        tree.add(12, role: "AXRow", children: [14])
        tree.add(14, role: "AXCell", children: [15])
        tree.add(15, role: "AXUnknown", children: [16, 17, 18])
        tree.add(16, role: "AXStaticText", ["AXValue": .string("15:18")])
        tree.add(17, role: "AXStaticText", ["AXValue": .string("Trip plan")])
        tree.add(18, role: "AXStaticText", ["AXValue": .string("No additional text")])
        tree.add(13, role: "AXRow", children: [19])
        tree.add(19, role: "AXCell", children: [20])
        tree.add(20, role: "AXUnknown", children: [21])
        tree.add(21, role: "AXStaticText", ["AXValue": .string("24/09/2026")])
        let collection = try #require(read(capture(tree, windows: [7]))?.first)
        #expect(collection.members.map(\.name) == ["Trip plan", "24/09/2026"])
    }

    /// The tree's order is not the reading order: a note's row lists two icons, its preview, its time and its folder
    /// before the title drawn above them all (Notes: rows were named "No additional text"). The text shown first, top
    /// then left, names the row.
    @Test func aRowIsNamedByTheTextItShowsFirst() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXTable", title: "notes", ["AXRows": .nodes([12], complete: true)])
        tree.add(12, role: "AXRow", children: [13])
        tree.add(13, role: "AXCell", children: [14])
        tree.add(14, role: "AXRow", children: Array(15...21))
        func text(_ node: Int, _ value: String, y: Int, x: Int) {
            tree.add(node, role: "AXStaticText", ["AXValue": .string(value), "AXPositionY": .integer(y), "AXPositionX": .integer(x)])
        }
        tree.add(15, role: "AXImage")
        tree.add(16, role: "AXImage")
        text(17, "No additional text", y: 140, x: 60)
        text(18, "17:24", y: 140, x: 20)
        tree.add(19, role: "AXImage", ["AXDescription": .string("move")])
        text(20, "Notes", y: 158, x: 20)
        text(21, "Meeting notes", y: 122, x: 20)
        let collection = try #require(read(capture(tree, windows: [7]))?.first)
        #expect(collection.members.map(\.name) == ["Meeting notes"])
    }

    private func read(_ read: InteractionStructuralRead) -> [InteractionStructuralRead.Collection]? {
        read.windows.first?.collections
    }

    /// A row's name read from a live element that answers once and not the next time is read once: it neither traps
    /// nor loses the name (a lazy compactMap read it twice and trapped).
    @Test func aNameThatChangesBetweenReadsIsReadOnce() throws {
        let tree = Tree()
        tree.nodes[1] = ["AXWindows": .nodes([10], complete: true)]
        window(tree, 10, number: 7, children: [11])
        tree.add(11, role: "AXOutline", title: "list view", ["AXRows": .nodes([12], complete: true)])
        tree.add(12, role: "AXRow", children: [13])
        tree.add(13, role: "AXCell", children: [14, 15])
        tree.add(14, role: "AXImage")
        tree.add(15, role: "AXTextField", ["AXValue": .string("Trip plan")])
        tree.flicker = [15]
        let read = capture(tree, windows: [7])
        #expect(read.windows.first?.collections.first?.members.map(\.name) == ["Trip plan"])
    }
}
