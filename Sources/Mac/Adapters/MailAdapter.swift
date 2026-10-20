import EngineCore
import Foundation
import LocalMCP

/// MailMessage is one message as Mail's dictionary gives it. `id` is its Message-ID header, which
/// names it in every mailbox and account.
public struct MailMessage: Sendable, Equatable {
    public let id        : String
    public let subject   : String
    public let sender    : String
    public let date      : Date?
    public let isRead    : Bool
    /// The To addresses; filled by `message(id:)` and `sent(subject:since:)`.
    public let recipients: [String]
    /// The plain text; filled by `message(id:)` and `drafts(subject:)`.
    public let content   : String?

    public init(id: String, subject: String, sender: String, date: Date?, isRead: Bool = true,
                recipients: [String] = [], content: String? = nil) {
        self.id         = id
        self.subject    = subject
        self.sender     = sender
        self.date       = date
        self.isRead     = isRead
        self.recipients = recipients
        self.content    = content
    }
}

extension MailTransporting {
    public func requestPermission() async -> AdapterAvailability { await availability() }
}

/// MailTransporting is Mail as the Mail adapter reaches it. The live one is `MacMailTransport`;
/// tests use an in-memory one. A transport that would prompt for Automation throws
/// `AutomationPermissionNeeded`.
public protocol MailTransporting: Sendable {
    func availability() async -> AdapterAvailability
    /// Asks the person for Automation over Mail, prompting when they have not answered yet.
    func requestPermission() async -> AdapterAvailability
    /// The inbox's messages matching `query` in subject or sender, newest first.
    func messages(matching query: String?, unreadOnly: Bool, limit: Int) async throws -> [MailMessage]
    /// One message of the inbox or the sent mailbox, with its text.
    func message(id: String) async throws -> MailMessage?
    /// Sends a new message, from the account whose address is `sender`, or Mail's default account without one.
    func send(to address: String, subject: String, body: String, from sender: String?) async throws
    /// Saves a new message in the drafts mailbox without sending it, from `sender` as `send` does.
    func saveDraft(to address: String?, subject: String, body: String, from sender: String?) async throws
    /// The drafts mailbox's messages with this subject, with their text.
    func drafts(subject: String) async throws -> [MailMessage]
    /// The sent mailbox's messages with this subject sent at or after `since`.
    func sent(subject: String, since: Date) async throws -> [MailMessage]
}

/// MailAdapter is the Mail app through its dictionary (fixed scripts), with Mail hidden: the inbox
/// searched and read, and a mail sent from the default account or the one named, read back in the
/// sent mailbox as the one new message of its subject to its recipient, from its account, with its
/// text (measured on 14 Oct: that read-back confirmed what the scene could not).
///
/// Not here: replies and attachments; Braus's own mail route is the web mail, and this
/// adapter serves an assistant whose person reads mail in Mail.
public struct MailAdapter: AppAdapting {

    public let name       = "mail"
    public let appNames   = ["Mail", "Apple Mail", "Posta"]
    public let bundleIDs: Set<String> = ["com.apple.mail"]

    /// The most messages one find answers.
    static let maximumMessages = 50
    /// The longest text `read_message` answers, in characters.
    static let maximumContent = 20_000
    /// The fields of a message that are a person's words or addresses; its id, date and read state stay recorded.
    static let contentResults = ["subject", "sender", "to", "text"]

    private let transport   : any MailTransporting
    /// How many times, and how far apart, `send` looks for the mail in the sent mailbox.
    private let readBackTries: Int
    private let readBackPause: Duration

    public init(transport: any MailTransporting, readBackTries: Int = 10, readBackPause: Duration = .seconds(1)) {
        self.transport     = transport
        self.readBackTries = readBackTries
        self.readBackPause = readBackPause
    }

    public var verbs: [AdapterVerb] {
        [
            AdapterVerb("find_messages", "Find messages in the inbox, newest first, by words of the subject or sender.",
                        parameters: [
                            AdapterParameter("query", .string, "text the subject or the sender contains", required: false,
                                             confidential: .sensitiveMetadata),
                            AdapterParameter("unread_only", .boolean, "true for unread messages only", required: false),
                            AdapterParameter("limit", .integer, "at most this many; default 10", required: false,
                                             range: 1...Double(Self.maximumMessages)),
                        ],
                        safety: .read, readBack: "Mail's inbox", contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("read_message", "Read one message: sender, recipients, date and text.",
                        parameters: [AdapterParameter("id", .string, "the message's id from find_messages")],
                        safety: .read, readBack: "the inbox or the sent mailbox by Message-ID",
                        contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("create_draft", "Save a new mail in the drafts mailbox without sending it.",
                        parameters: [
                            AdapterParameter("to", .string, "the recipient's email address", required: false,
                                             confidential: .sensitiveMetadata),
                            AdapterParameter("subject", .string, "the subject", confidential: .content),
                            AdapterParameter("body", .string, "the plain text", confidential: .content),
                            AdapterParameter("from", .string, "the address of the account to write from; Mail's "
                                             + "default account without one", required: false, confidential: .sensitiveMetadata),
                        ],
                        safety: .write,
                        readBack: "the new draft in the drafts mailbox, by recipient, account and text",
                        contentResults: Self.contentResults, results: .identifiersAndDates, account: "from"),
            AdapterVerb("send", "Send a mail to one address, from Mail's default account or the one named.",
                        parameters: [
                            AdapterParameter("to", .string, "the recipient's email address (read it with contacts)",
                                             confidential: .sensitiveMetadata),
                            AdapterParameter("subject", .string, "the subject", confidential: .content),
                            AdapterParameter("body", .string, "the plain text", confidential: .content),
                            AdapterParameter("from", .string, "the address of the account to send from; Mail's "
                                             + "default account without one", required: false, confidential: .sensitiveMetadata),
                        ],
                        safety: .irreversible,
                        readBack: "the new message in the sent mailbox, by recipient, account and text",
                        confirms: .readBack, contentResults: Self.contentResults, results: .identifiersAndDates, account: "from"),
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
        do {
            switch verb {
                case "find_messages":
                    let query  = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let unread = arguments.bool("unread_only") ?? false
                    let limit  = arguments.number("limit").map { Int($0) } ?? 10
                    let found  = try await transport.messages(matching: query?.isEmpty == false ? query : nil,
                                                              unreadOnly: unread, limit: limit)
                    let sorted = found.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(limit)
                    return .confirmed("\(sorted.count) \(unread ? "unread " : "")message\(sorted.count == 1 ? "" : "s").",
                                      .object(["messages": .array(sorted.map { Self.json($0) })]))
                case "read_message":
                    let id = try arguments.required("id")
                    guard let message = try await transport.message(id: id) else {
                        return .missing("No message \(id) in the inbox or the sent mailbox.")
                    }
                    return .confirmed("From \(message.sender): \(message.subject).", Self.json(message))
                case "create_draft":
                    return try await draft(to: arguments.string("to"), subject: try arguments.required("subject"),
                                           body: try arguments.required("body"), from: arguments.string("from"))
                case "send":
                    return try await send(to: try arguments.required("to"), subject: try arguments.required("subject"),
                                          body: try arguments.required("body"), from: arguments.string("from"))
                default:
                    throw AdapterFailure("mail has no verb \(verb).")
            }
        } catch let needed as AutomationPermissionNeeded {
            return .refused(needed.reason)
        }
    }

    private func send(to address: String, subject: String, body: String, from sender: String?) async throws
        -> AdapterOutcome {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAddress(address) else {
            return .refused("\(address) is not an email address. Read it from contacts.find_contacts first.")
        }
        let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sender, !Self.isAddress(sender) {
            return .refused("\(sender) is not the address of an account. Give the account's email address.")
        }
        // Mail stamps the date sent in whole seconds, so the window opens a little before the call. What the sent
        // mailbox already holds under this subject is never taken for this send (A03).
        let since  = Date().addingTimeInterval(-5)
        let before = Set(try await transport.sent(subject: subject, since: since).map(\.id))
        let result: JSONValue = .object(["to": .string(address), "subject": .string(subject)])
        do {
            try await transport.send(to: address, subject: subject, body: body, from: sender)
        } catch let needed as AutomationPermissionNeeded where needed.beforeAnyEvent {
            // Refused before any event reached Mail: nothing was handed over.
            return .refused(needed.reason)
        } catch {
            return .mayHaveHappened("Mail was asked to send the message to \(address)", because: error,
                                    look: "Read the sent mailbox", result: result)
        }
        return await .afterChange("Mail took the message for \(address)", look: "Read the sent mailbox",
                                  result: result) {
            for attempt in 0..<readBackTries {
                if attempt > 0 { try await Task.sleep(for: readBackPause) }
                let new = try await transport.sent(subject: subject, since: since).filter {
                    !before.contains($0.id) && Self.addressed($0, to: address)
                }
                guard !new.isEmpty else { continue }
                guard new.count == 1, let mail = new.first else {
                    return AdapterOutcome(.actedUnverified, "Mail took the message for \(address), but \(new.count) "
                                          + "new messages of that subject went to that address: which one is this is "
                                          + "not known. Read the sent mailbox before sending again.", result: result)
                }
                if let sender, !Self.from(mail, sender) {
                    return AdapterOutcome(.actedUnverified, "Mail sent the message to \(address), but from "
                                          + "\(mail.sender), not the account asked for. Read the sent mailbox before "
                                          + "sending again.", result: Self.json(mail))
                }
                // Its text: a signature may follow, the text asked for is in it. A text Mail does not give confirms
                // nothing.
                guard let content = try await transport.message(id: mail.id)?.content else {
                    return AdapterOutcome(.actedUnverified, "Mail sent a message of that subject to \(address), but "
                                          + "its text could not be read back. Read the sent mailbox before sending "
                                          + "again.", result: Self.json(mail))
                }
                guard Self.holds(content, body) else {
                    return AdapterOutcome(.actedUnverified, "Mail sent a message of that subject to \(address), but "
                                          + "its text is not the one asked for. Read the sent mailbox before sending "
                                          + "again.", result: Self.json(mail))
                }
                return .confirmed("Sent to \(address); it is in the sent mailbox.", Self.json(mail))
            }
            return AdapterOutcome(.actedUnverified,
                                  "Mail took the message for \(address), but it is not in the sent mailbox yet. "
                                  + "Read the sent mailbox before sending again.", result: result)
        }
    }

    private func draft(to address: String?, subject: String, body: String, from sender: String?) async throws
        -> AdapterOutcome {
        let address = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address, !Self.isAddress(address) {
            return .refused("\(address) is not an email address. Read it from contacts.find_contacts first.")
        }
        let sender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sender, !Self.isAddress(sender) {
            return .refused("\(sender) is not the address of an account. Give the account's email address.")
        }
        // The drafts already there under this subject are never taken for this one (A04).
        let before = Set(try await transport.drafts(subject: subject).map(\.id))
        let result: JSONValue = .object(["subject": .string(subject)])
        do {
            try await transport.saveDraft(to: address, subject: subject, body: body, from: sender)
        } catch let needed as AutomationPermissionNeeded where needed.beforeAnyEvent {
            return .refused(needed.reason)
        } catch {
            return .mayHaveHappened("Mail was asked to save the draft", because: error, look: "Read the drafts mailbox",
                                    result: result)
        }
        return await .afterChange("Mail took the draft", look: "Read the drafts mailbox", result: result) {
            for attempt in 0..<readBackTries {
                if attempt > 0 { try await Task.sleep(for: readBackPause) }
                let new = try await transport.drafts(subject: subject).filter { !before.contains($0.id) }
                guard !new.isEmpty else { continue }
                // The new draft as asked for: to its recipient and from its account, the only one.
                let asked = new.filter { draft in
                    (address.map { Self.addressed(draft, to: $0) } ?? true)
                        && (sender.map { Self.from(draft, $0) } ?? true)
                }
                guard asked.count == 1, let saved = asked.first, new.count == 1 else {
                    return AdapterOutcome(.actedUnverified, "Mail took the draft, but the drafts mailbox holds "
                                          + "\(new.count) new drafts of that subject, \(asked.count) as asked for: "
                                          + "which one is this is not known. Read the drafts mailbox before saving "
                                          + "again.", result: result)
                }
                // Its text, as for a send: one Mail does not give, or another, confirms nothing.
                guard let content = saved.content, Self.holds(content, body) else {
                    let why = saved.content == nil ? "could not be read back" : "is not the one asked for"
                    return AdapterOutcome(.actedUnverified, "Mail saved a draft of that subject, but its text \(why). "
                                          + "Read the drafts mailbox before saving again.", result: Self.json(saved))
                }
                return .confirmed("The draft is in the drafts mailbox.", Self.json(saved))
            }
            return AdapterOutcome(.actedUnverified, "Mail took the draft, but it is not in the drafts mailbox yet.",
                                  result: result)
        }
    }

    /// Whether `mail` went to `address`.
    static func addressed(_ mail: MailMessage, to address: String) -> Bool {
        mail.recipients.contains { $0.caseInsensitiveCompare(address) == .orderedSame }
    }

    /// Whether `mail` is from the account whose address is `sender`: Mail writes the sender as an address, or as a name
    /// and an address in angle brackets.
    static func from(_ mail: MailMessage, _ sender: String) -> Bool {
        let written = mail.sender.lowercased()
        let wanted  = sender.lowercased()
        return written == wanted || written.hasSuffix("<\(wanted)>")
    }

    /// Whether a message's text holds the text asked for, its spaces and line ends as Mail may rewrite them.
    static func holds(_ content: String, _ body: String) -> Bool {
        func plain(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return plain(content).contains(plain(body))
    }

    /// One `@` with text on both sides and no spaces: enough to refuse a name where an address belongs.
    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(where: \.isWhitespace)
    }

    static func json(_ message: MailMessage) -> JSONValue {
        var object: [String: JSONValue] = [
            "id"     : .string(message.id),
            "subject": .string(message.subject),
            "sender" : .string(message.sender),
            "date"   : message.date.map { .string(AdapterArguments.text($0)) } ?? .null,
            "read"   : .bool(message.isRead),
        ]
        if !message.recipients.isEmpty { object["to"] = .array(message.recipients.map { .string($0) }) }
        if let content = message.content {
            object["text"] = .string(String(content.prefix(maximumContent)))
            if content.count > maximumContent { object["truncated"] = .bool(true) }
        }
        return .object(object)
    }
}

/// MacMailTransport is Mail through one fixed script, its handlers called with Apple event
/// parameters. Mail is started hidden when it is not running.
public struct MacMailTransport: MailTransporting {

    static let bundleID = "com.apple.mail"

    public init() {}

    public func availability() async -> AdapterAvailability {
        AppleScriptRunner.availability(bundleID: Self.bundleID, app: "Mail")
    }

    public func requestPermission() async -> AdapterAvailability {
        await AppleScriptRunner.requestPermission(bundleID: Self.bundleID, app: "Mail")
    }

    public func messages(matching query: String?, unreadOnly: Bool, limit: Int) async throws -> [MailMessage] {
        try await run("find_messages", [.text(query ?? ""), .flag(unreadOnly), .integer(limit)]).list.compactMap(Self.message)
    }

    public func message(id: String) async throws -> MailMessage? {
        Self.message(try await run("read_message", [.text(id)]))
    }

    public func send(to address: String, subject: String, body: String, from sender: String?) async throws {
        _ = try await run("send_mail", [.text(address), .text(subject), .text(body), .text(sender ?? "")])
    }

    public func saveDraft(to address: String?, subject: String, body: String, from sender: String?) async throws {
        _ = try await run("save_draft", [.text(address ?? ""), .text(subject), .text(body), .text(sender ?? "")])
    }

    public func drafts(subject: String) async throws -> [MailMessage] {
        try await run("drafts_with", [.text(subject)]).list.compactMap(Self.message)
    }

    public func sent(subject: String, since: Date) async throws -> [MailMessage] {
        try await run("sent_since", [.text(subject), .date(since)]).list.compactMap(Self.message)
    }

    private func run(_ handler: String, _ arguments: [ScriptArgument]) async throws -> ScriptValue {
        try await AppleScriptRunner.run(Self.script, handler: handler, arguments, bundleID: Self.bundleID, app: "Mail")
    }

    /// A message as the script lists it: id, subject, sender, date, read, then optionally the To
    /// addresses and the text.
    private static func message(_ value: ScriptValue) -> MailMessage? {
        let fields = value.list
        guard fields.count >= 5, let id = fields[0].text else { return nil }
        return MailMessage(id: id, subject: fields[1].text ?? "", sender: fields[2].text ?? "", date: fields[3].date,
                           isRead: fields[4].flag ?? true,
                           recipients: fields.count > 5 ? fields[5].list.compactMap(\.text) : [],
                           content: fields.count > 6 ? fields[6].text : nil)
    }

    /// The only script this transport runs. Every value comes in as a handler parameter. Each handler
    /// bounds its Apple events to 30 seconds, twice the other scripts' time: Mail searches whole
    /// mailboxes and sends over the network.
    static let script = """
        on describe(m, withText)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    set addresses to {}
                    repeat with r in (to recipients of m)
                        set end of addresses to (address of r)
                    end repeat
                    set fields to {message id of m, subject of m, sender of m, date received of m, read status of m, addresses}
                    if withText then set end of fields to (content of m)
                    return fields
                end tell
            end timeout
        end describe

        on find_messages(q, unreadOnly, maxCount)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    if q is "" and unreadOnly then
                        set found to (messages of inbox whose read status is false)
                    else if q is "" then
                        set found to (messages of inbox)
                    else if unreadOnly then
                        set found to (messages of inbox whose read status is false and (subject contains q or sender contains q))
                    else
                        set found to (messages of inbox whose subject contains q or sender contains q)
                    end if
                    set answer to {}
                    set n to count of found
                    if n > maxCount then set n to maxCount
                    repeat with i from 1 to n
                        set m to item i of found
                        set end of answer to {message id of m, subject of m, sender of m, date received of m, read status of m}
                    end repeat
                    return answer
                end tell
            end timeout
        end find_messages

        on read_message(mid)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    set found to (messages of inbox whose message id is mid)
                    if found is {} then set found to (messages of sent mailbox whose message id is mid)
                    if found is {} then return {}
                    return my describe(item 1 of found, true)
                end tell
            end timeout
        end read_message

        on send_mail(addr, subj, bodyText, fromAddr)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    set m to make new outgoing message with properties {subject:subj, content:bodyText, visible:false}
                    if fromAddr is not "" then set sender of m to fromAddr
                    tell m to make new to recipient at end of to recipients with properties {address:addr}
                    return send m
                end tell
            end timeout
        end send_mail

        on save_draft(addr, subj, bodyText, fromAddr)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    set m to make new outgoing message with properties {subject:subj, content:bodyText, visible:false}
                    if fromAddr is not "" then set sender of m to fromAddr
                    if addr is not "" then
                        tell m to make new to recipient at end of to recipients with properties {address:addr}
                    end if
                    save m
                    close m saving no
                    return true
                end tell
            end timeout
        end save_draft

        on drafts_with(subj)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    set found to (messages of drafts mailbox whose subject is subj)
                    set answer to {}
                    repeat with m in found
                        set end of answer to my describe(contents of m, true)
                    end repeat
                    return answer
                end tell
            end timeout
        end drafts_with

        on sent_since(subj, sinceDate)
            with timeout of 30 seconds
                tell application id "com.apple.mail"
                    set found to (messages of sent mailbox whose subject is subj and date sent is greater than or equal to sinceDate)
                    set answer to {}
                    repeat with m in found
                        set end of answer to my describe(contents of m, false)
                    end repeat
                    return answer
                end tell
            end timeout
        end sent_since
        """
}
