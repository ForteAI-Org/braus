//
//  DialogEndpointResolverTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The discovery of the window a dialog's events actually have to reach.
///
/// Every row is driven with a fake world: an accessibility tree that answers
/// frames, Window IDs and PIDs, and a window server that answers identities in
/// order so a row can make two readings disagree. The oracle is that world and
/// not the implementation: the test states which window really owns what, and
/// then asks what the discovery concluded.
///
/// The identifiers are this fixture's own. No Window ID, PID or connection from
/// any live measurement appears here, because the shipping code must never
/// recognise a number and a test that pinned one would invite it to.
@Suite("The dialog endpoint discovery")
struct DialogEndpointResolverTests {

    // MARK: The world

    private struct Node: Hashable {
        let id: Int
    }

    /// One accessibility subtree. A node missing from `windows` or `processes`
    /// is a node whose read failed, which is the incomplete subtree.
    private struct Tree {
        var hit      : Int?
        var focused  : Int?
        var frames   : [Int: CGRect] = [:]
        var children : [Int: [Int]]  = [:]
        var windows  : [Int: Int]    = [:]
        var processes: [Int: Int32]  = [:]
        var parents  : [Int: Int]    = [:]
        var unreadableWindows : Set<Int> = []
        var unreadableChildren: Set<Int> = []

        /// The page's own facts: AX reports no focused control (`-25212`), the
        /// application's focused window, and which nodes are an `AXWebArea`.
        var focusIsAbsent: Bool = false
        var focusedWindow: Int?
        var webAreas     : Set<Int> = []

        /// The application's `AXWindows` entries, by Window ID.
        var windowNodes  : [Int: Int] = [:]

        /// A control that takes the focus after this many reads of it.
        var focusAppearsAfterReads: Int?
    }

    private final class Answers {
        var identityCalls = 0
        var focusReads    = 0
    }

    private static let hostWindow    = 900
    private static let sheetWindow   = 901
    private static let remoteWindow  = 902
    private static let hostProcessID : Int32 = 100
    private static let remoteProcess : Int32 = 200

    private static let surfaceFrame = CGRect(x: 400, y: 300, width: 600, height: 400)
    private static let contentFrame = CGRect(x: 400, y: 340, width: 600, height: 360)
    private static let buttonFrame  = CGRect(x: 440, y: 650, width: 100, height: 30)
    private static let pointOnCancel = CGPoint(x: 490, y: 665)

    private func identity(
        window    : Int,
        processID : Int32,
        connection: Int32,
        serial    : UInt32 = 1
    ) -> WindowIdentity {

        WindowIdentity(
            process: ProcessIdentity(
                processID       : processID,
                serialNumberHigh: 0,
                serialNumberLow : serial
            ),
            windowNumber     : window,
            ownerConnectionID: connection
        )
    }

    private var host: WindowIdentity {
        identity(window: Self.hostWindow, processID: Self.hostProcessID, connection: 7000)
    }

    private var sheet: WindowIdentity {
        identity(window: Self.sheetWindow, processID: Self.hostProcessID, connection: 7000)
    }

    private var remote: WindowIdentity {
        identity(window: Self.remoteWindow, processID: Self.remoteProcess, connection: 8000)
    }

    private var chain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: host, surface: sheet, surfaceFrame: Self.surfaceFrame)
    }

    private func observation(
        _ identity: WindowIdentity,
        _ frame   : CGRect
    ) -> WindowGeometryObservation {

        WindowGeometryObservation(
            window     : WindowReference(identity: identity, frame: frame),
            scaleFactor: 2,
            version    : GeometryObservationVersion(observerGeneration: 0, sequence: 1)
        )!
    }

    /// The measured shape: the hit test stops at the sheet, which answers the
    /// host's Window ID, and the panel's own control below it answers the
    /// remote one while accessibility keeps reporting the host's PID.
    private var hostedPanelTree: Tree {
        Tree(
            hit      : 1,
            focused  : 3,
            frames   : [1: Self.surfaceFrame, 2: Self.contentFrame, 3: Self.buttonFrame],
            children : [1: [2], 2: [3]],
            windows  : [1: Self.sheetWindow, 2: Self.remoteWindow, 3: Self.remoteWindow],
            processes: [1: Self.hostProcessID, 2: Self.hostProcessID, 3: Self.hostProcessID]
        )
    }

    private func makeResolver(
        tree      : Tree,
        identities: [Int: [WindowIdentity?]],
        geometries: [Int: WindowGeometryObservation],
        now       : UInt64 = 1_000_000
    ) -> DialogEndpointResolver<Node> {

        let answers = Answers()
        let focusReading: (() -> DialogEndpointResolver<Node>.FocusedControlReading)? = tree.focusIsAbsent
            ? {
                answers.focusReads += 1
                if let after = tree.focusAppearsAfterReads, answers.focusReads > after { return .node(Node(id: 4)) }
                return .absent
            }
            : nil
        return DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in tree.hit.map(Node.init) },
            focusedNode: { tree.focused.map(Node.init) },
            children   : {
                tree.unreadableChildren.contains($0.id)
                    ? .unreadable
                    : .children((tree.children[$0.id] ?? []).map(Node.init))
            },
            nodeFrame  : { tree.frames[$0.id] },
            nodeWindow : { tree.windows[$0.id] },
            nodeProcess: { tree.processes[$0.id] },
            identity   : { window in
                let sequence = identities[window] ?? []
                defer { answers.identityCalls += 1 }
                guard answers.identityCalls < sequence.count else { return sequence.last ?? nil }
                return sequence[answers.identityCalls]
            },
            geometry   : { window, _ in geometries[window] },
            now        : { now },
            focusedControl: focusReading,
            focusedWindow: { tree.focusedWindow.map(Node.init) },
            windowNode : { tree.windowNodes[$0].map(Node.init) },
            parent     : { tree.parents[$0.id].map(Node.init) },
            windowReading: { node in
                if tree.unreadableWindows.contains(node.id) { return .unreadable }
                return tree.windows[node.id].map { .window($0) } ?? .windowless
            },
            isWebArea  : { tree.webAreas.contains($0.id) }
        )
    }

    /// The resolver of the measured case, with every reading agreeing.
    private func coherentResolver(tree: Tree? = nil) -> DialogEndpointResolver<Node> {
        makeResolver(
            tree      : tree ?? hostedPanelTree,
            identities: [Self.remoteWindow: [remote, remote], Self.sheetWindow: [sheet, sheet]],
            geometries: [
                Self.remoteWindow: observation(remote, Self.contentFrame),
                Self.sheetWindow : observation(sheet, Self.surfaceFrame)
            ]
        )
    }

    @Test("window-scoped pointer resolution rejects ambiguous or foreign controls",
          arguments: ["valid", "foreignWindow", "foreignProcess", "ambiguous", "unreadable", "wrongParent"])
    func ownWindowPointer(fault: String) throws {
        var tree = Tree(
            hit: 9,
            frames: [1: Self.surfaceFrame, 2: Self.buttonFrame, 9: Self.buttonFrame],
            children: [1: [2]],
            windows: [1: Self.sheetWindow, 2: Self.sheetWindow, 9: Self.hostWindow],
            processes: [1: Self.hostProcessID, 2: Self.hostProcessID, 9: Self.hostProcessID],
            parents: [2: 1],
            windowNodes: [Self.sheetWindow: 1]
        )
        switch fault {
            case "foreignWindow": tree.windows[2] = Self.hostWindow
            case "foreignProcess": tree.processes[2] = Self.remoteProcess
            case "ambiguous":
                tree.children[1] = [2, 3]
                tree.frames[3] = Self.buttonFrame
            case "unreadable": tree.unreadableChildren = [1]
            case "wrongParent": tree.parents[2] = 9
            default: break
        }
        let result = coherentResolver(tree: tree).ownWindowPointerEndpoint(
            at: Self.pointOnCancel, within: chain, selectionGeneration: 12
        )
        if fault == "valid" {
            let endpoint = try result.get()
            #expect(endpoint.identity == sheet)
            #expect(endpoint.relation == .logicalSurface)
        } else {
            #expect(throws: (any Error).self) { try result.get() }
        }
    }

    @Test("a remote panel resolves from its surface despite a sibling hit, with a verified parent path",
          arguments: ["valid", "wrongParent", "unreadable", "foreignProcess", "ambiguous", "outside"])
    func remotePanelFromWindowTree(fault: String) throws {
        var tree = hostedPanelTree
        tree.hit = 9
        tree.frames[9] = Self.buttonFrame
        tree.windows[9] = Self.hostWindow
        tree.processes[9] = Self.hostProcessID
        tree.parents = [3: 2, 2: 1]
        tree.windowNodes = [Self.sheetWindow: 1]
        switch fault {
            case "wrongParent": tree.parents[3] = 9
            case "unreadable": tree.unreadableChildren = [2]
            case "foreignProcess": tree.processes[3] = 999
            case "ambiguous":
                tree.children[2] = [3, 4]
                tree.frames[4] = Self.buttonFrame
            default: break
        }
        let resolver = coherentResolver(tree: tree)
        let point = fault == "outside" ? CGPoint.zero : Self.pointOnCancel
        let result = resolver.remoteWindowPointerEndpoint(at: point, within: chain, selectionGeneration: 12)
        if fault == "valid" {
            let endpoint = try result.get()
            #expect(endpoint.identity == remote)
            #expect(endpoint.relation == .remoteContent)
            let path = try resolver.remoteContentPath(
                at: point, of: endpoint, searchWindowTree: true
            ).get()
            #expect(path.map(\.id) == [3, 2])
        } else {
            #expect(throws: (any Error).self) { try result.get() }
        }
    }

    // MARK: The measured case

    @Test("the accessibility PID stays the host's while the owner is the remote service")
    func remoteOwnerBehindAHostAccessibilityIdentifier() throws {
        let endpoint = try coherentResolver()
            .pointerEndpoint(
                at                 : Self.pointOnCancel,
                within             : chain,
                selectionGeneration: 12
            )
            .get()

        // The oracle: the world says window 902 is owned by connection 8000 of
        // process 200, and says every accessibility node reports process 100.
        #expect(endpoint.identity == remote)
        #expect(endpoint.identity.processID == Self.remoteProcess)
        #expect(endpoint.accessibilityProcessID == Self.hostProcessID)
        #expect(endpoint.accessibilityProcessID != endpoint.identity.processID)
        #expect(endpoint.relation == .remoteContent)
        #expect(endpoint.evidence == .accessibilityNodeIdentity)
        #expect(endpoint.logicalSurface == sheet)
        #expect(endpoint.kind == .pointer)
        #expect(endpoint.selectionGeneration == 12)
        #expect(endpoint.geometry.window.frame == Self.contentFrame)
    }

    @Test("the descent goes past the proxy the hit test stops at")
    func descentPassesTheProxy() throws {
        // The node the hit test answers names the sheet, so a discovery that
        // stopped there would address the proxy.
        let tree = hostedPanelTree
        #expect(tree.windows[tree.hit!] == Self.sheetWindow)

        let endpoint = try coherentResolver()
            .pointerEndpoint(at: Self.pointOnCancel, within: chain, selectionGeneration: 1)
            .get()
        #expect(endpoint.identity.windowNumber == Self.remoteWindow)
    }

    @Test("a surface whose own control answers it stays the recipient")
    func ordinarySheetIsNotRedirected() throws {
        var tree = hostedPanelTree
        tree.windows = [1: Self.sheetWindow, 2: Self.sheetWindow, 3: Self.sheetWindow]

        let endpoint = try coherentResolver(tree: tree)
            .pointerEndpoint(at: Self.pointOnCancel, within: chain, selectionGeneration: 1)
            .get()

        #expect(endpoint.identity == sheet)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .attestedSurfaceItself)
    }

    // MARK: What it refuses

    private func refusal(
        tree      : Tree? = nil,
        identities: [Int: [WindowIdentity?]]? = nil,
        geometries: [Int: WindowGeometryObservation]? = nil,
        at point  : CGPoint = DialogEndpointResolverTests.pointOnCancel
    ) -> InputEndpointRefusal? {

        let resolver = makeResolver(
            tree      : tree ?? hostedPanelTree,
            identities: identities ?? [
                Self.remoteWindow: [remote, remote],
                Self.sheetWindow : [sheet, sheet]
            ],
            geometries: geometries ?? [
                Self.remoteWindow: observation(remote, Self.contentFrame),
                Self.sheetWindow : observation(sheet, Self.surfaceFrame)
            ]
        )
        guard case .failure(let refusal) = resolver.pointerEndpoint(
            at                 : point,
            within             : chain,
            selectionGeneration: 1
        ) else { return nil }
        return refusal
    }

    @Test("a window absent from every geometry reading is refused, never assumed")
    func missingGeometryIsRefused() {
        #expect(
            refusal(geometries: [Self.sheetWindow: observation(sheet, Self.surfaceFrame)])
                == .geometryUnavailable(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a reused Window ID is refused")
    func reusedIdentifierIsRefused() {
        let reused = identity(
            window    : Self.remoteWindow,
            processID : Self.remoteProcess,
            connection: 8000,
            serial    : 2
        )
        #expect(reused.windowNumber == remote.windowNumber)
        #expect(reused != remote)

        #expect(
            refusal(identities: [Self.remoteWindow: [remote, reused]])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a helper replaced under the panel is refused")
    func replacedHelperIsRefused() {
        let successor = identity(window: Self.remoteWindow, processID: 314, connection: 8100)

        // Replaced before the geometry: the reading carries the new owner.
        #expect(
            refusal(
                identities: [Self.remoteWindow: [remote, remote]],
                geometries: [Self.remoteWindow: observation(successor, Self.contentFrame)]
            ) == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
        // Replaced after it: the second chain reading disagrees.
        #expect(
            refusal(identities: [Self.remoteWindow: [remote, successor]])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a second panel of the same service is not this panel")
    func anotherPanelOfTheSameServiceIsRefused() {
        // Same process and same owner connection, drawn somewhere else: the
        // service hosts both, and only one of them is inside this surface.
        let elsewhere = CGRect(x: 1400, y: 340, width: 600, height: 360)
        #expect(!Self.surfaceFrame.contains(elsewhere))

        #expect(
            refusal(geometries: [Self.remoteWindow: observation(remote, elsewhere)])
                == .notContainedInSurface(windowNumber: Self.remoteWindow)
        )
    }

    @Test("an incomplete accessibility subtree refuses instead of naming the host")
    func incompleteSubtreeIsRefused() {
        var unreadableWindows = hostedPanelTree
        unreadableWindows.windows = [:]
        #expect(refusal(tree: unreadableWindows) == .subtreeUnreadable(surface: sheet))

        var unreadableProcess = hostedPanelTree
        unreadableProcess.processes = [:]
        #expect(refusal(tree: unreadableProcess) == .subtreeUnreadable(surface: sheet))

        var noHit = hostedPanelTree
        noHit.hit = nil
        #expect(refusal(tree: noHit) == .noNodeAtPoint)
    }

    @Test("a concrete descendant without a Window ID refuses instead of retaining its proxy")
    func concreteDescendantWithoutWindowIsUnreadable() {
        // The control contains the target point, so retaining the group above
        // would address a proxy after the concrete recipient stopped answering.
        var tree = hostedPanelTree
        tree.windows[3] = nil
        #expect(refusal(tree: tree) == .subtreeUnreadable(surface: sheet))
    }

    @Test("an unreadable children read refuses instead of selecting the proxy")
    func unreadableChildrenRefuse() {
        let resolver = DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in Node(id: 1) },
            focusedNode: { nil },
            children: { node in node.id == 1 ? .unreadable : .leaf },
            nodeFrame: { hostedPanelTree.frames[$0.id] },
            nodeWindow: { hostedPanelTree.windows[$0.id] },
            nodeProcess: { hostedPanelTree.processes[$0.id] },
            identity: { _ in remote },
            geometry: { _, _ in observation(remote, Self.contentFrame) },
            now: { 1 }
        )
        guard case .failure(let refusal) = resolver.pointerEndpoint(
            at: Self.pointOnCancel, within: chain, selectionGeneration: 1
        ) else {
            Issue.record("unreadable children must refuse")
            return
        }
        #expect(refusal == .subtreeUnreadable(surface: sheet))
    }

    @Test("a window the chain cannot attest is refused")
    func unattestedWindowIsRefused() {
        #expect(
            refusal(identities: [Self.remoteWindow: [nil]])
                == .identityUnattested(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a point outside the attested surface names no relation")
    func pointOutsideTheSurfaceIsRefused() {
        let outside = CGPoint(x: 100, y: 100)
        #expect(!Self.surfaceFrame.contains(outside))
        #expect(refusal(at: outside) == .pointOutsideSurface)
    }

    @Test("no incoherent window, connection and process combination becomes a recipient")
    func incoherentCombinationsNeverResolve() {
        // The geometry names another window than the one the node reported.
        let otherWindow = identity(window: 903, processID: Self.remoteProcess, connection: 8000)
        #expect(
            refusal(geometries: [Self.remoteWindow: observation(otherWindow, Self.contentFrame)])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
        // The chain names another owner connection than the geometry carries.
        let otherConnection = identity(
            window    : Self.remoteWindow,
            processID : Self.remoteProcess,
            connection: 9999
        )
        #expect(
            refusal(identities: [Self.remoteWindow: [otherConnection, otherConnection]])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
        // The chain answers an identity of a different window entirely.
        #expect(
            refusal(identities: [Self.remoteWindow: [otherWindow, otherWindow]])
                == .identityUnattested(windowNumber: Self.remoteWindow)
        )
    }

    // MARK: The keyboard context

    @Test("the keyboard context comes from the focused node, not from a point")
    func keyboardContextIsResolvedFromFocus() throws {
        let endpoint = try coherentResolver()
            .keyboardContext(within: chain, selectionGeneration: 4)
            .get()

        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.identity == remote)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)
    }

    @Test("a surface with no readable focused node refuses")
    func keyboardContextWithoutFocusRefuses() {
        var tree = hostedPanelTree
        tree.focused = nil
        let outcome = coherentResolver(tree: tree)
            .keyboardContext(within: chain, selectionGeneration: 1)

        guard case .failure(let refusal) = outcome else {
            Issue.record("a missing focused node must refuse")
            return
        }
        #expect(refusal == .subtreeUnreadable(surface: sheet))
    }

    /// The reading the boundary revalidates a keyboard context against. An
    /// unreadable focus answers nil, which retires the context rather than
    /// leaving it standing on a window nobody is typing into.
    @Test("the focused node's window is read on its own, and answers nil when nothing does")
    func focusedNodeWindowIsReadableOnItsOwn() {
        #expect(coherentResolver().focusedNodeWindowNumber() == Self.remoteWindow)

        var tree = hostedPanelTree
        tree.focused = nil
        #expect(coherentResolver(tree: tree).focusedNodeWindowNumber() == nil)
    }

    // MARK: The windowless content of an ordinary window

    private var ordinaryChain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: host, surface: host, surfaceFrame: Self.surfaceFrame)
    }

    /// The shape of a web page: the window names itself, while the web area
    /// and every node under it name no window, all with the application's PID.
    /// The hit test answers the link, whose text is the innermost node.
    private var webPageTree: Tree {
        Tree(
            hit      : 3,
            focused  : 4,
            frames   : [
                1: Self.surfaceFrame,
                2: Self.contentFrame,
                3: Self.buttonFrame,
                4: Self.buttonFrame.insetBy(dx: 10, dy: 5),
                5: CGRect(x: 400, y: 300, width: 600, height: 40)
            ],
            children : [1: [5, 2], 2: [3], 3: [4]],
            windows  : [1: Self.hostWindow, 5: Self.hostWindow],
            processes: [1: Self.hostProcessID, 2: Self.hostProcessID, 3: Self.hostProcessID,
                        4: Self.hostProcessID, 5: Self.hostProcessID],
            parents  : [2: 1, 3: 2, 4: 3, 5: 1]
        )
    }

    private func pageResolver(_ tree: Tree) -> DialogEndpointResolver<Node> {
        makeResolver(
            tree      : tree,
            identities: [Self.hostWindow: [host, host]],
            geometries: [Self.hostWindow: observation(host, Self.surfaceFrame)]
        )
    }

    private func windowless(
        _ tree : Tree,
        pointer: Bool,
        within chain: DialogEndpointResolver<Node>.SurfaceChain? = nil
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        pageResolver(tree).windowlessContentEndpoint(
            at                 : pointer ? Self.pointOnCancel : nil,
            within             : chain ?? ordinaryChain,
            selectionGeneration: 6
        )
    }

    @Test("a web page's node under the point, or its focused control, is the window's own content",
          arguments: [true, false])
    func windowlessContentIsTheSurfaces(pointer: Bool) throws {
        // The discovery refuses this tree, which is the refusal the route answers.
        let resolver = pageResolver(webPageTree)
        let refused = pointer
            ? resolver.pointerEndpoint(at: Self.pointOnCancel, within: ordinaryChain, selectionGeneration: 6)
            : resolver.keyboardContext(within: ordinaryChain, selectionGeneration: 6)
        #expect(refused == .failure(.subtreeUnreadable(surface: host)))

        let endpoint = try windowless(webPageTree, pointer: pointer).get()
        #expect(endpoint.identity == host)
        #expect(endpoint.logicalSurface == host)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .windowlessContentOfSurface)
        #expect(endpoint.kind == (pointer ? .pointer : .keyboardContext))
        #expect(endpoint.focusedNodeWindowNumber == (pointer ? nil : Self.hostWindow))
        #expect(endpoint.selectionGeneration == 6)
    }

    @Test("a node on the path that names another window refuses", arguments: [true, false])
    func windowlessContentRefusesAForeignWindow(pointer: Bool) {
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: host))
        // Above the start, and at the innermost node: the focused control for keys.
        for node in [2, 4] {
            var tree = webPageTree
            tree.windows[node] = Self.remoteWindow
            #expect(windowless(tree, pointer: pointer) == refusal)
        }
        // The nearest node naming a window is another window of the same process.
        var nested = webPageTree
        nested.windows[2] = Self.sheetWindow
        #expect(windowless(nested, pointer: pointer) == refusal)
    }

    @Test("a node on the path of another process refuses", arguments: [true, false])
    func windowlessContentRefusesAnotherProcess(pointer: Bool) {
        for node in [2, 4] {
            var tree = webPageTree
            tree.processes[node] = Self.remoteProcess
            #expect(windowless(tree, pointer: pointer) == .failure(.subtreeUnreadable(surface: host)))
        }
    }

    @Test("a read on the path that failed refuses", arguments: [true, false])
    func windowlessContentRefusesAnUnreadableRead(pointer: Bool) {
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: host))

        var window = webPageTree
        window.unreadableWindows = [2]
        #expect(windowless(window, pointer: pointer) == refusal)

        var parent = webPageTree
        parent.parents[2] = nil
        #expect(windowless(parent, pointer: pointer) == refusal)

        var focus = webPageTree
        focus.focused = nil
        var children = webPageTree
        children.unreadableChildren = [3]
        #expect(windowless(pointer ? children : focus, pointer: pointer) == refusal)
    }

    @Test("a hosted surface, or a path past its budget, refuses", arguments: [true, false])
    func windowlessContentRefusesAHostedSurfaceAndALongPath(pointer: Bool) throws {
        #expect(windowless(webPageTree, pointer: pointer, within: chain)
            == .failure(.subtreeUnreadable(surface: sheet)))

        // A start node with `length` windowless ancestors before the window.
        func path(_ length: Int) -> Tree {
            var tree = webPageTree
            tree.hit     = 100
            tree.focused = 100
            for node in 100..<(100 + length) {
                tree.processes[node] = Self.hostProcessID
                tree.parents[node]   = node + 1
            }
            tree.parents[100 + length - 1] = 1
            return tree
        }
        _ = try windowless(path(60), pointer: pointer).get()
        #expect(windowless(path(70), pointer: pointer) == .failure(.subtreeUnreadable(surface: host)))
    }

    // MARK: Keys on a web page that names no focused control

    /// Safari in the background: no focused control, the focused window is the
    /// window, the page's web area (node 2) is windowless and its parent is the
    /// window. The hit test at the centre answers a node inside the page.
    private var unfocusedPageTree: Tree {
        var tree = webPageTree
        tree.focused       = nil
        tree.focusIsAbsent = true
        tree.focusedWindow = 1
        tree.webAreas      = [2]
        return tree
    }

    private func webArea(
        _ tree: Tree,
        at point: CGPoint? = nil,
        within chain: DialogEndpointResolver<Node>.SurfaceChain? = nil
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        pageResolver(tree).webAreaKeyboardContext(
            at                 : point,
            within             : chain ?? ordinaryChain,
            selectionGeneration: 6
        )
    }

    private var unreadable: Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        .failure(.subtreeUnreadable(surface: host))
    }

    @Test("with no focused control, the web area under the centre or a point is the window's own content",
          arguments: [true, false])
    func webAreaWithoutFocusIsTheSurfaces(usesPoint: Bool) throws {
        // The routes that start from a focused control refuse this page.
        #expect(pageResolver(unfocusedPageTree)
            .keyboardContext(within: ordinaryChain, selectionGeneration: 6) == unreadable)
        #expect(pageResolver(unfocusedPageTree)
            .windowlessContentEndpoint(at: nil, within: ordinaryChain, selectionGeneration: 6) == unreadable)

        let endpoint = try webArea(unfocusedPageTree, at: usesPoint ? Self.pointOnCancel : nil).get()
        #expect(endpoint.identity == host)
        #expect(endpoint.logicalSurface == host)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .windowlessContentWithoutFocus)
        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.focusedNodeWindowNumber == nil)
        #expect(endpoint.selectionGeneration == 6)
    }

    @Test("a focused control, or a focus that cannot be read, is not an absent focus")
    func webAreaRefusesAFocusThatIsNotAbsent() {
        var focused = unfocusedPageTree
        focused.focusIsAbsent = false
        focused.focused       = 4
        #expect(webArea(focused) == unreadable)

        var unread = unfocusedPageTree
        unread.focusIsAbsent = false
        unread.focused       = nil
        #expect(webArea(unread) == unreadable)
    }

    @Test("a focus that appears while the page is proved refuses")
    func webAreaRefusesAFocusThatAppearsDuringTheProof() {
        var tree = unfocusedPageTree
        tree.focusAppearsAfterReads = 1
        #expect(webArea(tree) == unreadable)
    }

    @Test("the application's focused window has to be this window")
    func webAreaRefusesAnotherFocusedWindow() {
        var other = unfocusedPageTree
        other.windows[6]    = Self.sheetWindow
        other.processes[6]  = Self.hostProcessID
        other.focusedWindow = 6
        #expect(webArea(other) == unreadable)

        var none = unfocusedPageTree
        none.focusedWindow = nil
        #expect(webArea(none) == unreadable)

        // Another process's window named as focused cannot lend its page either.
        var foreign = unfocusedPageTree
        foreign.processes[1] = Self.remoteProcess
        #expect(webArea(foreign) == unreadable)
    }

    @Test("a page with no web area on the path refuses, and so does a web area that names a window")
    func webAreaNeedsAWindowlessWebArea() {
        var none = unfocusedPageTree
        none.webAreas = []
        #expect(webArea(none) == unreadable)

        var named = unfocusedPageTree
        named.windows[2] = Self.hostWindow
        #expect(webArea(named) == unreadable)
    }

    /// The path from the web area: node 2 below node 6 below the window.
    private var deepPageTree: Tree {
        var tree = unfocusedPageTree
        tree.parents[2]   = 6
        tree.parents[6]   = 1
        tree.processes[6] = Self.hostProcessID
        tree.frames[6]    = Self.contentFrame
        return tree
    }

    @Test("a longer windowless path to the window is proved node by node")
    func webAreaAcceptsALongerPath() throws {
        let endpoint = try webArea(deepPageTree).get()
        #expect(endpoint.identity == host)
    }

    @Test("a node of the path that names another window, even of the same process, refuses")
    func webAreaRefusesAForeignWindowOnThePath() {
        var sameProcess = deepPageTree
        sameProcess.windows[6] = Self.sheetWindow
        #expect(webArea(sameProcess) == unreadable)

        var otherProcess = deepPageTree
        otherProcess.windows[6]   = Self.remoteWindow
        otherProcess.processes[6] = Self.remoteProcess
        #expect(webArea(otherProcess) == unreadable)
    }

    @Test("a node of another process on the path refuses, above the web area or below it")
    func webAreaRefusesAnotherProcess() {
        var above = deepPageTree
        above.processes[6] = Self.remoteProcess
        #expect(webArea(above) == unreadable)

        var webAreaItself = unfocusedPageTree
        webAreaItself.processes[2] = Self.remoteProcess
        #expect(webArea(webAreaItself) == unreadable)

        var below = unfocusedPageTree
        below.processes[3] = Self.remoteProcess
        #expect(webArea(below) == unreadable)
    }

    @Test("a read that failed on the path refuses")
    func webAreaRefusesAnUnreadableRead() {
        var window = deepPageTree
        window.unreadableWindows = [6]
        #expect(webArea(window) == unreadable)

        var parent = deepPageTree
        parent.parents[6] = nil
        #expect(webArea(parent) == unreadable)

        var hit = unfocusedPageTree
        hit.hit = nil
        #expect(webArea(hit) == .failure(.noNodeAtPoint))
    }

    @Test("a hosted surface, a point outside the window, or a path past its budget refuses")
    func webAreaRefusesAHostedSurfaceAnOutsidePointAndALongPath() {
        #expect(webArea(unfocusedPageTree, within: chain) == .failure(.subtreeUnreadable(surface: sheet)))
        #expect(webArea(unfocusedPageTree, at: CGPoint(x: 5, y: 5)) == .failure(.pointOutsideSurface))

        var long = unfocusedPageTree
        for node in 100..<170 {
            long.processes[node] = Self.hostProcessID
            long.parents[node]   = node + 1
        }
        long.parents[169] = 1
        long.parents[2]   = 100
        #expect(webArea(long) == unreadable)
    }

    // MARK: Web content of a sheet or a modal (ADR 0014, 2026-10-14)

    private static let modalWindow = 905

    private var modal: WindowIdentity {
        identity(window: Self.modalWindow, processID: Self.hostProcessID, connection: 7000)
    }

    /// The fixture's two surfaces as the read-only dump of 14/10/2026 found them
    /// (WebPopupProbe, AppKit with one WKWebView, after the hit test made WebKit
    /// fill its subtree). Frames are the dump's; Window IDs are this suite's.
    ///
    /// The sheet, `AXSheet` inside the host's `AXStandardWindow`:
    ///
    ///     AXWindow sub=AXStandardWindow title="WebPopupProbe" @608,-1115 240x232 wid=<host>
    ///       AXSheet @518,-1083 420x368 wid=<sheet>
    ///         AXGroup @518,-1075 420x320 wid=<sheet>
    ///           AXGroup @518,-1075 420x320
    ///             AXScrollArea @518,-1075 420x320
    ///               AXWebArea desc="WebPopupProbe page" @518,-1075 420x1385
    ///                 AXButton title="Probe button" dom="button" @534,-1058 84x19
    ///                 AXLink title="Probe link" dom="link" @622,-1059 64x17
    ///                 AXGroup @534,-1026 388x22
    ///                   AXTextField dom="input" @534,-1026 156x22
    ///         AXButton title="Close" @698,-748 61x26 wid=<sheet>
    ///
    /// The modal, a top-level `runModal` window:
    ///
    ///     AXWindow sub=AXDialog title="WebPopupProbe modal" modal=true @518,-1157 420x400 wid=<modal>
    ///       AXGroup @518,-1117 420x320 wid=<modal>
    ///         AXGroup @518,-1117 420x320
    ///           AXScrollArea @518,-1117 420x320
    ///             AXWebArea desc="WebPopupProbe page" @518,-1117 420x1385
    ///               AXButton title="Probe button" dom="button" @534,-1100 84x19
    ///               AXGroup @534,-1068 388x22
    ///                 AXTextField dom="input" @534,-1068 156x22
    ///       AXButton title="Close" @698,-790 61x26 wid=<modal>
    ///
    /// Every node answered the application's PID, and nothing from the
    /// windowless `AXGroup` down answered a Window ID. The hit test at the
    /// button answered the button.
    private struct ProbeSurface {
        let tree   : Tree
        let chain  : DialogEndpointResolver<Node>.SurfaceChain
        let button : CGPoint
        /// The windowless nodes between the surface's own group and the leaves.
        let webNodes: [Int]
    }

    private func probeSurface(isSheet: Bool) -> ProbeSurface {
        let dy: CGFloat = isSheet ? 0 : -42
        let surfaceFrame = isSheet
            ? CGRect(x: 518, y: -1083, width: 420, height: 368)
            : CGRect(x: 518, y: -1157, width: 420, height: 400)
        let window   = isSheet ? Self.sheetWindow : Self.modalWindow
        let content  = CGRect(x: 518, y: -1075 + dy, width: 420, height: 320)
        // 1 the surface, 2 its own group, 3 group, 4 scroll area, 5 web area,
        // 6 button, 7 field's group, 8 field, 9 Close; 10 the sheet's host.
        var tree = Tree(
            hit      : 6,
            focused  : 8,
            frames   : [
                1: surfaceFrame,
                2: content,
                3: content,
                4: content,
                5: CGRect(x: 518, y: -1075 + dy, width: 420, height: 1385),
                6: CGRect(x: 534, y: -1058 + dy, width: 84, height: 19),
                7: CGRect(x: 534, y: -1026 + dy, width: 388, height: 22),
                8: CGRect(x: 534, y: -1026 + dy, width: 156, height: 22),
                9: CGRect(x: 698, y: -748 + dy, width: 61, height: 26)
            ],
            children : [1: [2, 9], 2: [3], 3: [4], 4: [5], 5: [6, 7], 7: [8]],
            windows  : [1: window, 2: window, 9: window],
            processes: Dictionary(uniqueKeysWithValues: (1...10).map { ($0, Self.hostProcessID) }),
            parents  : [2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 5, 8: 7, 9: 1],
            focusedWindow: 1,
            webAreas : [5],
            windowNodes: [window: 1]
        )
        if isSheet {
            tree.frames[10]   = CGRect(x: 608, y: -1115, width: 240, height: 232)
            tree.windows[10]  = Self.hostWindow
            tree.children[10] = [1]
            tree.parents[1]   = 10
            // A sheet is listed under its host's entry only.
            tree.windowNodes  = [Self.hostWindow: 10]
        }
        let surface = isSheet ? sheet : modal
        return ProbeSurface(
            tree    : tree,
            chain   : .init(host: isSheet ? host : modal, surface: surface, surfaceFrame: surfaceFrame),
            button  : CGPoint(x: 576, y: -1048 + dy),
            webNodes: [3, 4, 5, 6, 7, 8]
        )
    }

    private func probeResolver(_ probe: ProbeSurface, tree: Tree? = nil) -> DialogEndpointResolver<Node> {
        let surface = probe.chain.surface
        return makeResolver(
            tree      : tree ?? probe.tree,
            identities: [surface.windowNumber: [surface, surface]],
            geometries: [surface.windowNumber: observation(surface, probe.chain.surfaceFrame)]
        )
    }

    private func probeContent(
        _ probe : ProbeSurface,
        tree    : Tree? = nil,
        pointer : Bool,
        modal   : Bool = true
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        probeResolver(probe, tree: tree).windowlessContentEndpoint(
            at                 : pointer ? probe.button : nil,
            within             : probe.chain,
            selectionGeneration: 6,
            ofModalSurface     : modal
        )
    }

    private func probeWithoutFocus(
        _ probe: ProbeSurface,
        tree   : Tree? = nil,
        modal  : Bool = true
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        var unfocused = tree ?? probe.tree
        unfocused.focused       = nil
        unfocused.focusIsAbsent = true
        return probeResolver(probe, tree: unfocused).webAreaKeyboardContext(
            within             : probe.chain,
            selectionGeneration: 6,
            ofModalSurface     : modal
        )
    }

    @Test("the fixture's sheet and modal: web content under a point, or focused, is the surface's own",
          arguments: [true, false], [true, false])
    func probeWebContentIsTheModalSurfaces(isSheet: Bool, pointer: Bool) throws {
        let probe    = probeSurface(isSheet: isSheet)
        let resolver = probeResolver(probe)
        // The measured F1: the descent and the focused control find no Window ID.
        let measured = pointer
            ? resolver.pointerEndpoint(at: probe.button, within: probe.chain, selectionGeneration: 6)
            : resolver.keyboardContext(within: probe.chain, selectionGeneration: 6)
        #expect(measured == .failure(.subtreeUnreadable(surface: probe.chain.surface)))

        let endpoint = try probeContent(probe, pointer: pointer).get()
        #expect(endpoint.identity == probe.chain.surface)
        #expect(endpoint.logicalSurface == probe.chain.surface)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .windowlessContentOfSurface)
        #expect(endpoint.kind == (pointer ? .pointer : .keyboardContext))
        #expect(endpoint.focusedNodeWindowNumber == (pointer ? nil : probe.chain.surface.windowNumber))
    }

    @Test("the fixture's sheet and modal take keys through their page when nothing is focused",
          arguments: [true, false])
    func probeWebAreaWithoutFocusIsTheModalSurfaces(isSheet: Bool) throws {
        let probe    = probeSurface(isSheet: isSheet)
        let endpoint = try probeWithoutFocus(probe).get()
        #expect(endpoint.identity == probe.chain.surface)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .windowlessContentWithoutFocus)
        #expect(endpoint.focusedNodeWindowNumber == nil)
    }

    @Test("a sheet's web content is refused by the routes of an ordinary window")
    func probeSheetNeedsTheModalRoute() {
        let probe   = probeSurface(isSheet: true)
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>.failure(.subtreeUnreadable(surface: sheet))
        #expect(probeContent(probe, pointer: true, modal: false) == refusal)
        #expect(probeContent(probe, pointer: false, modal: false) == refusal)
        #expect(probeWithoutFocus(probe, modal: false) == refusal)
    }

    @Test("the same web content under another process is refused",
          arguments: [true, false], [true, false])
    func probeWebContentOfAnotherProcessIsRefused(isSheet: Bool, pointer: Bool) {
        let probe   = probeSurface(isSheet: isSheet)
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: probe.chain.surface))

        var foreign = probe.tree
        for node in probe.webNodes { foreign.processes[node] = Self.remoteProcess }
        #expect(probeContent(probe, tree: foreign, pointer: pointer) == refusal)
        #expect(probeWithoutFocus(probe, tree: foreign) == refusal)

        // A remote panel's shape: the content names another process's window.
        var remoteContent = probe.tree
        remoteContent.windows[3]   = Self.remoteWindow
        remoteContent.processes[3] = Self.remoteProcess
        #expect(probeContent(probe, tree: remoteContent, pointer: pointer) == refusal)
        #expect(probeWithoutFocus(probe, tree: remoteContent) == refusal)
    }

    @Test("a modal's windowless path that crosses no web area is refused, as panel content is",
          arguments: [true, false], [true, false])
    func probeModalPathWithoutAWebAreaIsRefused(isSheet: Bool, pointer: Bool) throws {
        let probe = probeSurface(isSheet: isSheet)
        var native = probe.tree
        native.webAreas = []
        #expect(probeContent(probe, tree: native, pointer: pointer)
            == .failure(.subtreeUnreadable(surface: probe.chain.surface)))
        #expect(probeWithoutFocus(probe, tree: native)
            == .failure(.subtreeUnreadable(surface: probe.chain.surface)))
        // The same windowless path on an ordinary window needs no web area.
        if !isSheet {
            _ = try probeContent(probe, tree: native, pointer: pointer, modal: false).get()
        }
    }

    @Test("a sheet or a modal whose subtree names another window is refused, as a remote panel's is",
          arguments: [true, false], [true, false])
    func probeSurfaceNamingAnotherWindowIsRefused(isSheet: Bool, pointer: Bool) {
        // Resolve's Go to Folder shape: the list beside the field names the panel
        // service's window, off the field's path. The node is given the
        // surface's process as the remote view's nodes answer it.
        let probe   = probeSurface(isSheet: isSheet)
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: probe.chain.surface))
        var sibling = probe.tree
        sibling.children[1]   = [2, 9, 11]
        sibling.parents[11]   = 1
        sibling.frames[11]    = CGRect(x: 518, y: -760, width: 100, height: 20)
        sibling.windows[11]   = Self.remoteWindow
        sibling.processes[11] = Self.hostProcessID
        #expect(probeContent(probe, tree: sibling, pointer: pointer) == refusal)
        #expect(probeWithoutFocus(probe, tree: sibling) == refusal)
    }

    @Test("a sheet or a modal whose subtree cannot be read whole is refused",
          arguments: [true, false], [true, false])
    func probeSurfaceWithAnUnreadableSubtreeIsRefused(isSheet: Bool, pointer: Bool) {
        let probe   = probeSurface(isSheet: isSheet)
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: probe.chain.surface))
        // The Close button is off the path; its children refuse to be read.
        var unreadable = probe.tree
        unreadable.unreadableChildren = [9]
        #expect(probeContent(probe, tree: unreadable, pointer: pointer) == refusal)
        #expect(probeWithoutFocus(probe, tree: unreadable) == refusal)

        // No entry for the surface among the application's windows refuses too.
        var unlisted = probe.tree
        unlisted.windowNodes = [:]
        #expect(probeContent(probe, tree: unlisted, pointer: pointer) == refusal)
        #expect(probeWithoutFocus(probe, tree: unlisted) == refusal)
    }

    @Test("the page under the web area is not read for the surface's other windows")
    func probeWebAreaSubtreeIsNotReadWhole() throws {
        // A long page: more nodes under the web area than a whole reading admits.
        let probe = probeSurface(isSheet: false)
        var long  = probe.tree
        long.children[5] = [6, 7] + Array(100...1_200)
        for node in 100...1_200 { long.processes[node] = Self.hostProcessID }
        let endpoint = try probeContent(probe, tree: long, pointer: true).get()
        #expect(endpoint.evidence == .windowlessContentOfSurface)
        #expect(endpoint.identity == probe.chain.surface)
    }

    // MARK: Retiring an endpoint

    @Test("every retirement is named, and a current endpoint is not retired")
    func invalidationTable() throws {
        let endpoint = try coherentResolver()
            .pointerEndpoint(at: Self.pointOnCancel, within: chain, selectionGeneration: 12)
            .get()

        func invalidation(
            at now             : UInt64 = 1_000_000,
            generation         : UInt64 = 12,
            surface            : WindowIdentity? = nil,
            current            : WindowIdentity?? = nil,
            focusedNodeWindow  : Int? = nil
        ) -> InputEndpointInvalidation? {

            endpoint.invalidation(
                at                     : now,
                selectionGeneration    : generation,
                logicalSurface         : surface ?? sheet,
                currentIdentity        : current ?? remote,
                focusedNodeWindowNumber: focusedNodeWindow
            )
        }

        #expect(invalidation() == nil)
        #expect(invalidation(at: endpoint.expiresAtNanoseconds) == .expired)
        #expect(invalidation(generation: 13) == .selectionSuperseded)
        #expect(invalidation(surface: host) == .relationNoLongerValid)
        #expect(invalidation(current: .some(nil)) == .identityChanged)
        #expect(
            invalidation(
                current: identity(
                    window    : Self.remoteWindow,
                    processID : Self.remoteProcess,
                    connection: 8000,
                    serial    : 9
                )
            ) == .identityChanged
        )
        // A pointer endpoint knows nothing about where the focus is.
        #expect(invalidation(focusedNodeWindow: 12_345) == nil)
    }

    @Test("a keyboard context is retired when the focus moves to another window")
    func keyboardContextFollowsTheFocusedNode() throws {
        let endpoint = try coherentResolver()
            .keyboardContext(within: chain, selectionGeneration: 4)
            .get()

        #expect(
            endpoint.invalidation(
                at                     : 1_000_000,
                selectionGeneration    : 4,
                logicalSurface         : sheet,
                currentIdentity        : remote,
                focusedNodeWindowNumber: Self.remoteWindow
            ) == nil
        )
        #expect(
            endpoint.invalidation(
                at                     : 1_000_000,
                selectionGeneration    : 4,
                logicalSurface         : sheet,
                currentIdentity        : remote,
                focusedNodeWindowNumber: Self.sheetWindow
            ) == .focusedNodeChanged
        )
    }

    @Test("an endpoint cannot be assembled from facts that contradict each other")
    func endpointInitializerRefusesContradictions() {
        let geometry = observation(remote, Self.contentFrame)

        // Remote content that is the surface itself is not a relation.
        #expect(
            ResolvedInputEndpoint(
                kind                  : .pointer,
                geometry              : geometry,
                evidence              : .accessibilityNodeIdentity,
                relation              : .remoteContent,
                logicalSurface        : remote,
                accessibilityProcessID: Self.hostProcessID,
                selectionGeneration   : 1,
                resolvedAtNanoseconds : 10,
                expiresAtNanoseconds  : 20
            ) == nil
        )
        // A deadline that has already passed at the moment of the resolution.
        #expect(
            ResolvedInputEndpoint(
                kind                  : .pointer,
                geometry              : geometry,
                evidence              : .accessibilityNodeIdentity,
                relation              : .remoteContent,
                logicalSurface        : sheet,
                accessibilityProcessID: Self.hostProcessID,
                selectionGeneration   : 1,
                resolvedAtNanoseconds : 20,
                expiresAtNanoseconds  : 20
            ) == nil
        )
        // A geometry with no attested identity cannot exist in the first place.
        #expect(
            WindowGeometryObservation(
                window     : WindowReference(
                    processID   : Self.remoteProcess,
                    windowNumber: Self.remoteWindow,
                    frame       : Self.contentFrame
                ),
                scaleFactor: 2,
                version    : GeometryObservationVersion(observerGeneration: 0, sequence: 1)
            ) == nil
        )
    }
}
