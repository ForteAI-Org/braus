//
//  WorkerScreenWindowController.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/10/2026.
//

import AppKit
import SwiftUI

/// WorkerScreenWindowController shows one worker's screen in an ordinary macOS window, not a
/// picture in picture: the title is the worker's name and the subtitle its task, the toolbar leads
/// with the worker's three-quarter portrait and its status, and ends with Open in Braus.
///
/// One window per worker: opening a worker whose window is open brings that window forward. The
/// window leaves `openWindows` when it closes.
final class WorkerScreenWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let worker: HouseWorker

    /// The open screen windows, by worker.
    private(set) static var openWindows: [HouseWorker.ID: WorkerScreenWindowController] = [:]

    /// Puts a controller's window on screen. Tests replace it, so no window comes in front of the
    /// person's work, and reset it when they end.
    static var present: (WorkerScreenWindowController) -> Void = { $0.showWindow(nil) }

    /// The screen's width when the window opens; the content keeps the screen's 16:10.
    static let contentWidth: CGFloat = 560

    private static let portraitItem = NSToolbarItem.Identifier("worker")
    private static let openItem     = NSToolbarItem.Identifier("openInBraus")

    /// Opens `worker`'s screen window, or brings its open one forward, and returns its controller.
    @discardableResult
    static func open(worker: HouseWorker) -> WorkerScreenWindowController {
        let controller = openWindows[worker.id] ?? WorkerScreenWindowController(worker: worker)
        openWindows[worker.id] = controller
        present(controller)
        return controller
    }

    init(worker: HouseWorker) {
        self.worker = worker
        let size = CGSize(
            width : Self.contentWidth,
            height: Self.contentWidth * 10 / 16
        )
        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size  : size
            ),
            styleMask  : [.titled, .closable, .miniaturizable, .resizable],
            backing    : .buffered,
            defer      : true
        )
        let content = NSHostingView(rootView: MockScreenView(worker: worker))
        content.sizingOptions = []
        window.contentView          = content
        window.title                = worker.name
        window.subtitle             = worker.activity
        window.appearance           = NSAppearance(named: .darkAqua)
        window.toolbarStyle         = .unified
        window.contentAspectRatio   = size
        window.contentMinSize       = CGSize(
            width : 320,
            height: 200
        )
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        let toolbar = NSToolbar(identifier: "WorkerScreen")
        toolbar.delegate    = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.setContentSize(size)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        Self.openWindows[worker.id] = nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.portraitItem, .flexibleSpace, Self.openItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar                     : NSToolbar,
        itemForItemIdentifier itemID  : NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemID)
        switch itemID {
        case Self.portraitItem:
            // Navigational, so the system places it before the title.
            item.view            = NSHostingView(rootView: Portrait(worker: worker))
            item.isNavigational  = true
            item.label           = worker.name
        case Self.openItem:
            item.image           = NSImage(
                systemSymbolName        : "arrow.up.forward.app",
                accessibilityDescription: "Open in Braus"
            )
            item.label           = "Open in Braus"
            item.toolTip         = "Open in Braus"
            item.isBordered      = true
            item.target          = self
            item.action          = #selector(openInBraus)
        default:
            return nil
        }
        return item
    }

    /// Brings Braus's own window forward; the screen window stays open beside it.
    @objc
    private func openInBraus() {
        NSApp.windows
            .first { !($0.windowController is Self) && $0.isVisible && $0.canBecomeMain }?
            .makeKeyAndOrderFront(nil)
    }

    /// Portrait is the toolbar's worker: the rows' three-quarter portrait at toolbar size, with a
    /// dot of its status light at the trailing foot.
    private struct Portrait: View {
        let worker: HouseWorker

        var body: some View {
            HouseWorkerPortrait(
                shape     : worker.shape,
                status    : worker.status,
                seed      : WorkerBehaviour.seed(for: worker.id),
                usesScreen: worker.usesScreen
            )
            .scaleEffect(0.6)
            .frame(
                width : 34,
                height: 28
            )
            .overlay(alignment: .bottomTrailing) {
                if worker.status.light != nil {
                    Circle()
                        .fill(HouseLayout.light(of: worker.status))
                        .frame(
                            width : 7,
                            height: 7
                        )
                        .padding(
                            .trailing,
                            4
                        )
                }
            }
            .accessibilityElement()
            .accessibilityLabel(worker.name)
        }
    }
}
