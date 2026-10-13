//
//  RecallUseLinkingTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// RecallUseLinkingTests prove that a call is linked to a delivered step, and confirms it, only when the facts show it
/// carried out that step: the same tool in the same application and functional context, on the same element when
/// the observations identify it, with the arguments that define the operation and the values actually bound. The
/// review's counterexamples are kept as they were written: another control, an unresolved parameter, a text that
/// differs in case or accents, another scroll amount. Each call names the step's application and state, so a pass
/// isolates the defect and never rests on refusing a call whose application the facts omit.
@Suite("The Recall links a call to a delivered step only when the facts show it carried it out")
struct RecallUseLinkingTests {

    typealias S = RecallSelectionTests

    // MARK: The review's counterexamples

    @Test("a verified click on Delete does not confirm the recalled click on Export")
    func differentControlDoesNotConfirm() {
        let step = S.step(0, tool: .act, [("target", S.text("Export")), ("verb", S.text("click"))],
                          bundle: S.preview, entry: .state("editor"), exit: .state("editor"))
        let links = RecallUseLinking.link(steps: [step], calls: [
            .init(eventID: "delete-call", request: .act(target: "Delete", verb: .click, value: nil, section: nil), checkPassed: true,
                  bundleID: S.preview, entry: .state("editor"))
        ], values: [:])
        #expect(links.first?.stepPosition == nil, "the local check proves Delete, not the remembered Export")
        #expect(links.first?.confirmed == false)
    }

    @Test("an unresolved input does not match, and confirm, any text the agent happens to type")
    func unresolvedParameterDoesNotConfirm() {
        let step = S.step(0, tool: .typeText, [("target", S.text("Search")), ("text", .parameter("criterion")),
                                               ("replace", .literal(.boolean(true)))],
                          bundle: S.finder, entry: .state("finder"))
        let links = RecallUseLinking.link(steps: [step], calls: [
            .init(eventID: "typed-call", request: .typeText(target: "Search", text: "unrelated", section: nil, replace: true), checkPassed: true,
                  bundleID: S.finder, entry: .state("finder"))
        ], values: [:])
        #expect(links.first?.stepPosition == nil)
        #expect(links.first?.confirmed == false)
    }

    @Test("a text differing in case or accents is not the bound value")
    func changedTextDoesNotConfirm() {
        let step = S.step(0, tool: .typeText, [("target", S.text("Body")), ("text", .parameter("body")),
                                               ("replace", .literal(.boolean(true)))],
                          bundle: "com.apple.Notes", entry: .state("note"))
        let links = RecallUseLinking.link(steps: [step], calls: [
            .init(eventID: "typed-call", request: .typeText(target: "Body", text: "PAYE", section: nil, replace: true), checkPassed: true,
                  bundleID: "com.apple.Notes", entry: .state("note"))
        ], values: ["body": "payé"])
        #expect(links.first?.stepPosition == nil)
        #expect(links.first?.confirmed == false)
    }

    @Test("another scroll amount is an adaptation, not the remembered operation carried out")
    func changedScrollDoesNotConfirm() {
        let step = S.step(0, tool: .scroll, [("direction", S.text("down")), ("lines", .literal(.integer(3))),
                                             ("target", S.text("Results"))],
                          bundle: S.finder, entry: .state("finder"))
        let links = RecallUseLinking.link(steps: [step], calls: [
            .init(eventID: "scroll-call", request: .scroll(direction: .down, lines: 100, target: "Results", section: nil), checkPassed: true,
                  bundleID: S.finder, entry: .state("finder"))
        ], values: [:])
        #expect(links.first?.stepPosition == nil)
        #expect(links.first?.confirmed == false)
    }

    // MARK: The whole matrix

    static let app = "com.example.Editor"
    static let other = "com.example.Other"

    static func one(_ step: RecallSource.Step, _ request: AgentCallRequest, bundle: String? = app, entry: RecallSource.Entry = .state("main"),
                    elementKey: String? = nil, values: [String: String] = [:], passed: Bool = true) -> RecallUseLinking.Link? {
        RecallUseLinking.link(steps: [step], calls: [.init(eventID: "call", request: request, checkPassed: passed, bundleID: bundle,
                                                           entry: entry, elementKey: elementKey)], values: values).first
    }

    static func step(_ tool: AgentTool, _ arguments: [(String, OperationValue)], entry: RecallSource.Entry = .state("main"),
                     elementKey: String? = nil) -> RecallSource.Step {
        S.step(0, tool: tool, arguments, bundle: app, entry: entry, elementKey: elementKey)
    }

    static func linked(_ link: RecallUseLinking.Link?) -> Bool { link?.stepPosition == 0 && link?.confirmed == true }
    static func unlinked(_ link: RecallUseLinking.Link?) -> Bool { link?.stepPosition == nil && link?.confirmed == false }

    @Test("act: each verb and a toggle's state define the operation; another application, control or state is another operation")
    func actMatrix() {
        for verb in [ActionVerb.click, .doubleClick, .tripleClick, .rightClick] {
            let step = Self.step(.act, [("target", S.text("Export")), ("verb", S.text(verb.rawValue))])
            #expect(Self.linked(Self.one(step, .act(target: "Export", verb: verb, value: nil, section: nil))), "\(verb)")
            #expect(Self.unlinked(Self.one(step, .act(target: "Export", verb: verb, value: nil, section: nil), bundle: Self.other)))
            #expect(Self.unlinked(Self.one(step, .act(target: "Export", verb: verb, value: nil, section: nil), bundle: nil)),
                    "an application the facts do not name proves nothing")
            #expect(Self.unlinked(Self.one(step, .act(target: "Delete", verb: verb, value: nil, section: nil))))
            #expect(Self.unlinked(Self.one(step, .act(target: "Export", verb: verb, value: nil, section: nil), entry: .state("other"))),
                    "another functional state is another context")
        }
        let click = Self.step(.act, [("target", S.text("Export")), ("verb", S.text("click"))])
        #expect(Self.unlinked(Self.one(click, .act(target: "Export", verb: .doubleClick, value: nil, section: nil))))
        #expect(Self.one(click, .act(target: "export", verb: .click, value: nil, section: nil), entry: .unknown)?.stepPosition == 0,
                "a label as the screen spells it, and a context the facts do not state, do not refuse the link")
        let failed = Self.one(click, .act(target: "Export", verb: .click, value: nil, section: nil), passed: false)
        #expect(failed?.stepPosition == 0 && failed?.confirmed == false, "carried out, not confirmed: its own check did not pass")
        let toggle = Self.step(.act, [("target", S.text("Show Preview")), ("verb", S.text("set_toggle")), ("value", S.text("on"))])
        #expect(Self.linked(Self.one(toggle, .act(target: "Show Preview", verb: .setToggle, value: .on, section: nil))))
        #expect(Self.unlinked(Self.one(toggle, .act(target: "Show Preview", verb: .setToggle, value: .off, section: nil))))
    }

    @Test("select and context_menu: the item chosen defines the operation, as the application shows it")
    func choiceMatrix() {
        let select = Self.step(.select, [("control", S.text("Format")), ("item", .parameter("format"))])
        #expect(Self.linked(Self.one(select, .select(control: "Format", item: "PNG"), values: ["format": "PNG"])))
        #expect(Self.linked(Self.one(select, .select(control: "Format", item: "png"), values: ["format": "PNG"])))
        #expect(Self.unlinked(Self.one(select, .select(control: "Format", item: "TIFF"), values: ["format": "PNG"])))
        #expect(Self.unlinked(Self.one(select, .select(control: "Quality", item: "PNG"), values: ["format": "PNG"])))
        #expect(Self.unlinked(Self.one(select, .select(control: "Format", item: "PNG"))), "an unbound choice matches nothing")
        let menu = Self.step(.contextMenu, [("target", S.text("Progetto")), ("item", S.text("Compress"))])
        #expect(Self.linked(Self.one(menu, .contextMenu(target: "Progetto", item: "Compress", section: nil))))
        #expect(Self.unlinked(Self.one(menu, .contextMenu(target: "Progetto", item: "Rename", section: nil))))
        #expect(Self.unlinked(Self.one(menu, .contextMenu(target: "Archivio", item: "Compress", section: nil))))
    }

    @Test("type_text and insert_text: the text is the person's, exactly; a template needs every value; another field is another step")
    func textMatrix() {
        let typed = Self.step(.typeText, [("target", S.text("Name")),
                                          ("text", .template([.parameter("name"), .literal("."), .parameter("ext")])),
                                          ("replace", .literal(.boolean(true)))])
        let values = ["name": "relazione_finale", "ext": "pdf"]
        #expect(Self.linked(Self.one(typed, .typeText(target: "Name", text: "relazione_finale.pdf", section: nil, replace: true), values: values)))
        #expect(Self.unlinked(Self.one(typed, .typeText(target: "Name", text: "Relazione_Finale.pdf", section: nil, replace: true), values: values)))
        #expect(Self.unlinked(Self.one(typed, .typeText(target: "Name", text: "relazione_finale.pdf", section: nil, replace: false), values: values)))
        #expect(Self.unlinked(Self.one(typed, .typeText(target: "Name", text: "relazione_finale.pdf", section: nil, replace: true),
                                       values: ["name": "relazione_finale"])), "a template with a value missing matches nothing")
        #expect(Self.unlinked(Self.one(typed, .typeText(target: "Subject", text: "relazione_finale.pdf", section: nil, replace: true), values: values)))
        let composed = "caf\u{0065}\u{0301}", precomposed = "caf\u{00E9}"
        let note = Self.step(.insertText, [("text", .parameter("body"))])
        #expect(Self.linked(Self.one(note, .insertText(text: precomposed, expectedValue: nil), values: ["body": composed])),
                "canonically equivalent text is the same text")
        #expect(Self.unlinked(Self.one(note, .insertText(text: "cafe", expectedValue: nil), values: ["body": composed])))
    }

    @Test("a field labelled by its value: the same functional element under another label is the step; without that proof it is not")
    func dynamicTarget() {
        let typed = Self.step(.typeText, [("target", S.text("foto_demo.png")), ("text", .parameter("name")),
                                          ("replace", .literal(.boolean(true)))], entry: .state("dialog"), elementKey: "field|dialog|1")
        let request = AgentCallRequest.typeText(target: "Untitled", text: "foto_mail.png", section: nil, replace: true)
        #expect(Self.linked(Self.one(typed, request, entry: .state("dialog"), elementKey: "field|dialog|1", values: ["name": "foto_mail.png"])),
                "the Brain identifies the same field, whatever its value shows")
        #expect(Self.unlinked(Self.one(typed, request, entry: .state("dialog"), elementKey: "field|dialog|2", values: ["name": "foto_mail.png"])),
                "another functional element")
        #expect(Self.unlinked(Self.one(typed, request, entry: .state("dialog"), values: ["name": "foto_mail.png"])),
                "an equivalence the facts do not prove stays unknown and confirms nothing")
    }

    @Test("a row template is what every row offers: the row is told by its label, and a target the task gives is its value")
    func itemTemplateMatrix() {
        let template = "item_template|/results|row|"
        let click = AgentCallRequest.act(target: "Invoice-123", verb: .click, value: nil, section: nil)
        let other = AgentCallRequest.act(target: "Invoice-999", verb: .click, value: nil, section: nil)
        let bound = Self.step(.act, [("target", .parameter("record")), ("verb", S.text("click"))], elementKey: template)
        #expect(Self.linked(Self.one(bound, click, elementKey: template, values: ["record": "Invoice-123"])))
        #expect(Self.unlinked(Self.one(bound, other, elementKey: template, values: ["record": "Invoice-123"])), "another row, the wrong record")
        #expect(Self.unlinked(Self.one(bound, click, elementKey: template)), "an unresolved record matches no row")
        #expect(Self.unlinked(Self.one(bound, click, elementKey: "item_template|/archive|row|", values: ["record": "Invoice-123"])),
                "another collection's rows")
        let unidentified = Self.one(bound, other, elementKey: nil, values: ["record": "Invoice-123"])
        #expect(Self.unlinked(unidentified) && unidentified?.undetermined == false, "a wrong record is no missing fact")
        let fixed = Self.step(.act, [("target", S.text("Inbox")), ("verb", S.text("click"))], elementKey: template)
        #expect(Self.linked(Self.one(fixed, .act(target: "Inbox", verb: .click, value: nil, section: nil), elementKey: template)))
        #expect(Self.unlinked(Self.one(fixed, .act(target: "Archive", verb: .click, value: nil, section: nil), elementKey: template)),
                "the template says a row was clicked; the label says it was another row")
        let control = "control|/toolbar|button|share"
        let shared = Self.step(.act, [("target", .parameter("record")), ("verb", S.text("click"))], elementKey: control)
        #expect(Self.unlinked(Self.one(shared, other, elementKey: control, values: ["record": "Invoice-123"])),
                "a control's identity does not make another value the task's")
        #expect(Self.unlinked(Self.one(shared, click, elementKey: control)), "nor bind a value the task left unresolved")
    }

    @Test("a parameter of a number or a flag matches the value its binding spells as that type; a text of digits stays a text")
    func typedParameters() {
        let scroll = Self.step(.scroll, [("direction", S.text("down")), ("lines", .parameter("amount")), ("target", S.text("Results"))])
        let three = AgentCallRequest.scroll(direction: .down, lines: 3, target: "Results", section: nil)
        #expect(Self.linked(Self.one(scroll, three, values: ["amount": "3"])))
        #expect(Self.unlinked(Self.one(scroll, three, values: ["amount": "4"])))
        #expect(Self.unlinked(Self.one(scroll, three)), "an unbound amount matches nothing")
        #expect(Self.unlinked(Self.one(scroll, three, values: ["amount": "3.0"])), "not an integer's spelling")
        #expect(Self.unlinked(Self.one(scroll, three, values: ["amount": "three"])))
        let key = Self.step(.pressKey, [("key", S.text("down")), ("count", .parameter("times"))])
        #expect(Self.linked(Self.one(key, .pressKey(key: .down, modifiers: [], count: 5), values: ["times": "5"])))
        #expect(Self.unlinked(Self.one(key, .pressKey(key: .down, modifiers: [], count: 5), values: ["times": "6"])))
        let drag = Self.step(.drag, [("from", S.text("Slider")), ("dx", .parameter("dx")), ("dy", .parameter("dy"))])
        #expect(Self.linked(Self.one(drag, .drag(from: "Slider", to: .offset(dx: 12.5, dy: -3), section: nil), values: ["dx": "12.5", "dy": "-3"])))
        #expect(Self.unlinked(Self.one(drag, .drag(from: "Slider", to: .offset(dx: 12.5, dy: -3), section: nil), values: ["dx": "12.5", "dy": "3"])))
        #expect(Self.unlinked(Self.one(drag, .drag(from: "Slider", to: .offset(dx: 12.5, dy: -3), section: nil), values: ["dx": "12.5"])),
                "an axis without its value")
        let typed = Self.step(.typeText, [("target", S.text("Name")), ("text", S.text("x")), ("replace", .parameter("replace"))])
        let replacing = AgentCallRequest.typeText(target: "Name", text: "x", section: nil, replace: true)
        #expect(Self.linked(Self.one(typed, replacing, values: ["replace": "true"])))
        #expect(Self.unlinked(Self.one(typed, replacing, values: ["replace": "false"])))
        #expect(Self.unlinked(Self.one(typed, replacing, values: ["replace": "yes"])), "only true and false spell a flag")
        let file = Self.step(.typeText, [("target", S.text("Name")), ("text", .parameter("name")), ("replace", .literal(.boolean(true)))])
        #expect(Self.linked(Self.one(file, .typeText(target: "Name", text: "0042", section: nil, replace: true), values: ["name": "0042"])))
        #expect(Self.unlinked(Self.one(file, .typeText(target: "Name", text: "42", section: nil, replace: true), values: ["name": "0042"])),
                "a file name of digits is compared as written, never as a number")
    }

    @Test("a call that would carry out the step were its missing facts to agree is undetermined: neither confirmed nor a deviation")
    func undeterminedUse() {
        let click = Self.step(.act, [("target", S.text("Export")), ("verb", S.text("click"))])
        let request = AgentCallRequest.act(target: "Export", verb: .click, value: nil, section: nil)
        let unrecorded = Self.one(click, request, bundle: nil)
        #expect(Self.unlinked(unrecorded) && unrecorded?.undetermined == true, "its application was not recorded")
        let elsewhere = Self.one(click, request, bundle: Self.other)
        #expect(Self.unlinked(elsewhere) && elsewhere?.undetermined == false, "another application is a deviation, not an unknown")
        let typed = Self.step(.typeText, [("target", S.text("foto_demo.png")), ("text", .parameter("name")),
                                          ("replace", .literal(.boolean(true)))], entry: .state("dialog"), elementKey: "field|dialog|1")
        let renamed = AgentCallRequest.typeText(target: "Untitled", text: "foto_mail.png", section: nil, replace: true)
        let unidentified = Self.one(typed, renamed, entry: .state("dialog"), values: ["name": "foto_mail.png"])
        #expect(Self.unlinked(unidentified) && unidentified?.undetermined == true, "the element's identity was not derived")
        let otherText = Self.one(typed, .typeText(target: "Untitled", text: "altro.png", section: nil, replace: true), entry: .state("dialog"),
                                 values: ["name": "foto_mail.png"])
        #expect(otherText?.undetermined == false, "another text is another operation whatever the facts")
    }

    @Test("press_key: the key, its modifiers in any order and the count define the operation")
    func keyMatrix() {
        let key = Self.step(.pressKey, [("key", S.text("f")), ("modifiers", S.text("cmd")), ("modifiers", S.text("opt")),
                                        ("count", .literal(.integer(1)))])
        #expect(Self.linked(Self.one(key, .pressKey(key: .character("f"), modifiers: [.opt, .cmd], count: 1))))
        #expect(Self.unlinked(Self.one(key, .pressKey(key: .character("f"), modifiers: [.cmd], count: 1))))
        #expect(Self.unlinked(Self.one(key, .pressKey(key: .character("f"), modifiers: [.cmd, .opt], count: 2))))
        #expect(Self.unlinked(Self.one(key, .pressKey(key: .character("g"), modifiers: [.cmd, .opt], count: 1))))
    }

    @Test("scroll and drag: the amount, the area, the ends and the offset define the operation")
    func motionMatrix() {
        let scroll = Self.step(.scroll, [("direction", S.text("down")), ("lines", .literal(.integer(3))), ("target", S.text("Results"))])
        #expect(Self.linked(Self.one(scroll, .scroll(direction: .down, lines: 3, target: "Results", section: nil))))
        #expect(Self.unlinked(Self.one(scroll, .scroll(direction: .up, lines: 3, target: "Results", section: nil))))
        #expect(Self.unlinked(Self.one(scroll, .scroll(direction: .down, lines: 3, target: "Sidebar", section: nil))))
        #expect(Self.unlinked(Self.one(scroll, .scroll(direction: .down, lines: 3, target: nil, section: nil))), "the window is another area")
        let drag = Self.step(.drag, [("from", S.text("report.pdf")), ("to", S.text("Archive"))])
        #expect(Self.linked(Self.one(drag, .drag(from: "report.pdf", to: .target("Archive"), section: nil))))
        #expect(Self.unlinked(Self.one(drag, .drag(from: "report.pdf", to: .target("Trash"), section: nil))))
        #expect(Self.unlinked(Self.one(drag, .drag(from: "notes.pdf", to: .target("Archive"), section: nil))))
        let offset = Self.step(.drag, [("from", S.text("Slider")), ("dx", .literal(.real(40))), ("dy", .literal(.real(0)))])
        #expect(Self.linked(Self.one(offset, .drag(from: "Slider", to: .offset(dx: 40, dy: 0), section: nil))))
        #expect(Self.unlinked(Self.one(offset, .drag(from: "Slider", to: .offset(dx: 80, dy: 0), section: nil))))
        #expect(Self.unlinked(Self.one(offset, .drag(from: "Slider", to: .target("Archive"), section: nil))))
    }

    @Test("menu and press: the command path and the button define the operation")
    func commandMatrix() {
        let menu = Self.step(.menu, [("path", S.text("File > Export…"))])
        #expect(Self.linked(Self.one(menu, .menu(path: "File > Export…"))))
        #expect(Self.linked(Self.one(menu, .menu(path: "file > export…"))))
        #expect(Self.unlinked(Self.one(menu, .menu(path: "File > Export As…"))))
        #expect(Self.unlinked(Self.one(menu, .menu(path: "File > Export…"), bundle: Self.other)))
        let press = Self.step(.press, [("button", S.text("Save"))])
        #expect(Self.linked(Self.one(press, .press(button: "Save"))))
        #expect(Self.unlinked(Self.one(press, .press(button: "Don't Save"))))
    }

    @Test("a batch's children are calls of their own and link like any call; the batch is no operation step")
    func batchChildren() {
        let steps = [S.step(0, tool: .act, [("target", S.text("Bold")), ("verb", S.text("click"))], bundle: Self.app, entry: .state("main")),
                     S.step(1, tool: .typeText, [("target", S.text("Body")), ("text", .parameter("body")), ("replace", .literal(.boolean(true)))],
                            bundle: Self.app, entry: .state("main"))]
        let links = RecallUseLinking.link(steps: steps, calls: [
            .init(eventID: "batch", request: .batch, checkPassed: true, bundleID: Self.app, entry: .state("main")),
            .init(eventID: "child-1", request: .act(target: "Bold", verb: .click, value: nil, section: nil), checkPassed: true,
                  bundleID: Self.app, entry: .state("main")),
            .init(eventID: "child-2", request: .typeText(target: "Body", text: "Ciao", section: nil, replace: true), checkPassed: false,
                  bundleID: Self.app, entry: .state("main")),
        ], values: ["body": "Ciao"])
        #expect(links.map(\.stepPosition) == [nil, 0, 1])
        #expect(links.map(\.confirmed) == [false, true, false], "the second child ran but its own check did not pass")
    }
}
