//
//  SurfacesInFrontReadingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import Testing
@testable import WindowPlacement

/// The shipping rule of `WindowServerProbe.surfaces(inFrontOf:)` on lists of
/// this suite's own (ADR 0014, 2026-10-14). The rows the window server draws
/// itself are told by what the kernel says their owner PID is, never by the
/// owner name a row carries, which any application can take.
@Suite("Windows in front of a surface, read from the window server's list")
struct SurfacesInFrontReadingTests {

    private static let windowServerPID: Int32 = 169
    private static let surfacePID     : Int32 = 42
    private static let display   = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
    private static let spoofPath = "/Applications/Spoof.app/Contents/MacOS/Spoof"

    private let surface = WindowIdentity(
        process          : ProcessIdentity(processID: surfacePID, serialNumberHigh: 0, serialNumberLow: 1),
        windowNumber     : 1_515,
        ownerConnectionID: 9
    )

    /// One row of the on-screen list, as the dump of 2026-10-14 shaped them.
    private func row(
        _ number : Int,
        processID: Int32,
        name     : String,
        bounds   : CGRect? = CGRect(x: 100, y: 100, width: 400, height: 300),
        layer    : Int = 0
    ) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowOwnerName as String : name,
            kCGWindowNumber as String    : NSNumber(value: number),
            kCGWindowLayer as String     : NSNumber(value: layer),
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String     : NSNumber(value: 1)
        ]
        if processID >= 0 { row[kCGWindowOwnerPID as String] = NSNumber(value: processID) }
        if let bounds { row[kCGWindowBounds as String] = bounds.dictionaryRepresentation }
        return row
    }

    private var surfaceRow: [String: Any] {
        row(surface.windowNumber, processID: Self.surfacePID, name: "WebPopupProbe")
    }

    /// The cursor and a status indicator, the rows the real window server draws
    /// in front of every window, over the surface's frame.
    private var windowServerRows: [[String: Any]] {
        [
            row(
                7,
                processID: Self.windowServerPID,
                name     : "Window Server",
                bounds   : CGRect(x: 290, y: 240, width: 32, height: 32),
                layer    : 2_147_483_630
            ),
            row(
                8,
                processID: Self.windowServerPID,
                name     : "Window Server",
                bounds   : Self.display,
                layer    : 2_147_483_630
            )
        ]
    }

    /// Finder's desktop, the wallpaper and the backstop, each covering the display.
    private var desktopRows: [[String: Any]] {
        [
            row(16_722, processID: 457, name: "Finder", bounds: Self.display, layer: -2_147_483_603),
            row(16_716, processID: 443, name: "WindowManager", bounds: Self.display, layer: -2_147_483_624),
            row(3, processID: Self.windowServerPID, name: "Window Server", bounds: Self.display, layer: -2_147_483_626)
        ]
    }

    /// A 14 by 14 window of another process in front of the surface, as a view
    /// service's window is listed.
    private func serviceRow(named name: String) -> [String: Any] {
        row(9_090, processID: 777, name: name, bounds: CGRect(x: 120, y: 120, width: 14, height: 14))
    }

    /// The kernel's description of each PID in these lists: the window server
    /// for its own PID, an application of the person's for every other.
    private func executable(of processID: Int32) -> WindowServerProbe.ProcessExecutable? {
        processID == Self.windowServerPID
            ? WindowServerProbe.windowServer
            : WindowServerProbe.ProcessExecutable(path: Self.spoofPath, userID: 501)
    }

    private func attest(_ processID: Int32, _ number: Int, _ frame: CGRect) -> WindowReference? {
        WindowReference(
            identity: processID == Self.surfacePID && number == surface.windowNumber
                ? surface
                : WindowIdentity(
                    process          : ProcessIdentity(processID: processID, serialNumberHigh: 0, serialNumberLow: 2),
                    windowNumber     : number,
                    ownerConnectionID: 10 + processID
                ),
            frame: frame
        )
    }

    private func read(
        _ rows      : [[String: Any]],
        executableOf: (Int32) -> WindowServerProbe.ProcessExecutable? = { _ in nil },
        attesting   : ((Int32, Int, CGRect) -> WindowReference?)? = nil
    ) -> [WindowSurface]? {
        WindowServerProbe.readSurfaces(
            inFrontOf   : surface,
            rows        : rows,
            executableOf: executableOf,
            attesting   : attesting ?? attest
        )
    }

    @Test("the window server's own rows in front are left out, asked of the kernel once")
    func theWindowServersRowsAreLeftOut() throws {
        var asked: [Int32] = []
        let surfaces = try #require(read(windowServerRows + [surfaceRow] + desktopRows, executableOf: {
            asked.append($0)
            return executable(of: $0)
        }))
        #expect(surfaces.isEmpty)
        #expect(asked == [Self.windowServerPID])
    }

    @Test(
        "a process named Window Server that the kernel describes as anything else counts",
        arguments: [
            WindowServerProbe.ProcessExecutable(path: spoofPath, userID: 501),
            WindowServerProbe.ProcessExecutable(path: WindowServerProbe.windowServer.path, userID: 501),
            WindowServerProbe.ProcessExecutable(path: spoofPath, userID: 88)
        ]
    )
    func aProcessNamedWindowServerCounts(described: WindowServerProbe.ProcessExecutable) throws {
        let spoof    = serviceRow(named: "Window Server")
        let surfaces = try #require(read(windowServerRows + [spoof, surfaceRow] + desktopRows, executableOf: {
            $0 == 777 ? described : executable(of: $0)
        }))
        #expect(surfaces.map(\.reference.windowNumber) == [9_090])
        #expect(surfaces.map(\.reference.processID) == [777])
        #expect(surfaces.map(\.isVisible) == [true])
    }

    @Test("a row in front whose owner the kernel cannot describe counts, whatever its name")
    func anUndescribedOwnerInFrontCounts() throws {
        let surfaces = try #require(read(windowServerRows + [surfaceRow] + desktopRows, executableOf: { _ in nil }))
        #expect(surfaces.map(\.reference.windowNumber) == [7, 8])
        #expect(surfaces.map(\.reference.processID) == [Self.windowServerPID, Self.windowServerPID])
    }

    @Test("the desktop rows behind the surface are neither read nor counted")
    func theDesktopRowsBehindAreNotRead() throws {
        var asked   : [Int32] = []
        var attested: [Int]   = []
        let surfaces = try #require(read(
            [surfaceRow] + desktopRows,
            executableOf: {
                asked.append($0)
                return nil
            },
            attesting: { processID, number, frame in
                attested.append(number)
                return attest(processID, number, frame)
            }
        ))
        #expect(surfaces.isEmpty)
        #expect(asked.isEmpty)
        #expect(attested == [surface.windowNumber])
    }

    @Test("a surface not listed, a row in front with no owner, and a failed attestation are no reading")
    func failedReadings() {
        let service = serviceRow(named: "Service")
        #expect(read(windowServerRows + desktopRows, executableOf: executable(of:)) == nil)
        #expect(read([row(9_091, processID: -1, name: "Service"), surfaceRow], executableOf: executable(of:)) == nil)
        #expect(read([service, surfaceRow], executableOf: executable(of:), attesting: { _, _, _ in nil }) == nil)
        #expect(read(
            [service, surfaceRow],
            executableOf: executable(of:),
            attesting   : { processID, number, frame in
                number == surface.windowNumber ? attest(processID, number, frame) : nil
            }
        ) == nil)
    }

    @Test("a row of the surface's own process, or one not over it, is not asked of the kernel")
    func ownAndDistantRowsAreSkipped() throws {
        var asked: [Int32] = []
        let own  = row(1_516, processID: Self.surfacePID, name: "WebPopupProbe")
        let away = row(9_092, processID: 777, name: "Service", bounds: CGRect(x: 1_000, y: 1_000, width: 50, height: 50))
        let surfaces = try #require(read([own, away, surfaceRow], executableOf: {
            asked.append($0)
            return executable(of: $0)
        }))
        #expect(surfaces.isEmpty)
        #expect(asked.isEmpty)
    }
}
