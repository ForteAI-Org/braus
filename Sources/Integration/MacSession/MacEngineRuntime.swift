//
//  MacEngineRuntime.swift
//  Braus
//

import AccessibilityActions
import AutomationRuntime
import Engine
import EngineCore
import Foundation
import MacDelivery
import MacDriver
import MacDriving
import Memory

/// MacEngineRuntime is `EngineRuntime` for the MacDriver: the same engine, memory and recorder over
/// the Mac's own roles. Scenes come from the accessibility tree with the app behind, gestures climb
/// the ladder (rung 1 accessibility actions, rung 2 events to the process), the settler waits on the
/// app's notifications. No seat and no activation (spec 2026-10-14-mac-driver-design, sections 3, 7).
public struct MacEngineRuntime {

    public let cache   : MacSceneCache
    public let scenes  : MacScenes
    public let actuator: MacActuator
    public let windows : MacWindows
    public let controls: any ControlPressing
    public let settling: MacSettler
    public let service : MemoryService
    public let memory  : BrainMemory

    /// `focus` guards the person's front app across each gesture; nil guards nothing.
    public init(knowledgeDirectory: URL, roles: MacRoles = .live(), focus: (any MacWorkspace)? = nil) {
        let cache = MacSceneCache()
        self.cache = cache
        scenes   = MacScenes(reader: roles.reader, cache: cache, serverWindows: roles.serverWindows,
                             identity: roles.identity ?? MacScenes.liveIdentity)
        actuator = MacActuator(cache: cache, actor: roles.actor, delivery: roles.delivery, person: roles.person,
                               focus: focus)
        windows  = MacWindows(reader: roles.reader, serverWindows: roles.serverWindows)
        controls = roles.controls
            ?? MacControls(cache: cache, reader: roles.reader, actor: roles.actor,
                           menus: roles.menus ?? AccessibilityController(), person: roles.person)
        settling = MacSettler(source: roles.notifications)
        let service = MemoryService.shared(for: knowledgeDirectory)
        self.service = service
        memory = BrainMemory(brains: service, applications: service, relations: service, clock: { service.clock.brainNow() })
    }

    public func recorder(_ context: ActionContext) -> CallRecorder {
        CallRecorder(memory: service, brain: memory, context: context)
    }

    /// The engine over the Mac roles, expecting from the Brain and reporting to `recorder`.
    public func engine(recorder: CallRecorder, allowsDestructive: Bool) -> ActionEngine {
        ActionEngine(
            ActionEngine.Dependencies(
                scenes      : scenes,
                actuator    : actuator,
                windows     : windows,
                controls    : controls,
                expectations: memory,
                observer    : recorder,
                settling    : settling,
                // The MacDriver's texts are the app's displays read from accessibility (Calculator's result).
                countsNativeTextChange: true
            ),
            permissions: ActionPermissions(allowsDestructive: allowsDestructive)
        )
    }

    public func finish() async {
        await service.flush(within: service.configuration.closingBudget)
    }
}

/// MacRoles are the Mac's interfaces a runtime is built on: live ones in Braus, fakes in the tests.
public struct MacRoles: Sendable {

    public var reader       : any MacTreeReading
    public var actor        : any MacAccessibilityActing
    public var delivery     : any MacEventDelivering
    /// Rule 6; nil where no person can touch the app.
    public var person       : (any MacPersonWatching)?
    public var notifications: any MacNotificationSource
    /// Nil for `MacControls` over the runtime's scenes, the live default.
    public var controls     : (any ControlPressing)?
    /// The menu controller `MacControls` delegates native menus to; nil for the live one (`AccessibilityController`).
    public var menus        : (any ControlPressing)?
    public var serverWindows: MacWindows.ServerWindows
    /// Who a process is, for its scenes' bundle identifier and name; nil for the workspace's own answer
    /// (`MacScenes.liveIdentity`). A test's fake process declares itself here, so its scenes are recorded under an app.
    public var identity     : MacScenes.ProcessIdentity?

    public init(
        reader       : any MacTreeReading,
        actor        : any MacAccessibilityActing,
        delivery     : any MacEventDelivering,
        person       : (any MacPersonWatching)?,
        notifications: any MacNotificationSource,
        controls     : (any ControlPressing)?,
        menus        : (any ControlPressing)? = nil,
        serverWindows: @escaping MacWindows.ServerWindows,
        identity     : MacScenes.ProcessIdentity? = nil
    ) {
        self.reader        = reader
        self.actor         = actor
        self.delivery      = delivery
        self.person        = person
        self.notifications = notifications
        self.controls      = controls
        self.menus         = menus
        self.serverWindows = serverWindows
        self.identity      = identity
    }

    /// The live roles. The person watch and the notification source are one per process: each holds
    /// an event tap or observers on its own thread.
    public static func live() -> MacRoles {
        let reader = LiveMacTreeReader()
        return MacRoles(reader: reader, actor: reader, delivery: MacInPlaceDelivery(), person: sharedPerson,
                        notifications: sharedNotifications, controls: nil,
                        serverWindows: MacWindows.liveServerWindows)
    }

    private static let sharedPerson        = LiveMacPersonWatch()
    private static let sharedNotifications = LiveMacNotificationSource()
}
