import AutomationRuntime
import AppKit
import CoreGraphics
import EngineCore
import Foundation
import ImageIO
import Memory
import SeatBroker
import SeatCore
import SeatSession
import UniformTypeIdentifiers

/// SelectCommand selects a dropdown item within one background Seat lifetime, through the brokered
/// session's own selection (`BrokeredSeat`).
enum SelectCommand {

    static func run(_ invocation: Invocation) async throws {
        guard invocation.flags.contains("seat") else {
            throw UsageError.missing("--seat (select currently supports background dropdowns)")
        }
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let control = try invocation.positional(1, "<dropdown>")
        let item = try invocation.positional(2, "<item>")
        let bundleID = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        let knowledge = Runtime.knowledgeDirectory(invocation)
        try await BrokeredSeat.withSession(
            application,
            invocation,
            knowledge: knowledge,
            recorder : Runtime.commandLineRecorder(knowledge: knowledge)
        ) { desktop, _ in
            let kind = try await perform(
                control   : control,
                item      : item,
                bundleID  : bundleID,
                desktop   : desktop,
                invocation: invocation,
                recorder  : Runtime.commandLineRecorder(knowledge: knowledge)
            )
            guard [.foundActed, .dryRun].contains(kind) else { throw ActFailure(kind) }
        }
    }

    /// Selects on a session already open, allowing a batch to reuse the same menu operation and
    /// verification.
    static func perform(
        control: String,
        item: String,
        bundleID: String,
        desktop: BrokeredAutomationSession,
        invocation: Invocation,
        recorder: CallRecorder,
        begun: Bool = false,
        evidenceDirectory: String? = nil
    ) async throws -> ActOutcomeKind {
        let dryRun = invocation.flags.contains("dry-run")
        // A batch's step is begun and started by its batch; the command's own call is begun here.
        if !dryRun, !begun {
            do {
                try await recorder.begin(
                    .select(control: control, item: item),
                    app: AppContextIdentity(bundleID: bundleID)
                )
            } catch {
                print("refused: Braus's memory did not confirm the selection before it could act (\(error)); nothing was done")
                return .refused
            }
        }
        do {
            // A dry run is no call, so what the selector perceived is reported to none.
            let result = try await CallRecorder.$current.withValue(dryRun ? nil : recorder) {
                try await desktop.select(
                    control  : control,
                    item     : item,
                    dryRun   : dryRun,
                    onMenu   : { menu in print("menu: observed #\(menu.window.windowNumber) at \(menu.frame)") },
                    onCapture: { stage, image in
                        if let directory = evidenceDirectory ?? invocation.options["evidence"] {
                            try save(image, stage: stage, directory: directory)
                        }
                    }
                )
            }
            print("\(result.outcome.kind.rawValue): \(result.outcome.message)")
            if !dryRun { try await CommandLineCall.end(recorder, outcome: result.outcome, tool: .select) }
            if let receipt = result.receipt {
                print("menu: #\(receipt.menu.window.windowNumber), closed by \(receipt.closedBy.rawValue)")
                if receipt.opening != nil {
                    print("menu: routed opening click, \(receipt.choosing.count) selection key presses")
                }
                if let observation = receipt.observation {
                    print("selection: focus changed=\(observation.frontmostApplicationChanged), cursor distance=\(observation.maximumCursorDistance)")
                }
            }
            return result.outcome.kind
        } catch let suspension as CommandLineCall.Unsaved {
            throw suspension
        } catch {
            if !dryRun {
                try? await recorder.end(
                    error is CancellationError ? .cancelled : .failed,
                    result: error is CancellationError ? nil : .error(message: String(describing: error)),
                    tool: .select
                )
            }
            if let seat = desktop.heldSeat {
                print("seat: selection stopped in state \(seat.state)")
                if seat.lastFocusRecovery != nil {
                    print("seat: a focus recovery occurred; this was not an uninterrupted background operation")
                }
            }
            throw error
        }
    }

    private static func save(_ image: CGImage, stage: String, directory: String) throws {
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(stage).png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
