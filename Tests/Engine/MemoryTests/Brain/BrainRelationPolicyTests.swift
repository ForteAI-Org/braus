//
//  BrainRelationPolicyTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 11/10/2026.
//

import EngineCore
import Foundation
@testable import Memory
import PerceptionCore
import Testing

/// What one concluded call teaches the Brain's relations, as a pure rule over its recorded facts: the
/// precise verb and the arguments that change it, the structural element, the outcome the verification
/// judged, the states before and after, and every reason a call teaches nothing.
@Suite("Brain relations from verified calls")
struct BrainRelationPolicyTests {

    static let bundle = "com.example.Editor"

    static let export = CaptureElement(kind: .control, role: "AXButton", label: "Export", labelOrigin: .title, containerPath: "toolbar",
                                       isUnderCollection: false, state: nil, bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.04))
    static let field = CaptureElement(kind: .control, role: "AXTextField", label: "foto.png", labelOrigin: .value, containerPath: "",
                                      isUnderCollection: false, state: nil, bounds: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.04))
    static let row = CaptureElement(kind: .control, role: "AXRow", label: "foto.png", labelOrigin: .rowContent, containerPath: "files",
                                    isUnderCollection: true, state: nil, bounds: NormalizedRect(x: 0.2, y: 0.5, width: 0.5, height: 0.04))

    static func facts(_ request: AgentCallRequest, _ verification: QualificationPolicy.VerificationFact?,
                      status: AgentCallStatus = .completed, effect: String? = "elementsAppeared", expected: String? = nil,
                      role: String? = "AXButton", label: String? = "Export", from: String? = "S", to: String? = "S",
                      elements: [CaptureElement] = [export, field, row], gap: Bool = false,
                      withheld: Bool = false, beforeAwaits: Bool = false, afterAwaits: Bool = false) -> BrainRelationPolicy.Facts {
        BrainRelationPolicy.Facts(callEventID: "c", bundleID: bundle, contextID: nil, request: request, status: status, hasRecordingGap: gap,
                                  hasWithheldTarget: withheld, verification: verification, expected: expected, observed: nil,
                                  observedEffectKind: effect, targetRole: role, targetLabel: label, fromSceneID: from, toSceneID: to,
                                  beforeAwaitsState: beforeAwaits, afterAwaitsState: afterAwaits, beforeElements: elements)
    }

    static func control(_ role: String, _ label: String, origin: LabelOrigin, in path: String = "form", x: Double = 0.1) -> CaptureElement {
        CaptureElement(kind: .control, role: role, label: label, labelOrigin: origin, containerPath: path, isUnderCollection: false,
                       state: nil, bounds: NormalizedRect(x: x, y: 0.3, width: 0.2, height: 0.04))
    }

    static func verified(_ condition: OperationCheck.Condition, _ verdict: OperationCheck.Verdict = .passed,
                         performed: OperationCheck.Performed = .requested, limits: [OperationCheck.Limit] = []) -> QualificationPolicy.VerificationFact {
        QualificationPolicy.VerificationFact(eventID: "v", condition: condition, verdict: verdict, performed: performed, limits: limits)
    }

    static func click(_ verb: ActionVerb = .click, value: ControlState? = nil) -> AgentCallRequest {
        .act(target: "Export", verb: verb, value: value, section: nil)
    }

    @Test("each act verb is its own relation: a double click teaches nothing about a click; a toggle keeps its requested state")
    func preciseVerbs() throws {
        for verb in [ActionVerb.click, .doubleClick, .tripleClick, .rightClick] {
            guard case .supports(let key) = BrainRelationPolicy.decide(Self.facts(Self.click(verb), Self.verified(.structuralEffect))) else {
                Issue.record("\(verb) taught nothing"); continue
            }
            #expect(key.verb == BrainVerb(verb) && key.elementKey == "control|toolbar|AXButton|export" && key.argumentsKey.isEmpty)
            #expect(key.outcome == .effect && key.effectKind == "elementsAppeared")
        }
        guard case .supports(let toggle) = BrainRelationPolicy.decide(Self.facts(Self.click(.setToggle, value: .on),
                                                                                  Self.verified(.stateAfterGesture))) else {
            Issue.record("the toggle taught nothing"); return
        }
        #expect(toggle.verb == .setToggle && toggle.argumentsKey == "value=on" && toggle.outcome == .stateSet)
    }

    @Test("a key that changes a field's value teaches its relation by the family alone, and the engine compares by that family")
    func valueChanges() throws {
        let key = AgentCallRequest.pressKey(key: KeyChord.Name("return")!, modifiers: [], count: 1)
        guard case .supports(let relation) = BrainRelationPolicy.decide(Self.facts(key, Self.verified(.structuralEffect),
                                                                                   effect: "valueChanged")) else {
            Issue.record("the value change taught nothing"); return
        }
        #expect(relation.outcome == .effect && relation.effectKind == "valueChanged")
        #expect(BrainRelationPolicy.effectFamilies.contains("valueChanged"))
        #expect(BrainMemory.effect(ofFamily: "valueChanged")?.family == "valueChanged")
    }

    @Test("a whole-window verdict of a key or a scroll over the window teaches no relation, and a click still does")
    func windowWideVerdictOfAKeyTeachesNothing() {
        // Escape and Return learned valueChanged, Space learned elementsAppeared: a counter or a light changed alone.
        let wide = Self.verified(.structuralEffect, limits: [.windowWide, .noExpectation])
        for request in [AgentCallRequest.pressKey(key: KeyChord.Name("escape")!, modifiers: [], count: 1),
                        .pressKey(key: KeyChord.Name("space")!, modifiers: [], count: 1),
                        .scroll(direction: .down, lines: 3, target: nil, section: nil)] {
            #expect(BrainRelationPolicy.decide(Self.facts(request, wide, effect: "valueChanged")) == .excluded(.notLearnable))
            #expect(BrainRelationPolicy.decide(Self.facts(request, Self.verified(.structuralEffect, .failed, limits: [.windowWide]),
                                                          expected: "valueChanged")) == .excluded(.notLearnable),
                    "a window that did not change contradicts nothing either")
        }
        guard case .supports = BrainRelationPolicy.decide(Self.facts(Self.click(), wide)) else {
            Issue.record("a click judged in its control's scope taught nothing"); return
        }
        let scoped = AgentCallRequest.pressKey(key: KeyChord.Name("return")!, modifiers: [], count: 1)
        guard case .supports = BrainRelationPolicy.decide(Self.facts(scoped, Self.verified(.structuralEffect), effect: "valueChanged"))
        else { Issue.record("a key verdict with no window-wide limit taught nothing"); return }
    }

    @Test("every operation tool has its verb and the arguments that change it; parameters are no part of a relation")
    func everyTool() throws {
        let cases: [(AgentCallRequest, QualificationPolicy.VerificationFact, String, String, String?, String?)] = [
            (.select(control: "Export", item: "JPEG"), Self.verified(.valueReadBack), "select", "item=jpeg", "AXButton", "Export"),
            (.typeText(target: "foto.png", text: "anything", section: nil, replace: false), Self.verified(.valueReadBack), "type_text",
             "replace=false", "AXTextField", "foto.png"),
            (.insertText(text: "x", expectedValue: "x"), Self.verified(.valueReadBack), "insert_text", "", nil, nil),
            (.pressKey(key: KeyChord.Name("s")!, modifiers: [.cmd, .shift], count: 3), Self.verified(.structuralEffect), "press_key",
             "key=s;modifiers=cmd+shift;count=3", nil, nil),
            (.scroll(direction: .down, lines: 7, target: nil, section: nil), Self.verified(.structuralEffect), "scroll",
             "direction=down;over=window", nil, nil),
            (.drag(from: "Export", to: .offset(dx: 10, dy: 0), section: nil), Self.verified(.structuralEffect), "drag",
             "to=offset;dx=+;dy=0", "AXButton", "Export"),
            (.contextMenu(target: "Export", item: "Open With", section: nil), Self.verified(.menuItemChosen,
             limits: [.commandEffectUnchecked]), "context_menu", "item=openwith", "AXButton", "Export"),
        ]
        for (request, verification, verb, arguments, role, label) in cases {
            guard case .supports(let key) = BrainRelationPolicy.decide(Self.facts(request, verification, role: role, label: label)) else {
                Issue.record("\(verb) taught nothing"); continue
            }
            #expect(key.verb.rawValue == verb && key.argumentsKey == arguments, "\(key)")
        }
        // Different texts are the same relation: a text is a parameter.
        let first = BrainRelationPolicy.decide(Self.facts(.typeText(target: "foto.png", text: "a", section: nil, replace: true),
                                                          Self.verified(.valueReadBack), role: "AXTextField", label: "foto.png"))
        let second = BrainRelationPolicy.decide(Self.facts(.typeText(target: "foto.png", text: "b", section: nil, replace: true),
                                                           Self.verified(.valueReadBack), role: "AXTextField", label: "foto.png"))
        #expect(first == second)
        // A click on any row of a list is a click on the list's rows.
        guard case .supports(let rowKey) = BrainRelationPolicy.decide(Self.facts(Self.click(), Self.verified(.structuralEffect),
                                                                                   role: "AXRow", label: "foto.png")) else {
            Issue.record("the row taught nothing"); return
        }
        #expect(rowKey.elementKey == "item_template|files|AXRow|")
    }

    @Test("a target is one physical element: two with its label are ambiguous, one sharing its key with another is indistinct, a named one is identified whatever its value")
    func instanceIdentity() throws {
        let typed = AgentCallRequest.typeText(target: "photo.png", text: "a", section: nil, replace: true)
        let name = Self.control("AXTextField", "photo.png", origin: .value)
        let destination = Self.control("AXTextField", "/tmp/export", origin: .value, x: 0.6)
        #expect(BrainRelationPolicy.decide(Self.facts(typed, Self.verified(.valueReadBack), role: "AXTextField", label: "photo.png",
                                                      elements: [name, destination])) == .excluded(.indistinctElement),
                "two fields with no name share a template: what the call did teaches neither")
        let twin = Self.control("AXTextField", "photo.png", origin: .value, in: "other")
        #expect(BrainRelationPolicy.decide(Self.facts(typed, Self.verified(.valueReadBack), role: "AXTextField", label: "photo.png",
                                                      elements: [name, twin])) == .excluded(.ambiguousElement),
                "two physical elements with the target's label are ambiguous, even with different keys")
        let named = Self.control("AXTextField", "File name", origin: .description)
        let other = Self.control("AXTextField", "Destination", origin: .description, x: 0.6)
        let byName = AgentCallRequest.typeText(target: "File name", text: "a", section: nil, replace: true)
        guard case .supports(let key) = BrainRelationPolicy.decide(Self.facts(byName, Self.verified(.valueReadBack), role: "AXTextField",
                                                                                label: "File name", elements: [named, other])) else {
            Issue.record("a named field taught nothing"); return
        }
        #expect(key.elementKey == "control|form|AXTextField|filename")
        let moved = Self.control("AXTextField", "File name", origin: .description, x: 0.4)
        guard case .supports(let again) = BrainRelationPolicy.decide(Self.facts(byName, Self.verified(.valueReadBack), role: "AXTextField",
                                                                                  label: "File name", elements: [moved, other])) else {
            Issue.record("the moved field taught nothing"); return
        }
        #expect(again.elementKey == key.elementKey, "a position is no part of an identity")
        let cell = CaptureElement(kind: .control, role: "AXCheckBox", label: "Keep", labelOrigin: .title, containerPath: "files",
                                  isUnderCollection: true, state: .off, bounds: NormalizedRect(x: 0.8, y: 0.5, width: 0.04, height: 0.04))
        #expect(SceneElementKey.key(of: cell) == "item_template|files|AXCheckBox|keep" && SceneElementKey.key(of: Self.row)
                == "item_template|files|AXRow|", "two controls of a list's rows are two templates")
    }

    @Test("what decides an effect is kept for every family: two choices, two counts, two drag destinations, two offsets are apart; a file's name is a parameter")
    func argumentsThatDecide() throws {
        func key(_ request: AgentCallRequest, _ condition: OperationCheck.Condition = .structuralEffect, role: String? = "AXButton",
                 label: String? = "Export", elements: [CaptureElement] = [Self.export, Self.field, Self.row]) -> String? {
            guard case .supports(let key) = BrainRelationPolicy.decide(Self.facts(request, Self.verified(condition), role: role, label: label,
                                                                                    elements: elements)) else { return nil }
            return key.argumentsKey
        }
        #expect(key(.select(control: "Export", item: "JPEG"), .valueReadBack) != key(.select(control: "Export", item: "PNG"), .valueReadBack))
        let tab = KeyChord.Name("tab")!
        #expect(key(.pressKey(key: tab, modifiers: [], count: 1), role: nil, label: nil)
                != key(.pressKey(key: tab, modifiers: [], count: 3), role: nil, label: nil))
        let target = Self.control("AXButton", "Trash", origin: .title, in: "sidebar"), folder = Self.control("AXButton", "Desktop", origin: .title, in: "sidebar")
        let toTrash = key(.drag(from: "Export", to: .target("Trash"), section: nil), elements: [Self.export, target, folder])
        let toFolder = key(.drag(from: "Export", to: .target("Desktop"), section: nil), elements: [Self.export, target, folder])
        #expect(toTrash == "to=control|sidebar|AXButton|trash" && toFolder == "to=control|sidebar|AXButton|desktop")
        #expect(key(.drag(from: "Export", to: .offset(dx: -40, dy: 0), section: nil))
                != key(.drag(from: "Export", to: .offset(dx: 40, dy: 0), section: nil)))
        #expect(key(.drag(from: "Export", to: .offset(dx: 40, dy: 0), section: nil))
                == key(.drag(from: "Export", to: .offset(dx: 300, dy: 0), section: nil)), "a distance is a parameter")
        #expect(BrainRelationPolicy.decide(Self.facts(.drag(from: "Export", to: .target("Nowhere"), section: nil), Self.verified(.structuralEffect)))
                == .excluded(.noStructuralElement), "a destination the capture does not have teaches nothing")
        let first = key(.typeText(target: "foto.png", text: "ritratto_finale.png", section: nil, replace: true), .valueReadBack,
                        role: "AXTextField", label: "foto.png")
        let second = key(.typeText(target: "foto.png", text: "paesaggio.jpg", section: nil, replace: true), .valueReadBack,
                         role: "AXTextField", label: "foto.png")
        #expect(first != nil && first == second, "a new file name multiplies no relation")
        for verb in BrainVerb.allCases { #expect(BrainRelationPolicy.argumentRoles[verb] != nil, "\(verb) has no argument roles") }
    }

    @Test("a sample not placed in a state yet makes the call wait for it, recoverable; one that never can be is final")
    func awaitingState() throws {
        let passed = Self.verified(.structuralEffect)
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, from: nil, beforeAwaits: true)) == .excluded(.awaitingState))
        #expect(BrainRelationPolicy.Exclusion.awaitingState.isRecoverable && !BrainRelationPolicy.Exclusion.noBeforeState.isRecoverable)
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, from: nil)) == .excluded(.noBeforeState))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, to: nil, afterAwaits: true)) == .excluded(.awaitingState),
                "the state after acting is part of the relation too")
        #expect(BrainRelationPolicy.Exclusion.notConcluded.isRecoverable && BrainRelationPolicy.Exclusion.nothingToContradict.isRecoverable)
    }

    @Test("a verified no-op is the state already present, from the state to itself; a substitute gesture never teaches the requested click")
    func noOpAndRecovery() throws {
        guard case .supports(let noop) = BrainRelationPolicy.decide(Self.facts(Self.click(.setToggle, value: .on),
            Self.verified(.requestedStateAlreadyPresent, performed: .none), to: nil)) else {
            Issue.record("the no-op taught nothing"); return
        }
        #expect(noop.outcome == .alreadySatisfied && noop.toSceneID == "S")
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), Self.verified(.recoveryInsteadOfRequest, performed: .substitute)))
                == .excluded(.substituteGesture))
    }

    @Test("what teaches nothing says why: no verification, no oracle, unknown, in doubt, withheld, no state, no element, two elements, a gap, an end that failed")
    func exclusions() throws {
        let passed = Self.verified(.structuralEffect)
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), nil)) == .excluded(.noVerification))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), Self.verified(.none, .unknown))) == .excluded(.noOracle))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), Self.verified(.structuralEffect, .unknown, limits: [.unattributed])))
                == .excluded(.verdictUnknown), "a change the oracle could not attribute stays unknown")
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), Self.verified(.structuralEffect, performed: .uncertain)))
                == .excluded(.deliveryUncertain))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, withheld: true)) == .excluded(.valueWithheld))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, from: nil)) == .excluded(.noBeforeState))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, label: "Missing")) == .excluded(.noStructuralElement))
        let twice = CaptureElement(kind: .control, role: "AXButton", label: "Export", labelOrigin: .title, containerPath: "footer",
                                   isUnderCollection: false, state: nil, bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.1, height: 0.04))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, elements: [Self.export, twice])) == .excluded(.ambiguousElement))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, gap: true)) == .excluded(.recordingGap))
        #expect(BrainRelationPolicy.decide(Self.facts(Self.click(), passed, status: .failed)) == .excluded(.callFailed))
        #expect(BrainRelationPolicy.decide(Self.facts(.observe(full: false), passed)) == .excluded(.notAnOperation))
        #expect(BrainRelationPolicy.decide(Self.facts(.menu(path: "File > Export…"), Self.verified(.windowSetChanged), from: nil))
                == .excluded(.noBeforeState), "a menu command has no observation before it")
    }

    @Test("a failed verification contradicts the group's relations of the outcome it expected, of any family when it expected none")
    func contradictions() throws {
        guard case .contradicts(let group, let outcome, let family) = BrainRelationPolicy.decide(Self.facts(Self.click(),
            Self.verified(.structuralEffect, .failed), expected: "menuOpened")) else {
            Issue.record("no contradiction"); return
        }
        #expect(group.verb == .click && outcome == .effect && family == "menuOpened")
        guard case .contradicts(_, _, let none) = BrainRelationPolicy.decide(Self.facts(Self.click(),
            Self.verified(.structuralEffect, .failed), expected: nil)) else {
            Issue.record("no contradiction"); return
        }
        #expect(none == nil)
        guard case .contradicts(_, .valueSet, _) = BrainRelationPolicy.decide(Self.facts(.select(control: "Export", item: "PNG"),
            Self.verified(.valueReadBack, .failed))) else {
            Issue.record("no contradiction of the value"); return
        }
    }

    @Test("a relation is offered at its threshold, one proof for a menu that opened and two for anything else, and only as a possibility once contradicted")
    func standing() throws {
        func relation(_ family: String, supports: Int, contradictions: Int = 0) -> BrainRelation {
            let key = BrainRelationKey(bundleID: Self.bundle, contextID: nil, fromSceneID: "S", elementKey: "e", verb: .click,
                                       argumentsKey: "", toSceneID: nil, outcome: .effect, effectKind: family)
            return BrainRelation(relationID: key.relationID, key: key, firstSeenMS: 0, lastSeenMS: 0, supports: supports,
                                 contradictions: contradictions)
        }
        #expect(relation("menuOpened", supports: 1).standing == .exposed)
        #expect(relation("elementsAppeared", supports: 1).standing == .candidate)
        #expect(relation("elementsAppeared", supports: 2).standing == .exposed)
        #expect(relation("elementsAppeared", supports: 5, contradictions: 1).standing == .limited)
        #expect(relation("elementsAppeared", supports: 2).summary == "click: elementsAppeared → unknown state")
    }
}
