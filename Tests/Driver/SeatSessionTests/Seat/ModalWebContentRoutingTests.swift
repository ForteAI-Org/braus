//
//  ModalWebContentRoutingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// Where a click or a key on the web content of a sheet or a modal goes (ADR 0014,
/// amendment of 2026-10-14). The page's proof belongs to the resolver and is
/// exercised on the fixture's own trees in `DialogEndpointResolverTests`; on trial
/// here is when the seat asks for it, which routes it never asks instead, and what
/// reaches the driver.
@MainActor
@Suite("Routing input to the web content of a sheet or a modal")
struct ModalWebContentRoutingTests {

    enum Shape {
        case sheet, modal, ordinary
    }

    /// A click, a key with a focused control, or a key while nothing is focused.
    enum Input {
        case click, key, keyWithoutFocus
    }

    private static let sheetWindowNumber = 1_414

    @MainActor
    private final class Discovery {

        var geometry  : WindowGeometryObservation?
        var identities: [Int: WindowIdentity] = [:]

        /// False once the page stops proving it is the surface's own.
        var isProved = true

        /// True when the application names no focused control, as a page in the background does.
        var focusIsAbsent = false

        /// What the keyboard discovery answers instead of the measured refusal.
        var keyboardEndpoint: ResolvedInputEndpoint?

        /// What each route was asked: the modal routes, and the ordinary window's two.
        var modalPoints: [CGPoint?] = []
        var modalWebAreaReadings    = 0
        var ordinaryReadings        = 0

        /// The page's proof: from the control a point or a focus names, or, with
        /// `withoutFocus`, from the web area when nothing is focused.
        private func page(
            point       : CGPoint?,
            withoutFocus: Bool,
            chain       : DialogEndpointResolver<AXUIElement>.SurfaceChain,
            generation  : UInt64
        ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
            let now = DispatchTime.now().uptimeNanoseconds
            guard isProved,
                  point != nil || withoutFocus == focusIsAbsent,
                  let geometry,
                  let found = ResolvedInputEndpoint(
                      kind                   : point == nil ? .keyboardContext : .pointer,
                      geometry               : geometry,
                      evidence               : withoutFocus
                          ? .windowlessContentWithoutFocus
                          : .windowlessContentOfSurface,
                      relation               : .logicalSurface,
                      logicalSurface         : chain.surface,
                      accessibilityProcessID : chain.surface.processID,
                      selectionGeneration    : generation,
                      resolvedAtNanoseconds  : now,
                      // A parallel run takes longer than a real endpoint lives.
                      expiresAtNanoseconds   : now + 60_000_000_000,
                      focusedNodeWindowNumber: point == nil && !withoutFocus ? chain.surface.windowNumber : nil
                  )
            else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
            return .success(found)
        }

        var discovery: EndpointDiscovery {
            EndpointDiscovery(
                // The measured F1: the descent and the focus find no Window ID.
                pointer: { _, _, chain, _ in .failure(.subtreeUnreadable(surface: chain.surface)) },
                keyboardContext: { [self] _, chain, _ in
                    keyboardEndpoint.map { .success($0) } ?? .failure(.subtreeUnreadable(surface: chain.surface))
                },
                identity: { [self] in identities[$0] },
                focusedWindowNumber: { _ in nil },
                focusedWindowReading: { _, _ in .noWindow },
                windowlessContent: { [self] _, point, chain, generation in
                    ordinaryReadings += 1
                    return page(point: point, withoutFocus: false, chain: chain, generation: generation)
                },
                webAreaKeyboardContext: { [self] _, _, chain, generation in
                    ordinaryReadings += 1
                    return page(point: nil, withoutFocus: true, chain: chain, generation: generation)
                },
                modalWebContent: { [self] _, point, chain, generation in
                    modalPoints.append(point)
                    return page(point: point, withoutFocus: false, chain: chain, generation: generation)
                },
                modalWebAreaKeyboardContext: { [self] _, _, chain, generation in
                    modalWebAreaReadings += 1
                    return page(point: nil, withoutFocus: true, chain: chain, generation: generation)
                }
            )
        }
    }

    private struct Context {
        let seat       : AgentSeat
        let sensing    : FakeSensing
        let sender     : FakeSender
        let discovery  : Discovery
        let observation: SeatObservationReference
        let surface    : WindowIdentity
        let command    : InputCommand
    }

    /// A window of another process the window server lists over the surface,
    /// such as the service window drawing a remote view's content.
    private func otherProcessWindow(over context: Context, size: CGSize) -> WindowSurface {
        let frame = context.discovery.geometry!.window.frame
        return WindowSurface(
            reference: FakeGeometry.reference(
                frame       : CGRect(origin: frame.origin, size: size),
                processID   : context.surface.processID + 1,
                windowNumber: 9_090
            ),
            level    : 0,
            isVisible: true
        )
    }

    /// The on-screen list as this Mac lists it (read-only dump, 2026-10-14): the
    /// cursor and the menu bar, drawn by the window server, in front of every
    /// window; then the windows; then, behind them all and covering the whole
    /// display, Finder's desktop (layer -2147483603), WindowManager's wallpaper
    /// (-2147483624) and the window server's backstop (-2147483626).
    private func windowList(of context: Context, windows: [WindowSurface]) -> [FakeSensing.WindowRow] {
        let display = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let desktop = [(457 as Int32, 16_722), (443, 16_716)].map { processID, windowNumber in
            FakeSensing.WindowRow.window(WindowSurface(
                reference: FakeGeometry.reference(frame: display, processID: processID, windowNumber: windowNumber),
                level    : -2_147_483_603,
                isVisible: true
            ))
        }
        return [.drawnByWindowServer, .drawnByWindowServer]
            + windows.map { .window($0) }
            + desktop
            + [.drawnByWindowServer]
    }

    /// The remote content window a modal's keyboard discovery names, as
    /// Resolve's Go to Folder field names the panel service's window.
    private func remoteContentEndpoint(of context: Context) throws -> ResolvedInputEndpoint {
        let geometry = try #require(context.discovery.geometry)
        let remote   = otherProcessWindow(over: context, size: geometry.window.frame.size).reference
        let now      = DispatchTime.now().uptimeNanoseconds
        let remoteGeometry = try #require(WindowGeometryObservation(
            window: remote, scaleFactor: geometry.scaleFactor, version: geometry.version
        ))
        return try #require(ResolvedInputEndpoint(
            kind                   : .keyboardContext,
            geometry               : remoteGeometry,
            evidence               : .remoteContentOfSurface,
            relation               : .remoteContent,
            logicalSurface         : context.surface,
            accessibilityProcessID : context.surface.processID,
            selectionGeneration    : context.observation.selectionGeneration,
            resolvedAtNanoseconds  : now,
            expiresAtNanoseconds   : now + 60_000_000_000,
            focusedNodeWindowNumber: remote.windowNumber
        ))
    }

    /// A seat holding an AppKit window, with a sheet attached to it, as the window
    /// itself under an application modal, or as an ordinary window.
    private func context(_ shape: Shape, pointer: Bool, focusIsAbsent: Bool = false) async throws -> Context {
        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let discovery = Discovery()
        let reader    = ControlledSurfaceReader(sensing: sensing)
        let seat      = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : 2_141,
            reader   : reader,
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )
        let window = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        var surface = window
        switch shape {
            case .sheet:
                let inbound = FakeGeometry.reference(
                    frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: 60, dy: 60),
                    windowNumber: Self.sheetWindowNumber
                )
                sensing.additionalWindows[Self.sheetWindowNumber] = inbound
                surface = try await seat.adopt(inbound, platform: AppKitPlatform())
                sensing.additionalWindows[Self.sheetWindowNumber] = surface.reference
                reader.roles[surface.id]  = .dialog
                reader.modals[surface.id] = .window(try #require(window.reference.identity))
            case .modal:
                reader.roles[window.id]  = .dialog
                reader.modals[window.id] = .application
            case .ordinary:
                break
        }
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()

        let identity = try #require(surface.reference.identity)
        let geometry = try #require(sensing.windowGeometryObservation(of: surface.reference))
        discovery.geometry      = geometry
        discovery.identities    = [identity.windowNumber: identity]
        discovery.focusIsAbsent = focusIsAbsent
        // The window server lists the surface first: a sheet above its host.
        sensing.surfaces = [surface, window].map {
            WindowSurface(reference: $0.reference, level: 0, isVisible: true)
        }
        let observation = try await observedReference(seat)
        if shape == .sheet { #expect(observation.role == .hostedSheet(sheet: identity)) }

        let point   = CGPoint(x: geometry.window.frame.midX, y: geometry.window.frame.midY)
        let context = Context(
            seat       : seat,
            sensing    : sensing,
            sender     : sender,
            discovery  : discovery,
            observation: observation,
            surface    : identity,
            command    : pointer
                ? .click(InputLocation(screenPoint: point, windowPointFromTop: CGPoint(x: 1, y: 1)))
                : KeyboardEndpointRoutingTests.escapeKey
        )
        sensing.windowList = windowList(of: context, windows: sensing.surfaces!)
        return context
    }

    private func send(_ context: Context) async throws {
        let turn    = try await context.seat.acquire()
        let receipt = try await context.seat.send(
            context.command,
            observation: context.observation,
            turn       : turn
        )
        try context.seat.confirm(receipt, .unknown)
        try context.seat.release(turn)
    }

    /// The recipe reaching the driver prepares nothing and primes no window, so the
    /// application is never activated for this Command.
    private func expectDeliveredToTheSurface(_ context: Context) {
        #expect(context.sender.sent.count == 1)
        #expect(context.sender.addressed.last?.window.identity == context.surface)
        let platform = context.sender.addressed.last?.platform
        #expect(platform is AppKitPlatform)
        #expect(platform?.preparation(for: context.command) == Preparation.none)
        #expect(platform?.keyWindowPriming(for: context.command) == nil)
    }

    @Test("a click or a key on a sheet's or a modal's web content goes to that surface",
          arguments: [Shape.sheet, .modal], [true, false])
    func theModalSurfaceTakesItsWebContentsInput(shape: Shape, pointer: Bool) async throws {
        let context = try await context(shape, pointer: pointer)
        try await send(context)

        expectDeliveredToTheSurface(context)
        #expect(context.discovery.ordinaryReadings == 0, "an ordinary window's routes are never asked of a modal")
        if pointer {
            #expect(context.discovery.modalPoints.count == 1)
            #expect(context.discovery.modalPoints.allSatisfy { $0 != nil })
        } else {
            // Resolved for the Command and proved again at the boundary, with no point.
            #expect(context.discovery.modalPoints.count >= 2)
            #expect(context.discovery.modalPoints.allSatisfy { $0 == nil })
        }
    }

    @Test("keys on a sheet's or a modal's page with no focused control go to that surface",
          arguments: [Shape.sheet, .modal])
    func theModalSurfaceTakesKeysWithoutFocus(shape: Shape) async throws {
        let context = try await context(shape, pointer: false, focusIsAbsent: true)
        try await send(context)

        expectDeliveredToTheSurface(context)
        #expect(context.discovery.modalWebAreaReadings >= 2)
        #expect(context.discovery.ordinaryReadings == 0)
    }

    @Test("a modal's content that does not prove it is a web page keeps refusing",
          arguments: [Shape.sheet, .modal], [true, false])
    func unprovedModalContentKeepsRefusing(shape: Shape, pointer: Bool) async throws {
        let context = try await context(shape, pointer: pointer)
        context.discovery.isProved = false
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.surface)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        #expect(context.discovery.ordinaryReadings == 0)
        try context.seat.release(turn)
    }

    @Test("the desktop rows behind the surface and the window server's rows in front do not refuse",
          arguments: [Shape.sheet, .modal], [Input.click, .key, .keyWithoutFocus])
    func theDesktopBehindAndTheCursorInFrontDoNotRefuse(shape: Shape, input: Input) async throws {
        let context = try await context(shape, pointer: input == .click, focusIsAbsent: input == .keyWithoutFocus)
        // Another process's window behind the surface, over its whole frame, is not over it.
        let behind = otherProcessWindow(over: context, size: context.discovery.geometry!.window.frame.size)
        context.sensing.windowList?.append(.window(behind))
        try await send(context)

        expectDeliveredToTheSurface(context)
    }

    @Test("another process's window in front of a sheet or a modal refuses its web content",
          arguments: [Shape.sheet, .modal], [Input.click, .key, .keyWithoutFocus])
    func anotherProcessOverTheSurfaceRefuses(shape: Shape, input: Input) async throws {
        let context = try await context(shape, pointer: input == .click, focusIsAbsent: input == .keyWithoutFocus)
        // A service window a fraction of the surface's size still counts.
        let service = otherProcessWindow(over: context, size: CGSize(width: 14, height: 14))
        context.sensing.windowList?.insert(.window(service), at: 2)
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.surface)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        #expect(context.discovery.ordinaryReadings == 0)
        try context.seat.release(turn)
    }

    @Test("a window list that cannot be read refuses a sheet's or a modal's web content",
          arguments: [Shape.sheet, .modal], [Input.click, .key, .keyWithoutFocus])
    func anUnreadableWindowListRefuses(shape: Shape, input: Input) async throws {
        let context = try await context(shape, pointer: input == .click, focusIsAbsent: input == .keyWithoutFocus)
        context.sensing.windowList = nil
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.surface)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a surface the window server does not list refuses its web content",
          arguments: [Shape.sheet, .modal], [Input.click, .key, .keyWithoutFocus])
    func aSurfaceMissingFromTheWindowListRefuses(shape: Shape, input: Input) async throws {
        let context = try await context(shape, pointer: input == .click, focusIsAbsent: input == .keyWithoutFocus)
        context.sensing.windowList?.removeAll {
            if case .window(let row) = $0 { return row.reference.identity == context.surface }
            return false
        }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.surface)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a row in front of the surface that cannot be read refuses its web content",
          arguments: [Shape.sheet, .modal], [Input.click, .key, .keyWithoutFocus])
    func anUnreadableRowInFrontRefuses(shape: Shape, input: Input) async throws {
        let context = try await context(shape, pointer: input == .click, focusIsAbsent: input == .keyWithoutFocus)
        context.sensing.windowList?.insert(.unreadable, at: 2)
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointRefusal.subtreeUnreadable(surface: context.surface)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("a modal whose keys already go to its remote content window keeps that window",
          arguments: [Shape.sheet, .modal])
    func aModalKeepsItsRemoteContentWindow(shape: Shape) async throws {
        let context  = try await context(shape, pointer: false)
        let endpoint = try remoteContentEndpoint(of: context)
        context.discovery.keyboardEndpoint = endpoint
        let turn = try await context.seat.acquire()
        // The remote window reaches the driver, which knows no family for it;
        // the refusal names the sheet when there is one.
        let named = shape == .sheet ? Self.sheetWindowNumber : endpoint.identity.windowNumber
        await #expect(throws: SessionFailure.surfaceFamilyUnclassified(windowNumber: named)) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.discovery.modalPoints.isEmpty, "the modal web route is asked only after a refusal")
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }

    @Test("an ordinary window never asks the modal routes", arguments: [true, false])
    func anOrdinaryWindowKeepsItsOwnRoutes(pointer: Bool) async throws {
        let context = try await context(.ordinary, pointer: pointer)
        try await send(context)

        expectDeliveredToTheSurface(context)
        #expect(context.discovery.ordinaryReadings >= 1)
        #expect(context.discovery.modalPoints.isEmpty)
        #expect(context.discovery.modalWebAreaReadings == 0)
    }

    @Test("a modal's page that stops proving it before the key is posted posts nothing",
          arguments: [Shape.sheet, .modal], [true, false])
    func aLostProofAtTheBoundaryPostsNothing(shape: Shape, focusIsAbsent: Bool) async throws {
        let context = try await context(shape, pointer: false, focusIsAbsent: focusIsAbsent)
        context.sender.onSendWait = { context.discovery.isProved = false }
        let turn = try await context.seat.acquire()
        await #expect(throws: InputEndpointInvalidation.focusedNodeChanged) {
            try await context.seat.send(context.command, observation: context.observation, turn: turn)
        }
        #expect(context.sender.sent.isEmpty)
        try context.seat.release(turn)
    }
}
