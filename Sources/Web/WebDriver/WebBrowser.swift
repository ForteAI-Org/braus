//
//  WebBrowser.swift
//  Braus
//

import Foundation
import Synchronization

/// WebBrowser is one running Chrome driven over DevTools: it opens and lists pages, and ends what it
/// owns.
///
/// A launched browser owns its process over a pipe: `close()` ends it, and a browser released without
/// `close()` leaves Chrome to exit on its own when its pipe closes. An attached browser is the person's
/// own Chrome, which it never owns: `close()` closes only the tabs it opened and disconnects.
public final class WebBrowser: Sendable {

    public let connection: CDPConnection

    /// Chrome's product string, such as `HeadlessChrome/155.0.8059.40`.
    public let product: String

    /// The process this browser started, nil when it is attached to a Chrome it did not start.
    private let process: ChromeProcess?

    /// The tabs `openPage` opened, the only ones an attached browser closes.
    private let openedTargets = Mutex<[String]>([])

    private init(connection: CDPConnection, product: String, process: ChromeProcess?) {
        self.connection = connection
        self.product    = product
        self.process    = process
    }

    /// Whether this browser started its Chrome and ends it on `close()`; false for the person's own Chrome.
    public var ownsChrome: Bool { process != nil }

    /// Starts Chrome and waits until it answers `Browser.getVersion`.
    ///
    /// Throws `CDPError.launchFailed` when it does not answer within `readySeconds`; the process
    /// is terminated before the error is thrown.
    public static func launch(_ options: ChromeLaunchOptions, readySeconds: Double = 20) async throws -> WebBrowser {
        let process    = try ChromeProcess.spawn(options)
        let connection = await CDPConnection(transport: process.transport)
        do {
            let version = try await connection.send("Browser.getVersion", timeoutSeconds: readySeconds)
            return WebBrowser(
                connection: connection,
                product   : version["product"]?.stringValue ?? "",
                process   : process
            )
        } catch {
            await connection.close()
            await process.terminate()
            throw CDPError.launchFailed("Chrome did not answer: \(error)")
        }
    }

    /// Connects over `transport` to a Chrome this process did not start, and waits until it answers
    /// `Browser.getVersion`. Throws the command's own error when it does not within `readySeconds`; the
    /// connection is closed before the error is thrown, and Chrome is left as it was.
    package static func attached(over transport: any CDPTransporting, readySeconds: Double) async throws -> WebBrowser {
        let connection = await CDPConnection(transport: transport)
        do {
            let version = try await connection.send("Browser.getVersion", timeoutSeconds: readySeconds)
            return WebBrowser(connection: connection, product: version["product"]?.stringValue ?? "", process: nil)
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Opens a new tab on `url` and attaches to it. Returns before the page has loaded; use
    /// `WebPage.navigate` to wait for a load.
    public func openPage(url: String = "about:blank") async throws -> WebPage {
        // In the background, so a visible Chrome's new window never takes the person's focus.
        let created = try await connection.send(
            "Target.createTarget",
            ["url": .string(url), "background": true, "newWindow": true]
        )
        guard let targetID = created["targetId"]?.stringValue else {
            throw CDPError.malformedResult(method: "Target.createTarget", detail: "no targetId")
        }
        openedTargets.withLock { $0.append(targetID) }
        return try await attach(targetID: targetID)
    }

    /// Attaches to an existing page target with a flattened session.
    public func attach(targetID: String) async throws -> WebPage {
        let attached = try await connection.send(
            "Target.attachToTarget",
            ["targetId": .string(targetID), "flatten": true]
        )
        guard let sessionID = attached["sessionId"]?.stringValue else {
            throw CDPError.malformedResult(method: "Target.attachToTarget", detail: "no sessionId")
        }
        return WebPage(connection: connection, targetID: targetID, sessionID: sessionID)
    }

    /// The page targets Chrome has open, in its order.
    public func pageTargets() async throws -> [WebPageTarget] {
        let answer = try await connection.send("Target.getTargets")
        return (answer["targetInfos"]?.arrayValue ?? []).compactMap { info in
            guard info["type"]?.stringValue == "page", let targetID = info["targetId"]?.stringValue else { return nil }
            return WebPageTarget(
                targetID: targetID,
                url     : info["url"]?.stringValue ?? "",
                title   : info["title"]?.stringValue ?? ""
            )
        }
    }

    /// Whether the Chrome process is still running; for an attached browser, whether it is still connected.
    public func isRunning() async -> Bool {
        guard let process else { return !(await connection.isClosed) }
        return await process.isRunning()
    }

    /// Ends what this browser owns. A launched browser asks Chrome to close, then ends the process if it has
    /// not within `graceSeconds`, and returns once the process is gone. An attached browser closes only the
    /// tabs it opened and disconnects: the person's Chrome and every other tab stay as they are. Idempotent.
    public func close(graceSeconds: Double = 5) async {
        guard let process else {
            let opened = openedTargets.withLock { opened in
                defer { opened.removeAll() }
                return opened
            }
            // A tab the person already closed answers an error, which leaves nothing to undo.
            for targetID in opened {
                _ = try? await connection.send("Target.closeTarget", ["targetId": .string(targetID)],
                                               timeoutSeconds: 2)
            }
            await connection.close()
            return
        }
        // A refused or unanswered Browser.close is covered by the termination that follows.
        _ = try? await connection.send("Browser.close", timeoutSeconds: 2)
        await connection.close()
        await process.terminate(graceSeconds: graceSeconds)
    }
}

/// WebPageTarget is one open tab as `Target.getTargets` lists it.
public struct WebPageTarget: Sendable, Hashable {
    public let targetID: String
    public let url     : String
    public let title   : String
}
