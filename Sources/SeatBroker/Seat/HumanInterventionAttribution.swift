//
//  HumanInterventionAttribution.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 30/10/2026.
//

import Foundation
import InteractionListener

/// HumanInterventionAttribution links effects to commands: deterministic gates (time, window, subject touched) give the
/// candidates; embeddings only rank them and grade the choice, never touching an effect or the report's body.
nonisolated struct HumanInterventionAttribution: Sendable {
    enum Confidence: String, Sendable {
        /// The embedding ranking agrees with the gated cause.
        case confirmed
        /// The gated cause stays, but it is far below the floor or another command is much closer.
        case uncertain
        /// No embeddings, or several candidates none of which reached the floor.
        case unranked
    }

    struct Link: Sendable {
        /// Commands that pass the time and window gates.
        let candidates: [Int]
        /// Candidates that touched the subject, its member or container, or closed the surface it followed.
        let touching: [Int]
        /// For a change to a collection as a whole, candidates that committed a choice or command whose result no rule
        /// could represent (a menu's "Kind"); for a member added or removed, candidates whose command means that.
        var committed: [Int] = []
        var cause: Int?
        var confidence = Confidence.unranked
        var similarity: Double?
        /// A command the embeddings find much closer than the cause, for details.
        var alternative: Int?
        var reason: String

        /// The candidates the gates prefer: those that touched the subject, else those that committed something
        /// unrepresented or whose command means the change (a click that committed nothing is not the cause of a
        /// grouping or a removal), else all of them.
        var preferred: [Int] { !touching.isEmpty ? touching : !committed.isEmpty ? committed : candidates }
    }

    /// Similarity a ranked cause must reach when several candidates remain. Calibrated on recorded trials with
    /// Granite 107m (`floorModel`): the lowest right cause among several candidates scored 0.728 (a note edit);
    /// unrelated commands sit near 0.70. Vectors from any other model are not ranked against it.
    static let floor = 0.72
    static let floorModel = HumanInterventionEmbeddings.modelIdentity
    /// How far below the floor, or how much closer another command, makes a gated cause uncertain.
    static let margin = 0.05
    /// Effects at least this close and seen within a few actions of each other are one task in details.
    static let together = 0.90

    /// One text per thread root, then one per effect (body effects first, then intermediate ones).
    private(set) var commandTexts: [String] = []
    private(set) var effectTexts: [String] = []
    private(set) var links: [Link] = []
    /// Groups of effect indexes close in meaning and time, for details only.
    private(set) var tasks: [[Int]] = []
    /// The model whose vectors ranked the causes, "id@revision"; nil when nothing was ranked.
    private(set) var model: String?
    /// Why vectors were given but not ranked; nil otherwise.
    private(set) var skipped: String?

    init() {}

    init(threads: HumanInterventionThreads, effects: [HumanInterventionEffects.Effect], windows: [Int: String]) {
        let key = HumanInterventionIdentity.normalized
        commandTexts = threads.roots.map { root in
            var seen = Set<String>()
            let actions = root.actions.map { HumanInterventionEvidence.action(threads.actions[$0]) }.filter { seen.insert($0).inserted }
            return Self.bounded(([root.embeddingText] + actions + [root.document.flatMap { windows[$0] } ?? ""]).joined(separator: " "))
        }
        effectTexts = effects.map { Self.bounded("\($0.kind.rawValue) " + HumanInterventionEffects.describe($0) + " " + (windows[$0.window] ?? "")) }
        links = effects.map { effect in
            let owners = Set(effect.actions.compactMap { threads.owners.indices.contains($0) ? threads.owners[$0] : nil })
            // The window gate: the command acted in the effect's window or in a surface of its own over it.
            let candidates = owners.union(effect.causes).filter { id in
                let root = threads.roots[id]
                return root.document == effect.window || root.surface == effect.window || root.surfaces.contains(effect.window)
            }.sorted()
            let names = Set([effect.label, effect.before, effect.after, effect.member,
                             effect.collection?.components(separatedBy: " / ").last].compactMap { $0 }.map(key).filter { $0.count > 1 })
            func named(_ text: String?) -> Bool {
                guard let text else { return false }
                let label = key(text)
                return names.contains(label) || names.contains { $0.count > 3 && label.contains($0) }
            }
            let touching = candidates.filter { id in
                let root = threads.roots[id]
                // A title follows a load, which a Return in a field or a link starts.
                if effect.kind == .title {
                    return root.actions.contains { index in
                        let action = threads.actions[index]
                        return ["Return", "Enter"].contains(action.commandName ?? "") || action.kind == .click && action.role == "AXLink"
                    }
                }
                // A dialog's operation that committed on its own surface closed it onto the effect's window.
                let closing = [.create, .other, .menu].contains(root.operation)
                    && root.terminal.map { [.commit, .implicit].contains($0.kind) } == true
                    && root.surface != nil && root.surface != effect.window
                return closing || (root.affected + root.selectedObjects + [root.focusedRow].compactMap { $0 }).contains(where: named)
                    || root.actions.contains { named(threads.actions[$0].label) || named(threads.actions[$0].destination) }
            }
            var link = Link(candidates: candidates, touching: touching, reason: candidates.isEmpty ? "no candidate" : "")
            // Only for a change to a collection as a whole: a save commits too, and must not take a member's change.
            if effect.whole {
                link.committed = candidates.filter { threads.roots[$0].isOpaqueCommit }
            } else if effect.kind == .deleted || effect.kind == .created {
                link.committed = candidates.filter { threads.means($0, effect.kind == .deleted ? .delete : .create) }
            }
            if link.preferred.count == 1 {
                link.cause = link.preferred[0]
                link.reason = "single candidate"
            } else if !candidates.isEmpty { link.reason = "\(link.preferred.count) candidates, unranked" }
            return link
        }
    }

    /// Ranks with one vector per command and per effect from `model`: the best preferred candidate at or above the
    /// floor is the cause; every gated cause is then graded against all commands. Mismatched vectors, or vectors from
    /// a model the floor was not calibrated on, leave the links unranked.
    func ranked(commands: [[Float]], effects: [[Float]], model: String?) -> Self {
        guard commands.count == commandTexts.count, effects.count == effectTexts.count, !commands.isEmpty else { return self }
        var result = self
        guard model == Self.floorModel else {
            result.skipped = "vectors from \(model ?? "an unnamed model"), floor calibrated on \(Self.floorModel)"
            return result
        }
        result.model = model
        for index in result.links.indices {
            var link = result.links[index]
            let similarity = commands.map { Self.cosine(effects[index], $0) }
            if link.preferred.count > 1, let best = link.preferred.max(by: { similarity[$0] < similarity[$1] }) {
                link.cause = similarity[best] >= Self.floor ? best : nil
                link.reason = similarity[best] >= Self.floor ? "ranked among \(link.preferred.count)" : "below floor"
            }
            if let cause = link.cause, let top = similarity.indices.max(by: { similarity[$0] < similarity[$1] }) {
                link.similarity = similarity[cause]
                let closer = !link.candidates.contains(top) && similarity[top] - similarity[cause] > Self.margin
                link.confidence = similarity[cause] < Self.floor - Self.margin || closer ? .uncertain : .confirmed
                link.alternative = link.confidence == .uncertain && top != cause ? top : nil
            }
            result.links[index] = link
        }
        // Tasks: effects close in meaning that share a candidate command, so were seen around the same actions.
        var group = Array(effects.indices)
        func root(_ index: Int) -> Int { group[index] == index ? index : root(group[index]) }
        for i in effects.indices {
            for j in effects.indices where j > i && Self.cosine(effects[i], effects[j]) >= Self.together
                && !Set(result.links[i].candidates).isDisjoint(with: result.links[j].candidates) {
                group[root(j)] = root(i)
            }
        }
        result.tasks = Dictionary(grouping: effects.indices, by: root).values.filter { $0.count > 1 }.map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
        return result
    }

    func withholding(_ transform: (String) -> String) -> Self {
        var result = self
        result.commandTexts = commandTexts.map(transform)
        result.effectTexts = effectTexts.map(transform)
        return result
    }

    /// The commands a deterministic reading counts as causes: every one that touched an effect's subject, and the
    /// one preferred candidate of an effect. Embeddings never change it.
    var deterministicCauses: Set<Int> {
        Set(links.flatMap { $0.touching + ($0.preferred.count == 1 ? $0.preferred : []) })
    }

    private static func bounded(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= 1_000 else { break }
            result.append(character)
        }
        return result
    }

    static func cosine(_ left: [Float], _ right: [Float]) -> Double {
        guard !left.isEmpty, left.count == right.count else { return 0 }
        var dot = 0.0, a = 0.0, b = 0.0
        for (x, y) in zip(left, right) {
            guard x.isFinite, y.isFinite else { return 0 }
            dot += Double(x) * Double(y)
            a += Double(x) * Double(x)
            b += Double(y) * Double(y)
        }
        return a > 0 && b > 0 ? dot / sqrt(a * b) : 0
    }
}
