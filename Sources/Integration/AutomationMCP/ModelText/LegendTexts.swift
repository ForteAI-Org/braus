import Foundation

extension ModelText {
    nonisolated static let legendTexts: [Entry] = [
        Entry(
            key: .init(rawValue: "scene.personHadApp"),
            owner: "perception",
            delivery: .legend,
            budgetCharacters: 80,
            text: "Whole scene: the person used the application since your last reading.",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.sceneLegend.v1"),
            owner: "perception",
            delivery: .legend,
            budgetCharacters: 770,
            text: "Scene format: App (bundle) \"window title\" WxH pixels, N elements. \"## name @x,y wxh\" starts a section; x,y,w,h are window percent. Lines end in place @x,y: text or [control], [field], [icon?] (unnamed), [image]; [state], = value, [disabled], [sel a..b/n] selection or caret (utf-16 units out of n), \": effect\" learned before. {name} owns this and following lines; {} clears it. id:'X' names target X or id:'X'. \"icons: id@x,y\" lists unnamed icons; shared id and count can replace id@x,y and may be ambiguous. \"## past the window's edge (read only, not visible)\": window fields beyond the edge, no id, never a target; read with observe. Omitted fields: … N more · observe section \"X\".",
            legacy: false
        ),
        Entry(
            key: .init(rawValue: "tool_catalogue.changesLegend.v1"),
            owner: "perception",
            delivery: .legend,
            budgetCharacters: 130,
            text: "Changes: \"+ added\", \"- removed\", \"~ changed (was ...)\" under ## section; window: or viewport: when changed. All else is unchanged.",
            legacy: false
        ),
    ]
}
