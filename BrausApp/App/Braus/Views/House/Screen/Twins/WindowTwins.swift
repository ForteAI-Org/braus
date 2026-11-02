//
//  WindowTwins.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import os

/// WindowTwins keeps a twin of each of the held application's other windows beside the worker's
/// screen window (`WindowTwin`). A twin comes as its window appears, where the window stands around
/// the main window on the seat's display (`TwinLayout`), and goes as it closes. From then on it is a
/// window of its own: the person moves it where they like, and it follows only what its window does,
/// a move by as much and a new size from its top-left corner, and are on screen only while the screen
/// window is. Each change is logged with why.
///
/// The screen window and the twins are ordered as one application's windows are: the one the person
/// presses comes to the front of the group, and the group stays together against other applications'
/// windows. The application's own order wins only when it reorders its windows itself; its dialogs
/// and floating windows stay above the screen window (`TwinLayout.stack`).
///
/// On Take Control each of the application's windows lands on its own twin (`lendingFrames()`); on
/// the hand-back each twin comes back where the person left its window (`comeBack(at:)`).
@MainActor
final class WindowTwins {

    private let source: TwinSource

    /// The worker's screen window and its picture's frame, whether the person may move a twin now,
    /// and what goes back above the twins once they are ordered again: the worker on the corner.
    private weak var main  : NSWindow?
    private let mainPicture: () -> CGRect?
    private let movesWindow: () -> Bool
    private let raiseAbove : () -> Void

    private(set) var twins: [Int: WindowTwin] = [:]

    /// The group back to front, twins by window number and the screen window as
    /// `TwinLayout.screenMember`, and the application's own order of the same windows when last seen.
    private var stack   : [Int] = []
    private var appStack: [Int] = []

    /// The main window, the screen window's, kept while the application has it (`TwinLayout.main`).
    private var mainNumber: Int?

    /// Whether the twins stepped aside for the windows the person has, until the hand-back.
    private var isAside = false

    /// Until when, after the hand-back, a twin takes its window's frame as where it is followed from
    /// rather than as a move: the windows go back to the seat's display just after the twins come back.
    private var rebasesUntil: ContinuousClock.Instant?

    /// How long the windows' way back to the seat may take.
    static let rebasing: Duration = .seconds(3)

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "ScreenWindow"
    )

    init(
        source     : TwinSource,
        main       : NSWindow,
        mainPicture: @escaping () -> CGRect?,
        movesWindow: @escaping () -> Bool,
        raiseAbove : @escaping () -> Void = {}
    ) {
        self.source      = source
        self.main        = main
        self.mainPicture = mainPicture
        self.movesWindow = movesWindow
        self.raiseAbove  = raiseAbove
        watch()
    }

    private func watch() {
        withObservationTracking {
            _ = source.windows
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync(because: "the application's windows changed")
                self?.watch()
            }
        }
    }

    /// Brings the twins in line with the application's windows, saying why: on screen while the
    /// screen window is, off it otherwise.
    func sync(because reason: String) {
        // The windows are the person's: their twins wait for the hand-back.
        guard !isAside else { return }
        guard let main, let first = TwinLayout.main(
            of     : source.windows,
            keeping: mainNumber
        ) else {
            removeAll(because: reason)
            return
        }
        mainNumber = first.windowNumber
        guard main.isVisible, let picture = mainPicture(),
              let visible = (main.screen ?? NSScreen.main)?.visibleFrame else {
            hide(because: reason)
            return
        }
        let secondaries = TwinLayout.secondaries(
            of  : source.windows,
            main: first
        )
        let live        = TwinLayout.live(secondaries)
        let numbers     = Set(secondaries.map(\.windowNumber))
        for (number, twin) in twins where !numbers.contains(number) {
            twin.panel.orderOut(nil)
            twins[number] = nil
            Self.log.notice("Twin of window \(number, privacy: .public) goes: \(reason, privacy: .public)")
        }
        let scale = first.frame.width > 0 ? picture.width / first.frame.width : 1
        for window in secondaries {
            if let twin = twins[window.windowNumber] {
                follow(
                    twin,
                    to     : window,
                    scale  : scale,
                    because: reason
                )
                continue
            }
            let frame = TwinLayout.picture(
                of         : window,
                main       : first,
                mainPicture: picture,
                visible    : visible
            )
            // Streamed at the scale of the screen the twin shows on, which may not be the screen window's.
            let scale = Self.screen(holding: frame)?.backingScaleFactor ?? main.backingScaleFactor
            let twin  = WindowTwin(
                window     : window,
                view       : live.contains(window.windowNumber)
                    ? source.makeView(
                        windowNumber : window.windowNumber,
                        contentsScale: scale
                    )
                    : nil,
                streamScale: scale,
                movesWindow: movesWindow
            )
            // The same stream, asked at the new scale, sharpens the view the twin already shows.
            let number = window.windowNumber
            twin.restream = { [weak self] scale in
                _ = self?.source.makeView(
                    windowNumber : number,
                    contentsScale: scale
                )
            }
            twin.comesForward = { [weak self] in
                self?.bringForward(
                    number,
                    because: "the person pressed the twin"
                )
            }
            twin.frameView.canResize = movesWindow
            twin.frameView.resizes   = { [weak self, weak twin] from, to, ended in
                guard let self, let twin else { return }
                resized(
                    twin,
                    from : from,
                    to   : to,
                    ended: ended
                )
            }
            twin.place(picture: frame)
            twins[window.windowNumber] = twin
            Self.log.notice("Twin of \(String(describing: window.kind), privacy: .public) window \(window.windowNumber, privacy: .public) '\(window.title, privacy: .public)' comes at \(String(describing: frame), privacy: .public), live \(twin.isLive, privacy: .public) at \(scale, privacy: .public)x: \(reason, privacy: .public)")
        }
        let app    = TwinLayout.appStack(
            main       : first,
            secondaries: secondaries
        )
        let wanted = TwinLayout.stack(
            current: stack,
            app    : app,
            lastApp: appStack,
            pinned : pinned
        )
        appStack = app
        if wanted != stack || twins.values.contains(where: { !$0.panel.isVisible }) {
            stack = wanted
            apply(because: reason)
        }
    }

    /// The twins that stay above the screen window, by window number.
    private var pinned: Set<Int> {
        Set(source.windows.filter(TwinLayout.staysAbove).map(\.windowNumber))
    }

    /// Moves `twin` by as much as its window moved on the seat's display since it last followed it,
    /// at the main twin's `scale`, and gives it the window's new size from its top-left corner: where
    /// the person put it stays theirs.
    private func follow(
        _ twin  : WindowTwin,
        to window: TwinWindow,
        scale    : CGFloat,
        because reason: String
    ) {
        let last = twin.followed
        // The person's resize under way decides the twin's size; the window's is followed after it.
        guard window.frame != last, !twin.frameView.isResizing else { return }
        twin.followed = window.frame
        if let rebasesUntil, ContinuousClock.now < rebasesUntil {
            Self.log.notice("Twin of window \(window.windowNumber, privacy: .public) follows its window from \(String(describing: window.frame), privacy: .public) on: \(reason, privacy: .public), back from the person")
            return
        }
        let now    = twin.pictureFrame
        let width  = (window.frame.width * scale).rounded()
        let height = (window.frame.height * scale).rounded()
        // Window-server space counts y down; AppKit's up.
        let top    = now.maxY - (window.frame.minY - last.minY) * scale
        let frame  = CGRect(
            x     : (now.minX + (window.frame.minX - last.minX) * scale).rounded(),
            y     : (top - height).rounded(),
            width : width,
            height: height
        )
        if twin.place(picture: frame) {
            Self.log.notice("Twin of window \(window.windowNumber, privacy: .public) follows it to \(String(describing: frame), privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// The person resized `twin`'s picture from `from` to `to`, in AppKit's screen space: its window
    /// takes that size at the twin's scale, and as the press ends the twin takes the size the window
    /// kept from its top-left corner, back where the application refused.
    private func resized(
        _ twin: WindowTwin,
        from  : CGRect,
        to    : CGRect,
        ended : Bool
    ) {
        let scale  = twin.followed.width / max(from.width, 1)
        let wanted = CGSize(
            width : (to.width * scale).rounded(),
            height: (to.height * scale).rounded()
        )
        let took   = source.resize(
            windowNumber: twin.windowNumber,
            to          : wanted
        )
        Self.log.notice("Twin of window \(twin.windowNumber, privacy: .public) resized by the person to \(String(describing: to), privacy: .public): its window asked for \(String(describing: wanted), privacy: .public), took \(String(describing: took), privacy: .public)")
        guard ended else { return }
        let size   = took ?? twin.followed.size
        let width  = (size.width / scale).rounded()
        let height = (size.height / scale).rounded()
        twin.place(picture: CGRect(
            x     : to.minX,
            y     : to.maxY - height,
            width : width,
            height: height
        ))
    }

    /// Moves the twins that stood on the display of frame `left` as the screen window's picture went
    /// from `before` to `after` on another, kept inside `visible`, that display's visible frame: the
    /// group stays together where the person sees it. Twins the person put on another display stay.
    func carry(
        from before   : CGRect,
        to after      : CGRect,
        leaving left  : CGRect,
        within visible: CGRect,
        because reason: String
    ) {
        for twin in twins.values where Self.screen(holding: twin.pictureFrame)?.frame == left {
            let frame = TwinLayout.carried(
                twin.pictureFrame,
                from  : before,
                to    : after,
                within: visible
            )
            if twin.place(picture: frame) {
                Self.log.notice("Twin of window \(twin.windowNumber, privacy: .public) is carried to \(String(describing: frame), privacy: .public): \(reason, privacy: .public)")
            }
        }
    }

    /// Brings `member`, a twin's window number or `TwinLayout.screenMember`, to the front of the group
    /// as the person pressed it, and the group with it.
    func bringForward(
        _ member: Int,
        because reason: String
    ) {
        guard !isAside, let main, main.isVisible, let window = window(of: member) else { return }
        window.orderFront(nil)
        takeOrderOnScreen()
        stack.removeAll { $0 == member }
        stack.append(member)
        apply(because: reason)
    }

    /// Keeps the group together in the order it stands in on screen, which the person may have changed
    /// by pressing its windows.
    func restack(because reason: String) {
        guard !isAside, let main, main.isVisible else { return }
        takeOrderOnScreen()
        apply(because: reason)
    }

    /// The group front to back as it stands on screen, by member: the screen window and the twins shown.
    private func onScreen() -> [Int] {
        guard let main else { return [] }
        var members = [main.windowNumber: TwinLayout.screenMember]
        for (number, twin) in twins where twin.panel.isVisible {
            members[twin.panel.windowNumber] = number
        }
        return (NSWindow.windowNumbers(options: []) ?? []).compactMap { members[$0.intValue] }
    }

    /// Takes the order on screen as the group's, when every member of the group is on screen.
    private func takeOrderOnScreen() {
        let seen = onScreen()
        guard Set(seen) == Set(stack), seen.count == stack.count else { return }
        stack = seen.reversed()
    }

    private func window(of member: Int) -> NSWindow? {
        member == TwinLayout.screenMember ? main : twins[member]?.panel
    }

    /// Orders the group as `stack` has it, around the member in front on screen, without taking the
    /// keyboard or bringing any other window of Braus forward; the worker on the corner goes back on top.
    private func apply(because reason: String) {
        guard let main, main.isVisible else { return }
        stack = TwinLayout.settled(
            stack,
            pinned: pinned
        )
        let windows = stack.compactMap(window(of:))
        guard let top = windows.last else { return }
        for twin in twins.values { twin.panel.level = main.level }
        let front = onScreen().first.flatMap(window(of:)) ?? main
        if top !== front {
            top.order(
                .above,
                relativeTo: front.windowNumber
            )
        }
        var above = top
        for window in windows.reversed().dropFirst() {
            window.order(
                .below,
                relativeTo: above.windowNumber
            )
            above = window
        }
        raiseAbove()
        Self.log.notice("Twins and the screen window ordered back to front \(self.stack, privacy: .public): \(reason, privacy: .public)")
    }

    /// The screen that holds most of `frame`, in AppKit's screen space.
    static func screen(holding frame: CGRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) }
    }

    /// Takes the twins off the screen, keeping them and where they are.
    func hide(because reason: String) {
        let shown = twins.values.filter(\.panel.isVisible)
        guard !shown.isEmpty else { return }
        shown.forEach { $0.panel.orderOut(nil) }
        Self.log.notice("Twins hide, \(shown.count, privacy: .public) of them: \(reason, privacy: .public)")
    }

    /// Takes every twin away.
    func removeAll(because reason: String) {
        guard !twins.isEmpty else { return }
        twins.values.forEach { $0.panel.orderOut(nil) }
        Self.log.notice("Twins go, \(self.twins.count, privacy: .public) of them: \(reason, privacy: .public)")
        twins      = [:]
        stack      = []
        appStack   = []
        mainNumber = nil
    }

    /// Covers each twin with a still of its picture and takes the twins off the screen, as their
    /// windows come to the person each onto its own twin; the stills, by window number, fade into the
    /// windows once they stand still (`LendStill.land()`).
    func stepAside(because reason: String) -> [Int: LendStill] {
        var stills: [Int: LendStill] = [:]
        for (number, twin) in twins where twin.panel.isVisible {
            guard let still = LendStill(picture: twin.content) else { continue }
            still.show()
            stills[number] = still
        }
        hide(because: reason)
        isAside = true
        return stills
    }

    /// Puts the twins back on the screen, above the screen window, after the hand-back.
    func show(because reason: String) {
        isAside      = false
        rebasesUntil = .now + Self.rebasing
        // Back on the seat's display, each window is followed from where it is now.
        for window in source.windows {
            twins[window.windowNumber]?.followed = window.frame
        }
        sync(because: reason)
        restack(because: reason)
    }

    /// Where each of the application's other windows lands as the person takes control: on its own
    /// twin's picture, in window-server space, by window number.
    func lendingFrames() -> [Int: CGRect] {
        let menuBarScreen = NSScreen.screens.first?.frame ?? .zero
        return twins.mapValues {
            LendingCompanion.appKitFrame(
                $0.pictureFrame,
                menuBarScreen: menuBarScreen
            )
        }
    }

    /// Puts each twin back where the person left its window, `frames` in window-server space by window
    /// number, as the application is handed back.
    func comeBack(at frames: [Int: CGRect]) {
        let menuBarScreen = NSScreen.screens.first?.frame ?? .zero
        for (number, frame) in frames {
            guard let twin = twins[number] else { continue }
            let picture = LendingCompanion.appKitFrame(
                frame,
                menuBarScreen: menuBarScreen
            )
            twin.place(picture: picture)
            Self.log.notice("hand back: the twin of window \(number, privacy: .public) comes back at \(String(describing: picture), privacy: .public)")
        }
    }
}
