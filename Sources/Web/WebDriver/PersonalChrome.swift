//
//  PersonalChrome.swift
//  Braus
//

import Foundation

/// PersonalChrome reaches the person's own Chrome, already running on their everyday profile with its sign-ins,
/// through the remote debugging they turn on themselves at `chrome://inspect/#remote-debugging`.
///
/// Chrome refuses the debugging switches on its default profile, so a Chrome this process starts can never be
/// the person's. Instead their running Chrome writes the port and path of its DevTools WebSocket into
/// `DevToolsActivePort` in its user data directory, and asks the person to allow each connection made to it.
/// Nothing here launches, quits or reconfigures Chrome.
public enum PersonalChrome {

    /// The user data directory of Chrome's stable channel, where the person's profiles live.
    public static var userDataDirectory: URL {
        URL.homeDirectory.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
    }

    /// How long Chrome may take to answer once connected: the person reads Chrome's question and allows it.
    public static let allowSeconds: Double = 60

    /// Connects to the person's Chrome and waits until it answers, which it does once the person allowed the
    /// connection. The browser returned closes only the tabs it opened (`WebBrowser.close`).
    ///
    /// Throws `PersonalChromeError`: no endpoint, nothing listening, a connection refused, or no answer within
    /// `readySeconds`. The connection is closed before it throws.
    public static func connect(
        userDataDirectory: URL    = PersonalChrome.userDataDirectory,
        readySeconds     : Double = PersonalChrome.allowSeconds
    ) async throws -> WebBrowser {
        let endpoint  = try self.endpoint(in: userDataDirectory)
        let transport = WebSocketTransport(url: endpoint)
        do {
            return try await WebBrowser.attached(over: transport, readySeconds: readySeconds)
        } catch CDPError.timedOut(method: _, seconds: let seconds) {
            throw PersonalChromeError.notAllowedInTime(seconds: seconds)
        } catch {
            if let refused = transport.failure as? URLError, refused.code == .cannotConnectToHost {
                throw PersonalChromeError.unreachable
            }
            throw PersonalChromeError.refused
        }
    }

    /// The DevTools WebSocket the Chrome on `userDataDirectory` listens on, from its `DevToolsActivePort`.
    ///
    /// Throws `PersonalChromeError.remoteDebuggingOff` when the file is missing or does not name a loopback
    /// endpoint: Chrome writes it only while remote debugging is on.
    public static func endpoint(in userDataDirectory: URL) throws -> URL {
        let file = userDataDirectory.appending(path: "DevToolsActivePort", directoryHint: .notDirectory)
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let endpoint = endpoint(parsing: contents)
        else { throw PersonalChromeError.remoteDebuggingOff }
        return endpoint
    }

    /// The loopback WebSocket a `DevToolsActivePort` names, or nil when it does not: a port from 1 to 65535 on
    /// its first line and an absolute path on its second.
    static func endpoint(parsing contents: String) -> URL? {
        let lines = contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let port = Int(lines[0]), (1...65535).contains(port) else { return nil }
        let path = lines[1]
        guard path.hasPrefix("/"), !path.contains(where: \.isWhitespace) else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)\(path)")
    }
}

/// PersonalChromeError says why the person's Chrome could not be reached; in every case nothing was opened in it.
public enum PersonalChromeError: Error, Sendable, Equatable {

    /// No `DevToolsActivePort` names an endpoint: Chrome is not running with remote debugging turned on.
    case remoteDebuggingOff

    /// The endpoint named answers nothing: Chrome quit, or turned remote debugging off, since it wrote the port.
    case unreachable

    /// Chrome closed the connection before answering: the person did not allow it.
    case refused

    /// Chrome did not answer within the wait: the person has not allowed the connection yet.
    case notAllowedInTime(seconds: Double)
}
