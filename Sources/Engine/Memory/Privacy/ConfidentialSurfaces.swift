//
//  ConfidentialSurfaces.swift
//  Braus
//

import Foundation
import PerceptionCore

/// ConfidentialSurface is a kind of application or site whose content is the person's correspondence or records:
/// mail, messages, notes, contacts, calendars and reminders. What the person wrote or received there is confidential
/// content (P1-06): the live answer to the model carries it, so the model can do the task, and no persistent destination
/// of the memory keeps it. The archive's arguments, results, messages, errors, samples, targets and effects, the Brain,
/// the procedures and the Recall built from them, and the tools' transcript all keep the marker in its place, with a
/// `confidential_content` gap. The structure stays: roles, kinds, positions, states and the labels of the application's
/// own controls, so learning keeps the shape of the window without its content.
public enum ConfidentialSurface: String, Sendable, Equatable, Hashable, CaseIterable {
    case mail, messages, notes, contacts, calendar, reminders
}

/// ConfidentialSurfaces is the policy that names the confidential surfaces and, on one of them, which elements of a
/// scene are content. It is conservative where it cannot tell: an element is content unless it reads as one of the
/// application's own controls, so a mailbox name or a list's heading may be withheld with the messages they hold.
public enum ConfidentialSurfaces {

    /// The native applications whose windows show correspondence or records, by bundle ID.
    public static let applications: [String: ConfidentialSurface] = [
        "com.apple.mail"                     : .mail,
        "com.microsoft.Outlook"              : .mail,
        "com.readdle.smartemail-Mac"         : .mail,
        "org.mozilla.thunderbird"            : .mail,
        "com.apple.MobileSMS"                : .messages,
        "net.whatsapp.WhatsApp"              : .messages,
        "ru.keepcoder.Telegram"              : .messages,
        "org.whispersystems.signal-desktop"  : .messages,
        "com.tinyspeck.slackmacgap"          : .messages,
        "com.microsoft.teams2"               : .messages,
        "com.apple.Notes"                    : .notes,
        "net.shinyfrog.bear"                 : .notes,
        "md.obsidian"                        : .notes,
        "com.apple.AddressBook"              : .contacts,
        "com.apple.iCal"                     : .calendar,
        "com.apple.reminders"                : .reminders,
    ]

    /// The sites whose pages show correspondence or records, by host as a web scene names it (`web:<host>`, without
    /// `www.`). A subdomain of one of them is the same surface.
    public static let webHosts: [String: ConfidentialSurface] = [
        "mail.google.com"     : .mail,
        "outlook.live.com"    : .mail,
        "outlook.office.com"  : .mail,
        "outlook.office365.com": .mail,
        "mail.yahoo.com"      : .mail,
        "mail.proton.me"      : .mail,
        "app.fastmail.com"    : .mail,
        "icloud.com"          : .mail,
        "web.whatsapp.com"    : .messages,
        "messages.google.com" : .messages,
        "web.telegram.org"    : .messages,
        "app.slack.com"       : .messages,
        "teams.microsoft.com" : .messages,
        "discord.com"         : .messages,
        "keep.google.com"     : .notes,
        "contacts.google.com" : .contacts,
        "calendar.google.com" : .calendar,
    ]

    /// The app adapters whose verbs read or write correspondence or records, by adapter name.
    public static let adapters: [String: ConfidentialSurface] = [
        "mail": .mail, "messages": .messages, "notes": .notes, "contacts": .contacts, "calendar": .calendar,
        "reminders": .reminders,
    ]

    /// The surface an application or a page is, by the key a scene and a call's event name it with: a bundle ID, or
    /// `web:<host>`. Nil for any other.
    public static func surface(of appKey: String?) -> ConfidentialSurface? {
        guard let appKey, !appKey.isEmpty else { return nil }
        if appKey.hasPrefix("web:") {
            var host = String(appKey.dropFirst(4)).lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
            if let surface = webHosts[host] { return surface }
            return webHosts.first { host.hasSuffix("." + $0.key) }?.value
        }
        return applications[appKey]
    }

    /// The roles whose label is what they hold: a text, a cell, a row, a link, a heading, an image or a document's area.
    static let contentRoles: Set<String> = [
        "AXStaticText", "AXCell", "AXRow", "AXLink", "AXHeading", "AXWebArea", "AXDocument", "AXImage",
    ]

    /// The roles that hold content under a name of their own: a field, a group or a list is named by its title or
    /// description (the application's), and is content when its label has no such origin.
    static let namedHolders: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXGroup", "AXList", "AXOutline", "AXTable", "AXBrowser",
    ]

    /// Whether a scene element of a confidential surface is content: a text, anything inside a collection (a message,
    /// a note, a person, a chat), a label read from the element's value or its row, a role whose label is what it
    /// holds, a field or group whose label has no origin of its own, or an element with no role. Every other element,
    /// a field named by its title among them, is one of the application's own controls; a field's value is content
    /// whatever names it (`contentTexts`).
    public static func isContent(_ element: SceneElement) -> Bool {
        isContent(kind: element.kind, role: element.role, origin: element.labelOrigin,
                  inCollection: element.collectionPath != nil)
    }

    /// The same rule for an element as a sample keeps it.
    public static func isContent(_ element: CaptureElement) -> Bool {
        isContent(kind: element.kind, role: element.role, origin: element.labelOrigin,
                  inCollection: element.isUnderCollection)
    }

    static func isContent(kind: ElementKind, role: String?, origin: LabelOrigin?, inCollection: Bool) -> Bool {
        if kind == .text || inCollection { return true }
        if origin == .value || origin == .rowContent || origin == .column { return true }
        guard let role else { return true }
        if namedHolders.contains(role) { return origin == nil }
        return contentRoles.contains(role)
    }

    /// The shortest content text searched for in the other texts of a record: a shorter one is withheld where it is an
    /// element's own label, never as a fragment of another text, which it would cut into pieces.
    public static let shortestTrackedText = 4

    /// The texts of a confidential scene that are content: every field's value and every content element's label and
    /// collection, and the title when it is content (`contentTitle`), those long enough to be searched for elsewhere
    /// (`shortestTrackedText`).
    public static func contentTexts(of scene: SceneSnapshot) -> [String] {
        var texts: [String] = contentTitle(of: scene).map { [$0] } ?? []
        for element in scene.elements {
            if let value = element.value { texts.append(value) }
            guard isContent(element) else { continue }
            texts.append(element.label)
            if let path = element.collectionPath { texts.append(path) }
        }
        for field in scene.outOfViewFields {
            texts.append(contentsOf: [field.label, field.value])
            if let container = field.container { texts.append(container) }
        }
        var seen = Set<String>()
        return texts.filter { text in
            text.count >= shortestTrackedText && text != ValueMinimization.marker && seen.insert(text).inserted
        }
    }

    /// The window's title when it is content: always but when one of the scene's own controls bears it, as a dialog's
    /// title names its button ("Choose File"); a mailbox's or a message's title names the person's mail.
    public static func contentTitle(of scene: SceneSnapshot) -> String? {
        let title = scene.windowTitle
        guard !title.isEmpty, title != ValueMinimization.marker, !controlLabels(of: scene).contains(title) else { return nil }
        return title
    }

    /// The labels of a confidential scene's own controls: what an effect may name and still be kept.
    public static func controlLabels(of scene: SceneSnapshot) -> Set<String> {
        Set(scene.elements.filter { !isContent($0) }.map(\.label))
    }

    /// The scene a Brain may learn from on a confidential surface: its controls only, the title withheld. The structure
    /// of the window's chrome stays, and no content element becomes an anchor.
    public static func structure(of scene: SceneSnapshot) -> SceneSnapshot {
        var kept = scene
        kept.windowTitle = ValueMinimization.marker
        kept.elements = scene.elements.filter { !isContent($0) }
        kept.outOfViewFields = []
        return kept
    }
}
