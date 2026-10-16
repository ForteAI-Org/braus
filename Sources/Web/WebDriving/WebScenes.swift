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
/// A node a script found is named in a scene by its identity (`WebNodeIdentity`): the tab's target and
/// session, the document's own node and the element's node, by their backend ids. The scene's element
/// id, made of kind, label and place, is kept by a node replaced in the same place; the identity is not.
public struct WebScenes: SceneProviding {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        try await scene(of: processID).window
    }

    /// The scene, and the id in it of the element of the node `identity`, for a node found by other means (a
    /// script) and clicked through the engine. Nil when that node is not in this read: another tab or document
    /// (a navigation, a reload), a node removed or replaced, an element outside the view, or an id two elements
    /// share.
    public func currentScene(
        of processID   : pid_t,
        naming identity: WebNodeIdentity
    ) async throws -> (window: PerceivedWindow, target: String?) {
        let page = try tabs.page(for: processID)
        let read = try await scene(of: processID)
        guard identity.targetID == page.targetID, identity.sessionID == page.sessionID,
              read.document == identity.document
        else { return (read.window, nil) }
        return (read.window, read.backendNodes.first { $0.value == identity.node }?.key)
    }

    /// The scene, the document node it was read from, and the DOM node of each element by its id.
    private func scene(
        of processID: pid_t
    ) async throws -> (window: PerceivedWindow, document: Int?, backendNodes: [String: Int]) {
        let page = try tabs.page(for: processID)
        async let document = try? Self.documentNode(of: page)
        async let tree     = page.send("Accessibility.getFullAXTree")
        async let snapshot = page.send("DOMSnapshot.captureSnapshot", ["computedStyles": []])
        async let metrics  = page.send("Page.getLayoutMetrics")
        let layout = try WebLayout(snapshot: try await snapshot, metrics: try await metrics)
        let isOpen = tabs.window(of: processID)?.popup != nil
        let popup  = isOpen ? await WebControls(tabs: tabs).openPopup(in: processID) : nil
        tabs.setPopup(popup, for: processID)
        let built  = WebSceneBuilder.build(nodes: WebAXNode.nodes(fromFullTree: try await tree), layout: layout,
                                           popup: popup)
        tabs.note(viewport: layout.viewport, title: built.scene.windowTitle, for: processID)
        let window = PerceivedWindow(scene: built.scene, frame: CGRect(origin: .zero, size: layout.viewport),
                                     capture: built.capture, surface: popup == nil ? .window : .popupUnion)
        return (window, await document, built.backendNodes)
    }

    /// The identity of DOM node `node` of the document whose own node is `document`, in `page`'s tab.
    static func identity(page: WebPage, document: Int, node: Int) -> WebNodeIdentity {
        WebNodeIdentity(targetID: page.targetID, sessionID: page.sessionID, document: document, node: node)
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
