//
//  SyntheticForm.swift
//  Braus
//

import CoreGraphics
import Engine
import EngineCore
import Foundation
import WebDriver
@testable import WebDriving

/// SyntheticForm is the form the web roles' tests drive over a `SyntheticPage`: a prefilled password field,
/// "Accesso", and a text field, "Nome", with the production web roles and an engine over them.
enum SyntheticForm {

    static let fields = [
        SyntheticPage.Field(backendID: 11, type: "password", name: "Accesso", value: "Prefilled-Secret-4417",
                            box: CGRect(x: 100, y: 100, width: 300, height: 30)),
        SyntheticPage.Field(backendID: 12, type: "text", name: "Nome", value: "Ada",
                            box: CGRect(x: 100, y: 200, width: 300, height: 30)),
    ]

    struct Stack {
        let page     : SyntheticPage
        let tabs     : WebTabs
        let processID: pid_t
        let engine   : ActionEngine
    }

    static func stack() async -> Stack {
        let page = SyntheticPage(fields: fields)
        let connection = await CDPConnection(transport: page)
        let tabs = WebTabs()
        let processID = tabs.register(WebPage(connection: connection, targetID: "target-1", sessionID: "session-1"))
        let engine = ActionEngine(ActionEngine.Dependencies(
            scenes  : WebScenes(tabs: tabs),
            actuator: WebActuator(tabs: tabs),
            windows : WebWindows(tabs: tabs),
            controls: WebControls(tabs: tabs),
            settling: WebSettler(tabs: tabs)
        ))
        return Stack(page: page, tabs: tabs, processID: processID, engine: engine)
    }
}
