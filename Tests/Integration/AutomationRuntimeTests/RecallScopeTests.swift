//
//  RecallScopeTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// RecallScopeTests prove, through `memory_task begin` on the corpus learned by D2's producers, that a selection
/// holds the work the request asks for and no more: what the request forbids, work already done and parts whose
/// output is ready stay out, and what the request needs but cannot be resolved is said rather than certified complete.
@MainActor
@Suite("The Recall selects the work requested, within the request's constraints", .serialized)
struct RecallScopeTests {

    typealias P = ProcedureLearningTests

    static let preview = "com.apple.Preview"

    /// The corpus learned through the tools with the chosen lexical configuration, in a new archive.
    static func learned(_ corpus: RecallCorpus? = nil) async throws -> (LearningSession, MemoryService) {
        let session = P.photoSession(try W.directory())
        let memory = MemoryService.shared(for: session.directory)
        if let corpus {
            RecallService.install(RecallService(memory: memory, configuration: RecallCycleTests.configuration(.lexical)))
            for item in corpus.knowledge { _ = try await corpus.learn(item, into: session.directory) }
            #expect(await RecallService.shared(for: memory).waitUntilIdle(within: .seconds(120)))
        } else {
            _ = try await RecallCycleTests.learnCorpus(session, channel: .lexical)
        }
        return (session, memory)
    }

    static func close(_ session: LearningSession, _ memory: MemoryService) async {
        await memory.close()
        RecallService.forget(memory)
        MemoryService.forget(session.directory)
    }

    static func steps(_ begun: JSONValue) -> [Int] {
        (begun["recall"]["needs"].array?.first?["selection"]["steps"].array ?? []).compactMap { RecallCycleTests.int($0["step"]) }
    }

    static func conditions(_ begun: JSONValue) -> [String] {
        (begun["recall"]["needs"].array?.first?["selection"]["conditions"].array ?? []).compactMap { $0["kind"].string }
    }

    @Test("creating only a note does not recall the step that shares it by Mail, and the constraint is not lost")
    func creatingOnlyNoteExcludesSharing() async throws {
        let (session, memory) = try await Self.learned()
        let begun = try await P.task(P.tools(session, stream: "note-scope"), #"""
            {"operation":"begin","goal":"Create a new note titled Idee in Notes",
             "remaining":"Create a new note titled Idee in Notes",
             "constraints":["Do not share the note and do not open Mail"],
             "inputs":[{"name":"note_title","value":"Idee"}]}
            """#)
        let selected = begun["recall"]["needs"].array?.first?["selection"] ?? .null
        let steps = selected["steps"].array ?? []
        #expect(steps.compactMap { RecallCycleTests.int($0["step"]) } == [1, 2], "only creation and title, never sharing: \(begun)")
        #expect(!steps.contains { $0["tool"].string == "context_menu" }, "the source's third step shares by Mail")
        #expect(begun["recall"]["coverage"].string == "complete")
        #expect(!Self.conditions(begun).contains("constraint_unchecked"), "both clauses were checked against the steps")
        // A constraint the selector cannot check is carried to the agent, not dropped.
        let other = try await P.task(P.tools(session, stream: "note-scope-2"), #"""
            {"operation":"begin","goal":"Create a new note titled Idee in Notes","remaining":"Create a new note titled Idee in Notes",
             "constraints":["Keep the note short"],"inputs":[{"name":"note_title","value":"Idee"}]}
            """#)
        #expect(Self.steps(other) == [1, 2], "without the constraint the sharing is still no part of creating: \(other)")
        #expect(Self.conditions(other).contains("constraint_unchecked"))
        await Self.close(session, memory)
    }

    @Test("an Export dialog the session shows open: a need about its format gets that control alone, from the observed state")
    func dialogAlreadyOpen() async throws {
        let (session, memory) = try await Self.learned()
        let tools = P.tools(session, stream: "dialog-open")
        session.windows[Self.preview] = try RecallCorpus.load().window(Self.preview, "export")
        _ = try await tools.call("open_session", .object(["app": .string(Self.preview)]))
        let begun = try await P.task(tools, #"""
            {"operation":"begin","goal":"Choose PNG as the format in the Export dialog already open in Preview",
             "remaining":"Choose PNG as the format in the Export dialog already open in Preview",
             "inputs":[{"name":"output_format","value":"PNG","role":"format chosen in the Export dialog"}]}
            """#)
        let steps = begun["recall"]["needs"].array?.first?["selection"]["steps"].array ?? []
        #expect(steps.count == 1 && steps.first?["tool"].string == "select", "the format control alone: \(begun)")
        #expect(Self.conditions(begun).first == "observed_state", "it starts from the state the session showed")
        #expect(!steps.contains { $0["tool"].string == "menu" }, "the dialog is not opened again")
        await Self.close(session, memory)
    }

    @Test("a need whose app is imposed gets the input it lacks as missing: no producer is invented, the coverage is ambiguous")
    func trulyMissingInput() async throws {
        let (session, memory) = try await Self.learned()
        let begun = try await P.task(P.tools(session, stream: "missing"), #"""
            {"operation":"begin","goal":"Send the shared note by email","remaining":"Send the shared note by email",
             "needs":[{"text":"Type the recipient in To and send the shared note","app":"com.apple.mail"}]}
            """#)
        let need = begun["recall"]["needs"].array?.first ?? .null
        #expect(need["coverage"].string == "ambiguous" && need["reason"].string == "unresolved_input", "\(begun)")
        let parameters = need["selection"]["parameters"].array ?? []
        #expect(parameters.contains { $0["status"].string == "missing" }, "the recipient is to be asked, not guessed")
        #expect(!Self.conditions(begun).contains("input_produced"))
        await Self.close(session, memory)
    }

    @Test("a variant whose fixed choice contradicts the task's value is excluded and named; the coherent one is selected")
    func incoherentVariantExcluded() async throws {
        let (session, memory) = try await Self.learned()
        let begun = try await P.task(P.tools(session, stream: "variant"), #"""
            {"operation":"begin","goal":"Print the open PDF","remaining":"Print the open PDF",
             "inputs":[{"name":"pages","value":"Current","role":"pages to print"}]}
            """#)
        let need = begun["recall"]["needs"].array?.first ?? .null
        #expect(need["coverage"].string == "complete", "\(begun)")
        let labels = (need["selection"]["steps"].array ?? []).compactMap { $0["label"].string }
        #expect(labels.contains("Choose to print the current page only"))
        let excluded = need["excluded"].array ?? []
        #expect(excluded.contains { ($0["labels"].array ?? []).contains(.string("Choose to print all pages")) }, "the other variant is named")
        await Self.close(session, memory)
    }

    /// The corpus with one more task: an invoice downloaded in Safari, then attached to an email in Mail, whose
    /// interpretation declares the download's output and states that the file the email attaches is that output
    /// (`previous_output`, `invoice_file`).
    static func invoiceCorpus(attachmentSource: String = #""source":"previous_output","source_ref":"invoice_file""#) throws -> RecallCorpus {
        let base = try RecallCorpus.load()
        guard case .object(var root) = base.json, case .object(var apps) = root["apps"], case .object(var mail) = apps["com.apple.mail"],
              case .object(var windows) = mail["windows"], case .array(let knowledge) = root["knowledge"] else {
            throw RecallCorpus.Failure("the corpus's shape")
        }
        windows["attach-invoice"] = P.json(#"""
            {"title":"Choose File","surface":"sheet","elements":[{"kind":"row","label":"INV-2026-031.pdf","list":"files"},
             {"kind":"row","label":"report_q3.pdf","list":"files"},{"kind":"button","label":"Choose File"},{"kind":"button","label":"Cancel"}]}
            """#)
        mail["windows"] = .object(windows)
        apps["com.apple.mail"] = .object(mail)
        root["apps"] = .object(apps)
        root["knowledge"] = .array(knowledge + [P.json(#"""
            {"id":"invoice-mail","family":"invoice","goal":"Download invoice INV-2026-031 and email it to Anna",
             "inputs":[{"name":"invoice","value":"INV-2026-031"},{"name":"recipient","value":"anna@example.com"}],
             "run":[{"open":"com.apple.Safari","window":"portal"},{"op":"act","args":{"target":"Invoices"},"next":"invoices"},
                    {"op":"act","args":{"target":"INV-2026-031"}},{"op":"act","args":{"target":"Download PDF"}},
                    {"open":"com.apple.mail","window":"viewer"},{"op":"act","args":{"target":"New Message"},"next":"compose"},
                    {"op":"type_text","args":{"target":"To","text":"anna@example.com"}},
                    {"op":"act","args":{"target":"Attach"},"next":"attach-invoice"},{"op":"act","args":{"target":"INV-2026-031.pdf"}},
                    {"op":"press","args":{"button":"Choose File"},"next":"compose"},{"op":"act","args":{"target":"Send"},"next":"viewer"}],
             "end":"completed",
             "interpretation":{"procedure":{"label":"Download invoice <invoice> and email it to <recipient>"},
               "parts":[{"part":"b1","label":"Download invoice <invoice> from the supplier portal","outcome":"completed"},
                        {"part":"b2","label":"Email <attachment> to <recipient>","outcome":"completed"}],
               "steps":[{"step":1,"label":"Open the invoices page"},{"step":2,"label":"Select invoice <invoice>"},
                        {"step":3,"label":"Download the selected invoice"},{"step":4,"label":"Start a new email"},
                        {"step":5,"label":"Type <recipient> in To"},{"step":6,"label":"Open the attachment chooser"},
                        {"step":7,"label":"Pick <attachment>"},{"step":8,"label":"Confirm the attachment"},{"step":9,"label":"Send the email"}],
               "parameters":[{"name":"invoice","role":"number of the invoice","kind":"text"},
                             {"name":"invoice_file","role":"file of the downloaded invoice","kind":"text","direction":"output",
                              "value":"INV-2026-031.pdf","source":"observation","produced_by":"b1"},
                             {"name":"attachment","role":"name of the file attached","kind":"text","value":"INV-2026-031.pdf",
                              \#(attachmentSource)},
                             {"name":"recipient","role":"email address of the recipient","kind":"text"}],
               "uses":[{"step":2,"argument":"target","template":"{invoice}"},{"step":5,"argument":"text","template":"{recipient}"},
                       {"step":7,"argument":"target","template":"{attachment}"}]}}
            """#)])
        return RecallCorpus(json: .object(root), digest: base.digest)
    }

    @Test("an input produced by an earlier part comes with that part; an output the task already holds keeps its producer out")
    func producersOfInputs() async throws {
        let (session, memory) = try await Self.learned(try Self.invoiceCorpus())
        let lacking = try await P.task(P.tools(session, stream: "invoice-lacking"), #"""
            {"operation":"begin","goal":"Download invoice INV-2026-040 and email it to luca@example.com",
             "remaining":"Download invoice INV-2026-040 and email it to luca@example.com",
             "inputs":[{"name":"invoice","value":"INV-2026-040"},{"name":"recipient","value":"luca@example.com"}]}
            """#)
        let made = lacking["recall"]["needs"].array?.first ?? .null
        #expect(made["coverage"].string == "complete", "\(lacking)")
        #expect(Self.steps(lacking).first == 1 && Self.conditions(lacking).contains("input_produced"),
                "the download that produces the attached file is part of the selection: \(Self.steps(lacking)) \(Self.conditions(lacking))")
        let ready = try await P.task(P.tools(session, stream: "invoice-ready"), #"""
            {"operation":"begin","goal":"Email the invoice INV-2026-040 already downloaded to luca@example.com",
             "remaining":"Download invoice INV-2026-040 and email it to luca@example.com",
             "inputs":[{"name":"invoice","value":"INV-2026-040"},
                       {"name":"invoice_file","value":"INV-2026-040.pdf","role":"file of the downloaded invoice",
                        "source":"previous_output","source_ref":"task-0/invoice_file"},
                       {"name":"recipient","value":"luca@example.com"}]}
            """#)
        let need = ready["recall"]["needs"].array?.first ?? .null
        #expect(need["coverage"].string == "complete", "\(ready)")
        #expect(Self.steps(ready).first == 4, "the download is not planned again: \(Self.steps(ready)) \(Self.conditions(ready))")
        #expect(Self.conditions(ready).contains("output_ready"))
        let attachment = (need["selection"]["parameters"].array ?? []).first { $0["name"].string == "attachment" }
        #expect(attachment?["value"].string == "INV-2026-040.pdf" && attachment?["match"].string == "produced")
        await Self.close(session, memory)
    }

    @Test("the attached file equal to the downloaded one, but stated as observed: no relation, the attachment stays to resolve")
    func equalValuesWithoutStatedOrigin() async throws {
        let (session, memory) = try await Self.learned(try Self.invoiceCorpus(attachmentSource: #""source":"observation""#))
        let lacking = try await P.task(P.tools(session, stream: "invoice-unstated"), #"""
            {"operation":"begin","goal":"Download invoice INV-2026-040 and email it to luca@example.com",
             "remaining":"Download invoice INV-2026-040 and email it to luca@example.com",
             "inputs":[{"name":"invoice","value":"INV-2026-040"},{"name":"recipient","value":"luca@example.com"}]}
            """#)
        let made = lacking["recall"]["needs"].array?.first ?? .null
        #expect(made["coverage"].string != "complete", "\(lacking)")
        #expect(!Self.conditions(lacking).contains("input_produced"),
                "equal episodic values are no stated origin: \(Self.steps(lacking)) \(Self.conditions(lacking))")
        await Self.close(session, memory)
    }
}
