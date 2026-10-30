//
//  InteractionElementMetadata.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import Foundation

/// InteractionElementMetadata describes a control without reading its value or descendants.
/// A separate static title element may supply its value as a label. Reserved labels follow the caller's policy.
public struct InteractionElementMetadata: Sendable, Equatable {
    /// The part a button plays in its dialog, named by its window's own attributes in any language.
    public enum WindowButton: String, Sendable, Codable { case `default`, cancel }

    public let role: String?
    public let subrole: String?
    public let label: String?
    public let isProtected: Bool
    public var windowButton: WindowButton? = nil

    /// Reads role before labels; secure controls expose only their role. The title-element reader must
    /// address a separate AXTitleUIElement, never the field itself. Native reads and tests share this policy.
    public static func read(
        isReservedLabel: (String) -> Bool,
        titleElementAttribute: (String) -> String? = { _ in nil },
        isWindowButton: (String) -> Bool = { _ in false },
        attribute: (String) -> String?
    ) -> Self {
        let role = attribute("AXRole")
        let subrole = attribute("AXSubrole")
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return Self(role: role, subrole: nil, label: nil, isProtected: true)
        }
        let title = attribute("AXTitle")
        let description = attribute("AXDescription")
        let help = attribute("AXHelp")
        var labels = [title, description, help]
        var fallback: String?
        if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? ""),
           [title, description].allSatisfy({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }) {
            let labelRole = titleElementAttribute("AXRole")
            let labelSubrole = titleElementAttribute("AXSubrole")
            if labelRole != "AXSecureTextField", labelSubrole != "AXSecureTextField" {
                let labelTitle = titleElementAttribute("AXTitle")
                let labelDescription = titleElementAttribute("AXDescription")
                let labelValue = labelRole == "AXStaticText" ? titleElementAttribute("AXValue") : nil
                labels += [labelTitle, labelDescription, labelValue]
                let facts = InteractionAXLabel.Facts(role: labelRole, title: labelTitle,
                                                     description: labelDescription, displayValue: labelValue)
                fallback = InteractionAXLabel.resolve(0, facts: { _ in facts }, children: { _ in [] })?.label
            }
            let placeholder = attribute("AXPlaceholderValue")
            labels.append(placeholder)
            let facts = InteractionAXLabel.Facts(title: fallback, description: placeholder)
            fallback = InteractionAXLabel.resolve(0, facts: { _ in facts }, children: { _ in [] })?.label
        }
        if labels.compactMap({ $0 }).contains(where: isReservedLabel) {
            return Self(role: role, subrole: nil, label: nil, isProtected: true)
        }
        let facts = InteractionAXLabel.Facts(role: role, title: fallback ?? title, description: description, help: help)
        let name = InteractionAXLabel.resolve(0, facts: { _ in facts }, children: { _ in [] })
        var result = Self(role: role.map { String($0.prefix(80)) },
                          subrole: subrole.map { String($0.prefix(80)) }, label: name?.label, isProtected: false)
        if role == "AXButton" {
            result.windowButton = isWindowButton("AXDefaultButton") ? .default : isWindowButton("AXCancelButton") ? .cancel : nil
        }
        return result
    }
}
