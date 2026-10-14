//
//  ProbeController.swift
//  WebPopupProbe
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import AppKit
import WebKit

/// ProbeController owns the main window, the one open web surface and the event log.
///
/// Each surface shows the same bundled page; the page posts its events here, where the
/// app state (active, key window) is stamped on before they are written. Main thread only.
final class ProbeController: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler {

    private let log           : ProbeLog
    private let launchSurface : ProbeSurface?
    private let isSelfTest    : Bool

    private var mainWindow    : NSWindow!
    private var anchor        : NSButton!
    private var activeSurface : ProbeSurface?
    private var surfaceWindow : NSWindow?
    private var popover       : NSPopover?

    init(log: ProbeLog, launchSurface: ProbeSurface?, isSelfTest: Bool) {
        self.log           = log
        self.launchSurface = launchSurface
        self.isSelfTest    = isSelfTest
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow = makeMainWindow()
        mainWindow.makeKeyAndOrderFront(nil)
        log.append([
            "type"       : "launch",
            "pid"        : ProcessInfo.processInfo.processIdentifier,
            "open"       : launchSurface?.rawValue ?? NSNull(),
            "selfTest"   : isSelfTest,
            "appActive"  : NSApp.isActive,
        ])
        if launchSurface != nil {
            // A run loop perform, not a dispatch block: runModal nests a loop that never drains the main queue.
            perform(#selector(openLaunchSurface), with: nil, afterDelay: 0)
        }
        if isSelfTest {
            // Common modes, so the watchdog also fires inside runModal.
            let watchdog = Timer(timeInterval: 20, repeats: false) { _ in
                self.log.append(["type": "selfTestTimeout"])
                exit(2)
            }
            RunLoop.main.add(watchdog, forMode: .common)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowWillClose(_ notification: Notification) {
        if activeSurface == .modal { NSApp.stopModal() }
        activeSurface = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard var event = message.body as? [String: Any] else { return }
        event["time"]      = Date().timeIntervalSince1970
        event["appActive"] = NSApp.isActive
        event["keyWindow"] = NSApp.keyWindow?.title ?? NSNull()
        log.append(event)
        if event["type"] as? String == "selfTestDone" { exit(event["scrolled"] as? Bool == true ? 0 : 3) }
    }

    // MARK: Main window

    private func makeMainWindow() -> NSWindow {
        let buttons = ProbeSurface.allCases.enumerated().map { index, surface in
            let button = NSButton(title: surface.buttonTitle, target: self, action: #selector(openFromButton(_:)))
            button.tag = index
            return button
        }
        anchor = buttons[ProbeSurface.allCases.firstIndex(of: .popover)!]

        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.edgeInsets  = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(
            contentRect : NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask   : [.titled, .closable],
            backing     : .buffered,
            defer       : false
        )
        window.title                = "WebPopupProbe"
        window.isReleasedWhenClosed = false
        window.contentView          = stack
        window.center()
        return window
    }

    @objc private func openLaunchSurface() {
        open(launchSurface!)
    }

    @objc private func openFromButton(_ sender: NSButton) {
        open(ProbeSurface.allCases[sender.tag])
    }

    // MARK: Surfaces

    private func open(_ surface: ProbeSurface) {
        closeSurface()
        activeSurface = surface
        if surface == .popover {
            let controller = NSViewController()
            controller.view = makeContent(for: surface)
            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior              = .applicationDefined
            popover.animates              = false
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            self.popover = popover
            return
        }

        let style: NSWindow.StyleMask = [.titled, .closable]
        let window = surface == .panel
            ? NSPanel(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
            : NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.title                = surface.windowTitle
        window.isReleasedWhenClosed = false
        window.delegate             = self
        window.center()
        window.contentView          = makeContent(for: surface)
        surfaceWindow = window

        switch surface {
        case .panel   : window.makeKeyAndOrderFront(nil)
        case .sheet   : mainWindow.beginSheet(window)
        case .modal   : NSApp.runModal(for: window)
        case .popover : break
        }
    }

    @objc private func closeSurface() {
        switch activeSurface {
        case .panel   : surfaceWindow?.close()
        case .sheet   : surfaceWindow.map { mainWindow.endSheet($0) }
        case .modal   : NSApp.stopModal(); surfaceWindow?.orderOut(nil)
        case .popover : popover?.close()
        case nil      : break
        }
        activeSurface = nil
        surfaceWindow = nil
        popover       = nil
    }

    /// Builds the web view over a Close button; Escape triggers the button so a sheet or modal can be dismissed.
    private func makeContent(for surface: ProbeSurface) -> NSView {
        let page = Bundle.main.url(forResource: "probe", withExtension: "html")!
        let content = WKUserContentController()
        content.add(self, name: "probe")
        content.addUserScript(WKUserScript(
            source           : "window.probeSurface = \"\(surface.rawValue)\"; window.probeSelfTest = \(isSelfTest);",
            injectionTime    : .atDocumentStart,
            forMainFrameOnly : true
        ))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        web.widthAnchor.constraint(equalToConstant: 420).isActive  = true
        web.heightAnchor.constraint(equalToConstant: 320).isActive = true

        let close = NSButton(title: "Close", target: self, action: #selector(closeSurface))
        close.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [web, close])
        stack.orientation = .vertical
        stack.spacing     = 8
        stack.edgeInsets  = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return stack
    }
}
