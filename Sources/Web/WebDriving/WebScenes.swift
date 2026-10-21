//
//  WebScenes.swift
//  Braus
//

import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore
import WebDriver

/// WebScenes is `SceneProviding` for tabs: at every call it reads the page's accessibility tree,
/// its layout and its viewport, and builds the scene from them. The window is the viewport, at the
/// origin, so a scene's global point is a CSS pixel of the page, which is what the actuator sends.
///
/// Each element with a DOM node gets the physical identity of that node (`identity`): the tab's
/// target and session, the document's own node and the element's node, by their backend ids. The
/// scene's element id, made of kind, label and place, is kept by a node replaced in the same place;
/// this identity is not. When the document cannot be read, no element has one.
public struct WebScenes: SceneProviding {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        try await scene(of: processID).window
    }

    /// The scene, and the target that names in it the element of the node `identity`, for a node found by other means
    /// (a script) and clicked through the engine: the element's id, or for twins, which share it, its label read apart
    /// by its ordinal, whichever a click resolves to that element alone. Nil when that node is not in this read:
    /// another document (a navigation, a reload), a node removed or replaced, an element outside the view, or a name
    /// that resolves to another element too.
    public func currentScene(of processID: pid_t, naming identity: TargetIdentity) async throws
        -> (window: PerceivedWindow, target: String?) {
        let page = try tabs.page(for: processID)
        let read = try await scene(of: processID)
        guard let document = read.document, let node = Self.node(of: identity, page: page, document: document),
              let index = read.nodeElements[node]
        else { return (read.window, nil) }
        let element = read.window.scene.elements[index]
        let target = [element.id, element.label].first {
            read.window.scene.resolve(target: $0, preferNativeControls: true) == .found(element)
        }
        return (read.window, target)
    }

    /// The element `target` resolves to in a fresh scene, as the engine resolves a click, and the identity of its
    /// node; nil when it resolves to no element alone. The identity is nil for an element with no node of its own,
    /// one whose id another element shares, or a scene whose document could not be read.
    public func element(
        resolving target: String,
        in processID    : pid_t
    ) async throws -> (element: SceneElement, identity: TargetIdentity?)? {
        let page = try tabs.page(for: processID)
        let read = try await scene(of: processID)
        guard case .found(let element) = read.window.scene.resolve(target: target, preferNativeControls: true) else {
            return nil
        }
        let identity = read.document.flatMap { document in
            read.backendNodes[element.id].map { Self.identity(page: page, document: document, node: $0) }
        }
        return (element, identity)
    }

    /// Runs `body`, the gestures decided on the node `identity` names, with its tab held to that node: a click reaches
    /// that node only, and no gesture another document, even when a read in between, the engine's own, saw another
    /// node in its place (W05).
    public func holding<Result>(_ identity: TargetIdentity, in processID: pid_t,
                                _ body: () async throws -> Result) async rethrows -> Result {
        // An identity that names no node holds the tab to none: nothing is sent.
        tabs.hold(Self.place(of: identity) ?? (document: 0, node: 0), for: processID)
        defer { tabs.hold(nil, for: processID) }
        return try await body()
    }

    /// The scene, the document node it was read from, the DOM node of each element by its id, and the element of
    /// each DOM node by its index in the scene.
    private func scene(
        of processID: pid_t
    ) async throws -> (window: PerceivedWindow, document: Int?, backendNodes: [String: Int], nodeElements: [Int: Int]) {
        let page = try tabs.page(for: processID)
        async let document = try? Self.documentNode(of: page)
        async let tree     = page.send("Accessibility.getFullAXTree")
        async let snapshot = page.send("DOMSnapshot.captureSnapshot", [
            "computedStyles": .array(WebLayout.clippingStyles.map { .string($0) }),
        ])
        async let metrics  = page.send("Page.getLayoutMetrics")
        let layout = try WebLayout(snapshot: try await snapshot, metrics: try await metrics)
        let isOpen = tabs.window(of: processID)?.popup != nil
        let popup  = isOpen ? await WebControls(tabs: tabs).openPopup(in: processID) : nil
        tabs.setPopup(popup, for: processID)
        let built  = WebSceneBuilder.build(nodes: WebAXNode.nodes(fromFullTree: try await tree), layout: layout,
                                           popup: popup)
        tabs.note(viewport: layout.viewport, title: built.scene.windowTitle, for: processID)
        let read = await document
        tabs.note(document: read, for: processID)
        let elementNodes = Dictionary(built.nodeElements.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        tabs.note(targets: built.scene.elements.enumerated().map { index, element in
            WebTabs.Target(label: element.label, box: element.bounds.pixelBox(in: layout.viewport), node: elementNodes[index])
        }, for: processID)
        let identities = read.map { document in
            built.backendNodes.mapValues { Self.identity(page: page, document: document, node: $0) }
        } ?? [:]
        let window = PerceivedWindow(scene: built.scene, frame: CGRect(origin: .zero, size: layout.viewport),
                                     capture: built.capture, surface: popup == nil ? .window : .popupUnion,
                                     identities: identities)
        return (window, read, built.backendNodes, built.nodeElements)
    }

    /// The identity of DOM node `node` of the document whose own node is `document`, in `page`'s tab: opaque
    /// to everything but this module, compared whole.
    static func identity(page: WebPage, document: Int, node: Int) -> TargetIdentity {
        TargetIdentity("web|\(page.targetID)|\(page.sessionID)|\(document)|\(node)")
    }

    /// The DOM node `identity` names, when it names a node of `page`'s tab and of its document `document`; nil for
    /// another tab, session or document, which is no longer the node that was read.
    static func node(of identity: TargetIdentity, page: WebPage, document: Int) -> Int? {
        let parts = identity.token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "web", parts[1] == page.targetID, parts[2] == page.sessionID,
              Int(parts[3]) == document
        else { return nil }
        return Int(parts[4])
    }

    /// The DOM node `identity` names and its document's node, whatever its tab.
    static func place(of identity: TargetIdentity) -> (document: Int, node: Int)? {
        let parts = identity.token.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "web", let document = Int(parts[3]), let node = Int(parts[4]) else { return nil }
        return (document, node)
    }

    /// The backend id of the page's document node, which another document (a navigation, a reload) does not keep.
    static func documentNode(of page: WebPage) async throws -> Int {
        let answer = try await page.send("DOM.getDocument", ["depth": 0])
        guard let id = answer["root"]?["backendNodeId"]?.intValue else {
            throw WebDrivingError.unreadablePage("no document node")
        }
        return id
    }
}

/// WebWindows is `WindowListing` for tabs: one ordinary window, the viewport the last scene
/// measured, with an open select's list in front of it, and none for an id no tab has.
public struct WebWindows: WindowListing {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
        guard let window = tabs.window(of: processID) else { return [] }
        let main = WindowRow(layer: 0, frame: CGRect(origin: .zero, size: window.viewport), title: window.title)
        // An open select's list is a pop-up menu over the page, at the menu layer a toolkit uses.
        guard let popup = window.popup else { return [main] }
        return [WindowRow(layer: 101, frame: popup.frame(in: window.viewport)), main]
    }
}
