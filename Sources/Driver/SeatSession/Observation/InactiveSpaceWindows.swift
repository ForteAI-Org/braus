//
//  InactiveSpaceWindows.swift
//  Braus
//

import AppKit
import ApplicationServices
import SeatCore
import WindowPlacement

/// Reconciles retained discovery handles with windows on desktops the person is not showing.
nonisolated enum InactiveSpaceWindows {

    struct Candidate {
        let element: AXUIElement
        let surface: WindowSurface
    }

    static func read(ownedBy processIDs: Set<Int32>, cache: WindowElementCache) -> [Candidate] {
        // Every window it would keep needs a desktop no display shows; with none
        // there is nothing to find, and the per-window reads below are skipped.
        guard let layout = WindowSpaceProbe.layout(), layout.hasInactiveSpace else { return [] }
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        var candidates: [Candidate] = []
        var seen: Set<WindowIdentity> = []
        for element in cache.rememberedElements {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            AXUIElementSetMessagingTimeout(element, 0.05)
            var processID: pid_t = 0
            guard AXUIElementGetPid(element, &processID) == .success,
                  processIDs.contains(processID) else { continue }
            guard let number = WindowRelocator.windowNumber(of: element) else { continue }
            guard layout.containsOnlyInactive(WindowSpaceProbe.spaces(of: number)),
                  let application = NSRunningApplication(processIdentifier: processID),
                  !application.isHidden, !application.isTerminated,
                  let surfaces = WindowServerProbe.surfaces(matching: [processID: [number]]),
                  surfaces.count == 1, let surface = surfaces.first,
                  let identity = surface.reference.identity, seen.insert(identity).inserted,
                  surface.isOnInactiveSpace,
                  WindowRelocator.isWindowElement(element),
                  bool(kAXMinimizedAttribute, of: element) == false,
                  bool("AXFullScreen", of: element) != true,
                  bool(kAXModalAttribute, of: element) != nil else { continue }
            candidates.append(Candidate(element: element, surface: surface))
        }
        return candidates
    }

    private static func bool(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }
}
