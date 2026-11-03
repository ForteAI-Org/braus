//
//  HumanInterventionCanvases.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Memory
import IncrementalText
import InteractionListener
import PerceptionCore

/// HumanInterventionCanvases follows the canvases of each window a person works in during one episode, so the read
/// after an action can show what changed inside a canvas: the crop of its changed area before and after.
///
/// Each window keeps its own `CanvasHistory`, fed in order with every read of it (the read when control passes, then
/// each action's read) and with the frames taken while the person pauses, which teach each canvas's noise. The
/// person's input is the input `CanvasHistory` means: a comparison with input between its frames only moves the
/// baseline. Scenes are the minimized ones the report keeps, so a caption holds no withheld text, and a crop over a
/// field whose text was withheld is refused. Each window with canvases holds at most `2 * maxGenerationBytes` of pixels.
struct HumanInterventionCanvases {

    /// One picture of a window and when its capture began, in uptime nanoseconds.
    /// A capture of a window: when it began, and when it ended where the reader knows, in uptime nanoseconds.
    struct Frame: Sendable {
        let image      : CGImage
        let capturedAt : UInt64
        var completedAt: UInt64? = nil
    }

    private var histories: [Int: CanvasHistory] = [:]

    /// Whether the last read of `window` held a canvas, so its idle frames are worth taking.
    func hasCanvases(in window: Int) -> Bool { histories[window]?.hasCanvases == true }

    /// Records `scene`, read from `frame` of `window`, and answers the crop of every canvas whose unmasked tiles
    /// changed since the previous read of that window. `lastInputAt` is when the person's last input ended. A canvas
    /// whose crop is refused, or cannot be drawn, is left out: no pixel of it leaves.
    mutating func observe(
        _ scene    : SceneSnapshot,
        frame      : Frame,
        of window  : InteractionWindow,
        lastInputAt: UInt64?
    ) -> [HumanSceneFinding.Canvas] {
        var history = histories[window.number] ?? CanvasHistory()
        // The kept scene stays unmarked, so the report's text and its scene evidence do not change.
        var marked = scene
        history.observe(
            &marked,
            in           : frame.image,
            window       : window.number,
            windowSize   : window.frame.size,
            displayedAt  : frame.capturedAt,
            lastCommandAt: lastInputAt
        )
        histories[window.number] = history
        return marked.elements.compactMap { canvas in
            guard canvas.kind == .canvas, canvas.hasChangedPixels == true,
                  case .crop(let crop, let caption)? = try? history.crop(
                      canvas.id,
                      isWithheld: Self.isWithheld
                  ) else { return nil }
            return HumanSceneFinding.Canvas(
                windowNumber: window.number,
                id          : canvas.id,
                name        : canvas.container ?? canvas.section ?? canvas.label,
                caption     : caption,
                before      : crop.before,
                after       : crop.after
            )
        }
    }

    /// Teaches the noise of the canvases of `window` from `frame`, taken after its last read with no read since.
    mutating func learnIdle(
        _ frame    : Frame,
        of window  : Int,
        lastInputAt: UInt64?
    ) {
        histories[window]?.learnIdle(
            from         : frame.image,
            window       : window,
            displayedAt  : frame.capturedAt,
            lastCommandAt: lastInputAt
        )
    }

    /// Drops every window's pixels.
    mutating func removeAll() { histories.removeAll() }

    /// The report's withholding rule for a crop: a text minimization withheld, a label naming a secret, or
    /// credential-shaped text.
    static func isWithheld(_ text: String) -> Bool {
        text.contains(ValueMinimization.marker) || ValueMinimization.namesSecret(text)
            || ValueMinimization.scrubCredentials(text).1
    }
}
