//
//  WindowTwin.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/10/2026.
//

import AppKit
import os
import SeatBroker

/// WindowTwin is the twin of one of the held application's other windows, a dialog, a palette or a
/// small window, beside the main window's twin, the worker's screen window: its picture at the
/// window's size in a thin margin with the thin amber neon, and no bar and no worker. It is a window
/// of its own, as the application's is: the person moves it from its picture while the worker holds
/// the application, as they do the screen window, and it stays where they put it. It never takes the
/// keyboard nor activates Braus. Its neon and shadow follow the window's own corner, read from its
/// picture once and again only as the window changes size (`WindowCorner`).
@MainActor
final class WindowTwin {
    let windowNumber: Int

    let panel = TwinPanel(
        contentRect: .zero,
        styleMask  : [.borderless, .nonactivatingPanel],
        backing    : .buffered,
        defer      : true
    )

    let frameView = ScreenWindowFrame(
        style: .thin,
        inset: NeonTube.Style.thin.reach
    )

    /// Whether its picture is live; one past the live views a worker may have shows a dimmed card.
    let isLive: Bool

    /// The display scale its window's stream was asked for, and what asks for it again at another
    /// once the twin has settled on a display of that scale.
    private(set) var streamScale: CGFloat
    var restream: ((CGFloat) -> Void)?

    /// Told as a press brings the twin to the front, so the group comes with it.
    var comesForward: (() -> Void)?

    private var settling: Task<Void, Never>?
    private var scaleWatch: NSObjectProtocol?

    /// The window's frame on the seat's display when the twin last followed it.
    var followed: CGRect

    /// The window's own view, which a still is taken of as the window goes to the person.
    let content: NSView

    init(
        window     : TwinWindow,
        view       : NSView?,
        streamScale: CGFloat,
        movesWindow: @escaping () -> Bool
    ) {
        windowNumber     = window.windowNumber
        isLive           = view != nil
        self.streamScale = streamScale
        followed     = window.frame
        content      = view ?? Self.card()
        // Nothing behind the picture, as on the screen window: the stream's layer is black behind
        // the capture, which filled the window's clear rounded corners with square black ones.
        if view != nil { content.layer?.backgroundColor = nil }
        panel.isFloatingPanel      = false
        panel.level                = .normal
        panel.hidesOnDeactivate    = false
        panel.collectionBehavior   = [.managed, .ignoresCycle]
        panel.isOpaque             = false
        panel.backgroundColor      = .clear
        panel.hasShadow            = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior    = .none
        panel.appearance           = NSAppearance(named: .darkAqua)
        // Unseen, the title still names it to VoiceOver.
        panel.title                = window.title
        frameView.picture          = Picture(
            content     : content,
            movesWindow : movesWindow,
            comesForward: { [weak self] in self?.comesForward?() }
        )
        panel.contentView          = frameView
        frameView.minimumPicture   = Self.minimumPicture
        frameView.showsMargin(true)
        if let live = view as? LivePreviewView {
            // Told as the first frame shows and as the window changes size, after the frame is in.
            live.onPictureSize = { [weak self] _ in
                DispatchQueue.main.async { self?.followCorner() }
            }
        } else if view != nil {
            followCorner()
        }
        if isLive {
            scaleWatch = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeBackingPropertiesNotification,
                object : panel,
                queue  : .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.settleScale() }
            }
        }
    }

    isolated deinit {
        settling?.cancel()
        if let scaleWatch { NotificationCenter.default.removeObserver(scaleWatch) }
    }

    /// The least the person may make a twin's picture, which still shows it as a window.
    static let minimumPicture = CGSize(
        width : 64,
        height: 40
    )

    /// How long the twin must stand still, the button up, before its stream follows a new scale:
    /// never on every move of a drag across displays.
    static let settle: Duration = .milliseconds(300)

    /// Asks for the window's stream at the scale of the display the twin settles on, once it has
    /// stood still there.
    private func settleScale() {
        settling?.cancel()
        settling = Task { [weak self] in
            var last  = self?.panel.frame
            var still = Duration.zero
            while still < Self.settle {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                let frame = panel.frame
                still = frame == last && NSEvent.pressedMouseButtons & 1 == 0 ? still + .milliseconds(50) : .zero
                last  = frame
            }
            guard let self else { return }
            let scale = panel.backingScaleFactor
            guard scale != streamScale else { return }
            Self.log.notice("Twin of window \(self.windowNumber, privacy: .public) rescaled \(Int(self.streamScale), privacy: .public)x → \(Int(scale), privacy: .public)x")
            streamScale = scale
            restream?(scale)
        }
    }

    private static let log = Logger(
        subsystem: "dev.forte.Braus",
        category : "ScreenWindow"
    )

    /// The window's own corner radius, in its points, as its picture showed it.
    private var windowCorner: CGFloat?

    /// Reads the window's own corner from its picture and gives it to the neon and the shadow.
    private func followCorner() {
        guard isLive, let layer = content.layer,
              let radius = WindowCorner.radius(of: layer, windowWidth: followed.width),
              radius != windowCorner else { return }
        windowCorner = radius
        Self.log.notice("Twin of window \(self.windowNumber, privacy: .public) follows its corner of \(radius, privacy: .public) pt")
        applyCorner()
    }

    /// The window's corner at the twin's scale, once the twin has a place.
    private func applyCorner() {
        guard let windowCorner, followed.width > 0, pictureFrame.width > 0 else { return }
        frameView.setCorner((windowCorner * pictureFrame.width / followed.width).rounded())
    }

    /// Where its picture is, in AppKit's screen space.
    var pictureFrame: CGRect {
        panel.frame.insetBy(
            dx: frameView.inset,
            dy: frameView.inset
        )
    }

    /// Puts its picture at `frame`, in AppKit's screen space; true when it moved or changed size.
    @discardableResult
    func place(picture frame: CGRect) -> Bool {
        let outer = frame.insetBy(
            dx: -frameView.inset,
            dy: -frameView.inset
        )
        guard outer != panel.frame else { return false }
        panel.setFrame(
            outer,
            display: true
        )
        applyCorner()
        return true
    }

    /// A dim card in the window's shape, for a window past the live views a worker may have.
    private static func card() -> NSView {
        let view = NSView()
        view.wantsLayer             = true
        view.layer?.backgroundColor = NSColor(
            white: 0.12,
            alpha: 1
        ).cgColor
        view.layer?.cornerRadius    = NeonTube.windowCorner
        view.alphaValue             = 0.7
        return view
    }

    /// Picture holds the window's view, which never takes the pointer: a press on it comes forward
    /// and, while the worker holds the application, moves the twin.
    private final class Picture: NSView {
        private let movesWindow : () -> Bool
        private let comesForward: () -> Void

        init(
            content     : NSView,
            movesWindow : @escaping () -> Bool,
            comesForward: @escaping () -> Void
        ) {
            self.movesWindow  = movesWindow
            self.comesForward = comesForward
            super.init(frame: .zero)
            content.autoresizingMask = [.width, .height]
            addSubview(content)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            subviews.first?.frame = bounds
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.orderFront(nil)
            comesForward()
            guard movesWindow() else { return }
            window?.performDrag(with: event)
        }
    }

    /// TwinPanel never takes the keyboard nor becomes main, and stays where it is put, as the
    /// companion's panels do.
    final class TwinPanel: NSPanel {
        override var canBecomeKey : Bool { false }
        override var canBecomeMain: Bool { false }

        override func constrainFrameRect(
            _ frameRect: NSRect,
            to screen  : NSScreen?
        ) -> NSRect {
            frameRect
        }
    }
}
