//
//  TwinLayout.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import SeatBroker

/// TwinWindow is one window of the application a worker holds, as the seat reports it: its number,
/// its process, its frame on the seat's display in window-server space (y down from the top of the
/// menu-bar screen), its level, what kind of window it is, the window it belongs to, its title, and
/// its place front to back among the application's windows, 0 in front.
nonisolated struct TwinWindow: Equatable, Sendable {
    enum Kind: Sendable {
        case main, dialog, sheet, panel, other
    }

    let windowNumber      : Int
    let processID         : pid_t
    var frame             : CGRect
    let level             : Int
    let kind              : Kind
    let parentWindowNumber: Int?
    let title             : String
    var order             : Int
}

/// TwinSource gives the windows of the held application, observed as they change, and a live view of
/// each, and resizes one as the person resizes its picture, answering the size it took.
@MainActor
protocol TwinSource: AnyObject {
    var windows: [TwinWindow] { get }

    func makeView(
        windowNumber : Int,
        contentsScale: CGFloat
    ) -> NSView?

    func resize(
        windowNumber: Int,
        to size     : CGSize
    ) -> CGSize?
}

/// TwinLayout places the twins of the application's other windows around its main window's twin as
/// the windows stand around the main window on the seat's display, at the main twin's scale.
nonisolated enum TwinLayout {

    /// The live views a worker's windows may have at once, the main window's included: the seat's.
    static let liveLimit = BrokeredAutomationSession.windowStreamLimit

    /// The application's main window: `kept`, the one chosen before, while the application still has
    /// it, so a resize or a new order never moves the screen window to another window, a lent one
    /// least of all; otherwise the one the seat calls main, or its largest at the normal level.
    static func main(
        of windows: [TwinWindow],
        keeping kept: Int? = nil
    ) -> TwinWindow? {
        windows.first { $0.windowNumber == kept } ?? windows.first { $0.kind == .main } ?? windows
            .filter { $0.level == 0 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// The windows that get a twin of their own beside the main one, back to front: all but the main
    /// window and its sheets, which its picture already shows.
    static func secondaries(
        of windows: [TwinWindow],
        main      : TwinWindow
    ) -> [TwinWindow] {
        windows
            .filter { $0.windowNumber != main.windowNumber && $0.kind != .sheet }
            .sorted { $0.order > $1.order }
    }

    /// The screen window's place in the order the twins and it stand in; no window has this number.
    static let screenMember = 0

    /// Whether the twin of `window` stays above the screen window whatever the person presses, as the
    /// application keeps it above its own windows: a dialog, or a window at a floating level.
    static func staysAbove(_ window: TwinWindow) -> Bool {
        window.kind == .dialog || window.level > 0
    }

    /// The application's own order of its main window, as `screenMember`, and of the windows with a
    /// twin, back to front.
    static func appStack(
        main       : TwinWindow,
        secondaries: [TwinWindow]
    ) -> [Int] {
        (secondaries + [main])
            .sorted { $0.order > $1.order }
            .map { $0.windowNumber == main.windowNumber ? screenMember : $0.windowNumber }
    }

    /// The order the screen window and the twins stand in, back to front, once the application's
    /// windows changed. The person's order, `current`, holds with closed windows gone and new ones in
    /// front, unless the application itself reordered windows that were already there (`lastApp`
    /// against `app`): then the application's order is taken. Either way the `pinned` twins end
    /// above the screen window (`settled`).
    static func stack(
        current: [Int],
        app    : [Int],
        lastApp: [Int],
        pinned : Set<Int>
    ) -> [Int] {
        let members   = Set(app)
        let seen      = Set(lastApp)
        let reordered = app.filter(seen.contains) != lastApp.filter(members.contains)
        let kept      = current.filter(members.contains)
        let base      = reordered ? app : kept + app.filter { !kept.contains($0) }
        return settled(
            base,
            pinned: pinned
        )
    }

    /// `stack` with every `pinned` twin that stands below the screen window lifted just above it, the
    /// lifted ones in their order: a dialog stays above the window it belongs to, as in the application.
    static func settled(
        _ stack: [Int],
        pinned : Set<Int>
    ) -> [Int] {
        guard let screen = stack.firstIndex(of: screenMember) else { return stack }
        let lifted = stack[..<screen].filter(pinned.contains)
        guard !lifted.isEmpty else { return stack }
        var rest = stack.filter { !lifted.contains($0) }
        rest.insert(
            contentsOf: lifted,
            at        : (rest.firstIndex(of: screenMember) ?? rest.count - 1) + 1
        )
        return rest
    }

    /// The secondaries that show live, the largest first, after the main window's own view.
    static func live(_ secondaries: [TwinWindow]) -> Set<Int> {
        Set(secondaries
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .prefix(liveLimit - 1)
            .map(\.windowNumber))
    }

    /// Where the twin of `window` shows its picture, in AppKit's screen space: as far from the main
    /// twin's picture, `mainPicture`, as `window` is from `main` on the seat's display, both at the
    /// main twin's scale, moved in the least needed to stay inside `visible`.
    static func picture(
        of window  : TwinWindow,
        main       : TwinWindow,
        mainPicture: CGRect,
        visible    : CGRect
    ) -> CGRect {
        let scale  = main.frame.width > 0 ? mainPicture.width / main.frame.width : 1
        let width  = (window.frame.width * scale).rounded()
        let height = (window.frame.height * scale).rounded()
        // Window-server space counts y down; AppKit's up.
        let left   = mainPicture.minX + (window.frame.minX - main.frame.minX) * scale
        let top    = mainPicture.maxY - (window.frame.minY - main.frame.minY) * scale
        return clamped(
            CGRect(
                x     : left,
                y     : top - height,
                width : width,
                height: height
            ),
            within: visible
        )
    }

    /// Where a twin's `picture` goes as the main twin's picture goes from `before` to `after` on
    /// another display: as far as the main picture's top-left corner went, so the group keeps its
    /// layout, moved in the least needed to stay inside `visible`, that display's visible frame.
    static func carried(
        _ picture  : CGRect,
        from before: CGRect,
        to after   : CGRect,
        within visible: CGRect
    ) -> CGRect {
        clamped(
            picture.offsetBy(
                dx: after.minX - before.minX,
                dy: after.maxY - before.maxY
            ),
            within: visible
        )
    }

    /// `picture` moved in the least needed to stay inside `visible`, its top-left kept on it when it
    /// is larger; whole points.
    static func clamped(
        _ picture     : CGRect,
        within visible: CGRect
    ) -> CGRect {
        CGRect(
            x     : min(max(picture.minX, visible.minX), max(visible.minX, visible.maxX - picture.width)).rounded(),
            y     : min(max(picture.minY, visible.minY), max(visible.minY, visible.maxY - picture.height)).rounded(),
            width : picture.width,
            height: picture.height
        )
    }
}
