import AppAdapters
import CoreGraphics
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// P1-06 through the tools: synthetic confidential content crosses a mail window's scene, an action on one of its
/// messages, an adapter's arguments, results and errors, and a text typed into another app, and reaches the model's
/// answers; no persistent destination keeps it (the archive's file, its write-ahead log, the transcript), while the
/// structure stays (the samples' roles, the Brain's anchors of the application's own controls) and each withheld value
/// leaves a `confidential_content` gap.
///
/// Offline: `AutomationTools` over a session fake that reports its perceptions to the call's recorder as the real
/// sessions do, and an adapter in place of Mail's. No app, Seat, account or network.
@MainActor
@Suite("P1-06: confidential content reaches the model, never the records", .serialized)
struct ConfidentialSurfaceTests {

    nonisolated static let subject = "SYNTH-SUBJECT quarterly salary review"
    nonisolated static let body    = "SYNTH-BODY the diagnosis is confidential"
    nonisolated static let person  = "synth.person@example.invalid"
    nonisolated static let short   = "Zq"
    nonisolated static let draft   = "SYNTH-DRAFT please keep this between us"
    nonisolated static let all     = [subject, body, person, draft]

    nonisolated static let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)

    /// A session over Mail and one other app, whose perceptions reach the call's recorder as a real session's do.
    final class SurfaceFake: AutomationSessionOperating {
        let memoryDirectory: URL?
        private(set) var id: UUID?
        private var bundleID = "com.apple.mail"
        private(set) var typed: [String] = []
        var dispatchRoute: CallRoute.Route? { .desktop }
        var memoryApplication: String? { id == nil ? nil : bundleID }

        init(memory: URL) { memoryDirectory = memory }

        static func element(_ id: String, _ label: String, kind: ElementKind = .control, role: String,
                            collection: String? = nil, x: Double) -> SceneElement {
            SceneElement(id: id, kind: kind, label: label, bounds: NormalizedRect(x: x, y: 0.4, width: 0.05, height: 0.02),
                         role: role, collectionPath: collection)
        }

        func scene(opened: Bool = false) -> SceneSnapshot {
            guard bundleID == "com.apple.mail" else {
                return SceneSnapshot(bundleID: bundleID, appName: "Pages", windowTitle: "Untitled",
                                     viewportPixelSize: ViewportPixelSize(width: 1000, height: 800),
                                     elements: [Self.element("body", "Body", role: "AXTextArea", x: 0.5)])
            }
            var elements = [
                Self.element("reply", "Reply", role: "AXButton", x: 0.1),
                Self.element("delete", "Delete", role: "AXButton", x: 0.2),
                Self.element("row", ConfidentialSurfaceTests.subject, role: "AXRow", collection: "Messages", x: 0.3),
                Self.element("from", ConfidentialSurfaceTests.short, kind: .text, role: "AXStaticText", x: 0.4),
            ]
            if opened {
                elements.append(Self.element("text", ConfidentialSurfaceTests.body, kind: .text, role: "AXStaticText", x: 0.6))
            }
            return SceneSnapshot(bundleID: bundleID, appName: "Mail",
                                 windowTitle: opened ? ConfidentialSurfaceTests.subject : "Inbox – \(ConfidentialSurfaceTests.person)",
                                 viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements)
        }

        func window(_ scene: SceneSnapshot) -> PerceivedWindow {
            PerceivedWindow(scene: scene, frame: ConfidentialSurfaceTests.frame,
                            capture: CaptureQuality(walkCompleted: true, windowFound: true))
        }

        func open(application: String, window: String?) async throws -> SceneSnapshot {
            bundleID = application == "Mail" ? "com.apple.mail" : "com.example.pages"
            id = UUID()
            return await CallRecorder.current?.observe(self.window(scene())) ?? scene()
        }

        func observe() async throws -> SceneSnapshot {
            await CallRecorder.current?.observe(window(scene())) ?? scene()
        }

        func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
            let before = scene(), after = scene(opened: true)
            guard let element = before.elements.first(where: { $0.label == target }) else {
                throw AutomationFailure("no '\(target)' in \(before.elements.map(\.label))")
            }
            await CallRecorder.current?.record(ActionRecord(
                bundleID: bundleID, element: element, verb: verb,
                effect: .elementsAppeared(labels: [ConfidentialSurfaceTests.body, "Reply"]),
                windowTitleAfter: after.windowTitle, before: window(before), after: window(after)
            ))
            return ActOutcome(.foundActed, "clicked '\(target)': '\(ConfidentialSurfaceTests.body)' appeared", scene: after,
                              check: OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                                                    verdict: .passed, expected: target, observed: "elementsAppeared",
                                                    performed: .requested, target: OperationCheck.Target(element)))
        }

        func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.refused, "fake") }

        func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
            if case .typeText(let text, _, _) = input { typed.append(text) }
            return ActOutcome(.actedUnverified, "typed into the body")
        }

        func close() async { id = nil }
    }

    /// Mail's adapter as its verbs are declared, answering synthetic correspondence.
    final class MailFake: AppAdapting, @unchecked Sendable {
        let name = "mail"
        let appNames = ["Mail"]
        let bundleIDs: Set<String> = ["com.apple.mail"]
        let verbs = [
            AdapterVerb("read_message", "Read one message.", parameters: [AdapterParameter("id", .string, "the id")],
                        safety: .read, readBack: "the inbox", results: .identifiersAndDates),
            AdapterVerb("create_draft", "Save a draft.",
                        parameters: [AdapterParameter("to", .string, "recipient", confidential: .sensitiveMetadata),
                                     AdapterParameter("subject", .string, "subject", confidential: .content),
                                     AdapterParameter("body", .string, "text", confidential: .content)],
                        safety: .write, readBack: "the drafts mailbox", results: .identifiersAndDates),
            AdapterVerb("boom", "Fails while reading.", parameters: [AdapterParameter("id", .string, "the id")],
                        safety: .read, readBack: "nothing", results: .identifiersAndDates),
        ]

        func availability() async -> AdapterAvailability { .ready }
        func requestPermission() async -> AdapterAvailability { .ready }
        func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
            switch verb {
                case "read_message":
                    return AdapterOutcome(.foundActed, "From \(ConfidentialSurfaceTests.person): \(ConfidentialSurfaceTests.subject).",
                                          result: .object(["id": .string("msg-1"),
                                                           "subject": .string(ConfidentialSurfaceTests.subject),
                                                           "sender": .string(ConfidentialSurfaceTests.person),
                                                           "content": .string(ConfidentialSurfaceTests.body)]))
                case "create_draft":
                    return AdapterOutcome(.foundActed, "The draft for \(arguments["to"].string ?? "") is saved.",
                                          result: .object(["id": .string("draft-1")]))
                default:
                    throw AdapterFailure("could not read '\(ConfidentialSurfaceTests.subject)' from \(ConfidentialSurfaceTests.person)")
            }
        }
    }

    static func text(_ result: JSONValue) -> String { result["content"].array?.first?["text"].string ?? "" }

    /// Every byte of the archive's files, the write-ahead log included, as text.
    static func archiveBytes(_ knowledge: URL) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: knowledge.path).filter { $0.hasPrefix("memory.sqlite") }
        return try names.map { String(decoding: try Data(contentsOf: knowledge.appendingPathComponent($0)), as: UTF8.self) }
            .joined(separator: "\n")
    }

    static func query(_ knowledge: URL, _ sql: String) throws -> [String] {
        let archive = try SQLiteConnection(path: knowledge.appendingPathComponent("memory.sqlite").path, readOnly: true)
        defer { archive.close() }
        return try archive.query(sql) { try $0.text(0) ?? "" }
    }

    @Test("a mail window's content, an action on a message, Mail's adapter and a text typed elsewhere: the model reads the content, no record keeps it, the structure stays")
    func confidentialContentStaysOutOfTheRecords() async throws {
        let knowledge = FileManager.default.temporaryDirectory.appendingPathComponent("braus-p106-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let session = SurfaceFake(memory: knowledge)
        let tools = AutomationTools(session: session)
        tools.adapters = AppAdapters([MailFake()])
        tools.producer = CallProducer(source: .app, streamID: "p106", traceID: "confidential")
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let transcript = Lines()
        tools.record = { transcript.all.append($0) }

        let opened = try await tools.call("open_session", .object(["app": .string("Mail")]))
        let sessionID = try #require(CallDispatchRecordTests.sessionID(opened))
        // An observe of the same window answers it unchanged since the open: the open's answer carries the scene.
        _ = try await tools.call("observe", .object(["session": .string(sessionID)]))
        let clicked = try await tools.call("act", .object(["session": .string(sessionID), "target": .string(Self.subject),
                                                          "verb": .string("click")]))
        // Release the interface before using the same app through its adapter.
        _ = try await tools.call("close_session", .object(["session": .string(sessionID)]))
        let read = try await tools.call("app_call", .object(["app": .string("Mail"), "verb": .string("read_message"),
                                                             "arguments": .object(["id": .string("msg-1")])]))
        let drafted = try await tools.call("app_call", .object([
            "app": .string("Mail"), "verb": .string("create_draft"),
            "arguments": .object(["to": .string(Self.person), "subject": .string(Self.subject), "body": .string(Self.draft)]),
        ]))
        let failed = try? await tools.call("app_call", .object(["app": .string("Mail"), "verb": .string("boom"),
                                                                "arguments": .object(["id": .string("msg-1")])]))
        // The content leaves the confidential surface: typed into another app's document.
        let other = try await tools.call("open_session", .object(["app": .string("Pages")]))
        let otherID = try #require(CallDispatchRecordTests.sessionID(other))
        _ = try await tools.call("type_text", .object(["session": .string(otherID), "target": .string("Body"),
                                                       "text": .string(Self.body)]))

        // The model reads the content: the scene, the action's answer and the adapter's result carry it.
        #expect(Self.text(opened).contains(Self.subject), Comment(rawValue: Self.text(opened)))
        #expect(Self.text(clicked).contains(Self.body), Comment(rawValue: Self.text(clicked)))
        #expect(Self.text(read).contains(Self.body) && Self.text(read).contains(Self.person), Comment(rawValue: Self.text(read)))
        #expect(Self.text(drafted).contains(Self.person), Comment(rawValue: Self.text(drafted)))
        #expect(failed == nil || Self.text(failed ?? .null).contains("could not read"))
        #expect(session.typed == [Self.body], "the text went out as asked")

        // No record keeps it: the archive's files and the transcript.
        let memory = MemoryService.shared(for: knowledge)
        _ = await memory.flush(within: .seconds(5))
        let reasons = try Self.query(knowledge, "SELECT DISTINCT reason FROM memory_value_redactions ORDER BY reason")
        let anchors = try Self.query(knowledge, "SELECT label FROM brain_anchors ORDER BY label")
        let labels  = try Self.query(knowledge, "SELECT label FROM memory_event_observations WHERE label IS NOT NULL ORDER BY label")
        await MemoryService.closeAll()
        let bytes = try Self.archiveBytes(knowledge)
        for secret in Self.all {
            #expect(!bytes.contains(secret), "the archive keeps \(secret)")
            #expect(transcript.all.allSatisfy { !$0.contains(secret) }, "the transcript keeps \(secret)")
        }
        #expect(transcript.all.allSatisfy { !$0.contains("\"\(Self.short)\"") }, "a short content value is withheld whole")
        // The structure stays, and each withheld value leaves its gap.
        #expect(reasons.contains("confidential_content"), "\(reasons)")
        #expect(anchors.contains("Reply") && anchors.contains("Delete"), "the controls are learned: \(anchors)")
        #expect(!labels.isEmpty && labels.contains(ValueMinimization.marker) && labels.contains("Reply"), "\(labels)")
        await MemoryService.closeAll()
    }

    @Test("the policy: which surfaces are confidential, which elements are content, what a Brain learns of one")
    func policy() {
        #expect(ConfidentialSurfaces.surface(of: "com.apple.mail") == .mail)
        #expect(ConfidentialSurfaces.surface(of: "web:mail.google.com") == .mail)
        #expect(ConfidentialSurfaces.surface(of: "web:eu.app.slack.com") == .messages, "a subdomain is the same surface")
        #expect(ConfidentialSurfaces.surface(of: "web:example.com") == nil && ConfidentialSurfaces.surface(of: "com.apple.Safari") == nil)
        let button = SurfaceFake.element("r", "Reply", role: "AXButton", x: 0.1)
        let row = SurfaceFake.element("m", "Hi", role: "AXButton", collection: "Messages", x: 0.2)
        let text = SurfaceFake.element("t", "Hello", kind: .text, role: "AXStaticText", x: 0.3)
        var valued = SurfaceFake.element("f", "Ada", role: "AXButton", x: 0.4)
        valued.labelOrigin = .value
        #expect(!ConfidentialSurfaces.isContent(button))
        #expect(ConfidentialSurfaces.isContent(row) && ConfidentialSurfaces.isContent(text) && ConfidentialSurfaces.isContent(valued))
        let scene = SceneSnapshot(bundleID: "com.apple.mail", appName: "Mail", windowTitle: Self.subject,
                                  viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: [button, row, text])
        let structure = ConfidentialSurfaces.structure(of: scene)
        #expect(structure.elements.map(\.label) == ["Reply"] && structure.windowTitle == ValueMinimization.marker)
        // An effect keeps only the application's own controls' labels.
        let minimization = ValueMinimization()
        let (effect, reason) = minimization.minimize(effect: .elementsAppeared(labels: ["Reply", Self.body]),
                                                     confidentialControls: ["Reply"])
        #expect(effect == .elementsAppeared(labels: ["Reply", ValueMinimization.marker]) && reason == .confidentialContent)
    }
}
