import EngineCore
import Foundation
import LocalMCP

public struct NotesFolder: Sendable, Equatable {
    public let id     : String
    public let name   : String
    public let account: String
    public let count  : Int

    public init(id: String, name: String, account: String, count: Int) {
        self.id      = id
        self.name    = name
        self.account = account
        self.count   = count
    }
}

/// StoreNote is one note as Notes' dictionary gives it; `text` is its plain text, and `folderID` and
/// `account` the folder's id and its account's name, filled by `note(id:)` only.
public struct StoreNote: Sendable, Equatable {
    public let id      : String
    public let title   : String
    public let folder  : String
    public let modified: Date?
    public let text    : String?
    public let folderID: String?
    public let account : String?

    public init(
        id      : String,
        title   : String,
        folder  : String,
        modified: Date?,
        text    : String? = nil,
        folderID: String? = nil,
        account : String? = nil
    ) {
        self.id       = id
        self.title    = title
        self.folder   = folder
        self.modified = modified
        self.text     = text
        self.folderID = folderID
        self.account  = account
    }
}

extension NotesTransporting {
    public func requestPermission() async -> AdapterAvailability { await availability() }
}

/// NotesTransporting is Notes as the Notes adapter reaches it. The live one is `MacNotesTransport`;
/// tests use an in-memory one. A transport that would prompt for Automation throws
/// `AutomationPermissionNeeded`.
public protocol NotesTransporting: Sendable {
    func availability() async -> AdapterAvailability
    /// Asks the person for Automation over Notes, prompting when they have not answered yet.
    func requestPermission() async -> AdapterAvailability
    func folders() async throws -> [NotesFolder]
    /// The notes whose title or text contains `query`, in one folder or all of them.
    func notes(matching query: String?, folderID: String?, limit: Int) async throws -> [StoreNote]
    func note(id: String) async throws -> StoreNote?
    /// The note's HTML body and how many attachments it holds, nil when no note has the id.
    func content(id: String) async throws -> (body: String, attachments: Int)?
    /// Makes a note from HTML in the folder (the default one when nil) and answers its id.
    func create(html: String, folderID: String?) async throws -> String
    /// Adds HTML at the end of the note's body.
    func append(html: String, to id: String) async throws
}

/// NotesAdapter is the Notes app through its dictionary (one fixed script), with Notes hidden: folders
/// listed, notes found and read as plain text, a note created or added to and read back by its id. A note
/// created in a folder is confirmed only in that folder, read back by its id, which fixes the account too.
/// Text goes in escaped as HTML, so the agent's words never become markup. A note holding an image or an
/// attachment is never added to: setting its body drops them (measured on 19 Oct, the image went while the
/// note still counted two attachments, and the text read back as added).
///
/// Locked notes are not readable through the dictionary; they read back as empty.
public struct NotesAdapter: AppAdapting {

    public let name       = "notes"
    public let appNames   = ["Notes", "Note", "Apple Notes"]
    public let bundleIDs: Set<String> = ["com.apple.Notes"]

    static let maximumNotes   = 50
    static let maximumContent = 20_000
    /// A note's words; its id, folder, account and dates stay recorded.
    static let contentResults = ["title", "text"]

    private let transport: any NotesTransporting

    public init(transport: any NotesTransporting) {
        self.transport = transport
    }

    public var verbs: [AdapterVerb] {
        let folder = AdapterParameter("folder", .string, "a folder's name or id from list_folders", required: false,
                                      confidential: .sensitiveMetadata)
        return [
            AdapterVerb("list_folders", "List the folders, with their account and how many notes they hold.",
                        safety: .read, readBack: "Notes' folders", results: .identifiersAndDates),
            AdapterVerb("find_notes", "Find notes whose title or text contains a text, optionally in one folder.",
                        parameters: [
                            AdapterParameter("query", .string, "text the title or the note contains", required: false,
                                             confidential: .sensitiveMetadata),
                            folder,
                            AdapterParameter("limit", .integer, "at most this many; default 10", required: false,
                                             range: 1...Double(Self.maximumNotes)),
                        ],
                        safety: .read, readBack: "Notes' notes", contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("read_note", "Read one note's title, folder and plain text.",
                        parameters: [AdapterParameter("id", .string, "the note's id from find_notes")],
                        safety: .read, readBack: "the note by its id", contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("create_note", "Create a note with a title and a text.",
                        parameters: [
                            AdapterParameter("title", .string, "the note's title, its first line", confidential: .content),
                            AdapterParameter("text", .string, "the text under the title", required: false,
                                             confidential: .content),
                            folder,
                        ],
                        safety: .write, readBack: "the new note read by its id", contentResults: Self.contentResults, results: .identifiersAndDates),
            AdapterVerb("append_to_note", "Add text at the end of a note.",
                        parameters: [
                            AdapterParameter("id", .string, "the note's id from find_notes"),
                            AdapterParameter("text", .string, "the text to add, on new lines", confidential: .content),
                        ],
                        safety: .write, readBack: "the note's text read again", contentResults: Self.contentResults, results: .identifiersAndDates),
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
                case "list_folders":
                    let folders = try await transport.folders()
                    return .confirmed("\(folders.count) folders.", .object(["folders": .array(folders.map(Self.json))]))
                case "find_notes":     return try await find(arguments)
                case "read_note":
                    let id = try arguments.required("id")
                    guard let note = try await transport.note(id: id) else { return .missing("No note with id \(id).") }
                    return .confirmed("\(note.title).", Self.json(note))
                case "create_note":    return try await create(arguments)
                case "append_to_note": return try await append(arguments)
                default:               throw AdapterFailure("notes has no verb \(verb).")
            }
        } catch let needed as AutomationPermissionNeeded {
            return .refused(needed.reason)
        }
    }

    // MARK: Verbs

    private func find(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        var folderID: String?
        if let wanted = arguments.string("folder") {
            switch try await pick(wanted) {
                case .found(let folder):    folderID = folder.id
                case .outcome(let outcome): return outcome
            }
        }
        let query = arguments.string("query")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = arguments.number("limit").map { Int($0) } ?? 10
        let notes = try await transport.notes(matching: query?.isEmpty == false ? query : nil, folderID: folderID,
                                              limit: limit)
        let sorted = notes.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(limit)
        return .confirmed("\(sorted.count) note\(sorted.count == 1 ? "" : "s").",
                          .object(["notes": .array(sorted.map(Self.json))]))
    }

    private func create(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        let title = try arguments.required("title")
        let text  = arguments.string("text")
        var folders: [NotesFolder] = []
        var folderID: String?
        if let wanted = arguments.string("folder") {
            switch try await pick(wanted) {
                case .found(let folder):
                    folderID = folder.id
                    folders  = [folder]
                case .outcome(let outcome):
                    return outcome
            }
        }
        let html = "<div><h1>\(Self.escaped(title))</h1></div>" + (text.map(Self.paragraphs) ?? "")
        let id: String
        do {
            id = try await transport.create(html: html, folderID: folderID)
        } catch let needed as AutomationPermissionNeeded where needed.beforeAnyEvent {
            return .refused(needed.reason)
        } catch {
            return .mayHaveHappened("Notes was asked to create \(title)", because: error,
                                    look: "Read the folder's notes", result: .object(["title": .string(title)]))
        }
        let result: JSONValue = .object(["id": .string(id)])
        let asked = folderID.flatMap { id in folders.first { $0.id == id } }
        return await .afterChange("Notes took the note", look: "Read the note by its id", result: result) {
            guard let note = try await transport.note(id: id), note.title == title,
                  text.map({ Self.contains(note.text, $0) }) ?? true else {
                return AdapterOutcome(.actedUnverified, "Notes took the note, but it did not read back as written.",
                                      result: result)
            }
            // The folder's id fixes its account too: a note that landed elsewhere is not the one asked for.
            if let asked {
                guard let landed = note.folderID else {
                    return AdapterOutcome(.actedUnverified, "Notes took the note, but not which folder holds it.",
                                          result: Self.json(note))
                }
                guard landed == asked.id else {
                    return AdapterOutcome(.actedUnverified, "Notes took the note, but in \(note.folder)"
                                          + (note.account.map { " (\($0))" } ?? "")
                                          + ", not in \(asked.name) (\(asked.account)).", result: Self.json(note))
                }
            }
            let account = note.account ?? asked?.account
            return .confirmed("Created \(title) in \(note.folder)" + (account.map { " (\($0))" } ?? "") + ".",
                              Self.json(note))
        }
    }

    private func append(_ arguments: AdapterArguments) async throws -> AdapterOutcome {
        let id   = try arguments.required("id")
        let text = try arguments.required("text")
        guard let before = try await transport.note(id: id),
              let content = try await transport.content(id: id) else { return .missing("No note with id \(id).") }
        // Setting the body drops what the HTML cannot carry back: an embedded image went, its attachment still counted.
        if content.body.range(of: "<img", options: .caseInsensitive) != nil || content.attachments > 0 {
            return .refused("The note holds images or attachments, which adding text through Notes' scripting would "
                            + "drop: nothing was done. Put the text in a new note with create_note.")
        }
        let noted: JSONValue = .object(["id": .string(id)])
        do {
            try await transport.append(html: Self.paragraphs(text), to: id)
        } catch let needed as AutomationPermissionNeeded where needed.beforeAnyEvent {
            return .refused(needed.reason)
        } catch {
            return .mayHaveHappened("Notes was asked to add to the note", because: error,
                                    look: "Read the note by its id", result: noted)
        }
        return await .afterChange("Notes took the text", look: "Read the note by its id", result: noted) {
            guard let after = try await transport.note(id: id) else {
                return AdapterOutcome(.actedUnverified, "The note no longer reads back.", result: noted)
            }
            let previousLength = (before.text ?? "").count
            let grew = (after.text ?? "").count > previousLength && Self.contains(after.text, text)
            let result: JSONValue = .object(["id": .string(id), "title": .string(after.title),
                                             "previous_length": .number(Double(previousLength))])
            guard grew else {
                return AdapterOutcome(.actedUnverified, "Notes took the text, but the note does not read it back.",
                                      result: result)
            }
            return .confirmed("Added to \(after.title).", result)
        }
    }

    // MARK: Helpers

    /// A folder named by id or name, or the outcome that ends the call when none or several match.
    private enum Pick {
        case found(NotesFolder)
        case outcome(AdapterOutcome)
    }

    private func pick(_ wanted: String) async throws -> Pick {
        let folders = try await transport.folders()
        if let byID = folders.first(where: { $0.id == wanted }) { return .found(byID) }
        let named = folders.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        switch named.count {
            case 0:
                return .outcome(.missing("No folder \(wanted). Folders: " + folders.map(\.name).joined(separator: ", ") + "."))
            case 1:
                return .found(named[0])
            default:
                return .outcome(AdapterOutcome(.ambiguous, "\(named.count) folders are named \(wanted); pass its id.",
                                               result: .object(["folders": .array(named.map(Self.json))])))
        }
    }

    /// Whether the note's plain text holds `text`, line by line, the way Notes keeps it.
    static func contains(_ noteText: String?, _ text: String) -> Bool {
        let body = noteText ?? ""
        return text.split(whereSeparator: \.isNewline).allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || body.contains(trimmed)
        }
    }

    /// Text as Notes' HTML: one `div` per line, escaped.
    static func paragraphs(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.isEmpty ? "<div><br></div>" : "<div>\(escaped(String(line)))</div>"
        }.joined()
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func json(_ folder: NotesFolder) -> JSONValue {
        .object(["id": .string(folder.id), "name": .string(folder.name), "account": .string(folder.account),
                 "notes": .number(Double(folder.count))])
    }

    static func json(_ note: StoreNote) -> JSONValue {
        var object: [String: JSONValue] = [
            "id"      : .string(note.id),
            "title"   : .string(note.title),
            "folder"  : .string(note.folder),
            "modified": note.modified.map { .string(AdapterArguments.text($0)) } ?? .null,
        ]
        if let folderID = note.folderID { object["folder_id"] = .string(folderID) }
        if let account = note.account { object["account"] = .string(account) }
        if let text = note.text {
            object["text"] = .string(String(text.prefix(maximumContent)))
            if text.count > maximumContent { object["truncated"] = .bool(true) }
        }
        return .object(object)
    }
}

/// MacNotesTransport is Notes through one fixed script, its handlers called with Apple event
/// parameters. Notes is started hidden when it is not running.
public struct MacNotesTransport: NotesTransporting {

    static let bundleID = "com.apple.Notes"

    public init() {}

    public func availability() async -> AdapterAvailability {
        AppleScriptRunner.availability(bundleID: Self.bundleID, app: "Notes")
    }

    public func requestPermission() async -> AdapterAvailability {
        await AppleScriptRunner.requestPermission(bundleID: Self.bundleID, app: "Notes")
    }

    public func folders() async throws -> [NotesFolder] {
        try await run("list_folders", []).list.compactMap { value in
            let fields = value.list
            guard fields.count == 4, let id = fields[0].text else { return nil }
            if case .number(let count) = fields[3] {
                return NotesFolder(id: id, name: fields[1].text ?? "", account: fields[2].text ?? "", count: Int(count))
            }
            return NotesFolder(id: id, name: fields[1].text ?? "", account: fields[2].text ?? "", count: 0)
        }
    }

    public func notes(matching query: String?, folderID: String?, limit: Int) async throws -> [StoreNote] {
        try await run("find_notes", [.text(query ?? ""), .text(folderID ?? ""), .integer(limit)]).list.compactMap(Self.note)
    }

    public func note(id: String) async throws -> StoreNote? {
        Self.note(try await run("read_note", [.text(id)]))
    }

    public func content(id: String) async throws -> (body: String, attachments: Int)? {
        let fields = try await run("note_content", [.text(id)]).list
        guard fields.count == 2, let body = fields[0].text, case .number(let count) = fields[1] else { return nil }
        return (body, Int(count))
    }

    public func create(html: String, folderID: String?) async throws -> String {
        guard let id = try await run("create_note", [.text(html), .text(folderID ?? "")]).text else {
            throw AdapterFailure("Notes did not answer the new note's id.")
        }
        return id
    }

    public func append(html: String, to id: String) async throws {
        _ = try await run("append_to_note", [.text(id), .text(html)])
    }

    private func run(_ handler: String, _ arguments: [ScriptArgument]) async throws -> ScriptValue {
        try await AppleScriptRunner.run(Self.script, handler: handler, arguments, bundleID: Self.bundleID, app: "Notes")
    }

    /// A note as the script lists it: id, title, folder, modified, then optionally the plain text, the
    /// folder's id and its account's name.
    private static func note(_ value: ScriptValue) -> StoreNote? {
        let fields = value.list
        guard fields.count >= 4, let id = fields[0].text else { return nil }
        let account = fields.count > 6 ? fields[6].text.flatMap { $0.isEmpty ? nil : $0 } : nil
        return StoreNote(id: id, title: fields[1].text ?? "", folder: fields[2].text ?? "", modified: fields[3].date,
                         text    : fields.count > 4 ? fields[4].text : nil,
                         folderID: fields.count > 5 ? fields[5].text : nil,
                         account : account)
    }

    /// The only script this transport runs. Every value comes in as a handler parameter. Each handler
    /// bounds its Apple events to 15 seconds, and `find_notes` to 30, since it reads every note's text.
    static let script = """
        on list_folders()
            with timeout of 15 seconds
                tell application id "com.apple.Notes"
                    set answer to {}
                    repeat with a in accounts
                        repeat with f in folders of a
                            set end of answer to {id of f, name of f, name of a, count of notes of f}
                        end repeat
                    end repeat
                    return answer
                end tell
            end timeout
        end list_folders

        on find_notes(q, folderId, maxCount)
            with timeout of 30 seconds
                tell application id "com.apple.Notes"
                    if folderId is "" then
                        if q is "" then
                            set found to every note
                        else
                            set found to (every note whose name contains q or plaintext contains q)
                        end if
                    else
                        set f to folder id folderId
                        if q is "" then
                            set found to every note of f
                        else
                            set found to (every note of f whose name contains q or plaintext contains q)
                        end if
                    end if
                    set answer to {}
                    set n to count of found
                    if n > maxCount then set n to maxCount
                    repeat with i from 1 to n
                        set m to item i of found
                        set end of answer to {id of m, name of m, name of container of m, modification date of m}
                    end repeat
                    return answer
                end tell
            end timeout
        end find_notes

        on read_note(nid)
            with timeout of 15 seconds
                tell application id "com.apple.Notes"
                    set found to (every note whose id is nid)
                    if found is {} then return {}
                    set m to item 1 of found
                    set f to container of m
                    set a to container of f
                    repeat 16 times
                        if class of a is account then exit repeat
                        set a to container of a
                    end repeat
                    set accountName to ""
                    if class of a is account then set accountName to name of a
                    return {id of m, name of m, name of f, modification date of m, plaintext of m, id of f, accountName}
                end tell
            end timeout
        end read_note

        on note_content(nid)
            with timeout of 15 seconds
                tell application id "com.apple.Notes"
                    set found to (every note whose id is nid)
                    if found is {} then return {}
                    set m to item 1 of found
                    return {body of m, count of attachments of m}
                end tell
            end timeout
        end note_content

        on create_note(html, folderId)
            with timeout of 15 seconds
                tell application id "com.apple.Notes"
                    if folderId is "" then
                        set m to make new note with properties {body:html}
                    else
                        set m to make new note at folder id folderId with properties {body:html}
                    end if
                    return id of m
                end tell
            end timeout
        end create_note

        on append_to_note(nid, html)
            with timeout of 15 seconds
                tell application id "com.apple.Notes"
                    set m to item 1 of (every note whose id is nid)
                    set body of m to (body of m) & html
                    return true
                end tell
            end timeout
        end append_to_note
        """
}
