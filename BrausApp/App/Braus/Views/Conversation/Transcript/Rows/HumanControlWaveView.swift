//
//  HumanControlWaveView.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/10/2026.
//

import AppKit

/// HumanControlWaveView is the wave before the words of the row shown while
/// the person uses the worker's application: a few small dots that rise and
/// fall one after another, slowly, like a calm wave.
///
/// One dot is drawn and a `CAReplicatorLayer` repeats it, each copy's rise a
/// little later than the one before, so the render server plays the motion and
/// the main thread draws nothing per frame. The animation runs only while the
/// view is shown in a window on screen; Reduce Motion keeps the dots still. It
/// takes no clicks and is no accessibility element: its row speaks for it.
@MainActor
final class HumanControlWaveView: NSView {

    // Five dots on an 8 point pitch with a 3 point rise fill `RowGeometry.humanControlWave`.
    private static let dots        = 5
    private static let dotSide     = 4.0
    private static let rise        = 3.0
    private static let riseSeconds = 0.9
    private static let waveKey     = "wave.rise"

    /// The dots' colour, the caption's.
    var tint = NSColor.secondaryLabelColor {
        didSet { if tint != oldValue { updateFill() } }
    }

    /// Where the view reads Reduce Motion; tests replace it.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private let replicator = CAReplicatorLayer()
    private let dot        = CALayer()

    /// True while the wave animation is on the dot.
    private(set) var isRunning = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        replicator.instanceCount     = Self.dots
        replicator.instanceTransform = CATransform3DMakeTranslation(Self.dotSide * 2, 0, 0)
        replicator.instanceDelay     = Self.riseSeconds / Double(Self.dots)
        dot.cornerRadius             = Self.dotSide / 2
        replicator.addSublayer(dot)
        layer?.addSublayer(replicator)
        updateFill()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replicator.frame = bounds
        dot.frame        = CGRect(
            x     : 0,
            y     : (bounds.height - Self.dotSide) / 2,
            width : Self.dotSide,
            height: Self.dotSide
        )
        CATransaction.commit()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center    = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        center.removeObserver(self)
        workspace.removeObserver(self)
        if let window {
            center.addObserver(
                self,
                selector: #selector(changed),
                name    : NSWindow.didChangeOcclusionStateNotification,
                object  : window
            )
            workspace.addObserver(
                self,
                selector: #selector(changed),
                name    : NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object  : nil
            )
        }
        refresh()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    @objc private func changed(_ note: Notification) {
        refresh()
    }

    private func updateFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.backgroundColor = tint.cgColor
        }
        CATransaction.commit()
    }

    /// Starts the wave when the view is shown and motion is allowed, and removes it otherwise.
    private func refresh() {
        let isVisible = window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !bounds.isEmpty
        let shouldRun = isVisible && !reducesMotion()
        guard shouldRun != isRunning else { return }
        isRunning = shouldRun
        guard shouldRun else {
            dot.removeAnimation(forKey: Self.waveKey)
            return
        }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue      = -Self.rise
        rise.toValue        = Self.rise
        rise.duration       = Self.riseSeconds
        rise.autoreverses   = true
        rise.repeatCount    = .infinity
        rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(
            rise,
            forKey: Self.waveKey
        )
    }
}
