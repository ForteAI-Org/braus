//
//  HumanControlPanelTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import AppKit
import Testing
@testable import Braus

/// The order the window server keeps, read back from it: a panel stacked above the lent window stays
/// under the windows in front of that one.
@Suite("HumanControlPanel", .serialized)
@MainActor
struct HumanControlPanelTests {

    /// A small borderless window at the main screen's bottom-left corner, which never takes the keys.
    private func window(at offset: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(
                x     : offset,
                y     : 0,
                width : 40,
                height: 40
            ),
            styleMask  : [.borderless],
            backing    : .buffered,
            defer      : false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// The window server's order of `numbers`, front first.
    private func order(of numbers: [Int]) async -> [Int] {
        // The window server takes the orders on its next turn.
        try? await Task.sleep(for: .milliseconds(100))
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]] ?? []
        return rows.compactMap { $0[kCGWindowNumber as String] as? Int }.filter(numbers.contains)
    }

    @Test("Stacked above the lent window, the panel goes under a window in front of it, and floats again unanchored")
    func staysUnderWindowsInFrontOfTheLentOne() async {
        let lent  = window(at: 0)
        let other = window(at: 20)
        let panel = HumanControlPanel.make(ignoresMouse: true)
        panel.setFrame(
            CGRect(
                x     : 10,
                y     : 0,
                width : 40,
                height: 40
            ),
            display: false
        )
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            other.orderOut(nil)
            lent.orderOut(nil)
        }
        let numbers = [other.windowNumber, panel.windowNumber, lent.windowNumber]
        #expect(await order(of: numbers).first == panel.windowNumber)

        panel.stack(above: lent.windowNumber)
        #expect(panel.level == .normal)
        #expect(await order(of: numbers) == [other.windowNumber, panel.windowNumber, lent.windowNumber])

        panel.stack(above: nil)
        #expect(panel.level == .floating)
        #expect(await order(of: numbers).first == panel.windowNumber)
    }

    @Test("Anchored to a lent window that is off the screen, the panel goes behind ordinary windows")
    func goesBehindWhileTheLentWindowIsOff() async {
        let lent  = window(at: 0)
        let other = window(at: 20)
        let panel = HumanControlPanel.make(ignoresMouse: true)
        panel.setFrame(
            CGRect(
                x     : 10,
                y     : 0,
                width : 40,
                height: 40
            ),
            display: false
        )
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            other.orderOut(nil)
        }
        lent.orderOut(nil)
        panel.stack(above: lent.windowNumber)
        #expect(await order(of: [other.windowNumber, panel.windowNumber]) == [other.windowNumber, panel.windowNumber])
    }
}
