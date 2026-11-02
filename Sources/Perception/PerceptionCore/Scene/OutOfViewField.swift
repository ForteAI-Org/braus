//
//  OutOfViewField.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 27/10/2026.
//

/// OutOfViewField is a named native text field past the window's edge. Its value is readable,
/// but no bounds or target identity are attested, so it cannot participate in an action.
public struct OutOfViewField: Sendable, Equatable, Hashable, Codable {

    public var label: String
    public var value: String
    public var role: String
    public var isEnabled: Bool?
    public var container: String?

    public init(
        label    : String,
        value    : String,
        role     : String,
        isEnabled: Bool? = nil,
        container: String? = nil
    ) {
        self.label     = label
        self.value     = value
        self.role      = role
        self.isEnabled = isEnabled
        self.container = container
    }
}
