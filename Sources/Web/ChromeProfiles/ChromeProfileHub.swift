//
//  ChromeProfileHub.swift
//  Braus
//

import Foundation
import Synchronization
import WebDriver

/// ChromeProfileHub is where the Braus extension reaches Braus: a Unix socket in `directory` (0700), to which
/// the extension's native host connects once for each extension instance, that is for each Chrome profile the
/// extension runs in. It keeps:
/// - the paired profiles, each instance's random ID and the name the person confirmed for it on the instance's
///   own page (`paired-profiles.json` in `directory`, so a choice survives a relaunch);
/// - which instances are connected now;
/// - which transport owns each tab Braus opened, so an answer or an event reaches that transport only.
///
/// A web session uses a paired profile through `connect`, which refuses an unknown, unpaired, revoked or
/// disconnected instance before anything is sent: there is no fallback to another profile, to Braus's own
/// Chrome or to the desktop. Nothing here reads cookies, passwords or the keychain, attests a Chrome profile
/// directory, or discovers the profiles Chrome has installed.
public final class ChromeProfileHub: Sendable {

    public let directory: URL

    private struct TabKey: Hashable {
        let instanceID: String
        let tab       : Int
    }

    private struct State {
        var listener  : Int32 = -1
        var labels    : [String: String] = [:]
        var links     : [String: ExtensionLink] = [:]
        var transports: [ObjectIdentifier: ExtensionTransport] = [:]
        var requests  : [String: ExtensionTransport] = [:]
        var tabs      : [TabKey: ExtensionTransport] = [:]
        /// Counts the changes of `labels`, so their writes keep the order of the changes.
        var generation = 0
    }

    private let paired : PairedProfiles
    private let state  : Mutex<State>
    private let observers = Mutex<[@Sendable () -> Void]>([])
    /// The generation of the pairings last written to `paired`.
    private let written = Mutex(0)

    public init(directory: URL) {
        self.directory = directory
        paired = PairedProfiles(file: directory.appending(path: "paired-profiles.json", directoryHint: .notDirectory))
        state  = Mutex(State(labels: paired.load()))
    }

    /// The socket the native host connects to.
    public var socketPath: String {
        directory.appending(path: "hub.sock", directoryHint: .notDirectory).path(percentEncoded: false)
    }

    /// Calls `handler` after every change of the profiles or their connection, from any thread, with every other
    /// handler added: one for each window that shows the profiles.
    public func observe(_ handler: @escaping @Sendable () -> Void) {
        observers.withLock { $0.append(handler) }
    }

    /// Starts listening: makes `directory` private (0700), replaces a stale socket, and accepts the host's
    /// connections on a thread of its own. Throws when the socket cannot be made.
    public func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = socketPath
        guard path.utf8.count < 104 else { throw ChromeProfileError.notRunning }
        unlink(path)
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ChromeProfileError.notRunning }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0, chmod(path, 0o600) == 0 else {
            Darwin.close(listener)
            throw ChromeProfileError.notRunning
        }
        state.withLock { $0.listener = listener }
        let thread = Thread { [self] in
            // A blocked accept may not wake when the socket closes: wait in short polls, and end once `stop` ran.
            while true {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                let count = poll(&ready, 1, 250)
                if state.withLock({ $0.listener }) != listener { break }
                guard count > 0 else { continue }
                let descriptor = accept(listener, nil, nil)
                if descriptor < 0 { continue }
                _ = ExtensionLink(descriptor: descriptor,
                                  receive: { [self] link, message in receive(message, from: link) },
                                  ended: { [self] link in ended(link) })
            }
        }
        thread.name = "dev.forte.braus.chrome-profiles.accept"
        thread.start()
    }

    /// Stops listening and closes every link; their transports end as disconnected. Idempotent.
    public func stop() {
        let (listener, links) = state.withLock { state in
            defer { state.listener = -1 }
            return (state.listener, Array(state.links.values))
        }
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
            unlink(socketPath)
        }
        for link in links { link.close() }
    }

    /// The paired profiles, by name, each with whether its instance is connected now.
    public var profiles: [ChromeProfile] {
        state.withLock { state in
            state.labels.map { id, label in
                ChromeProfile(instanceID: id, label: label, isConnected: state.links[id] != nil)
            }
        }
        .sorted { ($0.label, $0.instanceID) < ($1.label, $1.instanceID) }
    }

    /// A browser on the paired profile `instanceID`: a tab Braus opens there is driven through that instance
    /// alone, and closing it closes only what it opened. Every new command and tab passes `gate`, which the caller
    /// closes when it may no longer act there. Throws `ChromeProfileError` before anything is sent when the profile
    /// is unknown, unpaired, revoked or disconnected, or the hub is not listening.
    public func connect(_ instanceID: String, gate: CommandGate = CommandGate(),
                        readySeconds: Double = 10) async throws -> WebBrowser {
        try await WebBrowser.attached(over: try transport(for: instanceID, gate: gate), readySeconds: readySeconds)
    }

    /// A transport on the paired profile `instanceID`'s current link, registered with the hub; `connect`'s refusals.
    func transport(for instanceID: String, gate: CommandGate = CommandGate()) throws -> ExtensionTransport {
        let (link, label) = try state.withLock { state -> (ExtensionLink, String) in
            guard state.listener >= 0 else { throw ChromeProfileError.notRunning }
            guard let label = state.labels[instanceID] else { throw ChromeProfileError.unknown(instanceID: instanceID) }
            guard let link = state.links[instanceID] else { throw ChromeProfileError.disconnected(label: label) }
            return (link, label)
        }
        let transport = ExtensionTransport(hub: self, link: link, instanceID: instanceID, label: label, gate: gate)
        state.withLock { $0.transports[ObjectIdentifier(transport)] = transport }
        return transport
    }

    // MARK: From the extension

    private func receive(_ message: JSONValue, from link: ExtensionLink) {
        guard let kind = message["type"]?.stringValue else { return }
        switch kind {
            case "hello":
                guard let id = message["instanceId"]?.stringValue, !id.isEmpty else { return }
                link.instanceID.withLock { $0 = id }
                let replaced = state.withLock { state -> ExtensionLink? in
                    defer { state.links[id] = link }
                    return state.links[id]
                }
                if let replaced, replaced !== link { replaced.close() }
                // The instance's own word on its pairing wins: one it no longer holds was revoked meanwhile.
                if message["paired"]?.boolValue == true, let label = message["label"]?.stringValue, !label.isEmpty {
                    setLabel(label, for: id)
                } else {
                    revoke(id)
                }
                notify()
            case "paired":
                guard let id = link.instanceID.withLock({ $0 }), let label = message["label"]?.stringValue,
                      !label.isEmpty else { return }
                setLabel(label, for: id)
                notify()
            case "revoked":
                guard let id = link.instanceID.withLock({ $0 }) else { return }
                revoke(id)
                notify()
            case "result":
                // Only from the link the request went out on, while it is still its instance's current one: an answer
                // from another instance or a replaced link is dropped, and the legitimate request stays waiting.
                guard let id = link.instanceID.withLock({ $0 }), let request = message["requestId"]?.stringValue else {
                    return
                }
                let transport = state.withLock { state -> ExtensionTransport? in
                    guard state.links[id] === link, let owner = state.requests[request], owner.link === link else {
                        return nil
                    }
                    state.requests[request] = nil
                    return owner
                }
                transport?.receive(message)
            default:
                // A DevTools answer or event, a tab gone, a popup: only from the current link of the tab's owner.
                guard let id = link.instanceID.withLock({ $0 }), let tab = message["tabId"]?.intValue else { return }
                let owner = message["type"]?.stringValue == "popup" ? message["openerTabId"]?.intValue ?? tab : tab
                let transport = state.withLock { state -> ExtensionTransport? in
                    guard state.links[id] === link, let transport = state.tabs[TabKey(instanceID: id, tab: owner)],
                          transport.link === link else { return nil }
                    return transport
                }
                transport?.receive(message)
        }
    }

    /// A link ended (the host closed, or a newer link of the same instance replaced it): every transport on it
    /// ends, so what it had sent stays uncertain, and the instance is disconnected unless a newer link holds it.
    private func ended(_ link: ExtensionLink) {
        let id = link.instanceID.withLock { $0 }
        let ending = state.withLock { state -> [ExtensionTransport] in
            if let id, state.links[id] === link { state.links[id] = nil }
            return state.transports.values.filter { $0.link === link }
        }
        for transport in ending { transport.end() }
        notify()
    }

    private func setLabel(_ label: String, for id: String) {
        let (labels, generation) = state.withLock { state -> ([String: String], Int) in
            state.labels[id] = label
            state.generation += 1
            return (state.labels, state.generation)
        }
        persist(labels, generation: generation)
    }

    /// Forgets the pairing and ends the transports on it: whatever they had sent stays uncertain.
    private func revoke(_ id: String) {
        let (snapshot, ending) = state.withLock { state -> (([String: String], Int)?, [ExtensionTransport]) in
            let ending = state.transports.values.filter { $0.instanceID == id }
            guard state.labels.removeValue(forKey: id) != nil else { return (nil, ending) }
            state.generation += 1
            return ((state.labels, state.generation), ending)
        }
        if let (labels, generation) = snapshot { persist(labels, generation: generation) }
        for transport in ending { transport.end() }
    }

    /// Writes the pairings of `generation` unless a later generation was written already: two changes made on
    /// different links, whose writes cross, never leave the file older than the hub, so no revoked pairing comes
    /// back and no confirmed one is lost at the next launch.
    func persist(_ labels: [String: String], generation: Int) {
        written.withLock { last in
            guard generation > last else { return }
            paired.save(labels)
            last = generation
        }
    }

    private func notify() {
        for handler in observers.withLock({ $0 }) { handler() }
    }

    // MARK: For the transports

    func track(request: String, for transport: ExtensionTransport) {
        state.withLock { $0.requests[request] = transport }
    }

    func track(tab: Int, for transport: ExtensionTransport) {
        state.withLock { $0.tabs[TabKey(instanceID: transport.instanceID, tab: tab)] = transport }
    }

    func untrack(tab: Int, of transport: ExtensionTransport) {
        state.withLock { state in
            let key = TabKey(instanceID: transport.instanceID, tab: tab)
            if state.tabs[key] === transport { state.tabs[key] = nil }
        }
    }

    func unregister(_ transport: ExtensionTransport) {
        state.withLock { state in
            state.transports[ObjectIdentifier(transport)] = nil
            state.requests = state.requests.filter { $0.value !== transport }
            state.tabs = state.tabs.filter { $0.value !== transport }
        }
    }
}
