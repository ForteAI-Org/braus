//
//  PersonScreen.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

import AppKit
import VirtualScreens

/// PersonScreen picks the screen the person is working on, where an app Braus lends them and the
/// companion that marks it belong: the screen under the pointer, otherwise the screen of Braus' key
/// window, otherwise the main screen, the one with the menu bar. A Seat's virtual display is never
/// chosen, since nobody looks at it.
public enum PersonScreen {

    /// Screen is one display as the rule reads it: its frame in AppKit's screen space and whether it
    /// is a Seat's virtual display.
    public struct Screen: Sendable, Equatable {
        public let displayID: CGDirectDisplayID
        public let frame    : CGRect
        public let isSeat   : Bool

        public init(
            displayID: CGDirectDisplayID,
            frame    : CGRect,
            isSeat   : Bool
        ) {
            self.displayID = displayID
            self.frame     = frame
            self.isSeat    = isSeat
        }
    }

    /// The person's screen among `screens`, in `NSScreen.screens`' order with the main screen first:
    /// the one holding `pointer`, otherwise the one showing Braus' key window, otherwise the first one.
    /// Nil when every screen is a Seat's.
    public static func chosen(
        among screens   : [Screen],
        pointer         : CGPoint?,
        keyWindowDisplay: CGDirectDisplayID?
    ) -> Screen? {
        let person = screens.filter { !$0.isSeat }
        if let pointer, let under = person.first(where: { holds($0.frame, pointer) }) { return under }
        if let keyWindowDisplay, let key = person.first(where: { $0.displayID == keyWindowDisplay }) { return key }
        return person.first
    }

    /// Whether a display with this vendor and model is a Seat's: the identity every virtual display
    /// the Seat creates presents (`VirtualDisplayConfiguration`).
    public static func isSeat(
        vendor: UInt32,
        model : UInt32
    ) -> Bool {
        vendor == VirtualDisplayConfiguration.vendorID && model == VirtualDisplayConfiguration.productID
    }

    /// The person's screen now, with the pointer where it is: call it when the person asks, as they
    /// press Take control. Nil only when there is no screen but a Seat's.
    @MainActor
    public static func current(pointer: CGPoint = NSEvent.mouseLocation) -> NSScreen? {
        let screens = NSScreen.screens
        let chosen  = chosen(
            among           : screens.map(screen),
            pointer         : pointer,
            keyWindowDisplay: NSApp.keyWindow?.screen.map(displayID)
        )
        return screens.first { displayID(of: $0) == chosen?.displayID }
    }

    /// Whether `screen` is a Seat's virtual display, which nobody looks at.
    @MainActor
    public static func isSeat(_ screen: NSScreen) -> Bool {
        Self.screen(screen).isSeat
    }

    /// The display behind `screen`.
    @MainActor
    public static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    @MainActor
    private static func screen(_ screen: NSScreen) -> Screen {
        let id = displayID(of: screen)
        return Screen(
            displayID: id,
            frame    : screen.frame,
            isSeat   : isSeat(
                vendor: CGDisplayVendorNumber(id),
                model : CGDisplayModelNumber(id)
            )
        )
    }

    /// Whether `frame` holds `point`, its top and right edges included: the pointer at the very top
    /// of a screen reads its height.
    private static func holds(
        _ frame: CGRect,
        _ point: CGPoint
    ) -> Bool {
        (frame.minX...frame.maxX).contains(point.x) && (frame.minY...frame.maxY).contains(point.y)
    }
}
