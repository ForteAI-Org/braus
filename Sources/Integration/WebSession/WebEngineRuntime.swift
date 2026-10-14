//
//  WebEngineRuntime.swift
//  Braus
//

import AutomationRuntime
import Engine
import EngineCore
import Foundation
import Memory
import WebDriving

/// WebEngineRuntime is `EngineRuntime` for tabs: the same engine, the same memory and the same
/// recorder, over the web roles. What a page teaches is filed under `web:<host>`, the scene's
/// bundle id, so the living memory keeps it the way it keeps an application's.
public struct WebEngineRuntime {

    public let tabs    : WebTabs
    public let scenes  : WebScenes
    public let actuator: WebActuator
    public let windows : WebWindows
    public let controls: WebControls
    public let settling: WebSettler
    public let service : MemoryService
    public let memory  : BrainMemory

    public init(knowledgeDirectory: URL, tabs: WebTabs = WebTabs()) {
        self.tabs = tabs
        scenes    = WebScenes(tabs: tabs)
        actuator  = WebActuator(tabs: tabs)
        windows   = WebWindows(tabs: tabs)
        controls  = WebControls(tabs: tabs)
        settling  = WebSettler(tabs: tabs)
        let service = MemoryService.shared(for: knowledgeDirectory)
        self.service = service
        memory = BrainMemory(brains: service, applications: service, relations: service, clock: { service.clock.brainNow() })
    }

    public func recorder(_ context: ActionContext) -> CallRecorder {
        CallRecorder(memory: service, brain: memory, context: context)
    }

    /// The engine over the web roles, expecting from the Brain and reporting to `recorder`. No
    /// activation: a tab needs no window in front.
    public func engine(recorder: CallRecorder, allowsDestructive: Bool) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes      : scenes,
                actuator    : actuator,
                windows     : windows,
                controls    : controls,
                expectations: memory,
                observer    : recorder,
                settling    : settling
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive)
        )
    }

    public func finish() async {
        await service.flush(within: service.configuration.closingBudget)
    }
}
