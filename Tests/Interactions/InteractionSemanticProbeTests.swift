import Foundation
import Testing
@testable import InteractionObservation

@Suite
struct InteractionSemanticProbeTests {
    private final class Reader: InteractionSemanticReading {
        var values: [Int: [String: InteractionSemanticProbe.Value<Int>]] = [:]
        var calls: [(Int, String)] = []
        var delay: Double = 0
        /// A busy wait per message, for costs below the sleep granularity.
        var spin: Double = 0
        func same(_ first: Int, _ second: Int) -> Bool { first == second }
        func read(_ node: Int, _ attribute: String, limit: Int) -> InteractionSemanticProbe.Value<Int> {
            calls.append((node, attribute))
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if spin > 0 {
                let end = ProcessInfo.processInfo.systemUptime + spin
                while ProcessInfo.processInfo.systemUptime < end {}
            }
            if attribute == "windowNumber", values[node]?[attribute] == nil, node >= 1000 { return .integer(7) }
            guard case .nodes(let nodes, let complete)? = values[node]?[attribute] else {
                return values[node]?[attribute] ?? .unsupported
            }
            return nodes.count > limit ? .nodes(Array(nodes.prefix(limit)), complete: false) : .nodes(nodes, complete: complete)
        }
    }

    @Test func selectedRowsFocusAndThreeStateAnswers() throws {
        let reader = fixture()
        let snapshot = capture(reader)
        #expect(snapshot.focusedElement?.label == "Name")
        #expect(snapshot.row(containing: try #require(snapshot.focusedElement))?.label == "Alpha")
        #expect(Set(snapshot.selectedElements.compactMap(\.label)) == ["Alpha", "Beta"])
        #expect(snapshot.elements.first { $0.label == "Gamma" }?.selected == .value(false))
        #expect(snapshot.elements.first { $0.label == "Beta" }?.selected == .unsupported)
        #expect(snapshot.elements.first { $0.label == "Unread" }?.selected == .unread)
        #expect(snapshot.elements.first { $0.label == "Objects" }?.membershipComplete == true)
        #expect(snapshot.elements.first { $0.label == "Alpha" }?.index == .value(0))
        #expect(snapshot.elements.first { $0.label == "Alpha" }?.expanded == .value(true))
        #expect(!reader.calls.contains { $0.1 == "AXValue" })
    }

    @Test func protectedSelectionStoresOnlyProtected() throws {
        let reader = fixture()
        reader.values[3] = ["AXRole": .string("AXTextField"), "AXSubrole": .string("AXSecureTextField"),
                            "AXTitle": .string("never retain"), "AXSelected": .bool(true), "AXValue": .string("secret")]
        let snapshot = capture(reader)
        #expect(snapshot.focused == .protected)
        let data = try JSONEncoder().encode(snapshot)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("never retain") && !text.contains("secret"))
        #expect(!reader.calls.contains { $0.0 == 3 && ["AXTitle", "AXSelected", "AXValue"].contains($0.1) })
        #expect(snapshot.elements.first { $0.isProtected }?.selected == .protected)
    }

    @Test func capsNodesMessagesAndPartialMembership() {
        let reader = fixture()
        reader.values[2]?["AXRows"] = .nodes(Array(4...80), complete: false)
        let snapshot = InteractionSemanticProbe.capture(reader: reader, application: 0, processID: 42,
            windows: [7], maximumElements: 8, maximumReads: 80, isReserved: { _ in false })
        #expect(snapshot.elements.count <= 8)
        #expect(snapshot.attributeReads <= 80)
        #expect(snapshot.truncated)
        #expect(snapshot.elements.first { $0.label == "Objects" }?.membershipComplete == false)
    }

    @Test func protectedAncestorsAndWindowTitlesAreWithheldEverywhere() throws {
        let reader = fixture()
        reader.values[4] = ["AXRole": .string("AXGroup"), "AXTitle": .string("Password"),
                            "windowNumber": .integer(7), "AXParent": .node(2)]
        reader.values[3]?["AXTitle"] = .string("private caption")
        reader.values[3]?["AXIdentifier"] = .string("private identifier")
        reader.values[3]?["AXSelected"] = .bool(true)
        reader.values[1]?["AXTitle"] = .string("private window title")
        let snapshot = capture(reader)
        let text = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(snapshot.focused == .protected)
        #expect(!text.contains("private caption"))
        #expect(!text.contains("private identifier"))
        #expect(!text.contains("private window title"))
    }

    @Test func partialSelectedRowsCannotReenterThroughIndividualSelectionFlags() {
        let reader = fixture()
        reader.values[2]?["AXSelectedRows"] = .nodes([4], complete: false)
        reader.values[4]?["AXSelected"] = .bool(true)
        let snapshot = capture(reader)
        #expect(snapshot.selectedElements.isEmpty)
    }

    @Test func unreadSubtreeCannotProveAnUnfocusedSelectionScope() {
        let reader = fixture()
        reader.values[0]?["AXFocusedUIElement"] = .unsupported
        reader.values[1]?["AXChildren"] = .nodes([2, 8], complete: true)
        reader.values[8] = ["AXRole": .string("AXGroup"), "windowNumber": .integer(7), "AXChildren": .unread]
        let snapshot = capture(reader)
        #expect(snapshot.truncated)
        #expect(snapshot.selection(in: 7) == nil)
    }

    @Test func unreadAncestorWithholdsDescendantLabelsAndSelection() throws {
        let reader = fixture()
        reader.values[4]?["AXSubrole"] = .unread
        reader.values[3]?["AXTitle"] = .string("private caption")
        reader.values[3]?["AXSelected"] = .bool(true)
        let snapshot = capture(reader)
        #expect(snapshot.focused == .unread)
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("private caption"))
    }

    @Test func selectedRowsBeyondTheElementCapAreReadFirst() throws {
        let reader = Reader()
        let buttons = Array(100..<140)
        reader.values[0] = ["AXFocusedUIElement": .unread, "AXWindows": .nodes([1], complete: true)]
        reader.values[1] = ["AXRole": .string("AXWindow"), "AXTitle": .string("Workspace"),
                            "windowNumber": .integer(7), "AXChildren": .nodes(buttons + [2], complete: true)]
        for id in buttons {
            reader.values[id] = ["AXRole": .string("AXButton"), "AXTitle": .string("Button \(id)"), "windowNumber": .integer(7)]
        }
        reader.values[2] = ["AXRole": .string("AXScrollArea"), "windowNumber": .integer(7), "AXChildren": .nodes([3], complete: true)]
        reader.values[3] = ["AXRole": .string("AXTable"), "AXTitle": .string("Objects"), "windowNumber": .integer(7),
                            "AXSelectedRows": .nodes([245, 248], complete: true),
                            "AXRows": .nodes(Array(200..<232), complete: false)]
        for id in 200..<250 {
            reader.values[id] = ["AXRole": .string("AXRow"), "windowNumber": .integer(7), "AXParent": .node(3),
                                 "AXChildren": .nodes([id + 100], complete: true)]
            reader.values[id + 100] = ["AXRole": .string("AXStaticText"), "AXValue": .string("Row \(id - 200)"),
                                       "windowNumber": .integer(7)]
        }
        let snapshot = InteractionSemanticProbe.capture(reader: reader, application: 0, processID: 42,
            windows: [7], maximumElements: 16, isReserved: { _ in false })
        #expect(snapshot.truncated)
        #expect(snapshot.selectionScan == true)
        #expect(snapshot.elements.count <= 16)
        let selection = try #require(snapshot.selection(in: 7))
        #expect(selection.objects.compactMap(\.label) == ["Row 45", "Row 48"])
        // Without the search, a truncated walk cannot name the scope.
        var unscanned = snapshot
        unscanned.selectionScan = nil
        unscanned.scannedWindows = nil
        #expect(unscanned.selection(in: 7) == nil)
    }

    @Test func searchResumesAcrossProbesAndRowsTakeTheirNameFromDescendants() throws {
        let reader = Reader()
        let groups = Array(100..<130)
        reader.values[0] = ["AXFocusedUIElement": .unread, "AXWindows": .nodes([1], complete: true)]
        reader.values[1] = ["AXRole": .string("AXWindow"), "windowNumber": .integer(7),
                            "AXChildren": .nodes(groups + [3], complete: true)]
        for id in groups {
            reader.values[id] = ["AXRole": .string("AXGroup"), "windowNumber": .integer(7),
                                 "AXChildren": .nodes([id + 1000], complete: true)]
            reader.values[id + 1000] = ["AXRole": .string("AXButton"), "windowNumber": .integer(7)]
        }
        // A table straight under the window whose selected row is named only inside its cells.
        reader.values[3] = ["AXRole": .string("AXTable"), "AXTitle": .string("Objects"), "windowNumber": .integer(7),
                            "AXSelectedRows": .nodes([5], complete: true), "AXRows": .nodes([5], complete: true)]
        reader.values[5] = ["AXRole": .string("AXRow"), "windowNumber": .integer(7), "AXParent": .node(3),
                            "AXChildren": .nodes([6, 7], complete: true)]
        reader.values[6] = ["AXRole": .string("AXCell"), "windowNumber": .integer(7), "AXChildren": .nodes([8], complete: true)]
        reader.values[7] = ["AXRole": .string("AXCell"), "windowNumber": .integer(7), "AXChildren": .nodes([9], complete: true)]
        reader.values[8] = ["AXRole": .string("AXButton"), "AXTitle": .string("Name"), "AXValue": .string("Second take"),
                            "windowNumber": .integer(7)]
        reader.values[9] = ["AXRole": .string("AXTextField"), "AXTitle": .string("Notes"), "AXValue": .string("never read"),
                            "windowNumber": .integer(7)]
        let memory = InteractionSemanticProbe.ScanMemory<Int>(processID: 42, started: 0)
        var clock = 0.0
        func probe() -> InteractionSemanticSnapshot {
            clock += 10
            var reads = 0
            // Each probe has time for about forty messages.
            return InteractionSemanticProbe.capture(reader: reader, application: 0, processID: 42, windows: [7],
                memory: memory, now: { reads += 1; return clock + Double(reads) * 0.0008 }, isReserved: { _ in false })
        }
        let first = probe()
        #expect(first.selectionScan == false)
        #expect(first.selection(in: 7) == nil)
        var last = first
        for _ in 0..<6 where last.selectionScan != true { last = probe() }
        #expect(last.selectionScan == true)
        #expect(last.scannedWindows == [7])
        let selection = try #require(last.selection(in: 7))
        #expect(selection.objects.compactMap(\.label) == ["Second take"])
        #expect(!reader.calls.contains { $0.0 == 9 && $0.1 == "AXValue" })
        // A new process starts a new search.
        memory.renew(processID: 43, at: clock)
        #expect(memory.windows.isEmpty)
    }

    @Test func fakeReaderBenchmark() {
        var times: [Double] = []
        var messages: [Int] = []
        for _ in 0..<30 {
            let snapshot = capture(fixture())
            times.append(snapshot.interval.milliseconds)
            messages.append(snapshot.attributeReads)
        }
        let slow = fixture()
        slow.delay = 0.002
        let bounded = capture(slow)
        #expect(bounded.truncated)
        #expect(bounded.interval.milliseconds < 150)
        #expect(bounded.attributeReads < 50)
        let sorted = times.sorted()
        print("PHASE2_AX_FAKE fast n=30 median_ms=\(sorted[15]) p95_ms=\(sorted[28]) max_ms=\(sorted.last ?? 0) messages=\(messages.max() ?? 0)")
        print("PHASE2_AX_FAKE slow message_delay_ms=2 elapsed_ms=\(bounded.interval.milliseconds) messages=\(bounded.attributeReads) truncated=\(bounded.truncated)")
    }

    @Test func selectedFileRowGoesByItsFileNameAndSlidersByTheirLevel() throws {
        let reader = longList(rows: 40, selected: 30)
        reader.values[7] = ["AXRole": .string("AXSlider"), "AXDescription": .string("Brightness"), "AXLevel": .string("0.7"),
                            "windowNumber": .integer(7)]
        reader.values[1]?["AXChildren"] = .nodes([2, 3, 7], complete: true)
        reader.values[0]?["AXFocusedUIElement"] = .node(7)
        reader.values[7]?["AXParent"] = .node(1)
        let snapshot = InteractionSemanticProbe.capture(reader: reader, application: 0, processID: 42, windows: [7],
                                                        isReserved: { _ in false })
        #expect(snapshot.selectedElements.compactMap(\.label) == ["File 30.pdf"])
        #expect(snapshot.focusedElement?.level == "0.7")
        // A field's own text is still never read to name a row.
        #expect(!reader.calls.contains { $0.0 == 10_305 && $0.1 == "AXValue" })
    }

    /// Probe cost by cap on a long file list, each message costing what a live log measured per query.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAUS_PROBE_BENCH"] != nil))
    func listProbeCostByCap() {
        for perMessage in [0.063, 0.089] {
            for (elements, reads) in [(64, 512), (128, 1024), (192, 1536), (256, 2048)] {
                var times: [Double] = []
                var last = InteractionSemanticSnapshot(processID: 42, interval: .init(start: 0, end: 0))
                for _ in 0..<9 {
                    let reader = longList(rows: 300, selected: 220)
                    reader.spin = perMessage / 1000
                    last = InteractionSemanticProbe.capture(reader: reader, application: 0, processID: 42, windows: [7],
                        maximumElements: elements, maximumReads: reads, seconds: 1, isReserved: { _ in false })
                    times.append(last.interval.milliseconds)
                }
                let named = last.selectedElements.compactMap(\.label)
                print("PROBE_BENCH per_message_ms=\(perMessage) elements=\(elements) reads=\(reads) median_ms=\(times.sorted()[4]) max_ms=\(times.max() ?? 0) kept=\(last.elements.count) messages=\(last.attributeReads) truncated=\(last.truncated) selected=\(named)")
            }
        }
    }

    /// A window with a toolbar, a sidebar and a list of `rows` files, each row four cells deep, one selected.
    private func longList(rows: Int, selected: Int) -> Reader {
        let reader = Reader()
        let toolbar = Array(1000..<1012), sidebar = Array(2000..<2020)
        let list = (0..<rows).map { 10_000 + $0 * 10 }
        reader.values[0] = ["AXFocusedUIElement": .node(6), "AXWindows": .nodes([1], complete: true)]
        reader.values[1] = ["AXRole": .string("AXWindow"), "AXTitle": .string("Downloads"), "windowNumber": .integer(7),
                            "AXChildren": .nodes([2, 3], complete: true)]
        reader.values[2] = ["AXRole": .string("AXToolbar"), "windowNumber": .integer(7), "AXChildren": .nodes(toolbar, complete: true)]
        for id in toolbar { reader.values[id] = ["AXRole": .string("AXButton"), "AXTitle": .string("Tool \(id)")] }
        reader.values[3] = ["AXRole": .string("AXSplitGroup"), "windowNumber": .integer(7), "AXChildren": .nodes([4, 5], complete: true)]
        reader.values[4] = ["AXRole": .string("AXOutline"), "AXDescription": .string("sidebar"),
                            "AXRows": .nodes(sidebar, complete: true), "AXSelectedRows": .nodes([], complete: true),
                            "AXChildren": .nodes(sidebar, complete: true)]
        for id in sidebar { reader.values[id] = ["AXRole": .string("AXRow"), "AXDescription": .string("Place \(id)")] }
        reader.values[5] = ["AXRole": .string("AXScrollArea"), "windowNumber": .integer(7), "AXChildren": .nodes([6], complete: true)]
        reader.values[6] = ["AXRole": .string("AXOutline"), "AXDescription": .string("list view"),
                            "AXRows": .nodes(list, complete: true), "AXSelectedRows": .nodes([list[selected]], complete: true),
                            "AXChildren": .nodes(list, complete: true)]
        for (index, row) in list.enumerated() {
            reader.values[row] = ["AXRole": .string("AXRow"), "AXIndex": .integer(index), "AXParent": .node(6),
                                  "AXChildren": .nodes([row + 1, row + 2, row + 3, row + 4], complete: true)]
            reader.values[row + 1] = ["AXRole": .string("AXCell"), "AXFilename": .string("File \(index).pdf"),
                                      "AXChildren": .nodes([row + 5], complete: true)]
            reader.values[row + 5] = ["AXRole": .string("AXTextField"), "AXValue": .string("File \(index).pdf")]
            for (offset, text) in [(2, "19 Oct 2026 at 14:\(index % 60)"), (3, "1,6 MB"), (4, "PDF Document")] {
                reader.values[row + offset] = ["AXRole": .string("AXCell"), "AXChildren": .nodes([row + offset + 5], complete: true)]
                reader.values[row + offset + 5] = ["AXRole": .string("AXStaticText"), "AXValue": .string(text)]
            }
        }
        return reader
    }

    private func capture(_ reader: Reader) -> InteractionSemanticSnapshot {
        InteractionSemanticProbe.capture(reader: reader, application: 0, processID: 42, windows: [7],
                                           isReserved: { $0.lowercased().contains("password") })
    }

    private func fixture() -> Reader {
        let reader = Reader()
        reader.values[0] = ["AXFocusedUIElement": .node(3), "AXWindows": .nodes([1], complete: true)]
        reader.values[1] = ["AXRole": .string("AXWindow"), "AXTitle": .string("Workspace"),
                            "windowNumber": .integer(7), "AXChildren": .nodes([2], complete: true)]
        reader.values[2] = ["AXRole": .string("AXTable"), "AXTitle": .string("Objects"), "windowNumber": .integer(7),
                            "AXSelectedRows": .nodes([4, 5], complete: true), "AXRows": .nodes([4, 5, 6, 7], complete: true)]
        reader.values[3] = ["AXRole": .string("AXTextField"), "AXTitle": .string("Name"),
                            "windowNumber": .integer(7), "AXParent": .node(4)]
        for (id, label) in [(4, "Alpha"), (5, "Beta"), (6, "Gamma"), (7, "Unread")] {
            reader.values[id] = ["AXRole": .string("AXRow"), "AXTitle": .string(label), "windowNumber": .integer(7),
                                "AXParent": .node(2), "AXIndex": .integer(id - 4)]
        }
        reader.values[4]?["AXSelected"] = .bool(true)
        reader.values[4]?["AXExpanded"] = .bool(true)
        reader.values[6]?["AXSelected"] = .bool(false)
        reader.values[7]?["AXSelected"] = .unread
        return reader
    }
}
