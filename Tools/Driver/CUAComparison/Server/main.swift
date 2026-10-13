import AppKit
import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import SeatBroker

// braus-mcp-stdio <knowledge directory>: one JSON-RPC message per line on stdin and stdout, answered by
// the MCPRouter and AutomationTools the app's worker host composes, over a worker's desktop: a
// BrokeredAutomationSession on a SeatBroker made as the app makes its own. BRAUS_BENCH_UNVALIDATED=1 is
// the broker's opt-in for a macOS build the ledger has not validated, which the app always passes.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: braus-mcp-stdio <knowledge directory>\n".utf8))
    exit(2)
}

// Driver ADR 0007: a caller-owned AppKit loop across asynchronous Seat work, as the braus CLI does.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    let knowledge = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    // The app's broker (AppModel) on the standard display, its run records kept with this run.
    let broker    = SeatBroker(configuration: SeatBrokerConfiguration(
        allowUnvalidatedBuild: ProcessInfo.processInfo.environment["BRAUS_BENCH_UNVALIDATED"] == "1",
        recordingDirectory   : knowledge.appending(
            path         : "Runs",
            directoryHint: .isDirectory
        )
    ))
    // A worker's desktop and tools, as TeamModel composes them for one conversation.
    let workerID  = UUID()
    let desktop   = BrokeredAutomationSession(
        broker            : broker,
        workerID          : workerID,
        knowledgeDirectory: knowledge
    )
    let tools     = AutomationTools(session: desktop)
    tools.producer = CallProducer(
        source  : .app,
        streamID: "worker-" + workerID.uuidString
    )
    let router    = MCPRouter(tools: AutomationTools.definitions) { name, arguments in
        try await tools.call(name, arguments)
    }
    // The whole client is one worker turn: the seat is held between calls, never released for idling.
    do {
        try await desktop.turn {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let request = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                if let reply = await router.handle(request) {
                    FileHandle.standardOutput.write(try JSONEncoder().encode(reply) + Data([10]))
                }
            }
        }
    } catch {
        FileHandle.standardError.write(Data("braus-mcp-stdio: \(error)\n".utf8))
    }
    // The client closed stdin: what the app does as it quits. The session gives the window and the
    // seat back, the parked seat takes its display down, and the memory writes what it was taught.
    await tools.session.close()
    await broker.queue.shutdown()
    await MemoryService.closeAll()
    exit(0)
}
application.run()
