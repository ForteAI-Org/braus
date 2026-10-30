import AppKit
import SeatCapture
import SeatCore

/// An AppKit view whose backing layer receives the capture stream's frames.
/// Frames go IOSurface to layer, no CGImage in between.
@MainActor
public final class LivePreviewView: NSView {
    private let monitorLayer: PreviewLayer
    private weak var driver: SeatDriver?
    private weak var preview: PreviewStreamController?

    public override var isFlipped: Bool { true }

    init(driver: SeatDriver, contentsScale: CGFloat) {
        self.driver = driver
        self.monitorLayer = PreviewLayer(contentsScale: contentsScale)
        super.init(frame: .zero)
        wantsLayer = true
        monitorLayer.onPictureSize = { [weak self] in self?.onPictureSize?($0) }
        monitorLayer.onPictureAspect = { [weak self] in self?.onPictureAspect?($0) }
        driver.attach(monitorLayer)
    }

    init(preview: PreviewStreamController, contentsScale: CGFloat) {
        self.preview = preview
        self.monitorLayer = PreviewLayer(contentsScale: contentsScale)
        super.init(frame: .zero)
        wantsLayer = true
        monitorLayer.onPictureSize = { [weak self] in self?.onPictureSize?($0) }
        monitorLayer.onPictureAspect = { [weak self] in self?.onPictureAspect?($0) }
        preview.attach(monitorLayer)
    }

    isolated deinit {
        preview?.detach(monitorLayer)
        driver?.detach(monitorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("LivePreviewView is code-only") }

    /// Told the width over height of the picture the layer draws, when it first is known and when it changes.
    /// The view's own shape can differ (bars inside it), so overlays placed on the picture read this.
    public var onPictureAspect: ((CGFloat) -> Void)? {
        didSet { if monitorLayer.pictureAspect > 0 { onPictureAspect?(monitorLayer.pictureAspect) } }
    }

    /// The displayed capture's size in screen points.
    public var onPictureSize: ((CGSize) -> Void)? {
        didSet { if monitorLayer.pictureSize != .zero { onPictureSize?(monitorLayer.pictureSize) } }
    }

    public override func makeBackingLayer() -> CALayer { monitorLayer }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        monitorLayer.contentsScale = window?.backingScaleFactor ?? monitorLayer.contentsScale
    }

    /// While true the stream presents nothing here and the view keeps its last frame; the stream runs on.
    public var isPaused = false {
        didSet { if isPaused != oldValue { updateAttachment() } }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAttachment()
    }

    private func updateAttachment() {
        if window == nil || isPaused {
            driver?.detach(monitorLayer)
            preview?.detach(monitorLayer)
        } else {
            driver?.attach(monitorLayer)
            preview?.attach(monitorLayer)
        }
    }
}

/// A monitor layer that also reports the shape of the part of the surface it draws.
private final class PreviewLayer: MonitorLayer {
    var onPictureAspect: ((CGFloat) -> Void)?
    var onPictureSize: ((CGSize) -> Void)?
    private(set) var pictureSize: CGSize = .zero
    private(set) var pictureAspect: CGFloat = 0

    override func present(_ frame: SeatFrame) {
        super.present(frame)
        let size = frame.geometry.screenRect.size
        if frame.geometry.isValid, size != pictureSize {
            pictureSize = size
            onPictureSize?(size)
        }
        let width  = CGFloat(frame.surface.width)  * contentsRect.width
        let height = CGFloat(frame.surface.height) * contentsRect.height
        guard width > 0, height > 0, abs(width / height - pictureAspect) > 0.001 else { return }
        pictureAspect = width / height
        onPictureAspect?(pictureAspect)
    }
}
