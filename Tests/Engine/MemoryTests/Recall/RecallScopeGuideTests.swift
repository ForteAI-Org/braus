//
//  RecallScopeGuideTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import Testing

/// RecallScopeGuideTests prove the delimitation rule on the cases the second review's mandate names, on versions built by
/// hand: the selection runs from the first episode the need names to the last, an episode is named by a word of the need
/// no other episode of the version holds (or by a value of the task the need mentions that only it reads), the work
/// before is stated, never repeated unasked, the work after is left out, and a need whose words name no episode gets
/// nothing from the version. The relevances given are flat on purpose: the rule must not depend on them.
@Suite("The Recall selects the episodes the need names, and states the rest")
struct RecallScopeGuideTests {

    typealias S = RecallSelectionTests
    static let contacts = "com.apple.AddressBook"
    static let music = "com.apple.Music"

    /// A contact created with a phone number, then shared from the list: one block, two episodes.
    static func contact() -> RecallSource {
        let steps = [
            S.step(0, part: "c", tool: .act, [("target", S.text("New Contact"))], bundle: contacts, entry: .state("list"), exit: .state("card"),
                   label: "Start a new contact"),
            S.step(1, part: "c", tool: .typeText, [("target", S.text("First name")), ("text", .parameter("first"))], bundle: contacts,
                   entry: .state("card"), label: "Type <first_name> as the first name"),
            S.step(2, part: "c", tool: .typeText, [("target", S.text("Last name")), ("text", .parameter("last"))], bundle: contacts,
                   entry: .state("card"), label: "Type <last_name> as the last name"),
            S.step(3, part: "c", tool: .typeText, [("target", S.text("Phone")), ("text", .parameter("phone"))], bundle: contacts,
                   entry: .state("card"), label: "Type <phone> as the phone number"),
            S.step(4, part: "c", tool: .press, [("button", S.text("Done"))], bundle: contacts, entry: .state("card"), exit: .state("list"),
                   label: "Save the new contact"),
            S.step(5, part: "c", tool: .contextMenu, [("target", .template([.parameter("first"), .literal(" "), .parameter("last")])),
                                                      ("item", S.text("Share Contact"))], bundle: contacts, entry: .state("list"),
                   exit: .state("list"), label: "Share the contact card"),
        ]
        let parts = [RecallSource.Part(partID: "c/procedure", kind: .procedure, firstPosition: 0, lastPosition: 5,
                                       label: "Add <first_name> <last_name> with phone <phone> to Contacts and share the card",
                                       bundleID: contacts, isOffered: true)]
            + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                            label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: "c", procedureLabel: parts[0].label ?? "", steps: steps, parts: parts, parameters: [
            S.parameter("first", "first_name", role: "first name of the person"),
            S.parameter("last", "last_name", role: "last name of the person"),
            S.parameter("phone", "phone", role: "phone number of the person"),
        ], confirmedUses: 0)
    }

    /// A playlist created, then selected, then a song added to it: one block, three episodes.
    static func playlist() -> RecallSource {
        let steps = [
            S.step(0, part: "m", tool: .menu, [("path", S.text("File > New > Playlist"))], bundle: music, entry: .state("library"),
                   exit: .state("sheet"), label: "Open the new playlist sheet"),
            S.step(1, part: "m", tool: .typeText, [("target", S.text("Playlist name")), ("text", .parameter("name"))], bundle: music,
                   entry: .state("sheet"), label: "Type <playlist_name> as the playlist's name"),
            S.step(2, part: "m", tool: .press, [("button", S.text("Create"))], bundle: music, entry: .state("sheet"), exit: .state("library"),
                   label: "Create the playlist"),
            S.step(3, part: "m", tool: .act, [("target", .parameter("name"))], bundle: music, entry: .state("library"), exit: .state("library"),
                   label: "Select the playlist <playlist_name>"),
            S.step(4, part: "m", tool: .act, [("target", S.text("Add Songs"))], bundle: music, entry: .state("library"), exit: .state("songs"),
                   label: "Open the song picker"),
            S.step(5, part: "m", tool: .act, [("target", .parameter("song"))], bundle: music, entry: .state("songs"), label: "Pick <song>"),
            S.step(6, part: "m", tool: .press, [("button", S.text("Add"))], bundle: music, entry: .state("songs"), exit: .state("library"),
                   label: "Add the song to the playlist"),
        ]
        let parts = [RecallSource.Part(partID: "m/procedure", kind: .procedure, firstPosition: 0, lastPosition: 6,
                                       label: "Create the playlist <playlist_name> and add <song> to it", bundleID: music, isOffered: true)]
            + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                            label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: "m", procedureLabel: parts[0].label ?? "", steps: steps, parts: parts, parameters: [
            S.parameter("name", "playlist_name", role: "name of the playlist"),
            S.parameter("song", "song", role: "title of the song to add"),
        ], confirmedUses: 0)
    }

    static func flat(_ source: RecallSource) -> ScoredSource {
        S.scored(source, steps: Dictionary(uniqueKeysWithValues: source.steps.map { ($0.position, 0.7) }),
                 parts: Dictionary(uniqueKeysWithValues: source.parts.filter { $0.kind != .step }.map { ($0.partID, 0.9) }))
    }

    static let marco = [S.value("first_name", "Marco"), S.value("last_name", "Rossi"), S.value("phone", "+39 333 1234567")]

    @Test("creating a contact without sharing it: the sharing at the end is no part of the need, even with the whole relevant")
    func contactWithoutSharing() throws {
        let outcome = S.select([Self.flat(Self.contact())], need: "Add Marco Rossi to Contacts with the phone number +39 333 1234567",
                               values: Self.marco)
        let selected = try #require(outcome.selected)
        #expect(selected.positions == 0...4 && outcome.coverage == .complete, "the phone names the card's episode; a name typed and shared names neither")
        let shared = try #require(S.select([Self.flat(Self.contact())], need: "Add Marco Rossi with phone +39 333 1234567 and share his card",
                                           values: Self.marco).selected)
        #expect(shared.positions == 0...5 && shared.wholePartID == "c/procedure", "the sharing asked by its own words")
    }

    @Test("adding a song to a playlist that exists: the creation is stated as done before, not repeated")
    func existingPlaylist() throws {
        let values = [S.value("playlist_name", "Estate 2026"), S.value("song", "Volare")]
        let outcome = S.select([Self.flat(Self.playlist())], need: "My playlist Estate 2026 is selected: add the song Volare to it",
                               values: values)
        let selected = try #require(outcome.selected)
        #expect(selected.positions.lowerBound >= 3 && selected.positions.upperBound == 6 && outcome.coverage == .complete)
        #expect(selected.requirements.contains { $0.kind == .preparedBefore && $0.stepPosition == 2 }, "the creation the source did first is named")
        let created = try #require(S.select([Self.flat(Self.playlist())], need: "Create the playlist Inverno and add the song Volare to it",
                                            values: [S.value("playlist_name", "Inverno"), S.value("song", "Volare")]).selected)
        #expect(created.positions == 0...6, "the creation asked by its own word")
    }

    @Test("renaming, deleting or opening a playlist is not creating one: words every episode shares name no work")
    func renameIsNotCreate() {
        for need in ["Rename the playlist Estate 2026 to Inverno", "Delete the playlist Estate 2026", "Open the playlist Estate 2026"] {
            let outcome = S.select([Self.flat(Self.playlist())], need: need,
                                   values: [S.value("playlist_name", "Estate 2026"), S.value("new_name", "Inverno")])
            #expect(outcome.coverage == .absent && outcome.selected == nil, "\(need)")
        }
    }

    @Test("a need that names work before the state the session shows: the observation will not hold then, the version is read whole")
    func observationBehindTheNamedWork() throws {
        let observed: Set<ObservedState> = [ObservedState(bundleID: S.preview, sceneID: "dialog")]
        let format = [S.value("output_format", "TIFF")]
        let inDialog = try #require(S.select([Self.flat(S.photo())], need: "Choose TIFF as the format", values: format, observed: observed).selected)
        #expect(inDialog.positions == 5...5 && inDialog.requirements.first?.kind == .observedState)
        let rotated = try #require(S.select([Self.flat(S.photo())], need: "Rotate the image right and choose TIFF as the format",
                                            values: format, observed: observed).selected)
        #expect(rotated.positions == 2...6, "the dialog open now will be closed by the rotation: it is opened again and confirmed")
        #expect(!rotated.requirements.contains { $0.kind == .observedState }, "no step starts from the state shown")
    }

    @Test("a value the need mentions names the episode that alone reads it; one several episodes read names none; a value the need does not mention names nothing")
    func valuesNameTheirEpisode() throws {
        let phone = try #require(S.select([Self.flat(Self.contact())], need: "Save the number +39 333 1234567 for Marco Rossi",
                                          values: Self.marco).selected)
        #expect(phone.positions == 0...4)
        let names = S.select([Self.flat(Self.contact())], need: "Marco Rossi", values: Self.marco)
        #expect(names.selected == nil, "first and last name are read by the card and by the sharing")
        let rotate = try #require(S.select([Self.flat(S.photo())], need: "Rotate the open image to the right", values: S.exportValues).selected)
        #expect(rotate.positions == 2...2, "the task's export values are not mentioned by this need")
    }

    // MARK: Found by the third final (development since)

    static let keynote = "com.apple.iWork.Keynote"

    /// A slide selected, exported as PNG through a dialog, the dialog's states known or not.
    static func slide(knownDialog: Bool) -> RecallSource {
        let dialog: RecallSource.Entry = knownDialog ? .state("export") : .unknown
        let steps = [
            S.step(0, part: "k", tool: .act, [("target", .template([.literal("Slide "), .parameter("number")]))], bundle: keynote,
                   entry: .state("deck"), exit: .state("deck"), label: "Select slide <slide_number>"),
            S.step(1, part: "k", tool: .menu, [("path", S.text("File > Export To > Images…"))], bundle: keynote, entry: .state("deck"),
                   exit: dialog, label: "Open the Export To Images dialog"),
            S.step(2, part: "k", tool: .select, [("control", S.text("Format")), ("item", S.text("PNG"))], bundle: keynote, entry: dialog,
                   label: "Choose PNG as the image format"),
            S.step(3, part: "k", tool: .typeText, [("target", S.text("Save As")), ("text", .parameter("name"))], bundle: keynote, entry: dialog,
                   label: "Type <image_name> as the file name"),
            S.step(4, part: "k", tool: .press, [("button", S.text("Export"))], bundle: keynote, entry: dialog, exit: .state("deck"),
                   label: "Export the slide image"),
        ]
        let parts = [RecallSource.Part(partID: "k/procedure", kind: .procedure, firstPosition: 0, lastPosition: 4,
                                       label: "Export slide <slide_number> as a PNG image named <image_name>", bundleID: keynote, isOffered: true)]
            + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                            label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: "k", procedureLabel: parts[0].label ?? "", steps: steps, parts: parts, parameters: [
            S.parameter("number", "slide_number", role: "number of the slide"),
            S.parameter("name", "image_name", role: "name of the exported image without extension"),
        ], confirmedUses: 0)
    }

    @Test("a fixed choice the task contradicts, in a dialog whose states were not recorded, takes the uncertain steps around it along")
    func exclusionOverUncertainEpisodes() {
        let values = [S.value("slide_number", "2"), S.value("image_name", "intro"), S.value("image_format", "JPEG", role: "format of the exported image")]
        let outcome = S.select([Self.flat(Self.slide(knownDialog: false))], need: "Export slide 2 of the presentation as a JPEG image named intro",
                               values: values)
        #expect(outcome.selected == nil && outcome.coverage == .absent, "no step of the dialog is delivered alone")
        #expect(outcome.excluded.contains { $0.requirements.contains { $0.kind == .certainConflict } })
    }

    @Test("a short number the need mentions names the step that alone reads it: the slide is selected before it is exported")
    func shortNumbersAreMentions() throws {
        let values = [S.value("slide_number", "2"), S.value("image_name", "intro")]
        let selected = try #require(S.select([Self.flat(Self.slide(knownDialog: true))], need: "Export slide 2 of the presentation as a PNG image named intro",
                                             values: values).selected)
        #expect(selected.positions == 0...4, "\(selected.positions)")
    }

    /// An event created, then an invitation sent from it: one block, two episodes.
    static func event() -> RecallSource {
        let calendar = "com.apple.iCal"
        let steps = [
            S.step(0, part: "e", tool: .act, [("target", S.text("New Event"))], bundle: calendar, entry: .state("week"), exit: .state("sheet"),
                   label: "Start a new event"),
            S.step(1, part: "e", tool: .typeText, [("target", S.text("Title")), ("text", .parameter("title"))], bundle: calendar,
                   entry: .state("sheet"), label: "Type <event_title> as the event's title"),
            S.step(2, part: "e", tool: .typeText, [("target", S.text("Date")), ("text", .parameter("date"))], bundle: calendar,
                   entry: .state("sheet"), label: "Type <event_date> as the date"),
            S.step(3, part: "e", tool: .press, [("button", S.text("Add"))], bundle: calendar, entry: .state("sheet"), exit: .state("week"),
                   label: "Add the event to the calendar"),
            S.step(4, part: "e", tool: .act, [("target", .parameter("title"))], bundle: calendar, entry: .state("week"), exit: .state("details"),
                   label: "Open the event <event_title>"),
            S.step(5, part: "e", tool: .typeText, [("target", S.text("Invitees")), ("text", .parameter("invitee"))], bundle: calendar,
                   entry: .state("details"), label: "Type <invitee> as an invitee"),
            S.step(6, part: "e", tool: .press, [("button", S.text("Send"))], bundle: calendar, entry: .state("details"), exit: .state("week"),
                   label: "Send the invitation"),
        ]
        let parts = [RecallSource.Part(partID: "e/procedure", kind: .procedure, firstPosition: 0, lastPosition: 6,
                                       label: "Create the event <event_title> on <event_date> and invite <invitee>", bundleID: calendar, isOffered: true)]
            + steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                            label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: "e", procedureLabel: parts[0].label ?? "", steps: steps, parts: parts, parameters: [
            S.parameter("title", "event_title", role: "title of the event"),
            S.parameter("date", "event_date", role: "date of the event"),
            S.parameter("invitee", "invitee", role: "email address of the person invited"),
        ], confirmedUses: 0)
    }

    @Test("a need that shares only the object every episode works on names no work, whatever values it mentions: moving is not creating")
    func objectWordsAndValuesNameNoWork() throws {
        let outcome = S.select([Self.flat(Self.event())], need: "Move the event Riunione budget to 2026-10-21",
                               values: [S.value("event_title", "Riunione budget"), S.value("event_date", "2026-10-21")])
        #expect(outcome.selected == nil && outcome.coverage == .absent, "the date is read by the creation alone, but no word asks for it")
    }

    @Test("the work a procedure's label names and no step spells is recognized: the values then name the episode that reads them")
    func labelWordsRecognizeTheWork() throws {
        let need = "Create the event Pranzo on 2026-11-03"
        let values = [S.value("event_title", "Pranzo"), S.value("event_date", "2026-11-03")]
        let created = try #require(S.select([Self.flat(Self.event())], need: need, values: values).selected)
        #expect(created.positions == 0...3, "\(created.positions)")
        let unlabelled = Self.event()
        let bare = RecallSource(routeID: unlabelled.routeID, procedureLabel: "", steps: unlabelled.steps,
                                parts: unlabelled.parts.map { $0.kind == .procedure ? RecallSource.Part(partID: $0.partID, kind: .procedure,
                                    firstPosition: $0.firstPosition, lastPosition: $0.lastPosition, label: nil, bundleID: $0.bundleID, isOffered: true) : $0 },
                                parameters: unlabelled.parameters, confirmedUses: 0)
        #expect(S.select([Self.flat(bare)], need: need, values: values).selected == nil, "without the label no word names the creation")
    }

    /// The invoice downloaded from the supplier's portal, alone or followed by an email that sends it.
    static func download(routeID: String, mailing: Bool) -> RecallSource {
        let safari = "com.apple.Safari", mail = "com.apple.mail"
        var steps = [
            S.step(0, part: routeID, tool: .act, [("target", S.text("Invoices"))], bundle: safari, entry: .state("portal"), exit: .state("list"),
                   label: "Open the supplier portal's invoices"),
            S.step(1, part: routeID, tool: .act, [("target", .parameter("invoice"))], bundle: safari, entry: .state("list"), exit: .state("list"),
                   label: "Select the invoice <invoice>"),
            S.step(2, part: routeID, tool: .press, [("button", S.text("Download PDF"))], bundle: safari, entry: .state("list"),
                   exit: .state("portal"), label: "Download the invoice as PDF"),
        ]
        var parameters = [S.parameter("invoice", "invoice", role: "number of the invoice")]
        if mailing {
            steps += [
                S.step(3, part: routeID, tool: .act, [("target", S.text("New Message"))], bundle: mail, entry: .state("inbox"),
                       exit: .state("compose"), label: "Start a new message"),
                S.step(4, part: routeID, tool: .typeText, [("target", S.text("To")), ("text", .parameter("recipient"))], bundle: mail,
                       entry: .state("compose"), label: "Type <recipient> as the recipient"),
                S.step(5, part: routeID, tool: .press, [("button", S.text("Send"))], bundle: mail, entry: .state("compose"), exit: .state("inbox"),
                       label: "Send the email with the invoice"),
            ]
            parameters.append(S.parameter("recipient", "recipient", role: "email address the invoice is sent to"))
        }
        let label = mailing ? "Download invoice <invoice> and email it to <recipient>" : "Download invoice <invoice> from the supplier portal"
        var parts = [RecallSource.Part(partID: routeID + "/procedure", kind: .procedure, firstPosition: 0, lastPosition: steps.count - 1,
                                       label: label, bundleID: safari, isOffered: true)]
        if mailing {
            parts.append(RecallSource.Part(partID: routeID + "/download", kind: .subprocedure, firstPosition: 0, lastPosition: 2,
                                           label: "Download invoice <invoice> from the supplier portal", bundleID: safari, isOffered: true))
        }
        parts += steps.map { RecallSource.Part(partID: $0.partID, kind: .step, firstPosition: $0.position, lastPosition: $0.position,
                                               label: $0.label, bundleID: $0.bundleID, isOffered: true) }
        return RecallSource(routeID: routeID, procedureLabel: label, steps: steps, parts: parts, parameters: parameters, confirmedUses: 0)
    }

    @Test("between proposals equal in coverage, preparations, evidence and relevance, the version learned for that work alone comes first, whatever its id")
    func equalProposalsByContent() throws {
        let values = [S.value("invoice", "INV-7")]
        let need = "Download invoice INV-7 from the supplier portal"
        for (long, short) in [("a-mailing", "z-alone"), ("z-mailing", "a-alone")] {
            let sources = [Self.flat(Self.download(routeID: long, mailing: true)), Self.flat(Self.download(routeID: short, mailing: false))]
            let selected = try #require(S.select(sources, need: need, values: values).selected)
            #expect(selected.routeID == short && selected.positions == 0...2, "\(selected.routeID) \(selected.positions)")
            let mailing = try #require(S.select([sources[0]], need: need, values: values).selected, "the longer version serves the need too")
            #expect(mailing.positions == 0...2)
        }
    }
}
