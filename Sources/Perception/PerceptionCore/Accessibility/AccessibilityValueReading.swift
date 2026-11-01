/// AccessibilityValueReading checks roles and decisive labels before a read and shapes after it.
/// An unreadable editable subrole remains protected. The closures permit deterministic native tests.
public enum AccessibilityValueReading {
    /// Reads text only when both guard phases admit it.
    public static func readText(
        guard valueGuard: ValueGuard,
        attribute: (String) -> String?,
        value: () -> String?
    ) -> String? {
        guard let labels = admittedLabels(guard: valueGuard, attribute: attribute),
              let text = value(), !valueGuard.withholdsValue(text, labels) else { return nil }
        return text
    }

    /// Checks the decimal representation of a number after reading it.
    public static func readNumber(
        guard valueGuard: ValueGuard,
        attribute: (String) -> String?,
        value: () -> Int?
    ) -> Int? {
        guard let labels = admittedLabels(guard: valueGuard, attribute: attribute),
              let number = value(), !valueGuard.withholdsValue(String(number), labels) else { return nil }
        return number
    }

    private static func admittedLabels(
        guard valueGuard: ValueGuard,
        attribute: (String) -> String?
    ) -> [String]? {
        guard let role = attribute("AXRole") else { return nil }
        let subrole = attribute("AXSubrole")
        guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return nil }
        let editable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        if editable, subrole == nil { return nil }
        let names = editable ? ["AXTitle", "AXDescription", "AXHelp", "AXIdentifier", "AXPlaceholderValue"]
                             : ["AXTitle", "AXDescription"]
        let labels = names.compactMap(attribute)
        guard !labels.contains(where: valueGuard.refusesLabel) else { return nil }
        return labels
    }
}
