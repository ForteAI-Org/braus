import AppAdapters
import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory

/// ExternalMCPSession exposes the current engine for one authenticated client connection.
/// The host serializes requests and drains them before closing this session. Disconnects
/// release its Seat; reconnects start fresh and never replay an earlier operation.
@MainActor
final class ExternalMCPSession {
    typealias Performing = @MainActor (@escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue

    private let profile: MCPClientProfile
    private let tools: AutomationTools
    private let perform: Performing
    private let activity: @MainActor (String) -> Void
    /// The client profile's barrier (R05), from the owner that outlives this session, so a reconnect does not reset it.
    private let barrier: ActionBarrier
    private var isClosed = false

    lazy var router: MCPRouter = {
        let router = MCPRouter(
            tools: profile.desktop ? tools.toolDefinitions : [],
            instructions: profile.desktop ? tools.instructions + "\n" + Self.instructions : Self.withoutDesktop
        ) { [weak self] name, arguments in
            guard let self, !self.isClosed else {
                throw MCPRequestFailure("This client is not authorized for desktop access.")
            }
            return try await self.callBraus(name, arguments)
        }

        return router
    }()

    /// `channels` are the routes beyond the Seat `session` was composed with, which decide Braus's tools. `barrier` is
    /// the profile's own, kept by the owner that makes its sessions (R05). `adapters` replaces the Mac's app adapters
    /// with a test's (on a temporary root) only where `channels` already composes them: it never turns the channel
    /// on, and nil, what the app passes, keeps the composition as it is.
    /// `adapterApprover` asks the person in the app before an adapter's irreversible verb runs; without one
    /// those verbs are refused. `offersWeb` says that `session` routes web addresses to a web session.
    init(
        profile: MCPClientProfile,
        session: any AutomationSessionOperating,
        channels: AutomationChannels = [],
        perform: @escaping Performing = { try await $0() },
        activity: @escaping @MainActor (String) -> Void = { _ in },
        barrier: ActionBarrier = ActionBarrier(),
        adapters: AppAdapters? = nil,
        adapterApprover: (any AdapterApproving)? = nil,
        offersWeb: Bool = false
    ) {
        self.profile = profile
        self.barrier = barrier
        self.tools = AutomationTools(session: session, channels: channels,
                                     adapters: channels.contains(.adapters) ? (adapters ?? .standard(approver: adapterApprover)) : nil,
                                     offersWeb: offersWeb)
        if let adapters, channels.contains(.adapters) { self.tools.adapters = adapters }
        self.tools.producer = CallProducer(source: .mcp, streamID: "mcp-" + profile.id.uuidString)
        self.perform = perform
        self.activity = activity
    }

    /// Braus's own tools, for a profile with desktop access, through the Seat's queue.
    private func callBraus(
        _ name     : String,
        _ arguments: JSONValue
    ) async throws -> JSONValue {
        guard !isClosed, profile.desktop else {
            throw MCPRequestFailure("This client is not authorized for desktop access.")
        }
        if let refusal = barrier.refusal(of: name, arguments) { throw MCPRequestFailure(refusal) }
        activity(name)
        return try await perform { [tools] in
            try await tools.call(
                name,
                arguments
            )
        }
    }

    static let instructions = "Braus must remain open. open_session can launch an installed app: "
        + "use apps to find its exact bundle ID. Calls share the app’s Seat queue with its workers; "
        + "if a session expires, observe the current state before deciding what to do. "
        + "Reconnects start a fresh session and do not restore the previous session ID."

    /// What a profile without desktop access is told instead of the desktop's instructions.
    static let withoutDesktop = "Braus must remain open. This client has no desktop access: it cannot see or "
        + "control the apps on this Mac, and Braus's desktop tools are not offered to it."

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await tools.session.close()
    }
}
