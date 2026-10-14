//
//  WebBrowser.swift
//  Braus
//

import Foundation

/// WebBrowser is one running Chrome driven over its DevTools pipe: it opens and lists pages
/// and shuts Chrome down.
///
/// It owns the process. `close()` ends it; a browser released without `close()` leaves Chrome
/// to exit on its own when its pipe closes.
public final class WebBrowser: Sendable {

    public let connection: CDPConnection

    /// Chrome's product string, such as `HeadlessChrome/155.0.8059.40`.
    public let product: String

    private let process: ChromeProcess

    private init(connection: CDPConnection, product: String, process: ChromeProcess) {
        self.connection = connection
        self.product    = product
        self.process    = process
    }

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

    /// Opens a new tab on `url` and attaches to it. Returns before the page has loaded; use
    /// `WebPage.navigate` to wait for a load.
    public func openPage(url: String = "about:blank") async throws -> WebPage {
        let created = try await connection.send("Target.createTarget", ["url": .string(url)])
        guard let targetID = created["targetId"]?.stringValue else {
            throw CDPError.malformedResult(method: "Target.createTarget", detail: "no targetId")
        }
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

    /// Whether the Chrome process is still running.
    public func isRunning() async -> Bool {
        await process.isRunning()
    }

    /// Asks Chrome to close, then ends the process if it has not within `graceSeconds`.
    /// Returns once the process is gone. Idempotent.
    public func close(graceSeconds: Double = 5) async {
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
