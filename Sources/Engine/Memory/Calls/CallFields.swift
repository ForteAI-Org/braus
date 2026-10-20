//
//  CallFields.swift
//  Braus
//

import EngineCore

/// StructuredField is one leaf of an adapter's argument or result object (P2-02), as the record may keep
/// it: its JSON pointer, the kind of its value, and the value as text (`"3"`, `"true"`, the text itself), or nil with the
/// reason it is withheld. A null leaf has no text. Nothing of a withheld value is kept: not its text, length or digest.
public struct StructuredField: Sendable, Equatable, Hashable {

    /// ValueKind is the JSON kind of the leaf: its text is read back as that kind.
    public enum ValueKind: String, Sendable, Equatable, Hashable, CaseIterable {
        case text, number, boolean, null
    }

    public let path: String
    public let kind: ValueKind
    public let text: String?
    public let withheld: WithholdingReason?

    public init(path: String, kind: ValueKind, text: String?, withheld: WithholdingReason? = nil) throws {
        guard path.hasPrefix("/"), path.count > 1 else { throw OperationFactError.invalid(.emptyText(field: "field_path")) }
        guard withheld == nil || text == nil, withheld != nil || kind == .null || text != nil else {
            throw OperationFactError.invalid(.emptyText(field: "field_value"))
        }
        if withheld == nil {
            let valid: Bool = switch kind {
                case .text: text != nil
                case .number: text.flatMap(Double.init)?.isFinite == true
                case .boolean: text == "true" || text == "false"
                case .null: text == nil
            }
            guard valid else { throw OperationFactError.invalid(.emptyText(field: "typed_field_value")) }
        }
        self.path     = path
        self.kind     = kind
        self.text     = withheld == nil ? text : nil
        self.withheld = withheld
    }

    /// The same leaf withheld for `reason`, its text dropped.
    public func withholding(_ reason: WithholdingReason) -> StructuredField {
        (try? StructuredField(path: path, kind: kind, text: nil, withheld: reason)) ?? self
    }

    /// The most leaves a call keeps of one object: a larger answer keeps its first ones, in pointer order, and no later
    /// step can refer to the others.
    public static let maximumLeaves = 512

    /// Whether a result leaf names an item a later call may refer to: an identifier, a number or a key by its name.
    public var namesAnItem: Bool {
        guard withheld == nil, kind == .text || kind == .number, let text, !text.isEmpty else { return false }
        let key = path.split(separator: "/").last.map(String.init) ?? ""
        let lowered = key.lowercased()
        return lowered == "id" || lowered.hasSuffix("_id") || key.hasSuffix("Id") || key.hasSuffix("ID")
            || ["number", "key", "uuid", "uid", "identifier", "url", "html_url", "slug"].contains(lowered)
    }
}

/// CallArgumentField is a leaf of a call's structured arguments as its end records it: a constant, a reference to the one
/// result field of an earlier call of the same attempt that held exactly its value, or a value two or more earlier
/// results held, which stays ambiguous: nothing chooses between them. The store decides the reference from the archive
/// (`resolved` false here), never from what the caller claims.
public struct CallArgumentField: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case constant
        case resultReference   = "result_reference"
        case ambiguousReference = "ambiguous_reference"
    }

    public let field: StructuredField
    public let kind: Kind
    public let sourceEventID: String?
    public let sourcePath: String?

    public init(field: StructuredField, kind: Kind = .constant, sourceEventID: String? = nil, sourcePath: String? = nil) {
        self.field         = field
        self.kind          = kind
        self.sourceEventID = kind == .resultReference ? sourceEventID : nil
        self.sourcePath    = kind == .resultReference ? sourcePath : nil
    }
}

/// CallDataContext is the data a call reached (P2-05): the service, the route, the profile, the account and the resource,
/// each only as the call attests it. The account is `accountRef`, a minimal identifier the store derives from the account
/// the call named (never kept), or nothing: an account the call did not name stays unknown (`default` when the service
/// used its own default, `unknown` when nothing says). The same site, profile or service never implies the same account.
public struct CallDataContext: Sendable, Equatable {

    public enum Route: String, Sendable, Equatable, CaseIterable {
        case native, desktop, web, adapter
    }

    public enum AccountSource: String, Sendable, Equatable, CaseIterable {
        case argument, result, `default`, unknown
    }

    public let service: String
    public let route: Route
    public let profile: String?
    /// The account as the call named it, in memory only: the store keeps a salted digest of it, never the text.
    public let account: String?
    public let accountSource: AccountSource
    public let resourceKind: String?
    public let resource: String?

    public init(service: String, route: Route, profile: String? = nil, account: String? = nil,
                accountSource: AccountSource, resourceKind: String? = nil, resource: String? = nil) throws {
        guard !service.isEmpty else { throw OperationFactError.invalid(.emptyText(field: "service")) }
        guard (accountSource == .argument || accountSource == .result) == (account?.isEmpty == false) else {
            throw OperationFactError.invalid(.emptyText(field: "account"))
        }
        guard (resourceKind == nil) == (resource == nil) else { throw OperationFactError.invalid(.emptyText(field: "resource")) }
        self.service       = service
        self.route         = route
        self.profile       = profile.flatMap { $0.isEmpty ? nil : $0 }
        self.account       = account
        self.accountSource = accountSource
        self.resourceKind  = resourceKind
        self.resource      = resource
    }
}
