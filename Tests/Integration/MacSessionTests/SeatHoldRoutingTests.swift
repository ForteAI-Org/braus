//
//  SeatHoldRoutingTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AppAdapters
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Router
import Synchronization
import Testing

/// The hold of the app an adapter scripts, through the router the app composes: it lands on the desktop session's
/// Seat whatever the native route would take, and a router with no Seat lets the adapter run unheld.
///
/// Offline: `AutomationTools` over a `RoutingAutomationSession` of fakes. No app, Seat or account.
@MainActor
@Suite("The hold of an adapter's app goes to the Seat, never to the native route")
struct SeatHoldRoutingTests {

    private static let write: JSONValue = .object(["name": .string("scripted.write"), "arguments": .object([:])])

    private static func text(_ answer: JSONValue) -> String {
        answer["content"].array?.first?["text"].string ?? ""
    }

    @Test("the hold opens the app on the desktop session; the native route is never asked")
    func holdSkipsTheNativeRoute() async throws {
        let native  = RouteFake(hasSeat: false)
        let desktop = RouteFake(hasSeat: true)
        let routing = RoutingAutomationSession(native: native, desktop: desktop)
        let adapter = ScriptedFixture()
        let tools   = AutomationTools(session: routing, adapters: AppAdapters([adapter]))
        #expect(Self.text(try await tools.call("call", Self.write)).hasPrefix("ok Wrote."))
        #expect(native.opened.isEmpty && desktop.opened == ["test.scripted"])
        #expect(routing.holdsOnSeat && adapter.runs == 1)
        _ = try await tools.call("call", Self.write)
        #expect(desktop.opened == ["test.scripted"] && adapter.runs == 2, "held on the Seat: nothing opened again")
    }

    @Test("an app the native route holds is closed there and held on the Seat before the adapter runs")
    func nativeHoldMovesToTheSeat() async throws {
        let native  = RouteFake(hasSeat: false)
        let desktop = RouteFake(hasSeat: true)
        let routing = RoutingAutomationSession(native: native, desktop: desktop)
        _ = try await routing.open(application: "test.scripted", window: nil)
        #expect(native.opened == ["test.scripted"] && !routing.holdsOnSeat)
        let adapter = ScriptedFixture()
        let tools   = AutomationTools(session: routing, adapters: AppAdapters([adapter]))
        _ = try await tools.call("call", Self.write)
        #expect(native.held == nil && desktop.opened == ["test.scripted"])
        #expect(routing.holdsOnSeat && adapter.runs == 1)
    }

    @Test("a router whose desktop has no Seat lets the adapter run unheld, opening nothing")
    func noSeatRunsUnheld() async throws {
        let native  = RouteFake(hasSeat: false)
        let desktop = RouteFake(hasSeat: false)
        let adapter = ScriptedFixture()
        let tools   = AutomationTools(session: RoutingAutomationSession(native: native, desktop: desktop),
                                      adapters: AppAdapters([adapter]))
        #expect(Self.text(try await tools.call("call", Self.write)) == "ok Wrote.")
        #expect(native.opened.isEmpty && desktop.opened.isEmpty && adapter.runs == 1)
    }
}

/// RouteFake opens whatever it is asked and holds it; on the Seat only when it has one.
@MainActor
private final class RouteFake: AutomationSessionOperating {
    let hasSeat: Bool
    private(set) var id: UUID?
    private(set) var held: String?
    private(set) var opened: [String] = []

    init(hasSeat: Bool) { self.hasSeat = hasSeat }

    var memoryApplication: String? { held }
    var holdsOnSeat: Bool { hasSeat && held != nil }

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        opened.append(application)
        held = application
        id   = UUID()
        return SceneSnapshot(bundleID: application, appName: "Scripted", windowTitle: "Scripted",
                             viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])
    }

    func observe() async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws
        -> ActOutcome { throw AutomationFailure("unused") }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }

    func close() async {
        held = nil
        id   = nil
    }
}

/// ScriptedFixture scripts its own app, as Mail's adapter does on the Mac, and counts its runs.
private final class ScriptedFixture: AppAdapting {
    let name                 = "scripted"
    let appNames             = ["Scripted"]
    let bundleIDs: Set<String> = ["test.scripted"]
    let scriptedApplication: String? = "test.scripted"
    let verbs = [AdapterVerb("write", "Writes.", safety: .write, readBack: "none, a fake")]

    private let count = Mutex(0)

    var runs: Int { count.withLock { $0 } }

    func availability() async -> AdapterAvailability { .ready }

    func call(_ verb: AdapterVerb.Name, _ arguments: JSONValue) async throws -> AdapterOutcome {
        count.withLock { $0 += 1 }
        return .confirmed("Wrote.")
    }
}
