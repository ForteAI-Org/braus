import PerceptionCore

/// NativeButtonState interprets native button facts without treating every button as a toggle.
nonisolated enum NativeButtonState {

    static func read(
        bundleID  : String?,
        identifier: String?,
        value     : String?,
        isSelected: Bool?
    ) -> ControlState? {
        // Pro Tools Mute uses string values in Mix and Edit; AXSelected stays false in both.
        if bundleID == "com.avid.ProTools", identifier == "mute" {
            switch value {
                case "on", "on state": return .on
                case ""              : return .off
                default              : return nil
            }
        }
        return isSelected == true ? .on : nil
    }
}
