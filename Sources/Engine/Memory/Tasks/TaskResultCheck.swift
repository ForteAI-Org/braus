//
//  TaskResultCheck.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 14/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// TaskResultCheck is Braus's own check of one thing a task's result is, made when the agent names it (at a
/// checkpoint, at the end, or with the interpretation that follows the end) and kept as a verification of the
/// attempt (`memory_verifications` scope `task`, a `verification` member of the attempt, at its position among the
/// attempt's calls).
///
/// Every operation's check judges one gesture within what the window shows, and a menu that opens a remote panel
/// or a field that cannot be read back stays unknown; on PhotoCraft no procedure could be admitted that way, though
/// each output was right on disk (14 October 2026). The result is the other evidence a method worked. It is not
/// always a file: a task changes a file in place, keeps an original intact, removes a file, closes a window, sets
/// a value or a switch the person reads on screen, or leaves nothing to read at all. The agent names what to read
/// (`Expectation`); Braus reads the disk or the scene itself, so the verdict is never the agent's word.
public struct TaskResultCheck: Sendable, Equatable {

    /// How much earlier than the attempt's opening a file may have been written and still count as written by
    /// it: the two clocks are the file system's and the memory's.
    public static let clockTolerance: Int64 = 2_000

    /// Expectation is one thing the task's result is, in a form Braus reads itself. Paths are absolute; an
    /// application is a name or a bundle ID, nil for the one the session holds.
    public enum Expectation: Sendable, Equatable, Hashable {
        /// A file the task wrote: created or saved during the attempt.
        case fileWritten(path: String)
        /// A file the task changed in place: written during the attempt and, when Braus read it as the task
        /// began, no longer the same content.
        case fileChanged(path: String)
        /// A file the task had to leave as it was, such as an original it copied.
        case fileUnchanged(path: String)
        /// No file at the path any more: deleted, moved or renamed away.
        case fileAbsent(path: String)
        /// A text file written during the attempt that holds a text.
        case fileContains(path: String, text: String)
        /// A file moved or renamed: nothing left at `from`, and at `to` the content `from` had when the task began.
        case fileMoved(from: String, to: String)
        /// A file copied: at `to` the content `from` still has.
        case fileCopied(from: String, to: String)
        /// A folder the task wrote in holds no new file but those named: a guard Braus adds, against a stray copy or a file
        /// saved in another format (`ordine_57.txt.rtf` beside `ordine_57.txt`, 14 October 2026).
        case noOtherFiles(folder: String, named: [String])
        /// A window of an application whose title contains a text, open or closed.
        case window(app: String?, title: String, open: Bool)
        /// An element of the scene the session reads at the check, by its label: its value, its state, present or
        /// absent.
        case element(app: String?, label: String, expect: ElementExpectation)
        /// The task leaves nothing Braus can read, for the reason the agent gives: no evidence either way.
        case nothing(reason: String)
        public static let noReadableResultReason = "No readable result was declared."
        /// The archive retained the predicate kind but withheld its literal operands.
        case withheld(kind: String)

        /// The path of a check on the disk.
        public var path: String? {
            switch self {
                case .fileWritten(let path), .fileChanged(let path), .fileUnchanged(let path), .fileAbsent(let path),
                     .fileContains(let path, _), .fileMoved(let path, _), .fileCopied(let path, _), .noOtherFiles(let path, _): path
                default: nil
            }
        }

        /// The kind as the contract names it.
        public var kind: String {
            switch self {
                case .fileWritten: "file_written"
                case .fileChanged: "file_changed"
                case .fileUnchanged: "file_unchanged"
                case .fileAbsent: "file_absent"
                case .fileContains: "file_contains"
                case .fileMoved: "file_moved"
                case .fileCopied: "file_copied"
                case .noOtherFiles: "no_other_files"
                case .window: "window"
                case .element: "element"
                case .nothing: "none"
                case .withheld(let kind): kind
            }
        }

        /// The method a verification of this kind is stored with.
        public var method: VerificationMethod {
            switch self {
                case .fileWritten, .fileChanged, .fileUnchanged, .fileAbsent, .fileContains, .fileMoved, .fileCopied, .noOtherFiles: .fileCheck
                case .window: .windowCensus
                case .element(_, _, .value): .controlValue
                case .element(_, _, .state): .controlState
                case .element: .sceneText
                case .nothing, .withheld: .none
            }
        }

        /// The texts of the expectation an agent wrote, which a stored procedure renders over its parameters: a path,
        /// a text a file holds, a window's title, an element's label and value.
        public var texts: [String] {
            switch self {
                case .fileWritten(let path), .fileChanged(let path), .fileUnchanged(let path), .fileAbsent(let path): [path]
                case .fileContains(let path, let text): [path, text]
                case .fileMoved(let from, let to), .fileCopied(let from, let to): [from, to]
                case .noOtherFiles(let folder, let named): [folder] + named
                case .window(_, let title, _): [title]
                case .element(_, let label, .value(let value)): [label, value]
                case .element(_, let label, _): [label]
                case .nothing, .withheld: []
            }
        }

        /// The same expectation with every text passed through `transform`, in the order of `texts`.
        public func mapTexts(_ transform: (String) -> String) -> Expectation {
            switch self {
                case .fileWritten(let path): .fileWritten(path: transform(path))
                case .fileChanged(let path): .fileChanged(path: transform(path))
                case .fileUnchanged(let path): .fileUnchanged(path: transform(path))
                case .fileAbsent(let path): .fileAbsent(path: transform(path))
                case .fileContains(let path, let text): .fileContains(path: transform(path), text: transform(text))
                case .fileMoved(let from, let to): .fileMoved(from: transform(from), to: transform(to))
                case .fileCopied(let from, let to): .fileCopied(from: transform(from), to: transform(to))
                case .noOtherFiles(let folder, let named): .noOtherFiles(folder: transform(folder), named: named.map(transform))
                case .window(let app, let title, let open): .window(app: app, title: transform(title), open: open)
                case .element(let app, let label, .value(let value)): .element(app: app, label: transform(label), expect: .value(transform(value)))
                case .element(let app, let label, let expect): .element(app: app, label: transform(label), expect: expect)
                case .nothing, .withheld: self
            }
        }
    }

    /// ElementExpectation is what an element must show: a value (a field's text, a pop-up's choice), a state (a
    /// switch or a checkbox), or only that it is there or not.
    public typealias ElementExpectation = EngineCore.ElementExpectation

    /// FileFacts is what the disk said of one path at one moment: whether something is there, when it was last
    /// written, its size and the digest of its content when it was read, and, for a text asked of it, whether
    /// it holds it.
    public struct FileFacts: Sendable, Equatable {
        public let exists: Bool
        public let modifiedAtMS: Int64?
        public let size: Int64?
        /// The SHA-256 of the content, nil when it was not read (a folder, a file over the reading limit).
        public let digest: String?
        public let holdsText: Bool?
        /// For a folder, the names of the files it holds, hidden ones left out; nil for a file or a folder not listed.
        public let listing: [String]?

        public init(exists: Bool, modifiedAtMS: Int64? = nil, size: Int64? = nil, digest: String? = nil, holdsText: Bool? = nil,
                    listing: [String]? = nil) {
            self.exists       = exists
            self.modifiedAtMS = modifiedAtMS
            self.size         = size
            self.digest       = digest
            self.holdsText    = holdsText
            self.listing      = listing
        }

        public static let missing = FileFacts(exists: false)

        /// Whether two readings show the same content: the same digest when both were read, else the same size and
        /// time of last writing.
        public func sameContent(as other: FileFacts) -> Bool {
            guard exists, other.exists else { return exists == other.exists }
            if let digest, let other = other.digest { return digest == other }
            return size == other.size && modifiedAtMS == other.modifiedAtMS
        }
    }

    public let attemptID: String
    public let expectation: Expectation
    public let verdict: VerificationVerdict
    /// What was found, in words that never carry the content read: written during the attempt, missing, the
    /// value expected or another one.
    public let observed: String

    public init(attemptID: String, expectation: Expectation, verdict: VerificationVerdict, observed: String) {
        self.attemptID   = attemptID
        self.expectation = expectation
        self.verdict     = verdict
        self.observed    = observed
    }

    /// The path of a check on the disk, for a reader of the first version.
    public var path: String { expectation.path ?? "" }

    /// The verdict on a file the task wrote, from what the disk said: passed when it exists and was last written
    /// once the attempt had opened, failed when it is missing or older. `modifiedAtMS` is nil for a missing file.
    public static func file(_ path: String, attemptID: String, openedAtMS: Int64, modifiedAtMS: Int64?) -> TaskResultCheck {
        judge(.fileWritten(path: path), attemptID: attemptID, openedAtMS: openedAtMS, before: nil,
              now: modifiedAtMS.map { FileFacts(exists: true, modifiedAtMS: $0) } ?? .missing)
    }

    /// CheckWindow selects the historical task clock or evidence bounded by one row.
    public enum CheckWindow: Sendable { case task, row }

    /// The verdict on a check of the disk, from what it said now and, when Braus read the path as the task began,
    /// then. Without a reading from the beginning, a change is judged by the time of last writing alone, and says so.
    /// `other` is the reading of the second path of a move or a copy, now.
    public static func judge(_ expectation: Expectation, attemptID: String, openedAtMS: Int64, before: FileFacts?,
                             now: FileFacts, other: FileFacts? = nil, window: CheckWindow = .task) -> TaskResultCheck {
        func verdict(_ verdict: VerificationVerdict, _ observed: String) -> TaskResultCheck {
            TaskResultCheck(attemptID: attemptID, expectation: expectation, verdict: verdict, observed: observed)
        }
        if window == .row {
            if before == nil {
                switch expectation {
                case .fileChanged, .fileUnchanged, .fileMoved, .fileCopied, .noOtherFiles:
                    return verdict(.unknown, "no reading at the row's start")
                default: break
                }
            }
            switch expectation {
            case .fileWritten, .fileChanged, .fileContains:
                guard now.exists else { return verdict(.failed, "no file at the path") }
                let written: Bool
                if let before {
                    if !before.exists { written = true }
                    else if let was = before.digest, let current = now.digest, was != current { written = true }
                    else if let was = before.modifiedAtMS, let current = now.modifiedAtMS { written = was != current }
                    else { return verdict(.unknown, "the file's writing time could not be compared") }
                } else if let modified = now.modifiedAtMS {
                    if modified < openedAtMS, modified >= openedAtMS - clockTolerance {
                        return verdict(.unknown, "written around the row's start")
                    }
                    written = modified >= openedAtMS
                } else { return verdict(.unknown, "the file's writing time could not be read") }
                guard written else { return verdict(.failed, "the file was not written during the row") }
                if case .fileChanged = expectation, let before, before.exists, before.sameContent(as: now) {
                    return verdict(.failed, "written during the row with the same content it had")
                }
                if case .fileContains = expectation {
                    guard let holds = now.holdsText else { return verdict(.unknown, "the file could not be read as text") }
                    return verdict(holds ? .passed : .failed,
                        holds ? "written during the row and holding the text" : "written during the row without the text")
                }
                return verdict(.passed, "written during the row")
            default: break
            }
        }
        let writtenDuring = now.modifiedAtMS.map { $0 + clockTolerance >= openedAtMS }
        switch expectation {
            case .fileWritten:
                guard now.exists else { return verdict(.failed, "no file at the path") }
                guard writtenDuring == true else { return verdict(.failed, "the file was last written before the task began") }
                return verdict(.passed, "written during the task")
            case .fileChanged:
                guard now.exists else { return verdict(.failed, "no file at the path") }
                guard writtenDuring == true else { return verdict(.failed, "the file was not written during the task") }
                guard let before else { return verdict(.passed, "written during the task; its content at the start was not read") }
                guard before.exists else { return verdict(.passed, "created during the task") }
                return before.sameContent(as: now) ? verdict(.failed, "written during the task with the same content it had")
                    : verdict(.passed, "its content changed during the task")
            case .fileUnchanged:
                guard now.exists else { return verdict(.failed, "no file at the path") }
                if let before {
                    return before.sameContent(as: now) ? verdict(.passed, "the same content as at the start")
                        : verdict(.failed, "its content changed during the task")
                }
                return writtenDuring == true ? verdict(.failed, "written during the task")
                    : verdict(.passed, "not written during the task")
            case .fileAbsent:
                guard !now.exists else { return verdict(.failed, "a file is still at the path") }
                if let before, !before.exists { return verdict(.unknown, "there was no file at the path at the start either") }
                return verdict(.passed, "no file at the path")
            case .fileContains:
                guard now.exists else { return verdict(.failed, "no file at the path") }
                guard writtenDuring == true else { return verdict(.failed, "the file was not written during the task") }
                switch now.holdsText {
                    case true?: return verdict(.passed, "written during the task and holding the text")
                    case false?: return verdict(.failed, "written during the task without the text")
                    case nil: return verdict(.unknown, "the file could not be read as text")
                }
            case .fileMoved:
                guard !now.exists else { return verdict(.failed, "a file is still at the path it was to leave") }
                guard let other, other.exists else { return verdict(.failed, "no file at the path it was to reach") }
                guard let before, before.exists, let was = before.digest, let moved = other.digest else {
                    return verdict(.unknown, "moved, but its content at the start was not read to compare")
                }
                return was == moved ? verdict(.passed, "moved with its content") : verdict(.failed, "another content at the new path")
            case .fileCopied:
                guard now.exists else { return verdict(.failed, "no file at the path it was copied from") }
                guard let other, other.exists else { return verdict(.failed, "no file at the path it was to be copied to") }
                guard let source = now.digest, let copy = other.digest else { return verdict(.unknown, "the files could not be compared") }
                return source == copy ? verdict(.passed, "the copy holds the same content") : verdict(.failed, "the copy holds another content")
            case .noOtherFiles(_, let named):
                guard let was = before?.listing, let now = now.listing else {
                    return verdict(.unknown, "the folder was not listed at the start")
                }
                let unexpected = Set(now).subtracting(was).subtracting(named)
                return unexpected.isEmpty ? verdict(.passed, "no file appeared but those named")
                    : verdict(.failed, "\(unexpected.count) file(s) appeared that no check or output names")
            case .window, .element, .nothing, .withheld:
                return verdict(.unknown, "not a check of the disk")
        }
    }

    /// The verdict on a check of the screen. `windows` are the titles of the application's windows the window server
    /// lists, nil when the application is not running or could not be listed; `scene` is the scene the session read
    /// at the check, nil when no session of the application was open.
    public static func judge(_ expectation: Expectation, attemptID: String, windows: [String]?, scene: SceneSnapshot?) -> TaskResultCheck {
        func verdict(_ verdict: VerificationVerdict, _ observed: String) -> TaskResultCheck {
            TaskResultCheck(attemptID: attemptID, expectation: expectation, verdict: verdict, observed: observed)
        }
        let screen: ScreenExpectation
        switch expectation {
        case .window(_, let title, let open): screen = .window(title: title, open: open)
        case .element(_, let label, let expect): screen = .element(label: label, expect: expect)
        case .nothing: return verdict(.unknown, "the task leaves nothing to read")
        default: return verdict(.unknown, "not a check of the screen")
        }
        let result = screen.judge(windows: windows, scene: scene)
        switch result.verdict {
        case .passed: return verdict(.passed, result.observed)
        case .failed: return verdict(.failed, result.observed)
        case .unknown: return verdict(.unknown, result.observed)
        }
    }

    /// Reading is what Braus read for one check: the disk, now and when the task began, or the screen, the titles of
    /// the application's windows and the scene its session showed.
    public enum Reading: Sendable {
        case disk(before: FileFacts?, now: FileFacts, other: FileFacts? = nil)
        case screen(windows: [String]?, scene: SceneSnapshot?)
        /// Braus could not read what the check is about, and why: an application named ambiguously, windows that could
        /// not be listed. Judged unknown, never as an absence (review A5-2, 14 October 2026).
        case unread(String)
        case nothing
    }

    /// The verdict on a check from what Braus read.
    public static func judge(_ expectation: Expectation, attemptID: String, openedAtMS: Int64, reading: Reading) -> TaskResultCheck {
        switch reading {
            case .disk(let before, let now, let other):
                judge(expectation, attemptID: attemptID, openedAtMS: openedAtMS, before: before, now: now, other: other)
            case .screen(let windows, let scene): judge(expectation, attemptID: attemptID, windows: windows, scene: scene)
            case .unread(let why): TaskResultCheck(attemptID: attemptID, expectation: expectation, verdict: .unknown, observed: why)
            case .nothing: judge(expectation, attemptID: attemptID, windows: nil, scene: nil)
        }
    }

    /// The verdict of several checks taken together, as the qualification reads them: failed when one failed, passed
    /// when every check that could read something passed, else unknown. A task that said it leaves nothing to read
    /// proves nothing.
    public static func combined(_ verdicts: [VerificationVerdict]) -> VerificationVerdict? {
        guard !verdicts.isEmpty else { return nil }
        if verdicts.contains(.failed) { return .failed }
        return verdicts.allSatisfy { $0 == .passed } ? .passed : .unknown
    }
}

extension TaskResultCheck.Expectation {

    /// The expectation as a stored procedure keeps it for a reuse: every value one run bound to a parameter written as
    /// `{name}`. In a path, a value that is a whole leading path or a whole component is replaced
    /// (`/Users/x/Out/G01.png` → `{output_folder}/{output_name}`), or a component's name before its extension
    /// (`{output_name}.jpg`). Any other text is replaced when it is the value whole, and inside it a value that is a path or
    /// a file's name is replaced too. Values under three characters are left, since they would match by chance.
    public func template(over values: [(name: String, value: String)]) -> TaskResultCheck.Expectation {
        let values = values.filter { $0.value.count >= 3 }.sorted { $0.value.count > $1.value.count }
        return mapTexts { text in
            guard text.hasPrefix("/") else {
                if let whole = values.first(where: { $0.value == text }) { return "{\(whole.name)}" }
                // Inside a text, a path or a file's name a run bound is written as its parameter: «Salvato: /…/lavoro_A.png»
                // is «Salvato: {folder}/{file_name}» (PhotoCraft v2, 14 October 2026), whatever else the text holds.
                var result = text
                for value in values where value.value.hasPrefix("/") || SceneSkeleton.isContentCaption(value.value) {
                    result = result.replacingOccurrences(of: value.value, with: "{\(value.name)}")
                }
                return result
            }
            var rest = text
            var head = ""
            if let folder = values.first(where: { $0.value.hasPrefix("/") && (rest == $0.value || rest.hasPrefix($0.value + "/")) }) {
                head = "{\(folder.name)}"
                rest = String(rest.dropFirst(folder.value.count))
            }
            // A component is a value whole, or a value with an extension after it (`{output_name}.jpg`).
            let components = rest.split(separator: "/", omittingEmptySubsequences: false).map { component -> String in
                if let whole = values.first(where: { $0.value == component }) { return "{\(whole.name)}" }
                if let stem = values.first(where: { !$0.value.hasPrefix("/") && component.hasPrefix($0.value + ".") }) {
                    return "{\(stem.name)}" + component.dropFirst(stem.value.count)
                }
                return String(component)
            }
            return head + components.joined(separator: "/")
        }
    }

    /// The template with the values of a new task in place of its `{name}`s; a name with no value stays as it is.
    public func bound(to values: [String: String]) -> TaskResultCheck.Expectation {
        mapTexts { text in
            var result = text
            for (name, value) in values { result = result.replacingOccurrences(of: "{\(name)}", with: value) }
            return result
        }
    }

    /// The parameters a template names, in order.
    public var parameterNames: [String] {
        texts.flatMap { text -> [String] in
            var names: [String] = []
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                names.append(String(rest[rest.index(after: open)..<close]))
                rest = rest[rest.index(after: close)...]
            }
            return names
        }
    }
}

extension TaskResultCheck.Expectation {

    /// The expectation as the archive keeps it in `expected_text`: a JSON object with its kind and fields, keys sorted.
    public var stored: String {
        var fields: [String: String] = ["kind": kind]
        switch self {
            case .fileWritten(let path), .fileChanged(let path), .fileUnchanged(let path), .fileAbsent(let path):
                fields["path"] = path
            case .fileContains(let path, let text):
                fields["path"] = path
                fields["text"] = text
            case .fileMoved(let from, let to), .fileCopied(let from, let to):
                fields["path"] = from
                fields["to"] = to
            case .noOtherFiles(let folder, let named):
                fields["path"] = folder
                fields["named"] = named.joined(separator: "\n")
            case .window(let app, let title, let open):
                fields["app"] = app
                fields["title"] = title
                fields["open"] = open ? "true" : "false"
            case .element(let app, let label, let expect):
                fields["app"] = app
                fields["label"] = label
                switch expect {
                    case .value(let value): fields["value"] = value
                    case .state(let state): fields["state"] = state.rawValue
                    case .present: fields["present"] = "true"
                    case .absent: fields["present"] = "false"
                }
            case .nothing(let reason):
                fields["reason"] = reason
            case .withheld:
                fields["withheld"] = "true"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(fields)).map { String(decoding: $0, as: UTF8.self) } ?? kind
    }

    /// The expectation an archive kept, nil for a text that is none. A plain path with `file_check` is the first
    /// version's record, a file written.
    public init?(stored text: String, method: VerificationMethod) {
        guard let data = text.data(using: .utf8), let fields = try? JSONDecoder().decode([String: String].self, from: data),
              let kind = fields["kind"] else {
            guard method == .fileCheck, text.hasPrefix("/") else { return nil }
            self = .fileWritten(path: text)
            return
        }
        if fields["withheld"] == "true" { self = .withheld(kind: kind); return }
        switch kind {
            case "file_written": guard let path = fields["path"] else { return nil }; self = .fileWritten(path: path)
            case "file_changed": guard let path = fields["path"] else { return nil }; self = .fileChanged(path: path)
            case "file_unchanged": guard let path = fields["path"] else { return nil }; self = .fileUnchanged(path: path)
            case "file_absent": guard let path = fields["path"] else { return nil }; self = .fileAbsent(path: path)
            case "file_contains":
                guard let path = fields["path"], let text = fields["text"] else { return nil }
                self = .fileContains(path: path, text: text)
            case "no_other_files":
                guard let folder = fields["path"] else { return nil }
                self = .noOtherFiles(folder: folder, named: (fields["named"] ?? "").split(separator: "\n").map(String.init))
            case "file_moved", "file_copied":
                guard let path = fields["path"], let to = fields["to"] else { return nil }
                self = kind == "file_moved" ? .fileMoved(from: path, to: to) : .fileCopied(from: path, to: to)
            case "window":
                guard let title = fields["title"] else { return nil }
                self = .window(app: fields["app"], title: title, open: fields["open"] != "false")
            case "element":
                guard let label = fields["label"] else { return nil }
                let expect: TaskResultCheck.ElementExpectation
                if let value = fields["value"] { expect = .value(value) }
                else if let state = fields["state"].flatMap(ControlState.init(rawValue:)) { expect = .state(state) }
                else { expect = fields["present"] == "false" ? .absent : .present }
                self = .element(app: fields["app"], label: label, expect: expect)
            case "none": self = .nothing(reason: fields["reason"] ?? "")
            default: return nil
        }
    }

    /// The expectation in one line, as an agent reads it: `file_written /Users/…/G01.png`, `element "Width" = 640`.
    public var line: String {
        switch self {
            case .fileWritten(let path), .fileChanged(let path), .fileUnchanged(let path), .fileAbsent(let path): "\(kind) \(path)"
            case .fileContains(let path, let text): "\(kind) \(path) holding \"\(text)\""
            case .fileMoved(let from, let to), .fileCopied(let from, let to): "\(kind) \(from) → \(to)"
            case .noOtherFiles(let folder, let named): "\(kind) \(folder) (but \(named.joined(separator: ", ")))"
            case .window(let app, let title, let open): "window \"\(title)\"\(app.map { " of \($0)" } ?? "") \(open ? "open" : "closed")"
            case .element(let app, let label, let expect):
                "element \"\(label)\"\(app.map { " of \($0)" } ?? "") " + {
                    switch expect {
                        case .value(let value): "= \"\(value)\""
                        case .state(let state): "is \(state.rawValue)"
                        case .present: "present"
                        case .absent: "absent"
                    }
                }()
            case .nothing(let reason): "none (\(reason))"
            case .withheld(let kind): "\(kind) (literal operands withheld)"
        }
    }
}

/// Encodes expectations using the existing lossless text form for transport, independently of SQL storage.
extension TaskResultCheck.Expectation: Codable {
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let expectation = Self(stored: value, method: .none) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Invalid result expectation"))
        }
        self = expectation
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}
