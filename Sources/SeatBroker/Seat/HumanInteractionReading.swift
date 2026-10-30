//
//  HumanInteractionReading.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import CoreGraphics
import InteractionObservation
import Memory
import ScreenCapture
import WindowPlacement

/// HumanInteractionReading supplies post-event metadata and optional pixels without main-thread IPC.
/// A nil point requests the application's focused control; menuBar selects its AXMenuBar.
/// Field values are never read; only a separate static title element may supply AXValue as a label.
protocol HumanInteractionReading: Sendable {
    func element(at point: CGPoint?, processID: Int32, menuBar: Bool) async -> InteractionElementMetadata?
    func semantics(processID: Int32, windows: Set<Int>) async -> InteractionSemanticSnapshot?
    func picture(of window: LentWindow) async -> HumanPreviewControl.RetainedPicture?
}

extension HumanInteractionReading {
    func semantics(processID: Int32, windows: Set<Int>) async -> InteractionSemanticSnapshot? { nil }
}

struct NativeHumanInteractionReader: HumanInteractionReading {
    func element(at point: CGPoint?, processID: Int32, menuBar: Bool) async -> InteractionElementMetadata? {
        await InteractionSceneReader.metadata(at: point, processID: processID, menuBar: menuBar) {
            ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1
        }
    }

    func semantics(processID: Int32, windows: Set<Int>) async -> InteractionSemanticSnapshot? {
        await NativeInteractionSemanticReader.capture(processID: processID, windows: windows, seconds: 0.1,
            resolveWindow: { WindowRelocator.windowNumber(of: $0) },
            isReserved: { ValueMinimization.namesSecret($0) || ValueMinimization.scrubCredentials($0).1 })
            .withholding { ValueMinimization().minimize(text: $0).0 }
    }

    @concurrent
    func picture(of window: LentWindow) async -> HumanPreviewControl.RetainedPicture? {
        do {
            let image = try await StillCapturer().captureWindow(
                number: window.windowNumber,
                frame: window.frame,
                expectedProcessID: window.processID
            )
            guard !Task.isCancelled, let encoded = await HumanPreviewControl.encoded(image) else { return nil }
            return .init(heic: encoded.data, pixelSize: CGSize(width: image.width, height: image.height),
                         encodedSize: encoded.size)
        } catch {
            // Pixels are optional evidence. A failed capture leaves the admitted action without a picture.
            return nil
        }
    }
}
