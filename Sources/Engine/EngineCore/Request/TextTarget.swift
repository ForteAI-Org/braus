//
//  TextTarget.swift
//  Braus
//

import Foundation

/// TargetIdentity is the physical identity of one element as the provider that perceived it attests it: an
/// opaque token that only that provider writes, from its own reads (on the web, the tab, the document and the
/// DOM node). Nothing in it comes from the scene's labels, bounds or element ids, which a node replaced in the
/// same place keeps; the engine only compares two tokens.
public struct TargetIdentity: Sendable, Hashable {
    public let token: String

    public init(_ token: String) {
        self.token = token
    }
}

/// TextTargetBinding is the field a call classified ordinary before its first write: the identity its provider
/// attested, and the role and label the scene gave it. The dispatch types only into that field: before any
/// gesture it must still resolve to it, and before the first key the focus must be it.
public struct TextTargetBinding: Sendable, Equatable {
    public let identity: TargetIdentity
    public let role    : String?
    public let label   : String

    public init(identity: TargetIdentity, role: String?, label: String) {
        self.identity = identity
        self.role     = role
        self.label    = label
    }
}

/// TextTargetClass is what a fresh perception attests about where a text would go, taken before anything of
/// the call is written: an ordinary field it can name physically, a secure field, or neither. Only an ordinary
/// field's text may be kept in the records; a secure field's is withheld as such, and every other is withheld
/// as unclassified, never kept on a guess.
public enum TextTargetClass: Sendable, Equatable {
    case ordinary(TextTargetBinding)
    case secure
    case unclassified(Cause)

    /// Why no ordinary field could be attested.
    public enum Cause: String, Sendable, Equatable {
        /// No scene could be read.
        case noScene = "no_scene"
        /// The target named no element, or several.
        case unresolved
        /// The element is not a field text goes into.
        case notTextEntry = "not_text_entry"
        /// The provider attests no physical identity for the element.
        case identityUnattested = "identity_unattested"
        /// The provider cannot say which field holds the focus, or what kind it is.
        case focusUnknown = "focus_unknown"
        /// The session or input cannot be classified.
        case unsupported
    }

    /// The field the dispatch is bound to, for an ordinary one.
    public var binding: TextTargetBinding? {
        if case .ordinary(let binding) = self { return binding }
        return nil
    }
}

/// TextDispatch is how a call that classified its text dispatches it (W1): bound to the ordinary field it attested,
/// or with the text withheld from every record of the call, the engine then quoting no value of the field in its
/// answer and keeping the texts out of its check.
public enum TextDispatch: Sendable, Equatable {
    case bound(TextTargetBinding)
    case withheld
}

/// FocusedField is the field that holds the keyboard focus as a provider attests it, never its value: an
/// ordinary field with its identity, a secure one, or unknown when the provider cannot say (no focus, a frame
/// it cannot read, a provider that does not read the focus).
public enum FocusedField: Sendable, Equatable {
    case ordinary(TargetIdentity)
    case secure(TargetIdentity?)
    case unknown
}
