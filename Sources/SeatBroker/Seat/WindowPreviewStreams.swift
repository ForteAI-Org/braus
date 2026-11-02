import AppKit
import Darwin
import OSLog
import SeatCore

/// WindowPreviewStreams owns fixed-window views. Besides SeatDriver's observation preview, at most
/// `WindowStreamTiers.streamLimit` windows stream concurrently, each at the quality the tiers give it.
/// A failed stop retains its slot until capture confirms resource release.
@MainActor
final class WindowPreviewStreams {
    private struct Entry {
        let identity: WindowIdentity
        let controller: PreviewStreamController
        let scale: CGFloat
        var quality: WindowStreamQuality?
    }

    private static let log = Logger(subsystem: "dev.forte.AgentSeatKit", category: "Preview")
    private let makeController: (Int) -> PreviewStreamController
    private var entries: [Int: Entry] = [:]
    private var surfaces: [WindowSurface] = []
    private var mainWindowNumber: Int?
    private var pending: Task<Void, Never>?
    private var stopped = false
    private var denied: Set<Int> = []
    private var retiring: Set<Int> = []
    private var waiting: [Int: Entry] = [:]

    /// The window last admitted, which stays on the top tier until another one is.
    private var newest: Int?
    private var report: Task<Void, Never>?
    private static let limit = WindowStreamTiers.streamLimit

    init(makeController: @escaping (Int) -> PreviewStreamController = {
        PreviewStreamController(activeFramesPerSecond: $0)
    }) {
        self.makeController = makeController
    }

    /// Reuses the pool across leases without dropping unconfirmed capture reservations.
    func begin() {
        stopped = false
    }

    func update(_ surfaces: [WindowSurface], mainWindowNumber: Int?) {
        guard !stopped else { return }
        self.surfaces = surfaces
        self.mainWindowNumber = mainWindowNumber
        waiting = waiting.filter { _, entry in surfaces.contains { $0.reference.identity == entry.identity } }
        for (number, entry) in entries where !surfaces.contains(where: { $0.reference.identity == entry.identity }) {
            retiring.insert(number)
        }
        let preceding = pending
        pending = Task { [weak self] in
            await preceding?.value
            guard let self, !stopped else { return }
            for (number, entry) in entries {
                if retiring.contains(number) {
                    await entry.controller.stop()
                    if entry.controller.stream?.hasUnconfirmedResource != true {
                        entries[number] = nil
                        retiring.remove(number)
                        denied.removeAll()
                        Self.log.info("window stream stopped: \(number), slots \(self.entries.count + 1)/\(Self.limit + 1)")
                    }
                    continue
                }
            }
            admitWaitingViews()
            configureAll()
        }
    }

    func makeView(windowNumber: Int, contentsScale: CGFloat) -> NSView? {
        guard !stopped, contentsScale.isFinite, contentsScale > 0,
              let surface = surfaces.first(where: { $0.reference.windowNumber == windowNumber }),
              let identity = surface.reference.identity else { return nil }
        if let entry = entries[windowNumber], !retiring.contains(windowNumber) {
            guard entry.identity == identity else { return nil }
            // Asked at another scale, as its view reached a display of another scale: the same
            // stream, in the same slot, follows the window at the new one.
            if entry.scale != contentsScale {
                entries[windowNumber] = Entry(identity: entry.identity, controller: entry.controller,
                                              scale: contentsScale, quality: entry.quality)
                configureAll()
                Self.log.info("window stream rescaled: \(windowNumber), \(entry.scale)x to \(contentsScale)x")
            }
            return LivePreviewView(preview: entry.controller, contentsScale: contentsScale)
        }
        if let entry = waiting[windowNumber] {
            guard entry.identity == identity else { return nil }
            if entry.scale != contentsScale {
                waiting[windowNumber] = Entry(identity: entry.identity, controller: entry.controller, scale: contentsScale, quality: nil)
            }
            return LivePreviewView(preview: entry.controller, contentsScale: contentsScale)
        }
        // A view requested by an inventory observer must survive the asynchronous slot release.
        let waitsForRelease = retiring.contains(windowNumber) || entries.count >= Self.limit
        guard entries.count + waiting.count - retiring.count < Self.limit else {
            if denied.insert(windowNumber).inserted {
                Self.log.info("window stream deferred: \(windowNumber), budget \(Self.limit + 1)/\(Self.limit + 1) including observation")
            }
            return nil
        }
        let main = windowNumber == mainWindowNumber
        let controller = makeController(main ? WindowStreamTiers.mainFramesPerSecond : WindowStreamTiers.tiers[0].framesPerSecond)
        let entry = Entry(identity: identity, controller: controller, scale: contentsScale, quality: nil)
        newest = windowNumber
        if waitsForRelease {
            waiting[windowNumber] = entry
            Self.log.info("window stream waiting for confirmed release: \(windowNumber)")
        } else {
            entries[windowNumber] = entry
            configureAll()
            Self.log.info("window stream admitted: \(windowNumber), slots \(self.entries.count + 1)/\(Self.limit + 1)")
            startReport()
        }
        return LivePreviewView(preview: controller, contentsScale: contentsScale)
    }

    private func admitWaitingViews() {
        guard !stopped else { return }
        let ordered = surfaces.sorted {
            ($0.reference.windowNumber == mainWindowNumber ? 0 : 1)
                < ($1.reference.windowNumber == mainWindowNumber ? 0 : 1)
        }
        for surface in ordered {
            let number = surface.reference.windowNumber
            guard entries.count < Self.limit, entries[number] == nil,
                  let entry = waiting.removeValue(forKey: number) else { continue }
            entries[number] = entry
            Self.log.info("window stream released from wait: \(number), slots \(self.entries.count + 1)/\(Self.limit + 1)")
            startReport()
        }
    }

    /// Gives every streaming window the quality the tiers give it now. Tier decisions are a few
    /// multiplications per window, made on open, close, order, frame and scale changes only.
    private func configureAll() {
        guard !stopped else { return }
        let front = surfaces.first?.reference.windowNumber
        let windows = surfaces.compactMap { surface -> WindowStreamTiers.Window? in
            let number = surface.reference.windowNumber
            guard let entry = entries[number], !retiring.contains(number),
                  entry.identity == surface.reference.identity else { return nil }
            return WindowStreamTiers.Window(number: number, size: surface.reference.frame.size, viewScale: entry.scale,
                                            isMain: number == mainWindowNumber, isFresh: number == front || number == newest)
        }
        let qualities = WindowStreamTiers.qualities(for: windows)
        for surface in surfaces {
            let number = surface.reference.windowNumber
            guard let entry = entries[number], let quality = qualities[number] else { continue }
            let frame = surface.reference.frame
            let pixels = quality.pixelSize(of: frame.size)
            entry.controller.setActiveFramesPerSecond(quality.framesPerSecond)
            entry.controller.follow(identity: entry.identity, frame: frame, pixelSize: pixels)
            guard quality != entry.quality else { continue }
            // A quality the tiers chose is not a reading that may move again: given twice, the
            // shape's stabilisation (two readings that agree) takes it at once.
            entry.controller.follow(identity: entry.identity, frame: frame, pixelSize: pixels)
            entries[number]?.quality = quality
            Self.log.info("window stream quality: \(number), \(Int(pixels.width))x\(Int(pixels.height)) at \(quality.framesPerSecond) fps")
        }
    }

    /// Logs every ~5 s, while windows stream, each stream's pixels and its configured and delivered
    /// frame rates, with the process CPU. Nothing runs per frame.
    private func startReport() {
        guard report == nil else { return }
        report = Task { [weak self] in
            var counts: [Int: Int] = [:]
            var cpu = Self.processCPUSeconds()
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !self.stopped, !self.entries.isEmpty else { break }
                let now = ContinuousClock.now
                let seconds = Double((now - last).components.seconds) + Double((now - last).components.attoseconds) / 1e18
                let used = Self.processCPUSeconds()
                var lines: [String] = []
                for (number, entry) in self.entries.sorted(by: { $0.key < $1.key }) {
                    let count = entry.controller.stream?.presentedFrameCount ?? 0
                    let delivered = Double(max(0, count - (counts[number] ?? count))) / seconds
                    counts[number] = count
                    guard let quality = entry.quality,
                          let size = self.surfaces.first(where: { $0.reference.windowNumber == number })?.reference.frame.size
                    else { continue }
                    let pixels = quality.pixelSize(of: size)
                    lines.append("\(number) \(Int(pixels.width))x\(Int(pixels.height)) \(quality.framesPerSecond)/\(String(format: "%.1f", delivered)) fps")
                }
                let percent = String(format: "%.1f", (used - cpu) / seconds * 100)
                Self.log.info("window streams: cpu \(percent, privacy: .public)%, \(lines.joined(separator: ", "), privacy: .public)")
                cpu = used
                last = now
            }
            // A cancelled report was replaced or stopped; only one that ran out clears the slot.
            if !Task.isCancelled { self?.report = nil }
        }
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    func waitForPendingTransitions() async {
        await pending?.value
        for entry in entries.values { await entry.controller.waitForPendingTransition() }
    }

    func stop() async {
        stopped = true
        surfaces = []
        waiting = [:]
        newest = nil
        report?.cancel()
        report = nil
        await pending?.value
        pending = nil
        retiring.formUnion(entries.keys)
        for entry in entries.values { await entry.controller.stop() }
        entries = entries.filter { $0.value.controller.stream?.hasUnconfirmedResource == true }
        retiring = Set(entries.keys)
        denied.removeAll()
    }
}
