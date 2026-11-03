import Foundation

extension ModelText {
    nonisolated static let legendTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "tool_catalogue.sceneLegend.v1"),
            owner: "AutomationMCP",
            delivery: .legend,
            budgetCharacters: 700,
            text: "Scene format: first line App (bundle) \"window title\" WxH pixels, N elements. \"## name @x,y wxh\" opens a section; x, y, w, h are percent of the window. Then one element per line, ending in its place @x,y: plain text, or [control], [field], [icon?] (an icon with no name), [image]; then [state], = value, [disabled], [sel a..b/n] (selection in UTF-16 units of n) and \": effect\" learned before. {name} owns this line and the following ones until another {..}; {} means none. id:'X' marks an element's exact id: pass X, or the whole id:'X', as target. \"icons: id@x,y id×n\" lists the section's unnamed icons: pass id as target to click one; id×n means n icons share that id and none can be targeted by it.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.changesLegend.v1"),
            owner: "AutomationMCP",
            delivery: .legend,
            budgetCharacters: 157,
            text: "Changes list \"+ added\", \"- removed\" and \"~ changed (was ...)\" lines under their ## section, and window: or viewport: when those moved; all else is unchanged.",
            legacy: true
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.budgetLegend.v1"),
            owner: "AutomationMCP",
            delivery: .legend,
            budgetCharacters: 220,
            text: "A scene too long for one answer keeps its first line, lists every section with its place, element count and whether it is shown, then the sections shown whole, and names those left out: read one with observe and section.",
            legacy: false
        ),
    ]
}
