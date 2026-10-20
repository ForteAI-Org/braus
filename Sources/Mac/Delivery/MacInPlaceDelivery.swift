import CoreGraphics
import EngineCore
import Foundation
import MacDriving
import SeatCore
import SeatInput
import WindowPlacement

/// MacInPlaceDelivery fills `MacEventDelivering` with the seat's Background Driver (`InputDriver`):
/// `CGEventPostToPid` with SkyLight's record fields, the same recipes the seat runs, aimed at a window
/// that stays on the person's screen. The driver refuses on builds the ledger does not list unless
/// `allowUnvalidatedBuild`; that refusal is the ladder's "mode 2 refused on this build".
public actor MacInPlaceDelivery: MacEventDelivering {

    private let allowUnvalidatedBuild: Bool
    private var driver: InputDriver?

    public init(allowUnvalidatedBuild: Bool = false) {
        self.allowUnvalidatedBuild = allowUnvalidatedBuild
    }

    public func deliver(
        _ gesture     : Gesture,
        toWindow windowNumber: Int,
        of processID  : pid_t,
        needsKeyWindow: Bool
    ) async throws -> MacEventReceipt {
        let driver = try inputDriver()
        guard let window = WindowServerProbe.geometry(of: windowNumber, allowUnvalidatedBuild: allowUnvalidatedBuild),
              window.processID == processID,
              let geometry = RemoteWindowProbe.recipientGeometry(of: window, allowUnvalidatedBuild: allowUnvalidatedBuild)
        else { throw MacDeliveryFailure.windowNotAttested(windowNumber) }

        let correlationID = Int64.random(in: 1..<Int64.max)
        let platform = MacInPlacePlatform(preparesKeyWindow: needsKeyWindow)
        let command = try await Self.command(for: gesture, in: geometry, owner: correlationID, processID: processID)
        let receipt = try await driver.send(command, to: window, correlationID: correlationID, platform: platform)
        return MacEventReceipt(preparationNotRestored: receipt.hasUnrestoredPreparation)
    }

    private func inputDriver() throws -> InputDriver {
        if let driver { return driver }
        do {
            let made = try InputDriver(allowUnvalidatedBuild: allowUnvalidatedBuild)
            driver = made
            return made
        } catch {
            throw MacDeliveryFailure.refusedOnThisBuild("\(error)")
        }
    }

    static func command(
        for gesture: Gesture, in geometry: WindowGeometryObservation, owner: Int64, processID: pid_t
    ) async throws -> InputCommand {
        func location(_ point: CGPoint) throws -> InputLocation {
            guard let location = InputLocation(screenPoint: point, observedIn: geometry) else {
                throw MacDeliveryFailure.pointOutsideWindow(point)
            }
            return location
        }
        switch gesture {
            case .click(let point, let button, let count):
                return .click(try location(point), button: button == .left ? .left : .right, count: count)
            case .scroll(let point, let deltaY, _):
                return .scroll(try location(point), deltaY: Int32(deltaY))
            case .key(let code, let modifiers):
                return .key(virtualKey: CGKeyCode(code), text: "", modifiers: Self.modifiers(modifiers))
            case .character(let character, let modifiers):
                let shortcut = Shortcut.character(character, holding: Self.modifiers(modifiers))
                return try ShortcutResolution.resolve(
                    shortcut, layout: await KeyboardLayoutReader.current(), owner: owner, processID: processID
                ).command
            case .type(let text):
                return .text(text)
            case .insert(let text):
                return .insertText(text)
            case .drag:
                throw MacDeliveryFailure.needsSeat("a drag")
        }
    }

    static func modifiers(_ modifiers: KeyModifiers) -> Modifiers {
        var result: Modifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift)   { result.insert(.shift) }
        if modifiers.contains(.option)  { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}

/// MacInPlacePlatform is AppKit's recipe for a window in place: plain events, with the target's own
/// AppKit state prepared (activation and the two key-window records on the target window, restored
/// after) when the gesture needs the key window.
nonisolated struct MacInPlacePlatform: InputPlatform {

    let preparesKeyWindow: Bool

    func preparation(for command: InputCommand) -> Preparation {
        preparesKeyWindow ? .internalAppKitState : .none
    }
}

nonisolated public enum MacDeliveryFailure: Error, Equatable, Sendable {
    /// Mode 2 refused on this build: the ledger does not list it, or a primitive is missing.
    case refusedOnThisBuild(String)
    case windowNotAttested(Int)
    case pointOutsideWindow(CGPoint)
    case needsSeat(String)
}
