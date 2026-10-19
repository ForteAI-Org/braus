import EngineCore
import Foundation
import LocalMCP
import SQLite3

/// SentMessage is one message this Mac sent, as Messages' own history records it.
public struct SentMessage: Sendable, Equatable {
    /// The history's own id for it, which no other message has.
    public let id      : String
    /// The handle it went to: a phone number in international form or an email address.
    public let handle  : String
    /// The text, nil when the history keeps it only in its rich form.
    public let text    : String?
    public let date    : Date
    /// Whether Messages recorded an error for it.
    public let failed  : Bool

    public init(id: String, handle: String, text: String?, date: Date, failed: Bool = false) {
        self.id     = id
        self.handle = handle
        self.text   = text
        self.date   = date
        self.failed = failed
    }
}

extension MessagesTransporting {
    public func requestPermission() async -> AdapterAvailability { await availability() }
}

/// MessagesTransporting is the Messages app as the Messages adapter reaches it. The live one is
/// `MacMessagesTransport`; tests use an in-memory one.
public protocol MessagesTransporting: Sendable {
    func availability() async -> AdapterAvailability
    /// Asks the person for Automation over Messages, prompting when they have not answered yet.
    func requestPermission() async -> AdapterAvailability
    /// Sends `text` over iMessage to a phone number or an email address.
    func send(_ text: String, to handle: String) async throws
    /// The messages sent since `since`, newest first; nil when the history cannot be read (it needs
    /// Full Disk Access).
    func sent(since: Date) async throws -> [SentMessage]?
}

/// MessagesAdapter sends an iMessage through Messages' dictionary (one fixed script), with Messages
/// hidden. The dictionary has no history, so the read-back is Messages' own database when Braus may
/// read it (Full Disk Access); without it, read before the send, nothing is sent (R07).
///
/// Reading a conversation stays on the scene. The handle must be a phone number or an address read
/// from Contacts: a name is refused, so the message never goes to a guess.
public struct MessagesAdapter: AppAdapting {

    public let name       = "messages"
    public let appNames   = ["Messages", "Messaggi", "iMessage"]
    public let bundleIDs: Set<String> = ["com.apple.MobileSMS"]

    private let transport    : any MessagesTransporting
    private let readBackTries: Int
    private let readBackPause: Duration

    public init(transport: any MessagesTransporting, readBackTries: Int = 8, readBackPause: Duration = .seconds(1)) {
        self.transport     = transport
        self.readBackTries = readBackTries
        self.readBackPause = readBackPause
    }

    public var verbs: [AdapterVerb] {
        [
            AdapterVerb("send_message", "Send an iMessage to a phone number or an email address.",
                        parameters: [
                            AdapterParameter("to", .string, "a phone number with its country code, or an email address "
                                             + "(read it with contacts)"),
                            AdapterParameter("text", .string, "the message"),
                        ],
                        safety: .irreversible,
                        readBack: "Messages' history by handle and time, when Braus has Full Disk Access",
                        confirms: .readBack),
        ]
    }

    public func availability() async -> AdapterAvailability {
        await transport.availability()
    }

    public func requestPermission() async -> AdapterAvailability {
        await transport.requestPermission()
    }

    public func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        let arguments = AdapterArguments(arguments)
        guard verb == "send_message" else { throw AdapterFailure("messages has no verb \(verb).") }
        let handle = try arguments.required("to").trimmingCharacters(in: .whitespacesAndNewlines)
        let text   = try arguments.required("text")
        guard let wanted = Self.normalized(handle) else {
            return .refused("\(handle) is not a phone number or an email address. Read it from contacts.find_contacts first.")
        }
        let since  = Date().addingTimeInterval(-2)
        // What the history already holds in the window is never taken for this send (A06). Without it read, no message
        // of the window could be told from one sent just before, so the send could never be confirmed: under the
        // read-back contract it is refused, before anything is sent (R07). Nothing asks for the permission.
        let before: Set<String>
        do {
            guard let rows = try await transport.sent(since: since) else {
                return .refused("Messages' history cannot be read, so a message sent now could not be confirmed: "
                                + "nothing was sent. Braus reads it back with Full Disk Access, which the person can "
                                + "allow in System Settings > Privacy & Security.")
            }
            before = Set(rows.map(\.id))
        } catch {
            return .refused("Messages' history could not be read before the send, so a message sent now could not be "
                            + "confirmed: nothing was sent. Try again in a moment.")
        }
        let result: JSONValue = .object(["to": .string(handle)])
        do {
            try await transport.send(text, to: handle)
        } catch let needed as AutomationPermissionNeeded where needed.beforeAnyEvent {
            // Refused before any event reached Messages: nothing was sent.
            return .refused(needed.reason)
        } catch {
            return .mayHaveHappened("Messages was asked to send the message to \(handle)", because: error,
                                    look: "Look at the chat", result: result)
        }
        // What became of the message, kept in the answer apart from the outcome (A06): `failed` when Messages
        // recorded it as not delivered, `unknown` when nothing says. Nothing here sends it again.
        let unknown: JSONValue = .object(["to": .string(handle), "delivery": .string("unknown")])
        return await .afterChange("Messages took the message for \(handle)", look: "Look at the chat",
                                  result: unknown) {
            for attempt in 0..<readBackTries {
                if attempt > 0 { try await Task.sleep(for: readBackPause) }
                // Read before the send, the history may still become unreadable after it: the message went.
                guard let sent = try await transport.sent(since: since) else {
                    return AdapterOutcome(.actedUnverified,
                                          "Messages took the message for \(handle), but its history could no longer be "
                                          + "read to confirm it. Look at the chat before sending again.",
                                          result: unknown)
                }
                // The new messages of the window to the number asked for, by its whole identity (`matches`).
                let toIt = sent.filter { !before.contains($0.id) && Self.matches($0.handle, asked: handle) }
                // A number given without its prefix, where the history writes one ending in its digits with a
                // prefix: said as such, never matched.
                if toIt.isEmpty, Self.lacksCountryPrefix(handle), sent.contains(where: {
                    Self.international($0.handle)?.hasSuffix(handle.filter(\.isNumber)) == true
                }) {
                    return AdapterOutcome(.actedUnverified, "Messages took the message for \(handle), but its "
                                          + "history writes numbers with their country prefix, and a number given "
                                          + "without one is not compared with them: which country it is would be a "
                                          + "guess. Look at the chat before sending again, and give the number with "
                                          + "its prefix next time.", result: unknown)
                }
                func found(_ message: SentMessage, _ delivery: String) -> JSONValue {
                    .object(["to": .string(message.handle), "sent_at": .string(AdapterArguments.text(message.date)),
                             "delivery": .string(delivery)])
                }
                if let match = toIt.first(where: { $0.text == text }) {
                    if match.failed {
                        return AdapterOutcome(.actedUnverified,
                                              "Messages recorded the message to \(handle) as not delivered. It was "
                                              + "sent once and is not sent again; sending it again would be a new "
                                              + "message.",
                                              result: found(match, "failed"))
                    }
                    return .confirmed("Sent to \(handle); it is in Messages' history.", found(match, "sent"))
                }
                // A message whose text the history does not give is not this one, as far as anyone can tell.
                if let unread = toIt.first(where: { $0.text == nil }) {
                    return AdapterOutcome(.actedUnverified, "Messages took the message for \(handle); its history "
                                          + "shows a message to that number but not its text, so it is not confirmed. "
                                          + "Look at the chat before sending again.", result: found(unread, "unknown"))
                }
            }
            return AdapterOutcome(.actedUnverified, "Messages took the message for \(handle), but its history does not "
                                  + "show it yet. Look at the chat before sending again.", result: unknown)
        }
    }

    /// Whether `handle`, as Messages' history writes it, is the one asked for (`asked`), by its whole identity: an
    /// email address by its lower case; a phone number by all its digits, a leading `00` read as the `+` it stands for.
    /// A number given without its country prefix is never matched with one the history writes with it: which country
    /// it is would be a guess, and a shared ending does not say which number received the message (A05).
    public static func matches(_ handle: String, asked: String) -> Bool {
        let asked  = asked.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if asked.contains("@") || handle.contains("@") {
            return handle.lowercased() == asked.lowercased()
        }
        guard let wanted = international(asked), let found = international(handle) else {
            // Neither written with a prefix: the same digits as both were written. One with a prefix and one without
            // is no match.
            let digits = asked.filter(\.isNumber)
            return lacksCountryPrefix(asked) && lacksCountryPrefix(handle) && digits.count >= 6
                && digits == handle.filter(\.isNumber)
        }
        return wanted == found
    }

    /// Whether a phone number is given without its country prefix, neither `+` nor `00`.
    static func lacksCountryPrefix(_ number: String) -> Bool {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.hasPrefix("+") && !trimmed.filter(\.isNumber).hasPrefix("00")
    }

    /// The digits of a number given with its country prefix, `00` dropped; nil without one or with fewer than six
    /// digits.
    static func international(_ number: String) -> String? {
        guard !lacksCountryPrefix(number) else { return nil }
        var digits = number.filter(\.isNumber)
        if !number.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+"), digits.hasPrefix("00") {
            digits.removeFirst(2)
        }
        return digits.count >= 6 ? digits : nil
    }

    /// A handle as it is checked before a send: an email address in lower case, or a phone number's digits (at least
    /// six) with the last nine kept. Nil for a name. The history is compared by `matches`, not by this.
    public static func normalized(_ handle: String) -> String? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return MailAdapter.isAddress(trimmed) ? trimmed.lowercased() : nil }
        guard trimmed.allSatisfy({ $0.isNumber || " +-().".contains($0) }) else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard digits.count >= 6 else { return nil }
        return String(digits.suffix(9))
    }
}

/// MacMessagesTransport sends through Messages' dictionary and reads back from `chat.db`, read-only.
public struct MacMessagesTransport: MessagesTransporting {

    static let bundleID = "com.apple.MobileSMS"

    private let database: URL

    public init(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db")) {
        self.database = database
    }

    public func availability() async -> AdapterAvailability {
        AppleScriptRunner.availability(bundleID: Self.bundleID, app: "Messages")
    }

    public func requestPermission() async -> AdapterAvailability {
        await AppleScriptRunner.requestPermission(bundleID: Self.bundleID, app: "Messages")
    }

    public func send(_ text: String, to handle: String) async throws {
        _ = try await AppleScriptRunner.run(Self.script, handler: "send_message", [.text(handle), .text(text)],
                                            bundleID: Self.bundleID, app: "Messages")
    }

    public func sent(since: Date) async throws -> [SentMessage]? {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        let query = """
            SELECT message.ROWID, handle.id, message.text, message.date, message.error FROM message
            JOIN handle ON handle.ROWID = message.handle_id
            WHERE message.is_from_me = 1 AND message.date >= ? ORDER BY message.date DESC LIMIT 20
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // An unreadable file (no Full Disk Access) opens and fails here.
        guard sqlite3_prepare_v2(connection, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        // The history counts nanoseconds since 2001.
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSinceReferenceDate * 1_000_000_000))
        var rows: [SentMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id     = String(sqlite3_column_int64(statement, 0))
            let handle = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let text   = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let nanoseconds = Double(sqlite3_column_int64(statement, 3))
            let date   = Date(timeIntervalSinceReferenceDate: nanoseconds / 1_000_000_000)
            rows.append(SentMessage(id: id, handle: handle, text: text, date: date,
                                    failed: sqlite3_column_int(statement, 4) != 0))
        }
        return rows
    }

    /// The only script this transport runs; the handle and the text come in as parameters. Its Apple
    /// events are bounded to 15 seconds.
    static let script = """
        on send_message(addr, textBody)
            with timeout of 15 seconds
                tell application id "com.apple.MobileSMS"
                    set targetService to 1st account whose service type = iMessage
                    set someone to participant addr of targetService
                    send textBody to someone
                end tell
                return true
            end timeout
        end send_message
        """
}
