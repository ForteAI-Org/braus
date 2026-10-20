import ApplicationServices
import CoreGraphics
import EngineCore
import Foundation
@testable import MacDriver
@testable import MacDriving
import Synchronization
import Testing

/// Two documents of one app, identical down to their controls, whose order in `AXWindows` the app swaps between the
/// scene's read and the action, with no input from the person (defect A of the closure audit, N03 and N04). Every
/// accessibility request is refused before it is sent, to either window, and the engine reads again. No app and no
/// trusted accessibility: a fake app resolves addresses by the live reader's rules, and the live window check runs on
/// elements made offline, which carry an identity but answer no message.
@Suite("Mac windows reordered between observe and act")
struct MacWindowOrderTests {

    /// SwappingTreeReader is an app with two identical documents, `A` and `B`, `A` in front until `swap()`. It resolves
    /// an address as `LiveMacTreeReader` does: the window at the address's index in the current order, checked with
    /// `MacElementAddress.admits` against that window's identity, then the path, then the role and the name. Every
    /// request it receives is recorded with the document it reached.
    final class SwappingTreeReader: MacTreeReading, MacAccessibilityActing {

        struct Document {
            let label   : String
            let tree    : MacTreeNode
            let identity: MacWindowIdentity
        }

        let isTrusted = true
        private let documents: [Document]
        /// Whether reads give the window's identity: false plays a reader that cannot say (legacy addresses).
        private let givesIdentity: Bool
        private let state = Mutex<(isSwapped: Bool, losesIdentity: Bool)>((false, false))
        let requests = Mutex<[String]>([])

        init(_ tree: MacTreeNode, givesIdentity: Bool = true) {
            documents = ["A", "B"].map { Document(label: $0, tree: tree.addressed(), identity: .init(synthetic: $0)) }
            self.givesIdentity = givesIdentity
        }

        /// The app brings `B` in front of `A` by itself.
        func swap() { state.withLock { $0.isSwapped = true } }

        /// From now on no window answers with an identity.
        func loseIdentities() { state.withLock { $0.losesIdentity = true } }

        private var order: [Document] { state.withLock { $0.isSwapped } ? documents.reversed() : documents }

        private func identity(of document: Document) -> MacWindowIdentity? {
            state.withLock { $0.losesIdentity } ? nil : document.identity
        }

        func windows(of processID: pid_t) throws -> [MacWindowSummary] {
            order.enumerated().map { index, document in
                MacWindowSummary(index: index, role: "AXWindow", subrole: document.tree.subrole,
                                 title: document.tree.title, frame: document.tree.frame, isFocused: index == 0)
            }
        }

        func read(windowAt index: Int, of processID: pid_t, limits: MacTreeLimits) throws -> MacTreeRead {
            let order = self.order
            guard order.indices.contains(index) else { throw MacTreeFailure.windowNotFound(index: index) }
            let document = order[index]
            return MacTreeRead(window: document.tree, nodesVisited: document.tree.flattened.count,
                               windowIdentity: givesIdentity ? identity(of: document) : nil)
        }

        func perform(_ action: String, on element: MacElementAddress) throws {
            let (label, _) = try resolve(element)
            requests.withLock { $0.append("perform \(action) in \(label) \(element.path)") }
        }

        func select(_ element: MacElementAddress) throws {
            let (label, _) = try resolve(element)
            requests.withLock { $0.append("select in \(label) \(element.path)") }
        }

        func focus(_ element: MacElementAddress) throws {
            let (label, _) = try resolve(element)
            requests.withLock { $0.append("focus in \(label) \(element.path)") }
        }

        func scroll(_ area: MacElementAddress, _ direction: MacScrollDirection) throws -> String {
            let (label, _) = try resolve(area)
            requests.withLock { $0.append("scroll \(direction.rawValue) in \(label) \(area.path)") }
            return "scroll bar AXValue"
        }

        /// As the live read-back: the window is checked, the role and the name are not.
        func readBack(_ element: MacElementAddress) -> MacTreeNode? {
            try? resolve(element, checksIdentity: false).node
        }

        /// The document the address reaches and the node there, by the live reader's rules.
        private func resolve(_ element: MacElementAddress, checksIdentity: Bool = true) throws
            -> (label: String, node: MacTreeNode) {
            let order = self.order
            guard order.indices.contains(element.windowIndex) else {
                throw MacTreeFailure.windowNotFound(index: element.windowIndex)
            }
            let document = order[element.windowIndex]
            guard element.admits(identity(of: document)) else { throw MacTreeFailure.staleTarget(path: element.path) }
            var node = document.tree
            for step in element.path {
                guard node.children.indices.contains(step) else { throw MacTreeFailure.staleTarget(path: element.path) }
                node = node.children[step]
            }
            guard checksIdentity else { return (document.label, node) }
            let names = [node.title, node.descriptionText, node.help, node.placeholder, node.value].compactMap { $0 }
                + node.flattened.filter { $0.role == "AXStaticText" }.compactMap(\.value)
            guard node.role == element.role, element.name.map(names.contains) ?? true else {
                throw MacTreeFailure.staleTarget(path: element.path)
            }
            return (document.label, node)
        }
    }

    static let frame = CGRect(x: 100, y: 100, width: 400, height: 300)

    /// One document: the same title, frame, button and pop-up in both, so neither the scene nor the window's frame
    /// tells them apart.
    static let document: MacTreeNode = Trees.window("Senza titolo", frame, children: [
        MacTreeNode(role: "AXButton", title: "Salva", frame: CGRect(x: 110, y: 110, width: 60, height: 20),
                    actions: ["AXPress"]),
        MacTreeNode(role: "AXPopUpButton", value: "medio", frame: CGRect(x: 180, y: 110, width: 80, height: 20),
                    actions: ["AXPress"]),
    ])

    static let saveButton = CGPoint(x: 140, y: 120)

    /// The scene of the front document, read and cached as the engine reads it before acting.
    private func observed(by reader: SwappingTreeReader, into cache: MacSceneCache = MacSceneCache()) async throws
        -> MacSceneCache {
        let scenes = MacScenes(reader: reader, cache: cache, serverWindows: { _ in [] })
        _ = try await scenes.scene(of: 9)
        return cache
    }

    private func actuator(_ reader: SwappingTreeReader, _ cache: MacSceneCache, _ delivery: FakeDelivery)
        -> MacActuator {
        MacActuator(cache: cache, actor: reader, delivery: delivery, person: nil)
    }

    // MARK: The identity

    @Test("identities are equal only for the same window: synthetic by token, live by element, never across kinds")
    func identityEquality() {
        #expect(MacWindowIdentity(synthetic: "A") == MacWindowIdentity(synthetic: "A"))
        #expect(MacWindowIdentity(synthetic: "A") != MacWindowIdentity(synthetic: "B"))
        // Application elements stand in for windows: they compare by process and element, and send no message.
        let first  = AXUIElementCreateApplication(900_001)
        let second = AXUIElementCreateApplication(900_002)
        #expect(MacWindowIdentity(window: first) == MacWindowIdentity(window: AXUIElementCreateApplication(900_001)))
        #expect(MacWindowIdentity(window: first) != MacWindowIdentity(window: second))
        for token in [String(describing: first), "\(CFHash(first))", "900001", "A"] {
            #expect(MacWindowIdentity(window: first) != MacWindowIdentity(synthetic: token), "\(token)")
        }
    }

    @Test("an address admits its own window only; a legacy address without one admits any, as before")
    func admits() {
        let address = MacElementAddress(processID: 9, windowIndex: 0, path: [0], role: "AXButton",
                                        window: MacWindowIdentity(synthetic: "A"))
        #expect(address.admits(MacWindowIdentity(synthetic: "A")))
        #expect(!address.admits(MacWindowIdentity(synthetic: "B")))
        #expect(!address.admits(nil), "an expected window refuses a current one with no identity")
        let legacy = MacElementAddress(processID: 9, windowIndex: 0, path: [0], role: "AXButton")
        #expect(legacy.admits(MacWindowIdentity(synthetic: "B")) && legacy.admits(nil))
    }

    @Test("the live window check takes the window at the index only when it is the one read; it sends nothing")
    func liveWindowCheck() throws {
        let documentA = AXUIElementCreateApplication(900_011)
        let documentB = AXUIElementCreateApplication(900_012)
        let address = MacElementAddress(processID: 9, windowIndex: 0, path: [0], role: "AXButton",
                                        window: MacWindowIdentity(window: documentA))
        let unchanged = try LiveMacTreeReader.attestedWindow(in: [documentA, documentB], for: address)
        #expect(CFEqual(unchanged, documentA))
        #expect(throws: MacTreeFailure.staleTarget(path: [0])) {
            try LiveMacTreeReader.attestedWindow(in: [documentB, documentA], for: address)
        }
        #expect(throws: MacTreeFailure.windowNotFound(index: 0)) {
            try LiveMacTreeReader.attestedWindow(in: [], for: address)
        }
        var legacy = address
        legacy.window = nil
        #expect(CFEqual(try LiveMacTreeReader.attestedWindow(in: [documentB, documentA], for: legacy), documentB))
    }

    @Test("the scene keeps the identity of the window it read, and a new read keeps the new one")
    func sceneKeepsIdentity() async throws {
        let reader = SwappingTreeReader(Self.document)
        let cache  = try await observed(by: reader)
        #expect(cache.latest(for: 9)?.windowIdentity == MacWindowIdentity(synthetic: "A"))
        reader.swap()
        _ = try await observed(by: reader, into: cache)
        #expect(cache.latest(for: 9)?.windowIdentity == MacWindowIdentity(synthetic: "B"))
    }

    // MARK: Acting after the swap

    @Test("with the order unchanged, the click reaches the document the scene was read from")
    func unchangedOrder() async throws {
        let reader   = SwappingTreeReader(Self.document)
        let delivery = FakeDelivery()
        try await actuator(reader, try await observed(by: reader), delivery).perform(.click(at: Self.saveButton), in: 9)
        #expect(reader.requests.withLock { $0 } == ["perform AXPress in A [0]"])
        #expect(delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("a click after the app swapped its documents is refused before any request, to either window")
    func clickAfterSwap() async throws {
        let reader   = SwappingTreeReader(Self.document)
        let delivery = FakeDelivery()
        let actuator = actuator(reader, try await observed(by: reader), delivery)
        reader.swap()
        await #expect(throws: try #require(MacActuationFailure.staleTarget([0]).notSent)) {
            try await actuator.perform(.click(at: Self.saveButton), in: 9)
        }
        #expect(reader.requests.withLock { $0 }.isEmpty, "nothing reached B, nor A")
        #expect(delivery.sent.withLock { $0 }.isEmpty, "and nothing went to rung 2")
        #expect(actuator.lastDelivery(in: 9) == nil, "no rung is noted as having run")
    }

    @Test("a control press after the app swapped its documents is refused before any request")
    func controlPressAfterSwap() async throws {
        let reader   = SwappingTreeReader(Self.document)
        let controls = MacControls(cache: try await observed(by: reader), reader: reader, actor: reader,
                                   menus: NoMenus())
        reader.swap()
        #expect(!(await controls.pressControl(labelled: "medio", in: 9)))
        #expect(reader.requests.withLock { $0 }.isEmpty, "nothing reached B, nor A")
    }

    @Test("after the swap a new observe reads B, and the click then reaches B")
    func newObserveAfterSwap() async throws {
        let reader   = SwappingTreeReader(Self.document)
        let delivery = FakeDelivery()
        let cache    = try await observed(by: reader)
        reader.swap()
        _ = try await observed(by: reader, into: cache)
        try await actuator(reader, cache, delivery).perform(.click(at: Self.saveButton), in: 9)
        #expect(reader.requests.withLock { $0 } == ["perform AXPress in B [0]"])
    }

    @Test("a window that answers no identity is refused to an address that names one")
    func currentWithoutIdentity() async throws {
        let reader   = SwappingTreeReader(Self.document)
        let delivery = FakeDelivery()
        let actuator = actuator(reader, try await observed(by: reader), delivery)
        reader.loseIdentities()
        await #expect(throws: try #require(MacActuationFailure.staleTarget([0]).notSent)) {
            try await actuator.perform(.click(at: Self.saveButton), in: 9)
        }
        #expect(reader.requests.withLock { $0 }.isEmpty && delivery.sent.withLock { $0 }.isEmpty)
    }

    @Test("a reader that gives no identity makes legacy addresses, which act by index as before the check")
    func legacyReader() async throws {
        let reader   = SwappingTreeReader(Self.document, givesIdentity: false)
        let delivery = FakeDelivery()
        let actuator = actuator(reader, try await observed(by: reader), delivery)
        reader.swap()
        try await actuator.perform(.click(at: Self.saveButton), in: 9)
        #expect(reader.requests.withLock { $0 } == ["perform AXPress in B [0]"], "the gap a legacy address keeps")
    }

    /// Each kind of accessibility step on `MacRungTests.window`: a press, a focus, a selection and a page scroll.
    static let steps: [(gesture: Gesture, request: String)] = [
        (.click(at: CGPoint(x: 20, y: 20)), "perform AXPress in A [0]"),
        (.click(at: CGPoint(x: 50, y: 50)), "focus in A [2]"),
        (.click(at: CGPoint(x: 20, y: 78)), "select in A [4, 0, 0]"),
        (.scroll(at: CGPoint(x: 20, y: 78), deltaY: -3), "scroll down in A [4]"),
    ]

    @Test("every kind of accessibility step carries the scene's window and is refused after the swap",
          arguments: steps.indices)
    func everyStepAfterSwap(step: Int) async throws {
        let (gesture, request) = Self.steps[step]
        let unchanged = SwappingTreeReader(MacRungTests.window)
        try await actuator(unchanged, try await observed(by: unchanged), FakeDelivery()).perform(gesture, in: 9)
        #expect(unchanged.requests.withLock { $0 } == [request], "the step reaches A in order")

        let reader   = SwappingTreeReader(MacRungTests.window)
        let delivery = FakeDelivery()
        let actuator = actuator(reader, try await observed(by: reader), delivery)
        reader.swap()
        await #expect(throws: GestureNotSent.self) { try await actuator.perform(gesture, in: 9) }
        #expect(reader.requests.withLock { $0 }.isEmpty && delivery.sent.withLock { $0 }.isEmpty, "\(request)")
    }

    @Test("a read-back checks the window though it skips the role and the name")
    func readBackChecksTheWindow() async throws {
        let reader  = SwappingTreeReader(Self.document)
        let entry   = try #require(try await observed(by: reader).latest(for: 9))
        let address = MacElementAddress(processID: 9, windowIndex: entry.windowIndex, path: [0], role: "AXGroup",
                                        window: entry.windowIdentity)
        #expect(reader.readBack(address)?.title == "Salva", "role and name are not checked")
        reader.swap()
        #expect(reader.readBack(address) == nil, "another window is not read back")
    }
}
