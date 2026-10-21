//
//  AttestedFields.swift
//  Braus
//

import AutomationRuntime
import EngineCore
import Foundation

/// AttestedFields is what the doubles of these tests answer for W1's classification: they stand for a provider
/// that attests every field it is asked about as an ordinary one, by an identity of its own, so a typed value is
/// kept as before W1. These tests are about what the memory learns from ordinary values; whether a provider
/// attests a field is tested where the providers are (`TextTargetTests`, `TextTargetWebTests`, `TypedSecretTests`).
enum AttestedFields {

    /// An ordinary field for a typed text, the focus for an inserted one; nothing else is classified.
    static func classify(_ input: InputRequest.Input) -> TextTargetClass {
        switch input {
            case .typeText(_, let target, _):
                .ordinary(TextTargetBinding(identity: TargetIdentity("double|\(target)"), role: "AXTextField", label: target))
            case .insertText:
                .ordinary(TextTargetBinding(identity: TargetIdentity("double|focus"), role: nil, label: ""))
            case .pressKey, .scroll, .drag, .contextMenu:
                .unclassified(.unsupported)
        }
    }
}
