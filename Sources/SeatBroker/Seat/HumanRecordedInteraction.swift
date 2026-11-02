//
//  HumanRecordedInteraction.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import CoreGraphics
import Foundation
import InteractionListener
import InteractionObservation

/// HumanRecordedInteraction is an immutable observation, not proof that the action had an effect.
/// AX metadata and optional pixels are read after delivery. Typing has no key, text or count field.
/// An inferred keyboard target retains the last eligible click's metadata and captured window title.
struct HumanRecordedInteraction: Sendable {
    /// SummaryAction carries target identity for merging without pictures, points or typed values.
    struct SummaryAction: Sendable, Codable {
        let kind: InteractionEvent.Kind
        let processID: Int32
        let windowNumber: Int?
        var windowTitle: String?
        let role: String?
        let label: String?
        let isProtected: Bool
        let destination: String?
        let commandName: String?
        let lostCritical: Int
        var provenance: HumanActionProvenance? = nil
        /// A clicked button's part in its dialog, from its window; absent in older sidecars.
        var windowButton: InteractionElementMetadata.WindowButton? = nil

        var target: String { isProtected ? "a protected field" : label ?? "unknown target" }
        var isUnknown: Bool { !isProtected && label == nil }
        var isMenu: Bool { kind == .click && ["AXMenuItem", "AXMenuBarItem"].contains(role ?? "") }
        var isField: Bool {
            ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXSecureTextField"].contains(role ?? "")
        }

        func sameTarget(as other: Self) -> Bool {
            !isUnknown && !other.isUnknown && !isProtected && !other.isProtected
                && processID == other.processID && windowNumber != nil && windowNumber == other.windowNumber
                && role == other.role && label == other.label
        }
    }

    var summaryAction: SummaryAction {
        func nonempty(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
        let state = provenance.attestedState.flatMap { $0.processID == processID ? $0 : nil }
        let observedFocus = state?.focusedElement
        let focus = (kind == .typing || kind == .shortcut)
            && (window == nil || observedFocus?.window == window?.number) ? observedFocus : nil
        let protected = element?.isProtected == true || provenance.semantics?.focused == .protected
        let focusedWindow = focus?.window
        return SummaryAction(
            kind: kind,
            processID: processID,
            windowNumber: focusedWindow ?? window?.number,
            windowTitle: protected ? nil : nonempty(focusedWindow.flatMap { state?.windowTitles[$0] } ?? window?.title),
            role: focus?.role ?? element?.role,
            label: protected ? nil : nonempty(focus?.label ?? element?.label),
            isProtected: protected,
            destination: endElement?.isProtected == true ? "a protected field" : nonempty(endElement?.label),
            commandName: commandName,
            lostCritical: Int(gap?.lostCritical ?? 0),
            provenance: provenance,
            windowButton: kind == .click ? element?.windowButton : nil
        )
    }

    let kind: InteractionEvent.Kind
    let sourceSequence: UInt64
    let provenance: HumanActionProvenance
    let startedAt: Double
    let endedAt: Double
    let processID: Int32
    let window: InteractionWindow?
    let point: CGPoint?
    let endPoint: CGPoint?
    let element: InteractionElementMetadata?
    let isTargetInferredFromLastClick: Bool
    let endElement: InteractionElementMetadata?
    let keyCode: UInt16?
    let modifiers: InteractionEvent.Modifiers?
    let commandName: String?
    let clickCount: UInt32?
    let deltaX: Double
    let deltaY: Double
    let gap: InteractionEvent.Gap?
    let picture: HumanPreviewControl.RetainedPicture?

    init(
        event: InteractionEvent,
        processID: Int32? = nil,
        element: InteractionElementMetadata?,
        endElement: InteractionElementMetadata?,
        isTargetInferredFromLastClick: Bool = false,
        inferredWindow: InteractionWindow? = nil,
        semantics: InteractionSemanticSnapshot? = nil,
        stateAtAction: Bool = false,
        beforeSemantics: InteractionSemanticSnapshot? = nil,
        commandName: String?,
        picture: HumanPreviewControl.RetainedPicture?
    ) {
        kind = event.kind
        sourceSequence = event.sequence
        provenance = HumanActionProvenance(interval: .init(start: event.startedAt, end: event.endedAt),
            sourceSequence: event.sequence, targetInferred: isTargetInferredFromLastClick,
            stateAtAction: stateAtAction, semantics: semantics, beforeSemantics: beforeSemantics)
        startedAt = event.startedAt
        endedAt = event.endedAt
        self.processID = processID ?? event.processID
        self.isTargetInferredFromLastClick = isTargetInferredFromLastClick
        if kind == .typing || kind == .shortcut {
            window = isTargetInferredFromLastClick ? inferredWindow : event.window.map {
                InteractionWindow(processID: $0.processID, number: $0.number, title: nil, layer: $0.layer, frame: $0.frame)
            }
        } else { window = kind == .gap ? nil : event.window }
        let pointer = [.click, .rightClick, .scroll, .drag].contains(kind)
        point = pointer ? event.point : nil
        endPoint = kind == .drag ? event.endPoint : nil
        self.element = element
        self.endElement = endElement
        keyCode = kind == .shortcut ? event.keyCode : nil
        modifiers = kind == .shortcut ? event.modifiers : nil
        self.commandName = kind == .shortcut ? commandName : nil
        clickCount = kind == .click || kind == .rightClick ? event.clickCount : nil
        deltaX = kind == .scroll ? event.deltaX : 0
        deltaY = kind == .scroll ? event.deltaY : 0
        gap = kind == .gap ? event.gap : nil
        self.picture = picture
    }

    /// Charges history indexes, summary metadata and string storage. Immutable strings and HEIC
    /// bytes are shared; native capture's one in-flight allocation is separate from this queue.
    var retainedBytes: Int {
        let strings = [window?.title, element?.role, element?.subrole, element?.label,
                       endElement?.role, endElement?.subrole, endElement?.label, commandName]
        return 1024 + strings.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count * 4 }
            + (picture?.heic.count ?? 0) + (provenance.semantics?.retainedBytes ?? 0)
            + (provenance.beforeSemantics?.retainedBytes ?? 0)
    }

    var diagnostic: String {
        let action = kind == .typing ? "typed in" : kind.rawValue
        let target = element.map {
            $0.isProtected ? "protected field \($0.role ?? "unknown role")"
                : "\($0.role ?? "unknown role") \"\($0.label ?? "")\""
        } ?? "unknown element"
        let command = commandName.map { " \($0)" } ?? ""
        let count = clickCount.map { " count=\($0)" } ?? ""
        let loss = gap.map { " lost=\($0.lostCritical) critical, \($0.lostCoalescible) coalescible" } ?? ""
        let pixels = picture.map { "picture \(($0.heic.count + 1023) / 1024) KB" } ?? "no picture"
        let inference = isTargetInferredFromLastClick ? " (from last click)" : ""
        let line = "\(action)\(command)\(count) \(target) in \"\(window?.title ?? "")\"\(inference) \(pixels)\(loss)"
        return line.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
    }
}
