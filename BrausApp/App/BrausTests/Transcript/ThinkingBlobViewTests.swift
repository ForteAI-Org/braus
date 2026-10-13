//
//  ThinkingBlobViewTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 12/10/2026.
//

import AppKit
import Foundation
import Testing
@testable import Braus

/// The thinking blob in a real window ordered on screen, which it needs to
/// animate at all. The window never becomes key and takes no input.
@Suite("Thinking blob in a real window", .serialized)
@MainActor
struct ThinkingBlobViewTests {

    private static let still  = ThinkingBlobView.Accessibility(reducesMotion: false, reducesTransparency: false)
    private static let reduce = ThinkingBlobView.Accessibility(reducesMotion: true, reducesTransparency: false)

    /// The animation keys on the blob's shape layer, once `ready` holds or after two seconds.
    private func keys(of view: ThinkingBlobView, until ready: (Set<String>) -> Bool) async -> Set<String> {
        let deadline = Date().addingTimeInterval(2)
        var found    = Set<String>()
        while Date() < deadline {
            let layer = view.layer?.sublayers?.first { $0 is CAShapeLayer }
            found = Set(layer?.animationKeys() ?? [])
            if ready(found) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return found
    }

    @Test("A change of the display options posted on the workspace centre stops the turn and the morph")
    func reduceMotionFromWorkspace() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 120, height: 120),
            styleMask  : [.titled],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = ThinkingBlobView(frame: NSRect(x: 40, y: 40, width: 20, height: 20))
        view.accessibility       = Self.still
        view.systemAccessibility = { Self.reduce }
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()

        let moving = await keys(of: view) { $0.contains("blob.spin") }
        #expect(moving.contains("blob.spin") && moving.contains("blob.path"))

        NSWorkspace.shared.notificationCenter.post(
            name  : NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
        #expect(view.accessibility == Self.reduce)
        let reduced = await keys(of: view) { !$0.contains("blob.spin") }
        #expect(!reduced.contains("blob.spin") && !reduced.contains("blob.path") && !reduced.contains("blob.scale"))
        #expect(reduced.contains("blob.fade"))
    }
}
