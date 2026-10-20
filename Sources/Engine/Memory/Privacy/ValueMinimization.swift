//
//  ValueMinimization.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import PerceptionCore

/// ValueMinimization decides, before anything reaches the archive, its copies or its log, which values
/// of a call are kept and which are withheld. Ordinary values, private as they may be, are kept: the
/// living memory learns from them locally. A secret is never kept: the task declared it secret, it
/// has the shape of a credential, or the control it went to is named for one. Its place keeps the
/// marker, and a `ValueRedaction` says which value it was and why; nothing of its content (length,
/// digest) is kept.
///
/// The rules are conservative where they can be: every text argument is searched for credential
/// shapes, not only the typed ones, and a secret declared by the task is withheld wherever it
/// appears, inside a longer text too and however short it is (a declared PIN of three digits is
/// withheld from "The PIN is 731", at the cost of the same digits in an ordinary text). The length
/// thresholds belong to the credential heuristics only. The rules cannot see what they are not told:
/// a password typed into a field whose label names no secret, which the task did not declare secret
/// and which has no credential shape, is kept unless the call classified it (`classified`). That limit
/// is stated, not hidden.
///
/// A call that types classifies its text before its first write (W1): typed into a secure field
/// (`secureField`), or where it could not attest an ordinary target (`unclassifiedTarget`). Those texts
/// are withheld from every record of that call wherever they appear, with their own reason; a text the
/// call attested ordinary is not classified and is kept, so the memory keeps learning it.
public struct ValueMinimization: Sendable {

    /// The text a withheld value is replaced with.
    public static let marker = "[withheld]"

    /// Secrets the current task declared, in memory only, never stored.
    public let secrets: [String]

    /// Texts the current call classified before its first write, with why each is withheld: in memory
    /// only, never stored, and only for the records of that call.
    public let classified: [String: WithholdingReason]
    /// Texts withheld only where a whole text is one of them, never as a fragment of a longer one: a confidential
    /// surface's short content (a name, a subject of two letters) and a result's field values (P1-06). In memory only.
    public let exact: [String: WithholdingReason]
    /// Whether credential shapes are withheld too: true for whatever is kept; false for what is only shown, an
    /// answer to the model, where the known secrets alone are withheld.
    public let scrubsCredentials: Bool

    public init(secrets: [String] = [], classified: [String: WithholdingReason] = [:],
                exact: [String: WithholdingReason] = [:], scrubsCredentials: Bool = true) {
        self.secrets           = secrets.filter { !$0.isEmpty }
        self.classified        = classified.filter { !$0.key.isEmpty }
        self.exact             = exact.filter { !$0.key.isEmpty && $0.key != Self.marker }
        self.scrubsCredentials = scrubsCredentials
    }

    /// Whether it withholds nothing but credential shapes: no secret, no classified text.
    public var knowsNoText: Bool { secrets.isEmpty && classified.isEmpty && exact.isEmpty }

    // MARK: Requests

    /// The request with every withheld value replaced by the marker, and the redactions it leaves.
    /// `eventID` is the call's event, which the redactions name.
    public func minimize(_ request: AgentCallRequest, eventID: String) -> (AgentCallRequest, [ValueRedaction]) {
        var redactions: [ValueRedaction] = []
        func keep(_ text: String, _ name: String, typedInto target: String? = nil) -> String {
            let (kept, reason) = minimize(text: text, typedInto: target)
            if let reason {
                redactions.append(ValueRedaction(eventID: eventID, location: .argument(name: name, position: 0),
                                                 reason: reason))
            }
            return kept
        }
        func keepOptional(_ text: String?, _ name: String) -> String? { text.map { keep($0, name) } }
        let minimized: AgentCallRequest
        switch request {
            case .status, .batch, .closeSession, .observe, .collectPosts:
                minimized = request
            case .windows(let app):
                minimized = .windows(app: keepOptional(app, "app"))
            case .apps(let query):
                minimized = .apps(query: keepOptional(query, "query"))
            case .openSession(let app, let window):
                minimized = .openSession(app: keep(app, "app"), window: keepOptional(window, "window"))
            case .act(let target, let verb, let value, let section):
                minimized = .act(target: keep(target, "target"), verb: verb, value: value,
                                 section: keepOptional(section, "section"))
            case .select(let control, let item):
                minimized = .select(control: keep(control, "control"), item: keep(item, "item", typedInto: control))
            case .typeText(let target, let text, let section, let replace):
                minimized = .typeText(target: keep(target, "target"), text: keep(text, "text", typedInto: target),
                                      section: keepOptional(section, "section"), replace: replace)
            case .insertText(let text, let expectedValue):
                minimized = .insertText(text: keep(text, "text"),
                                        expectedValue: keepOptional(expectedValue, "expected_value"))
            case .pressKey:
                minimized = request
            case .scroll(let direction, let lines, let target, let section):
                minimized = .scroll(direction: direction, lines: lines, target: keepOptional(target, "target"),
                                    section: keepOptional(section, "section"))
            case .drag(let from, let end, let section):
                let kept: AgentDragEnd
                if case .target(let to) = end { kept = .target(keep(to, "to")) } else { kept = end }
                minimized = .drag(from: keep(from, "from"), to: kept, section: keepOptional(section, "section"))
            case .contextMenu(let target, let item, let section):
                minimized = .contextMenu(target: keep(target, "target"), item: keep(item, "item"),
                                         section: keepOptional(section, "section"))
            case .menu(let path):
                minimized = .menu(path: keep(path, "path"))
            case .press(let button):
                minimized = .press(button: keep(button, "button"))
            case .appCapabilities(let app, let query):
                minimized = .appCapabilities(app: keep(app, "app"), query: keepOptional(query, "query"))
            case .appCall(let app, let verb, let arguments):
                minimized = .appCall(app: keep(app, "app"), verb: keep(verb, "verb"),
                                     arguments: keep(arguments, "arguments"))
        }
        return (minimized, redactions)
    }

    // MARK: Texts

    /// A text with what must be withheld removed: the whole text when it went to a control named for
    /// a secret, the call's classified texts, the declared secrets and the credential shapes inside it
    /// otherwise, every match found on the text as given and withheld at once (`withholding`). The reason
    /// is the strongest of what was found: a secure field's, an unclassified target's, a secret target's,
    /// a declared secret's, a credential's; nil when the text is kept as it is.
    public func minimize(text: String, typedInto target: String? = nil) -> (String, WithholdingReason?) {
        let (kept, reasons) = Self.withholding(text, classified: classified, secrets: secrets, credentials: scrubsCredentials)
        if let target, Self.namesSecret(target), !text.isEmpty {
            return (Self.marker, Self.strongest(reasons.union([.secretTarget])))
        }
        if let whole = exact[text] { return (Self.marker, Self.strongest(reasons.union([whole]))) }
        return (kept, Self.strongest(reasons))
    }

    /// The text with every declared secret replaced by the marker wherever it appears, and whether one
    /// was.
    func withholdingDeclared(_ text: String) -> (String, Bool) {
        let (kept, reasons) = Self.withholding(text, classified: [:], secrets: secrets, credentials: false)
        return (kept, !reasons.isEmpty)
    }

    /// The reason a gap is declared with when several apply: what the call knew of the field first.
    public static func strongest(_ reasons: Set<WithholdingReason>) -> WithholdingReason? {
        [.secureField, .unclassifiedTarget, .secretTarget, .declaredSecret, .confidentialContent, .credentialPattern]
            .first(where: reasons.contains)
    }

    /// The text with every sensitive range of it withheld at once, and the reasons of what was found. Every
    /// match is found on the text as given, never on a text another rule already changed: each occurrence of
    /// a classified text and of a declared secret, overlapping ones included, and, with `credentials`, every
    /// credential shape. Ranges that overlap are withheld as one, so no rule's match can leave a piece of
    /// another's visible or break a credential's shape before it is recognized. A match that overlaps a
    /// marker already in the text is not one: a secret that is part of the marker cannot break it.
    static func withholding(
        _ text     : String,
        classified : [String: WithholdingReason],
        secrets    : [String],
        credentials: Bool
    ) -> (String, Set<WithholdingReason>) {
        let markers = occurrences(of: marker, in: text)
        func outsideMarkers(_ range: Range<String.Index>) -> Bool { !markers.contains { $0.overlaps(range) } }
        var ranges : [Range<String.Index>] = []
        var reasons: Set<WithholdingReason> = []
        func add(_ found: [Range<String.Index>], _ reason: WithholdingReason) {
            let kept = found.filter(outsideMarkers)
            guard !kept.isEmpty else { return }
            ranges += kept
            reasons.insert(reason)
        }
        for (piece, reason) in classified { add(occurrences(of: piece, in: text), reason) }
        for secret in secrets { add(occurrences(of: secret, in: text), .declaredSecret) }
        if credentials { add(credentialRanges(in: text), .credentialPattern) }
        guard !ranges.isEmpty else { return (text, []) }
        return (replacing(ranges, in: text), reasons)
    }

    /// Every occurrence of `piece` in `text`, overlapping ones included; none for an empty piece.
    static func occurrences(of piece: String, in text: String) -> [Range<String.Index>] {
        guard !piece.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: piece, range: start..<text.endIndex) {
            found.append(range)
            start = text.index(after: range.lowerBound)
        }
        return found
    }

    /// The text with each run of overlapping ranges replaced by one marker.
    static func replacing(_ ranges: [Range<String.Index>], in text: String) -> String {
        var merged: [Range<String.Index>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound < last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var kept = ""
        var position = text.startIndex
        for range in merged {
            kept += text[position..<range.lowerBound]
            kept += marker
            position = range.upperBound
        }
        kept += text[position...]
        return kept
    }

    /// An optional text minimized the same way, with the same answer for nil.
    public func minimize(optional text: String?) -> (String?, WithholdingReason?) {
        guard let text else { return (nil, nil) }
        let (kept, reason) = minimize(text: text)
        return (kept, reason)
    }

    // MARK: Samples and scenes

    /// The sample with each element's label and its window title minimized, and the gaps it leaves.
    public func minimize(sample: CaptureSample) -> (CaptureSample, [ValueRedaction]) {
        var kept = sample
        var gaps: [ValueRedaction] = []
        let key = sample.key
        if let title = sample.windowTitle {
            let (scrubbed, reason) = minimize(text: title)
            if let reason {
                kept.windowTitle = scrubbed
                gaps.append(ValueRedaction(eventID: key.eventID,
                                           location: .sampleTitle(phase: key.phase, ordinal: key.ordinal),
                                           reason: reason))
            }
        }
        for index in kept.elements.indices {
            let (scrubbed, reason) = minimize(text: kept.elements[index].label)
            if let reason {
                kept.elements[index].label = scrubbed
                gaps.append(ValueRedaction(
                    eventID : key.eventID,
                    location: .sampleLabel(phase: key.phase, ordinal: key.ordinal, element: index),
                    reason  : reason
                ))
            }
            // The container path names the element's ancestors, whose labels may hold what the label does.
            let (path, withheld) = minimize(text: kept.elements[index].containerPath)
            if let withheld {
                kept.elements[index].containerPath = path
                gaps.append(ValueRedaction(
                    eventID : key.eventID,
                    location: .sampleContainer(phase: key.phase, ordinal: key.ordinal, element: index),
                    reason  : withheld
                ))
            }
        }
        return (kept, gaps)
    }

    /// The sample of a confidential surface (P1-06): its title, and every content element's label and container path,
    /// withheld whole with the `confidential_content` gap (`ConfidentialSurfaces.isContent`), then every text minimized
    /// as `minimize(sample:)` does. Roles, kinds, states, bounds and the controls' labels stay. Without a surface it is
    /// `minimize(sample:)`.
    public func minimize(sample: CaptureSample, confidential surface: ConfidentialSurface?) -> (CaptureSample, [ValueRedaction]) {
        guard surface != nil else { return minimize(sample: sample) }
        var kept = sample
        var gaps: [ValueRedaction] = []
        let key = sample.key
        if let title = sample.windowTitle, !title.isEmpty, title != Self.marker {
            kept.windowTitle = Self.marker
            gaps.append(ValueRedaction(eventID: key.eventID, location: .sampleTitle(phase: key.phase, ordinal: key.ordinal),
                                       reason: .confidentialContent))
        }
        for index in kept.elements.indices where ConfidentialSurfaces.isContent(kept.elements[index]) {
            if kept.elements[index].label != Self.marker {
                kept.elements[index].label = Self.marker
                gaps.append(ValueRedaction(
                    eventID : key.eventID,
                    location: .sampleLabel(phase: key.phase, ordinal: key.ordinal, element: index),
                    reason  : .confidentialContent
                ))
            }
            if !kept.elements[index].containerPath.isEmpty, kept.elements[index].containerPath != Self.marker {
                kept.elements[index].containerPath = Self.marker
                gaps.append(ValueRedaction(
                    eventID : key.eventID,
                    location: .sampleContainer(phase: key.phase, ordinal: key.ordinal, element: index),
                    reason  : .confidentialContent
                ))
            }
        }
        let (rest, more) = minimize(sample: kept)
        return (rest, gaps + more)
    }

    /// What the Brain may learn from a scene of a confidential surface: its controls only, minimized
    /// (`ConfidentialSurfaces.structure`); any other scene minimized as `minimize(scene:)`.
    public func minimize(scene: SceneSnapshot, confidential surface: ConfidentialSurface?) -> SceneSnapshot {
        minimize(scene: surface == nil ? scene : ConfidentialSurfaces.structure(of: scene))
    }

    /// An effect on a confidential surface: each label kept only when it is one of the application's own controls in
    /// the scenes around it (`controls`), the title and a value always withheld, with the `confidential_content`
    /// reason; then minimized as `minimize(effect:)`. Without controls it is `minimize(effect:)`.
    public func minimize(effect: SceneEffect, confidentialControls controls: Set<String>?) -> (SceneEffect, WithholdingReason?) {
        guard let controls else { return minimize(effect: effect) }
        var withheld = false
        func label(_ text: String) -> String {
            guard !controls.contains(text) else { return text }
            withheld = true
            return Self.marker
        }
        let kept: SceneEffect
        switch effect {
            case .windowTitleChanged:
                withheld = true
                kept = .windowTitleChanged(title: Self.marker)
            case .menuOpened(let labels):
                kept = .menuOpened(labels: labels.map(label))
            case .elementsAppeared(let labels):
                kept = .elementsAppeared(labels: labels.map(label))
            case .elementsDisappeared(let labels):
                kept = .elementsDisappeared(labels: labels.map(label))
            case .valueChanged(let name, _):
                withheld = true
                kept = .valueChanged(label: label(name), value: Self.marker)
            case .stateFlip, .textSelectionChanged:
                kept = effect
        }
        let (minimized, reason) = minimize(effect: kept)
        return (minimized, withheld ? Self.strongest([.confidentialContent, reason ?? .confidentialContent]) : reason)
    }

    /// The scene with its title and every text of its elements minimized: what the Brain may learn
    /// from it.
    public func minimize(scene: SceneSnapshot) -> SceneSnapshot {
        var kept = scene
        kept.windowTitle = minimize(text: scene.windowTitle).0
        kept.elements = scene.elements.map { minimize(element: $0).0 }
        return kept
    }

    /// An element as perception read it, every text of it minimized (its label and value, the names of
    /// its container, group, section and collection path, what it does) and its identity as its label
    /// was; with whether anything was withheld.
    public func minimize(element: SceneElement) -> (SceneElement, Bool) {
        var kept = element
        var withheld = false
        func scrub(_ text: String) -> String {
            let (minimized, reason) = minimize(text: text)
            if reason != nil { withheld = true }
            return minimized
        }
        kept.label          = scrub(element.label)
        kept.value          = element.value.map(scrub)
        kept.container      = element.container.map(scrub)
        kept.group          = element.group.map(scrub)
        kept.section        = element.section.map(scrub)
        kept.does           = element.does.map(scrub)
        kept.collectionPath = element.collectionPath.map(scrub)
        let (identity, reason) = minimize(identifier: element.id, label: element.label)
        if reason != nil { withheld = true }
        kept.id = identity
        return (kept, withheld)
    }

    // MARK: Identities, targets, effects and listings

    /// An element's identity minimized as its label is: perception names a labelled element
    /// `kind|normalized label` (`SceneIdentity`), so the withheld part of the label is withheld from the
    /// identity in its normalized form, the same way in every fact that names the element. A declared
    /// secret is withheld as written and normalized; a credential's shape as in any text.
    public func minimize(identifier: String, label: String?) -> (String, WithholdingReason?) {
        var kept = identifier
        var reasons: Set<WithholdingReason> = []
        if let label {
            let (minimized, why) = minimize(text: label)
            let original = LabelText.normalize(label)
            if let why, !original.isEmpty, kept.contains(original) {
                kept = kept.replacingOccurrences(of: original, with: LabelText.normalize(minimized))
                reasons.insert(why)
            }
        }
        // The classified texts and the declared secrets as written and normalized, and the credential shapes,
        // all found on the identity as it now is and withheld at once.
        var normalizedClassified = classified
        for (text, why) in classified {
            let key = LabelText.normalize(text)
            normalizedClassified[key] = Self.strongest([why, normalizedClassified[key] ?? why])
        }
        let (scrubbed, found) = Self.withholding(kept, classified: normalizedClassified,
                                                 secrets: secrets + secrets.map(LabelText.normalize),
                                                 credentials: scrubsCredentials)
        return (scrubbed, Self.strongest(reasons.union(found)))
    }

    /// The element a call resolved with its label, section, identity and role minimized, and the
    /// gaps it leaves, one per location.
    public func minimize(target: OperationCheck.Target, eventID: String) -> (OperationCheck.Target, [ValueRedaction]) {
        var gaps: [ValueRedaction] = []
        func note(_ location: ValueRedaction.Location, _ reason: WithholdingReason?) {
            guard let reason, !gaps.contains(where: { $0.location == location }) else { return }
            gaps.append(ValueRedaction(eventID: eventID, location: location, reason: reason))
        }
        let (label, labelReason) = minimize(text: target.label)
        note(.targetLabel, labelReason)
        let section = target.section.map { minimize(text: $0) }
        note(.targetSection, section?.1)
        let (identity, identityReason) = minimize(identifier: target.elementID, label: target.label)
        note(.targetElement, identityReason)
        let role = target.role.map { minimize(text: $0) }
        note(.targetElement, role?.1)
        return (OperationCheck.Target(elementID: identity, role: role?.0, label: label, section: section?.0), gaps)
    }

    /// An effect with its title and labels minimized and its family and states kept, so it is still an
    /// effect of its kind and its encoding still decodes (the marker holds no separator); and the
    /// reason when something was withheld. The value a field now reads is minimized as text typed into
    /// that field: withheld whole when the field names a secret.
    public func minimize(effect: SceneEffect) -> (SceneEffect, WithholdingReason?) {
        func list(_ labels: [String]) -> ([String], WithholdingReason?) {
            var reason: WithholdingReason?
            let kept = labels.map { label -> String in
                let (minimized, why) = minimize(text: label)
                reason = reason ?? why
                return minimized
            }
            return (kept, reason)
        }
        switch effect {
            case .windowTitleChanged(let title):
                let (kept, reason) = minimize(text: title)
                return (.windowTitleChanged(title: kept), reason)
            case .menuOpened(let labels):
                let (kept, reason) = list(labels)
                return (.menuOpened(labels: kept), reason)
            case .elementsAppeared(let labels):
                let (kept, reason) = list(labels)
                return (.elementsAppeared(labels: kept), reason)
            case .elementsDisappeared(let labels):
                let (kept, reason) = list(labels)
                return (.elementsDisappeared(labels: kept), reason)
            case .valueChanged(let label, let value):
                let (keptLabel, labelReason) = minimize(text: label)
                let (keptValue, valueReason) = minimize(text: value, typedInto: label)
                return (.valueChanged(label: keptLabel, value: keptValue), labelReason ?? valueReason)
            case .stateFlip, .textSelectionChanged:
                return (effect, nil)
        }
    }

    /// A listing with every application's name, location and version and every window's title
    /// minimized; one gap per application something was withheld from.
    public func minimize(listing: ListingResult, eventID: String) -> (ListingResult, [ValueRedaction]) {
        var gaps: [ValueRedaction] = []
        let applications = listing.applications.enumerated().map { position, application -> ListedApplication in
            var reason: WithholdingReason?
            func scrub(_ text: String) -> String {
                let (kept, why) = minimize(text: text)
                reason = reason ?? why
                return kept
            }
            let kept = ListedApplication(
                name            : scrub(application.name),
                bundleID        : application.bundleID,
                pid             : application.pid,
                version         : application.version.map(scrub),
                isRunning       : application.isRunning,
                location        : application.location.map(scrub),
                isDefaultBrowser: application.isDefaultBrowser,
                windows         : application.windows.map {
                    ListedWindow(number: $0.number, title: $0.title.map(scrub))
                }
            )
            if let reason {
                gaps.append(ValueRedaction(
                    eventID : eventID,
                    location: .listingEntry(application: position),
                    reason  : reason
                ))
            }
            return kept
        }
        return (ListingResult(kind: listing.kind, applications: applications, hiddenCount: listing.hiddenCount), gaps)
    }

    /// A call's result with its message or listing minimized, and the gaps it leaves.
    public func minimize(result: AgentCallResult?, eventID: String) -> (AgentCallResult?, [ValueRedaction]) {
        func scrub(_ message: String) -> (String, [ValueRedaction]) {
            let (kept, reason) = minimize(text: message)
            return (kept, reason.map { [ValueRedaction(eventID: eventID, location: .resultMessage, reason: $0)] } ?? [])
        }
        switch result {
            case .outcome(let kind, let message)?:
                let (kept, gap) = scrub(message)
                return (.outcome(kind, message: kept), gap)
            case .error(let message)?:
                let (kept, gap) = scrub(message)
                return (.error(message: kept), gap)
            case .closed(let message)?:
                let (kept, gap) = scrub(message)
                return (.closed(message: kept), gap)
            case .listing(let listing)?:
                let (kept, gaps) = minimize(listing: listing, eventID: eventID)
                return (.listing(kept), gaps)
            default:
                return (result, [])
        }
    }

    /// An observed effect with its title and labels minimized, as `minimize(effect:)` does.
    public func minimize(observed: ObservedEffect, eventID: String) -> (ObservedEffect, [ValueRedaction]) {
        let (kept, reason) = minimize(effect: observed.sceneEffect)
        guard let reason else { return (observed, []) }
        return (ObservedEffect(kept), [ValueRedaction(eventID: eventID, location: .observedEffect, reason: reason)])
    }

    // MARK: Brains

    /// A Brain application as an earlier build recorded it, admitted as a live one is made: the window
    /// and every label minimized, a name minimized; nil when its effect held a value this withholds,
    /// since learning it would teach the Brain to predict the marker. The flag says something was
    /// withheld.
    public func minimize(application command: BrainApplicationCommand) throws -> (BrainApplicationCommand?, Bool) {
        var withheld = false
        func scrub(_ text: String) -> String {
            let (kept, reason) = minimize(text: text)
            if reason != nil { withheld = true }
            return kept
        }
        func scrub(_ detection: BrainDetection) -> BrainDetection {
            var kept = detection
            kept.label = scrub(detection.label)
            return kept
        }
        let input: BrainApplicationCommand.Input
        switch command.input {
            case .observe(let window, let detections):
                input = .observe(window: window.map(scrub), detections: detections.map(scrub))
            case .record(let verb, let target, let effect):
                if let effect, ([effect.text, effect.label].compactMap { $0 } + effect.items).contains(where: {
                    minimize(text: $0).1 != nil
                }) || effect.value.map({ minimize(text: $0, typedInto: effect.label).1 != nil }) == true {
                    return (nil, true)
                }
                input = .record(verb: verb, target: scrub(target), effect: effect)
            case .setName(let anchorKey, let name):
                input = .setName(anchorKey: anchorKey, name: scrub(name))
        }
        let kept = try BrainApplicationCommand(key: command.key, bundleID: command.bundleID,
                                               requestedAtMS: command.requestedAtMS, input: input, coverage: command.coverage)
        return (kept, withheld)
    }

    /// BrainWithholding is what minimizing a Brain withheld: the anchors and groups whose texts it
    /// changed, by identity, and the transitions it left out, with their effect minimized, because a
    /// transition whose effect held a withheld value would be a prediction of the marker.
    public struct BrainWithholding: Sendable, Equatable {
        public var anchors: Set<String> = []
        public var groups: Set<UUID> = []
        public var transitions: [LearnedTransition] = []

        public init() {}

        public var isEmpty: Bool { anchors.isEmpty && groups.isEmpty && transitions.isEmpty }
    }

    /// A Brain admitted as a live one would have learned it: its anchors' labels, aliases and window
    /// families and its groups' names minimized, and the transitions whose effect held a withheld value
    /// left out; an effect that does not decode is left as it is, for the projection to judge.
    public func minimize(brain: UIBrain) -> (UIBrain, BrainWithholding) {
        var kept = brain
        var withheld = BrainWithholding()
        for index in kept.objects.indices {
            let anchor = kept.objects[index]
            var changed = false
            func scrub(_ text: String) -> String {
                let (minimized, reason) = minimize(text: text)
                if reason != nil { changed = true }
                return minimized
            }
            kept.objects[index].label   = scrub(anchor.label)
            kept.objects[index].aliases = anchor.aliases.map(scrub)
            kept.objects[index].window  = anchor.window.map(scrub)
            if changed { withheld.anchors.insert(anchor.anchorKey) }
        }
        for index in kept.groups.indices {
            guard let name = kept.groups[index].name else { continue }
            let (minimized, reason) = minimize(text: name)
            guard reason != nil else { continue }
            kept.groups[index].name = minimized
            withheld.groups.insert(kept.groups[index].id)
        }
        kept.transitions = brain.transitions.filter { transition in
            guard let effect = SceneEffect(encoded: transition.effect) else { return true }
            let (minimized, reason) = minimize(effect: effect)
            guard reason != nil else { return true }
            var left = transition
            left.effect = minimized.encoded
            withheld.transitions.append(left)
            return false
        }
        return (kept, withheld)
    }

    /// A text with the secrets withheld from earlier arguments added to the declared ones; the call's
    /// classification is kept.
    public func adding(secrets more: [String]) -> ValueMinimization {
        ValueMinimization(secrets: secrets + more.filter { !secrets.contains($0) }, classified: classified, exact: exact,
                          scrubsCredentials: scrubsCredentials)
    }

    /// The same minimization withholding more texts for `reason`: `fragments` wherever they appear, `wholes` only where
    /// a whole text is one of them. A text already withheld keeps the stronger of its reasons.
    public func adding(_ reason: WithholdingReason, fragments: [String] = [], wholes: [String] = []) -> ValueMinimization {
        var classified = self.classified, exact = self.exact
        for text in fragments where !text.isEmpty && text != Self.marker {
            classified[text] = Self.strongest([reason, classified[text] ?? reason])
        }
        for text in wholes where !text.isEmpty && text != Self.marker {
            exact[text] = Self.strongest([reason, exact[text] ?? reason])
        }
        return ValueMinimization(secrets: secrets, classified: classified, exact: exact, scrubsCredentials: scrubsCredentials)
    }

    // MARK: Rules

    /// Whether a control's name says it holds a secret: a password, a passcode, a PIN, a token, an
    /// API key, a one-time or security code, a card's verification number, in English or Italian.
    public static func namesSecret(_ label: String) -> Bool {
        let words = label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let joined = words.joined(separator: " ")
        let single: Set<String> = ["password", "passwd", "passcode", "passphrase", "pin", "token", "secret", "otp",
                                   "cvv", "cvc", "apikey", "totp", "2fa", "mfa"]
        if words.contains(where: single.contains) { return true }
        let phrases = ["api key", "access key", "secret key", "private key", "security code", "verification code",
                       "one time code", "auth code", "parola d ordine", "codice segreto", "codice di sicurezza",
                       "codice di verifica", "chiave api", "chiave segreta"]
        return phrases.contains { joined.contains($0) }
    }

    /// The text with every credential shape replaced by the marker, and whether any was found: private
    /// keys, well-known token prefixes (`sk-`, `ghp_`, `github_pat_`, `xox?-`, `AKIA`, `AIza`), JSON
    /// web tokens, and long mixed-case alphanumeric strings that read as generated keys.
    public static func scrubCredentials(_ text: String) -> (String, Bool) {
        let (kept, reasons) = withholding(text, classified: [:], secrets: [], credentials: true)
        return (kept, !reasons.isEmpty)
    }

    /// Where the credential shapes of `text` are: every match of the patterns and every word that reads as
    /// a generated key, found on the text as given.
    static func credentialRanges(in text: String) -> [Range<String.Index>] {
        // The shortest shape searched for is a Slack token's 15 characters: a shorter text holds none.
        guard text.utf8.count >= 15 else { return [] }
        var found: [Range<String.Index>] = []
        let whole = NSRange(text.startIndex..., in: text)
        for pattern in credentialPatterns {
            for match in pattern.matches(in: text, range: whole) {
                if let range = Range(match.range, in: text), !range.isEmpty { found.append(range) }
            }
        }
        for token in text.split(separator: " ") where looksGenerated(String(token)) {
            found.append(token.startIndex..<token.endIndex)
        }
        return found
    }

    /// Whether a text has a credential's shape anywhere in it.
    public static func hasCredentialShape(_ text: String) -> Bool { scrubCredentials(text).1 }

    /// Whether a word reads as a generated key. An absolute path (`/…` or `~/…`) is judged by its
    /// components, since its slashes join names that are each short and would otherwise add up to a
    /// key's length (live run R01, LV02): it has a key's shape when one component does, whole or as a
    /// shorter random run (`readsRandom`). Any other word, a key with slashes in its alphabet among them,
    /// is judged whole.
    static func looksGenerated(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:()[]{}<>"))
        guard trimmed != marker else { return false }
        if let components = pathComponents(trimmed) {
            return components.contains { isGeneratedWord($0) || readsRandom($0) }
        }
        return isGeneratedWord(trimmed)
    }

    /// The characters a generated key is drawn from: letters, digits and the separators of base64.
    private static let keyAlphabet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))

    /// A word of 32 or more characters drawn from a key's alphabet, with upper case, lower case and
    /// digits all present: how generated keys look, and how file names and hashes do not.
    static func isGeneratedWord(_ word: String) -> Bool {
        guard word.count >= 32 else { return false }
        guard word.unicodeScalars.allSatisfy({ keyAlphabet.contains($0) && $0.isASCII }) else { return false }
        let upper = word.contains { $0.isUppercase }, lower = word.contains { $0.isLowercase }
        let digit = word.contains { $0.isNumber }
        return upper && lower && digit
    }

    /// The components of an absolute path, from the root or the home folder, without the empty one a
    /// final slash leaves; nil for any other word, and for one with an empty component inside, which
    /// no path has and a key with slashes may.
    static func pathComponents(_ word: String) -> [String]? {
        let rest: Substring
        if word.hasPrefix("~/") { rest = word.dropFirst(2) } else if word.hasPrefix("/") { rest = word.dropFirst() } else { return nil }
        var components = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty, !components.contains("") else { return nil }
        return components
    }

    /// Whether a path component reads as random though shorter than a key: twelve letters and digits or
    /// more, drawn from a key's alphabet, upper case, lower case and digits all present, and the kind of
    /// character changing between at least half of the adjacent letters and digits, as it does in a
    /// generated string (`aB3dE5fG7hI9jK1l`) and not in a name (`Reports2026`, `BrausAppSupport`).
    static func readsRandom(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        guard scalars.allSatisfy({ keyAlphabet.contains($0) && $0.isASCII }) else { return false }
        func kind(_ scalar: Unicode.Scalar) -> Int? {
            switch scalar.value {
                case 0x41...0x5A: 0
                case 0x61...0x7A: 1
                case 0x30...0x39: 2
                default         : nil
            }
        }
        let kinds = scalars.map(kind)
        let present = Set(kinds.compactMap { $0 })
        guard kinds.compactMap({ $0 }).count >= 12, present.count == 3 else { return false }
        var pairs = 0, changes = 0
        for (left, right) in zip(kinds, kinds.dropFirst()) {
            guard let left, let right else { continue }
            pairs += 1
            if left != right { changes += 1 }
        }
        return changes * 2 >= pairs
    }

    private static let credentialPatterns: [NSRegularExpression] = [
        "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)",
        "\\bsk-(ant-)?[A-Za-z0-9_-]{16,}",
        "\\bgh[pousr]_[A-Za-z0-9]{30,}",
        "\\bgithub_pat_[A-Za-z0-9_]{20,}",
        "\\bxox[abposr]-[A-Za-z0-9-]{10,}",
        "\\bAKIA[0-9A-Z]{16}\\b",
        "\\bAIza[0-9A-Za-z_-]{35}\\b",
        "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}",
    ].compactMap { try? NSRegularExpression(pattern: $0) }
}
