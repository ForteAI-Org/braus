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
        // Solo exposes a different on value; its empty string is also an explicit off state.
        if bundleID == "com.avid.ProTools", identifier == "solo" {
            switch value {
                case "Selected", "on": return .on
                case ""              : return .off
                default              : return nil
            }
        }
        return isSelected == true ? .on : nil
    }
}
