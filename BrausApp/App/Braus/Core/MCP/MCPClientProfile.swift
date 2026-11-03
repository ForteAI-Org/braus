import Capabilities
import Foundation
import AutomationRuntime

/// MCPClientProfile records a local grant. Each launch creates separate credentials.
struct MCPClientProfile: Codable, Identifiable, Equatable {
    var sessionProfile: SessionProfile { .mcpClient(name: name, attendance: .client) }

    let id: UUID
    let name: String
    let desktop: Bool
    var enabled: Bool

    init(id: UUID = UUID(), name: String, desktop: Bool = true, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.desktop = desktop
        self.enabled = enabled
    }
}
