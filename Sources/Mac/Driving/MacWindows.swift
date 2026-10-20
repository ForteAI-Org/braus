import CoreGraphics
import Foundation
import MacDriver
import PerceptionCore

/// MacWindows fills `WindowListing` from the app's `AXWindows`, front to back, minimized windows left
/// out. Each row carries the window server's number when a window of the process has the same frame,
/// so the seat and the capture can address the same window.
public struct MacWindows: WindowListing {

    /// A process's window-server windows: number and frame in global points.
    public typealias ServerWindows = @Sendable (pid_t) -> [(number: Int, frame: CGRect)]

    public let reader: any MacTreeReading
    public let serverWindows: ServerWindows

    public init(reader: any MacTreeReading = LiveMacTreeReader(), serverWindows: @escaping ServerWindows = Self.liveServerWindows) {
        self.reader        = reader
        self.serverWindows = serverWindows
    }

    public func windows(ownedBy processID: pid_t) async throws -> [WindowRow] {
        let listed = try await reader.windows(of: processID).filter { !$0.isMinimized }
        let server = serverWindows(processID)
        return listed.compactMap { window in
            guard let frame = window.frame else { return nil }
            let number = server.first { Self.sameFrame($0.frame, frame) }?.number ?? 0
            return WindowRow(layer: 0, frame: frame, title: window.title, number: number)
        }
    }

    static func sameFrame(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) < 1 && abs(left.minY - right.minY) < 1
            && abs(left.width - right.width) < 1 && abs(left.height - right.height) < 1
    }

    /// The process's layer-0 windows from `CGWindowListCopyWindowInfo`, every Space included.
    public static let liveServerWindows: ServerWindows = { processID in
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == processID,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return (number, frame)
        }
    }
}
