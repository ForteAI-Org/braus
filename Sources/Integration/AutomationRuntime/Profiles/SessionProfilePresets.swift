import Foundation
import Capabilities

extension SessionProfile {
    public nonisolated static let app = SessionProfile(attendance: .app, level: .actConnectors, memory: .readLearn,
        catalogue: .openAndPrivate, takeover: true, options: .init(harnessWebSearch: true), name: "app")

    public nonisolated static let cli = SessionProfile(attendance: .none, level: .actConnectors, memory: .readLearn,
        catalogue: .openAndPrivate, takeover: false, options: .init(seatWarmSeconds: 0), name: "cli")

    public nonisolated static func mcpClient(name: String, attendance: Attendance) -> SessionProfile {
        SessionProfile(attendance: attendance, level: .act, memory: .read, catalogue: .open, takeover: false,
            options: .init(holdsFromPlanToEnd: true), name: name)
    }
}
