//
//  AccessibilityAugmentation.swift
//  Braus
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// AccessibilityAugmentation harvests the elements accessibility exposes cleanly and pixels mangle,
/// and merges them into a pixel-built scene. Pixels build the whole scene and the engine works with
/// no accessibility at all; this only ever adds.
///
/// Three harvests: the rows of tables, lists and outlines (a 30-track list OCR turned to mush while
/// the table held every name); focusable fields and pop-up buttons (a count field reading "1" is
/// "1"); and controls whose state pixels cannot read (an empty checkbox has nothing to segment, a
/// selected radio's dot misreads). A scrolling container clips its children, so a row a toolkit
/// reports at a virtual position outside its container is never emitted: it has no click target.
///
/// Generic over the tree reader, so the walk is decided by tests on a fake tree. The deadline is a
/// closure supplied by the caller: a reusable algorithm does not read the clock itself.
///
/// Beside the elements, `harvest` answers the quality of the read (`CaptureQuality`): whether the
/// walk reached the end of the tree or which limit stopped it, the window's role and subrole, and
/// what was counted. Each element says where its label came from (`labelOrigin`) and, for a row
/// and everything inside it, the structural path up to its collection (`collectionPath`), so a
/// consumer can tell a stable caption from content and a collection from the rows it repeats.
public enum AccessibilityAugmentation {

    /// Bounds on one walk. The deadline is asked before every node; a walk that runs out returns the
    /// rows read so far, which degrades to fewer labels, never to wrong ones.
    public struct Limits: Sendable {
        public var maxDepth: Int
        public var maxTables: Int
        public var maxElements: Int
        public var isPastDeadline: @Sendable () -> Bool

        public init(
            maxDepth      : Int = 32,
            maxTables     : Int = 24,
            maxElements   : Int = 1024,
            isPastDeadline: @escaping @Sendable () -> Bool = { false }
        ) {
            self.maxDepth       = maxDepth
            self.maxTables      = maxTables
            self.maxElements    = maxElements
            self.isPastDeadline = isPastDeadline
        }
    }

    /// Roles whose accessibility answer is authoritative over a pixel guess: right state, right role,
    /// a real click target.
    public static let interactiveRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXPopUpButton",
    ]

    /// Native roles that accept text. A pixel-inferred control does not establish this fact.
    public static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    private static let tableRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid"]
    private static let clippingRoles: Set<String> = ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXGrid"]
    private static let statefulRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton",
    ]
    private static let placeholder = "missing value"

    // MARK: Harvest

    /// Walks one window's tree and returns the harvested elements, normalized to `windowFrame`.
    /// Preserves named container paths, field values and availability. Short native static values
    /// fill OCR gaps as text, after controls have taken their share of the element budget.
    /// Duplicate labels within the same container take ordinals; labels in different containers
    /// remain independently addressable.
    /// Web ranges require native field focus: an inactive browser field can report
    /// 0..0 while retaining another DOM selection. Native fields outside web content are unchanged.
    /// The elements of `harvest`, for a caller that needs no quality.
    public static func elements<Reader: AccessibilityTreeReading>(
        under window: Reader.Node,
        windowFrame : CGRect,
        reader      : Reader,
        limits      : Limits = Limits()
    ) -> [SceneElement] {
        harvest(under: window, windowFrame: windowFrame, reader: reader, limits: limits).elements
    }

    /// Walks one window's tree and returns the harvested elements with the quality of the walk.
    ///
    /// The quality is measured, never inferred from the elements: `walkCompleted` is true only when
    /// no limit and no deadline cut the walk short and every list of children answered
    /// (`readChildren`, M2), and the first limit met is `stoppedBy`. A list that did not answer names no
    /// limit: the walk keeps the siblings it can read, and the capture is partial. A row
    /// scrolled out of its container, a frame the trust rule refuses, a sliver too thin to act on
    /// and a label outside the length bounds are filtered, not truncated: they are the walk's own
    /// rules, applied the same way on every capture, and they leave `walkCompleted` alone. Static
    /// text that the element budget leaves out is a limit like any other. A degenerate window frame
    /// reads nothing and answers `windowFound` false: there was no readable window for this capture.
    ///
    /// A label read from an attribute carries that attribute as its origin. The placeholder name an
    /// unnamed native editor receives ("Text area", "Text field") was read from nowhere, so it
    /// carries none.
    public static func harvest<Reader: AccessibilityTreeReading>(
        under window: Reader.Node,
        windowFrame : CGRect,
        reader      : Reader,
        limits      : Limits = Limits()
    ) -> AccessibilityHarvest {
        let windowRole    = reader.role(window)
        let windowSubrole = reader.subrole(window)
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return AccessibilityHarvest(elements: [], quality: CaptureQuality(
                walkCompleted  : false,
                windowFound    : false,
                windowRole     : windowRole,
                windowSubrole  : windowSubrole,
                nodesVisited   : 0,
                elementsEmitted: 0
            ))
        }
        var out: [SceneElement] = []
        var staticText: [SceneElement] = []
        var tables       = 0
        var nodesVisited = 0
        var stoppedBy: CaptureQuality.StopReason?
        // A list of children that did not answer (M2): the walk goes on with the siblings it can read, but
        // the capture is not whole. No limit stopped it, so none is named.
        var unlisted = false

        func listed(_ node: Reader.Node) -> [Reader.Node] {
            guard let children = reader.readChildren(node) else {
                unlisted = true
                return []
            }
            return children
        }

        func stop(_ reason: CaptureQuality.StopReason) {
            if stoppedBy == nil { stoppedBy = reason }
        }

        func emit(_ frame: CGRect, role: String, label: String, origin: LabelOrigin?, state: ControlState?,
                  clip: CGRect, container: String?, collectionPath: String?, value: String? = nil,
                  isEnabled: Bool? = nil, selectedRange: NSRange? = nil, kind: ElementKind = .control) {
            guard (kind == .text ? staticText.count : out.count) < limits.maxElements else {
                return stop(.elementLimit)
            }
            // Chrome reports offscreen controls as one-point edge frames.
            // Such slivers cannot supply a usable position or an observed value.
            let visible = frame.intersection(clip).intersection(windowFrame)
            guard visible.width >= 2, visible.height >= 2,
                  let bounds = AccessibilityFrameTrust.normalized(frame, in: windowFrame),
                  clip.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
            let element = SceneElement(
                id            : SceneIdentity.key(kind: kind, label: label, bounds: bounds, isUnlabeled: false),
                kind          : kind,
                label         : label,
                bounds        : bounds,
                role          : role,
                state         : state,
                value         : value,
                selectedRange : selectedRange,
                isEnabled     : isEnabled,
                container     : container,
                labelOrigin   : origin,
                collectionPath: collectionPath
            )
            if kind == .text { staticText.append(element) } else { out.append(element) }
        }

        // A switch or checkbox with no name of its own is captioned by the static text just before it
        // in its parent (System Settings), else by its identifier, else by its role: never dropped.
        func caption(of node: Reader.Node, after preceding: Reader.Node?) -> (String, LabelOrigin?) {
            if let preceding, reader.role(preceding) == "AXStaticText",
               let (text, _) = firstLabel([(reader.value(preceding), .value), (reader.title(preceding), .title)]),
               text.count <= 48 {
                return (text, .value)
            }
            if let handle = firstText([reader.identifier(node)]) {
                let words = handle.split { $0 == "-" || $0 == "_" }.joined(separator: " ")
                return (words.prefix(1).uppercased() + words.dropFirst(), .identifier)
            }
            let anonymous = reader.role(node) == "AXRadioButton" ? "Radio button"
                : reader.subrole(node) == "AXSwitch" ? "Switch" : "Checkbox"
            return (anonymous, nil)
        }

        // The static text just before a field in its parent, when it reads as a form label: it ends with a
        // colon. Any other text there is content, not the field's name.
        func formCaption(before preceding: Reader.Node?) -> String? {
            guard let preceding, reader.role(preceding) == "AXStaticText",
                  let (text, _) = firstLabel([(reader.value(preceding), .value), (reader.title(preceding), .title)]),
                  text.hasSuffix(":"), text.count <= 48
            else { return nil }
            return text
        }

        func walk(_ node: Reader.Node, _ depth: Int, _ clip: CGRect, _ container: String?,
                  collectionPath: String?, column: String? = nil, rowName: String? = nil,
                  insideControl: Bool = false, insideWebContent: Bool = false, preceding: Reader.Node? = nil) {
            guard depth < limits.maxDepth else { return stop(.depthLimit) }
            guard out.count < limits.maxElements else { return stop(.elementLimit) }
            guard !limits.isPastDeadline() else { return stop(.deadline) }
            nodesVisited += 1
            let role = reader.role(node) ?? ""
            let webContent = insideWebContent || role == "AXWebArea"
            var childContainer = container
            var isNamed = false
            if role == "AXGroup" || tableRoles.contains(role),
               let name = firstText([reader.title(node), reader.descriptionText(node)]),
               !name.hasPrefix("UI_"), name.count <= 80 {
                let clean = cleanLabel(name)
                childContainer = container.map { $0 + " / " + clean } ?? clean
                isNamed = true
            }
            // A scrolling container tightens the clip and prunes a subtree entirely outside it. A plain
            // group also tightens (some toolkits scroll in groups) but is never trusted to prune.
            var childClip = clip
            if clippingRoles.contains(role), let frame = reader.frame(node), frame.width >= 8, frame.height >= 8 {
                let inner = clip.intersection(frame)
                guard !inner.isNull, inner.width >= 8, inner.height >= 8 else { return }
                childClip = inner
            } else if role == "AXGroup", let frame = reader.frame(node), frame.width >= 8, frame.height >= 8 {
                let inner = clip.intersection(frame)
                if !inner.isNull, inner.width >= 8, inner.height >= 8 { childClip = inner }
            }
            if tableRoles.contains(role) {
                guard tables < limits.maxTables else { return stop(.tableLimit) }
                tables += 1
                // The collection's structural path: the table's own title when it has one, else its
                // role. A collection inside a row keeps the outer collection: a row's name is content.
                let collection = collectionPath
                    ?? (isNamed ? childContainer : container.map { $0 + " / " + role } ?? role)
                let children = listed(node)
                let columns = children.filter { reader.role($0) == "AXColumn" }.map {
                    firstText([reader.title($0), reader.descriptionText($0)])
                }
                for row in children where reader.role(row) == "AXRow" {
                    if out.count >= limits.maxElements { stop(.elementLimit); break }
                    if limits.isPastDeadline() { stop(.deadline); break }
                    nodesVisited += 1
                    if let rowFrame = reader.frame(row), rowFrame.height > 0, !childClip.intersects(rowFrame) {
                        continue
                    }
                    let named = deepestNamed(row, reader: reader, isPastDeadline: limits.isPastDeadline,
                                             unlisted: { unlisted = true })
                    if limits.isPastDeadline() { stop(.deadline) }
                    guard let named else { continue }
                    let label = cleanLabel(named.name)
                    guard label.count >= 2, label.count <= 48 else { continue }
                    emit(named.frame, role: "AXRow", label: label, origin: .rowContent, state: nil,
                         clip: childClip, container: childContainer, collectionPath: collection,
                         isEnabled: reader.isEnabled(row))
                    let owner = childContainer.map { $0 + " / " + label } ?? label
                    let cells = listed(row)
                    // Only use column order when the table exposes a complete cell-to-column map.
                    // Otherwise traverse the controls with their own labels and row context.
                    let aligned = cells.count == columns.count && cells.allSatisfy { reader.role($0) == "AXCell" }
                    for (index, cell) in cells.enumerated() {
                        walk(cell, depth + 2, childClip, owner, collectionPath: collection,
                             column: aligned ? columns[index] : nil, rowName: label,
                             insideControl: insideControl, insideWebContent: webContent)
                    }
                }
                return
            }
            if role == "AXStaticText", !insideControl, let frame = reader.frame(node) {
                let value = reader.value(node)
                if let (label, origin) = firstLabel([(value, .value), (reader.title(node), .title)]),
                   label.count <= 48, rowName != cleanLabel(label) {
                    emit(frame, role: role, label: label, origin: origin, state: nil, clip: clip,
                         container: container, collectionPath: collectionPath, value: value, kind: .text)
                }
            }
            if role == "AXTextField" || role == "AXTextArea" || role == "AXPopUpButton", let frame = reader.frame(node) {
                let rawValue = reader.value(node)
                // An unnamed empty native editor still has a measured role and frame.
                let anonymousHandle = role == "AXTextArea" ? "Text area" : "Text field"
                // A form names an unnamed field by the "Name:" text just before it, and its value is only
                // what it holds now (Pro Tools' rename dialog): the caption comes before the value.
                let formLabel = textEntryRoles.contains(role) ? formCaption(before: preceding) : nil
                let read = column.map { ($0, LabelOrigin.column) } ?? firstLabel([
                    (reader.descriptionText(node), .description),
                    (reader.title(node), .title),
                    (formLabel, .value),
                    (role == "AXTextArea" ? reader.identifier(node) : nil, .identifier),
                    (rawValue, .value),
                ])
                let handle: (String, LabelOrigin?)? = read.map { ($0.0, $0.1) }
                    ?? (textEntryRoles.contains(role) ? (anonymousHandle, nil) : nil)
                if let (handle, origin) = handle, handle.count <= 48, column != nil || rowName != cleanLabel(handle) {
                    emit(frame, role: role, label: handle, origin: origin, state: nil, clip: clip,
                         container: container, collectionPath: collectionPath,
                         value: role == "AXPopUpButton" ? firstText([rawValue, reader.title(node)]) : rawValue,
                         isEnabled: reader.isEnabled(node),
                         selectedRange: textEntryRoles.contains(role)
                            && (!webContent || reader.isFocused(node) == true) ? reader.selectedRange(node) : nil)
                }
            }
            if statefulRoles.contains(role), let frame = reader.frame(node) {
                let title = column.map { ($0, LabelOrigin.column) } ?? firstLabel([
                    (reader.title(node), .title),
                    (reader.descriptionText(node), .description),
                ])
                let rawValue = reader.value(node)
                let value = firstText([rawValue])
                var state: ControlState?
                if role == "AXCheckBox" || role == "AXRadioButton" {
                    switch reader.numericValue(node) {
                        case 1 : state = .on
                        case 0 : state = .off
                        case 2 : state = .mixed
                        default: break
                    }
                }
                if role == "AXButton" { state = reader.buttonState(node, value: rawValue) }
                var labeled: (String, LabelOrigin?)?
                if let title {
                    labeled = title
                } else if let value {
                    labeled = (value, .value)
                } else if role == "AXCheckBox" || role == "AXRadioButton" {
                    labeled = caption(of: node, after: preceding)
                }
                if let (label, origin) = labeled, label.count <= 48, column != nil || rowName != cleanLabel(label) {
                    emit(frame, role: role, label: label, origin: origin, state: state, clip: clip,
                         container: container, collectionPath: collectionPath,
                         value: role == "AXComboBox" ? rawValue : (role == "AXMenuButton" ? value : nil),
                         isEnabled: reader.isEnabled(node),
                         selectedRange: role == "AXComboBox"
                            && (!webContent || reader.isFocused(node) == true) ? reader.selectedRange(node) : nil)
                }
            }
            var previous: Reader.Node?
            for child in listed(node) {
                walk(child, depth + 1, childClip, childContainer, collectionPath: collectionPath,
                     column: column, rowName: rowName,
                     insideControl: insideControl || interactiveRoles.contains(role) || role == "AXTextArea",
                     insideWebContent: webContent, preceding: previous)
                previous = child
            }
        }
        walk(window, 0, windowFrame, nil, collectionPath: nil)
        let room = max(0, limits.maxElements - out.count)
        if staticText.count > room { stop(.elementLimit) }
        out.append(contentsOf: staticText.prefix(room))

        var seen: [String: Int] = [:]
        for index in out.indices {
            let key = out[index].kind.rawValue + "\n" + (out[index].container ?? "") + "\n" + out[index].label
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count > 1 { out[index].label += " #\(count)" }
        }
        return AccessibilityHarvest(elements: out, quality: CaptureQuality(
            walkCompleted  : stoppedBy == nil && !unlisted,
            stoppedBy      : stoppedBy,
            windowFound    : true,
            windowRole     : windowRole,
            windowSubrole  : windowSubrole,
            nodesVisited   : nodesVisited,
            elementsEmitted: out.count
        ))
    }

    // MARK: Merge

    /// Merges harvested elements into a pixel-built list. A harvested element is dropped only
    /// when a pixel element already carries the same core label or field value at the same spot. An interactive
    /// harvest upgrades that pixel element in place, keeping its precise position and taking the
    /// authoritative identity, role, state and clean name; a row harvest yields to the pixel element.
    ///
    /// A harvested name is cleaner than a pixel guess over the same widget, so it wins: a static text
    /// takes the label of the pixel text it matches, and a placed non-row, non-field element removes the
    /// unlabeled icons and the lone pixel text it covers. A pixel row that merely contains a harvested
    /// name keeps the rest of its text. Pixels stay wherever accessibility has nothing to say.
    ///
    /// A harvested element is final once placed, whether it upgraded a pixel element or was appended
    /// as its own. Some toolkits expose one visual control twice (a panel tab is a radio button
    /// carrying the state and a combo box carrying the same title); the second facet matches the
    /// first and is redundant, so it is skipped rather than allowed to overwrite the state the first
    /// one brought. Measured live on Premiere's tab strip, both ways.
    ///
    /// The harvested facts about structure survive the merge: a pixel element that a harvested one
    /// matches takes its `collectionPath` when it had none, and an upgrade takes the harvested
    /// label together with its `labelOrigin`. A pixel element that keeps its own label keeps no
    /// origin: its name came from pixels.
    public static func merge(pixels: [SceneElement], accessibility: [SceneElement]) -> [SceneElement] {
        guard !accessibility.isEmpty else { return pixels }
        var result = pixels
        // Normalize once per label, then update alongside upgrades and appends. Re-tokenizing
        // every candidate for every native element makes dense scenes needlessly quadratic in text work.
        var coreKeys = pixels.map { LabelText.coreKey(strippingOrdinal($0.label)) }
        var valueKeys = pixels.map { LabelText.coreKey($0.label) }
        var upgraded = Set<Int>()
        var removed = Set<Int>()

        // Pixel elements over the same widget as `element`, other than the one it matched.
        func absorb(_ element: SceneElement, matched: Int?) {
            guard element.role != "AXRow", !textEntryRoles.contains(element.role ?? "") else { return }
            let box = element.bounds
            let label = strippingOrdinal(element.label)
            var captions: [Int] = []
            for index in result.indices where index != matched && !upgraded.contains(index)
                && !removed.contains(index) {
                let pixel = result[index]
                let shared = pixel.bounds.cgRect.intersection(box.cgRect)
                guard !shared.isNull, shared.width * shared.height > 0 else { continue }
                let covered = Double(shared.width * shared.height)
                if pixel.kind == .icon, pixel.isUnlabeled {
                    // A name is not claimed for a glyph inside something much taller than the glyph.
                    if covered > 0.6 * pixel.bounds.area, box.height <= 2.5 * pixel.bounds.height {
                        removed.insert(index)
                    }
                } else if pixel.kind == .text, pixel.role == nil {
                    // A name found as whole words inside a longer pixel row shortens that row.
                    if covered > 0.4 * min(box.area, pixel.bounds.area), label.count >= 2,
                       LabelText.isNameworthy(label), pixel.label.count > label.count,
                       let range = pixel.label.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]),
                       !(pixel.label[..<range.lowerBound].last.map { $0.isLetter || $0.isNumber } ?? false),
                       !(pixel.label[range.upperBound...].first.map { $0.isLetter || $0.isNumber } ?? false) {
                        let before = pixel.label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                        let after = pixel.label[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        let rest = (before + " " + after).trimmingCharacters(in: .whitespaces)
                        guard LabelText.tokens(rest).contains(where: { $0.count >= 2 }) else {
                            removed.insert(index)
                            continue
                        }
                        // Only one end can be cut from the row's box; a name in the middle keeps it whole.
                        var bounds = pixel.bounds
                        if after.isEmpty, box.x > bounds.x {
                            bounds.width = box.x - bounds.x
                        } else if before.isEmpty, box.maxX < bounds.maxX {
                            bounds.width = bounds.maxX - box.maxX
                            bounds.x = box.maxX
                        }
                        result[index].label = rest
                        result[index].bounds = bounds
                        result[index].id = SceneIdentity.key(
                            kind       : .text,
                            label      : rest,
                            bounds     : bounds,
                            isUnlabeled: false
                        )
                        coreKeys[index] = LabelText.coreKey(strippingOrdinal(rest))
                        valueKeys[index] = LabelText.coreKey(rest)
                    } else if covered > 0.6 * pixel.bounds.area {
                        captions.append(index)
                    }
                }
            }
            // One pixel text inside the widget is its caption, however it was misread.
            if captions.count == 1, box.area <= 8 * result[captions[0]].bounds.area { removed.insert(captions[0]) }
        }

        for element in accessibility {
            let core = LabelText.coreKey(strippingOrdinal(element.label))
            let isInteractive = interactiveRoles.contains(element.role ?? "")
            // Duplicate evidence must overlap the same widget. Window-relative distance thresholds
            // collapse neighboring mixer buttons and bind dense list rows to the preceding row.
            var match = core.isEmpty ? nil : result.indices
                .filter { coreKeys[$0] == core }
                .map { ($0, overlap(result[$0].bounds, element.bounds)) }
                .filter { $0.1 > 0.6 }
                .max { $0.1 < $1.1 }?.0
            if match == nil, let value = element.value,
               ["AXTextField", "AXPopUpButton", "AXComboBox", "AXMenuButton"].contains(element.role ?? "") {
                let valueKey = LabelText.coreKey(value)
                let candidates = result.indices.filter {
                    result[$0].role == nil && result[$0].kind == .text && !valueKey.isEmpty
                        && valueKeys[$0] == valueKey
                        && overlap(result[$0].bounds, element.bounds) > 0.6
                }
                if candidates.count == 1 { match = candidates.first }
            }
            if let index = match {
                // A static text names the same words more cleanly than a recognizer that fused a glyph into them.
                if !isInteractive, !upgraded.contains(index), element.kind == .text,
                   result[index].kind == .text, result[index].role == nil,
                   result[index].label != strippingOrdinal(element.label) {
                    upgraded.insert(index)
                    result[index].id = element.id
                    result[index].role = element.role
                    result[index].value = element.value
                    result[index].container = element.container
                    result[index].label = element.label
                    coreKeys[index] = core
                    valueKeys[index] = LabelText.coreKey(element.label)
                    continue
                }
                absorb(element, matched: index)
                if result[index].container == nil { result[index].container = element.container }
                if result[index].collectionPath == nil { result[index].collectionPath = element.collectionPath }
                if result[index].isEnabled == nil { result[index].isEnabled = element.isEnabled }
                if result[index].value == nil { result[index].value = element.value }
                guard isInteractive, !upgraded.contains(index) else { continue }
                upgraded.insert(index)
                result[index].kind = .control
                result[index].id = element.id
                result[index].role = element.role
                result[index].state = element.state
                result[index].value = element.value
                result[index].selectedRange = element.selectedRange
                result[index].isEnabled = element.isEnabled
                result[index].container = element.container
                result[index].collectionPath = element.collectionPath
                result[index].label = element.label
                result[index].labelOrigin = element.labelOrigin
                coreKeys[index] = core
                valueKeys[index] = LabelText.coreKey(element.label)
                result[index].isUnlabeled = false
                if result[index].does == nil { result[index].does = element.does }
            } else {
                absorb(element, matched: nil)
                upgraded.insert(result.count)
                result.append(element)
                coreKeys.append(core)
                valueKeys.append(LabelText.coreKey(element.label))
            }
        }
        return result.indices.filter { !removed.contains($0) }.map { result[$0] }
    }

    private static func overlap(_ first: NormalizedRect, _ second: NormalizedRect) -> Double {
        let intersection = first.cgRect.intersection(second.cgRect)
        let smaller = min(first.area, second.area)
        guard !intersection.isNull, smaller > 0 else { return 0 }
        return Double(intersection.width * intersection.height) / smaller
    }

    // MARK: Names

    /// The most specific human name inside a row's subtree, with that node's frame. Some toolkits bury
    /// a row's name in a grandchild whose value reads "Audio 13 - Audio Track ".
    static func deepestNamed<Reader: AccessibilityTreeReading>(
        _ row         : Reader.Node,
        reader        : Reader,
        isPastDeadline: () -> Bool,
        unlisted      : () -> Void = {}
    ) -> (name: String, frame: CGRect)? {
        let rowFrame = reader.frame(row)
        var best: (name: String, frame: CGRect)?
        func visit(_ node: Reader.Node, _ depth: Int) {
            if isPastDeadline() { return }
            for candidate in [reader.value(node), reader.title(node), reader.descriptionText(node)] {
                guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text != placeholder else { continue }
                let lower = text.lowercased()
                guard lower != "cell", lower != "button", lower != "row" else { continue }
                if text.count > (best?.name.count ?? 0), let frame = reader.frame(node) ?? rowFrame {
                    best = (text, frame)
                }
            }
            guard depth < 4 else { return }
            guard let children = reader.readChildren(node) else { return unlisted() }
            for child in children { visit(child, depth + 1) }
        }
        visit(row, 0)
        return best
    }

    /// The kinds of track a toolkit appends to a track's name, as measured (Pro Tools, 19/10/2026).
    /// The driver keeps the same list in `RemoteContentActuator`, and a broker test keeps them in step.
    static let roleSuffixes = [" - Audio Track", " - Routing Folder Track"]

    /// Trims the role suffix and state prefix some toolkits append ("Audio 13 - Audio Track ",
    /// "Shown. Audio 13") down to the name a person says.
    static func cleanLabel(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let roleSuffix = roleSuffixes.first(where: text.hasSuffix) { text = String(text.dropLast(roleSuffix.count)) }
        for prefix in ["Shown. ", "Hidden. ", "Selected. ", "Active. ", "Inactive. "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Drops a trailing " #N" ordinal so a pixel label and its harvested twin still core-match.
    static func strippingOrdinal(_ label: String) -> String {
        guard let hash = label.range(of: " #", options: .backwards),
              hash.upperBound < label.endIndex,
              label[hash.upperBound...].allSatisfy(\.isNumber) else { return label }
        return String(label[..<hash.lowerBound])
    }

    private static func firstText(_ candidates: [String?]) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != placeholder }
    }

    /// The first usable text among the candidates, with the attribute it was read from.
    private static func firstLabel(_ candidates: [(String?, LabelOrigin)]) -> (String, LabelOrigin)? {
        for (candidate, origin) in candidates {
            guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text != placeholder else { continue }
            return (text, origin)
        }
        return nil
    }
}
