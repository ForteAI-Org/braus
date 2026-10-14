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
public struct WebScenes: SceneProviding {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
        let page = try tabs.page(for: processID)
        async let tree     = page.send("Accessibility.getFullAXTree")
        async let snapshot = page.send("DOMSnapshot.captureSnapshot", ["computedStyles": []])
        async let metrics  = page.send("Page.getLayoutMetrics")
        let layout = try WebLayout(snapshot: try await snapshot, metrics: try await metrics)
        let scene  = WebSceneBuilder.scene(nodes: WebAXNode.nodes(fromFullTree: try await tree), layout: layout)
        tabs.note(viewport: layout.viewport, title: scene.windowTitle, for: processID)
        return PerceivedWindow(scene: scene, frame: CGRect(origin: .zero, size: layout.viewport), surface: .window)
    }
}

/// WebWindows is `WindowListing` for tabs: one ordinary window, the viewport the last scene
/// measured, and none for an id no tab has.
public struct WebWindows: WindowListing {

    let tabs: WebTabs

    public init(tabs: WebTabs) {
        self.tabs = tabs
    }

    public func windows(ownedBy processID: pid_t) throws -> [WindowRow] {
        guard let window = tabs.window(of: processID) else { return [] }
        return [WindowRow(layer: 0, frame: CGRect(origin: .zero, size: window.viewport), title: window.title)]
    }
}
