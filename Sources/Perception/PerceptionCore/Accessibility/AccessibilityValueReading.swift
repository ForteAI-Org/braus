//
//  AccessibilityValueReading.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

/// AccessibilityValueReading refuses secure and reserved fields before requesting their value.
/// An unreadable editable subrole remains protected. The attribute closure permits deterministic
/// tests of which native attributes are read, without an accessibility connection.
public enum AccessibilityValueReading {
    public static func read<Value>(
        isReservedLabel: (String) -> Bool,
        attribute: (String) -> String?,
        value: () -> Value?
    ) -> Value? {
        guard let role = attribute("AXRole") else { return nil }
        let subrole = attribute("AXSubrole")
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return nil }
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) {
            guard subrole != nil else { return nil }
            let labels = ["AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXPlaceholderValue"]
                .compactMap(attribute)
            guard !labels.contains(where: isReservedLabel) else { return nil }
        }
        return value()
    }
}
