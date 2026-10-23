import CoreGraphics
import PerceptionCore

/// DropdownValueVerification checks the requested value at the original control's position.
/// A value elsewhere in the scene cannot establish the dropdown's selection.
public enum DropdownValueVerification {

    public static func verifies(
        item: String,
        control: SceneElement,
        after elements: [SceneElement],
        exactTitleOnly: Bool = false
    ) -> Bool {
        let key = exactTitleOnly ? LabelText.menuTitleKey : LabelText.normalize
        func overlapsOriginal(_ element: SceneElement) -> Bool {
            let original = control.bounds.cgRect
            let current = element.bounds.cgRect
            let overlap = original.intersection(current)
            return !overlap.isNull && overlap.width > 0
                && overlap.height > min(original.height, current.height) * 0.5
        }
        if exactTitleOnly {
            let nearby = elements.filter(overlapsOriginal)
            let native = nearby.filter { ["AXPopUpButton", "AXComboBox"].contains($0.role ?? "") }
            if !native.isEmpty {
                guard native.count == 1, let current = native.first,
                      current.container == control.container,
                      current.id == control.id || (current.role == control.role && key(current.label) == key(control.label))
                else { return false }
                return key(current.value ?? current.label) == key(item)
            }
            let pixels = nearby.filter { $0.role == nil || $0.role == "AXStaticText" }
            guard pixels.count == 1, let current = pixels.first else { return false }
            return key(current.label) == key(item)
        }
        return elements.contains { element in
            let nativeDropdown = ["AXPopUpButton", "AXComboBox"].contains(element.role ?? "")
            let value = nativeDropdown ? element.value ?? element.label : element.label
            let original = control.bounds.cgRect
            let current = element.bounds.cgRect
            let overlap = original.intersection(current)
            return key(value) == key(item)
                && !overlap.isNull && overlap.width > 0
                && overlap.height > min(original.height, current.height) * 0.5
        }
    }
}
