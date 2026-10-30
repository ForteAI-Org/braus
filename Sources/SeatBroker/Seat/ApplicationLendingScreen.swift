//
//  ApplicationLendingScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit

/// ApplicationLendingScreen converts the explicit PersonScreen choice into placement coordinates.
/// Selection belongs to PersonScreen; a removed or Seat-owned display refuses lending.
enum ApplicationLendingScreen {
    static func windowServerFrame(visibleFrame: CGRect, menuBarFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.minX,
               y: menuBarFrame.maxY - visibleFrame.maxY,
               width: visibleFrame.width, height: visibleFrame.height)
    }

    @MainActor
    static func visibleFrame(of screen: NSScreen) -> CGRect? {
        let id = PersonScreen.displayID(of: screen)
        guard !PersonScreen.isSeat(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id)),
              let current = NSScreen.screens.first(where: { PersonScreen.displayID(of: $0) == id }),
              let menuBar = NSScreen.screens.first else { return nil }
        return windowServerFrame(visibleFrame: current.visibleFrame, menuBarFrame: menuBar.frame)
    }
}
