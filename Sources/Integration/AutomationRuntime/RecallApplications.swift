//
//  RecallApplications.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AppKit
import Foundation
import Memory

/// RecallApplications resolves the application a need names (`needs[].app` of `memory_task`) to the bundle ID the Recall
/// filters by, records and delivers, before anything filters, selects or records it. The tool accepts a name as the other
/// tools do ("Preview", "Anteprima", "Preview.app") or a bundle ID, in any case; the learned parts carry bundle IDs only, so
/// comparing the word as it was given hid a Memory whose parts all run in one application (live run R01, LV03).
///
/// The word is matched among the applications the index's parts run in, with the names their installed bundles answer to
/// (`RunningApplicationLookup.names(declared:bundleName:bundleURL:)`: the English name, the file's and the one the Finder
/// shows in the person's language), and those the session offers the `apps` tool for it. Nothing is launched and no window
/// is read. The tiers are `RunningApplicationLookup.chosen`'s: an exact bundle ID, then an exact name, then a name prefix,
/// then a name that contains the word.
/// - A word with a bundle ID's form (two dots or more, no space), or a web identity (`web:<host>`, Braus's browser
///   engine), is a certain identity even when nothing knows it: it keeps the filter, which excludes the parts of every
///   other application. A site reached through the seat's browser is that browser's bundle ID, another identity (M08).
/// - A name nothing knows, or one several applications answer to, is not resolved: the need keeps no application, so
///   nothing is excluded for it, and a note says why. An unresolved name never becomes an absence of Memory.
nonisolated public enum RecallApplications {

    /// Known is one application a word may resolve to: its bundle ID and every name it answers to.
    public struct Known: Sendable, Equatable {
        public let bundleID: String
        public let names: [String]

        public init(bundleID: String, names: [String]) {
            self.bundleID = bundleID
            self.names    = names
        }
    }

    /// Resolution is what a word names: one bundle ID, several, or none known.
    public enum Resolution: Sendable, Equatable {
        case resolved(String)
        case ambiguous([String])
        case unknown
    }

    /// The applications known for a resolution: those the learned parts run in, with the names their installed bundles
    /// answer to (`installedNames`) and their last component, and those the session offers, with their names.
    public static func known(learned: [String], offered: [ApplicationCandidate],
                             installedNames: (String) -> [String] = installedNames(of:)) -> [Known] {
        var names: [String: [String]] = [:]
        var order: [String] = []
        func add(_ bundleID: String, _ more: [String]) {
            guard !bundleID.isEmpty else { return }
            if names[bundleID] == nil { order.append(bundleID) }
            for name in more where !name.isEmpty && !(names[bundleID] ?? []).contains(name) { names[bundleID, default: []].append(name) }
        }
        for bundleID in learned { add(bundleID, [RecallDocument.applicationName(bundleID)] + installedNames(bundleID)) }
        for candidate in offered { add(candidate.bundleID, [candidate.name]) }
        return order.map { Known(bundleID: $0, names: names[$0] ?? []) }
    }

    /// The names the application installed under `bundleID` answers to, read from its bundle without launching it; none
    /// when no application is installed under it.
    public static func installedNames(of bundleID: String) -> [String] {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return [] }
        let bundle = Bundle(url: url)
        let declared = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
        return RunningApplicationLookup.names(declared: declared, bundleName: bundle?.infoDictionary?["CFBundleName"] as? String,
                                              bundleURL: url)
    }

    /// What `word` names among `known`.
    public static func resolve(_ word: String, among known: [Known]) -> Resolution {
        var wanted = word.trimmingCharacters(in: .whitespacesAndNewlines)
        // A web identity is whole, a host that ends in `.app` too: only an application's name drops that suffix.
        if isWebIdentity(wanted) {
            return .resolved(known.first { fold($0.bundleID) == fold(wanted) }?.bundleID ?? wanted)
        }
        if wanted.lowercased().hasSuffix(".app") { wanted = String(wanted.dropLast(4)) }
        guard !wanted.isEmpty else { return .unknown }
        let folded = fold(wanted)
        if let exact = known.first(where: { fold($0.bundleID) == folded }) { return .resolved(exact.bundleID) }
        if isBundleID(wanted) { return .resolved(wanted) }
        let tiers: [(String) -> Bool] = [{ $0 == folded }, { $0.hasPrefix(folded) }, { $0.contains(folded) }]
        for tier in tiers {
            let matches = known.filter { $0.names.map(fold).contains(where: tier) }.map(\.bundleID)
            if matches.count == 1, let match = matches.first { return .resolved(match) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return .unknown
    }

    /// The needs with each application resolved, and the notes of those that could not be: their need keeps no
    /// application.
    public static func resolving(_ needs: [RecallNeed], among known: [Known]) throws -> (needs: [RecallNeed], notes: [String]) {
        var notes: [String] = []
        let resolved = try needs.enumerated().map { index, need -> RecallNeed in
            guard let word = need.bundleID else { return need }
            switch resolve(word, among: known) {
                case .resolved(let bundleID):
                    return try RecallNeed(text: need.text, bundleID: bundleID)
                case .ambiguous(let bundleIDs):
                    notes.append("need \(index + 1) names the application '\(word)', which could not be resolved: it is ambiguous among "
                                 + "\(bundleIDs.joined(separator: ", ")); the parts of every application were searched for it")
                case .unknown:
                    notes.append("need \(index + 1) names the application '\(word)', which could not be resolved: no learned or open "
                                 + "application answers to it; the parts of every application were searched for it")
            }
            return try RecallNeed(text: need.text, bundleID: nil)
        }
        return (resolved, notes)
    }

    /// Whether a word is a web identity: `web:` and a host, no space.
    static func isWebIdentity(_ word: String) -> Bool {
        word.lowercased().hasPrefix("web:") && word.count > 4 && !word.contains(" ")
    }

    /// Whether a word has a bundle ID's form: reverse-DNS components, two dots or more, no space.
    static func isBundleID(_ word: String) -> Bool {
        let components = word.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
        }
    }

    private static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
