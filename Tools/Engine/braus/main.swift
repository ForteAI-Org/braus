//
//  main.swift
//  Braus
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import AutomationRuntime
import Darwin
import Foundation
import LocalMCP

// The foreground command line over the Perception and Engine layers: what a model host will do
// through the tool registry, done by hand from a terminal. One subcommand per verb; every one exits
// non zero when it could not do what was asked, and prints one sentence saying why.
//
//   braus windows <app>
//   braus scene   <app> [--json]
//   braus act     <app> <target> [--verb click|double_click|triple_click|right_click|set_toggle]
//                                [--value on|off] [--section <name>] [--dry-run] [--allow-destructive]
//   braus memory  <app>
//   braus adapters [<app> [<query>] | call <adapter.verb> [<json>] [--allow-destructive]]
//
// <app> is a bundle id or an application name; --knowledge <dir> overrides where memory lives;
// --seat drives on the Seat's virtual display instead of the real screen.

let rawArguments = Array(CommandLine.arguments.dropFirst())
let normalizedArguments = rawArguments.first == "--chat" ? ["chat"] + rawArguments.dropFirst() : rawArguments
let invocation = Invocation(arguments: normalizedArguments)

guard let command = invocation.command else {
    print(Usage.text)
    exit(invocation.arguments.isEmpty ? 0 : 2)
}

// Driver ADR 0007 requires a caller-owned AppKit loop across asynchronous Seat work.
// A prohibited application keeps that loop alive without a Dock icon or activation.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        switch command {
            case "chat": try await ChatCommand.run(arguments: Array(normalizedArguments.dropFirst()))
            case "peek": try await PeekCommand.run(arguments: Array(normalizedArguments.dropFirst()))
            case "watch": try await WatchCommand.run(arguments: Array(normalizedArguments.dropFirst()))
            case "mcp-bridge":
                guard normalizedArguments.count == 3, normalizedArguments[1] == "--connection" else {
                    throw UsageError.missing("mcp-bridge --connection <private connection file>")
                }
                try await MCPStdioBridge.run(connectionFile: URL(fileURLWithPath: normalizedArguments[2]))
            case "windows": try await WindowsCommand.run(invocation)
            case "scene"  : try await SceneCommand.run(invocation)
            case "act"    : try await ActCommand.run(invocation)
            case "select" : try await SelectCommand.run(invocation)
            case "batch"  : try await BatchCommand.run(invocation)
            case "memory" : try await MemoryCommand.run(invocation)
            case "doctor" : try await DoctorCommand.run(invocation)
            case "adapters": try await AdaptersCommand.run(invocation)
            case "mac"     : try await MacCommand.run(invocation)
            case "help", "--help", "-h":
                print(Usage.text)
            default:
                FileHandle.standardError.write(Data("unknown command '\(command)'\n\n\(Usage.text)\n".utf8))
                exit(2)
        }
        // The process ends here: the Recall's index takes what was learned, so the next process finds it, and what the
        // commands left in the memory's queue is saved or counted.
        await RecallService.waitAllIdle(within: .seconds(10))
        await MemoryService.closeAll()
        exit(0)
    } catch {
        await RecallService.waitAllIdle(within: .seconds(10))
        await MemoryService.closeAll()
        if let stop = error as? ChatCommand.ScriptStop {
            FileHandle.standardError.write(Data("braus: \(stop.message)\n".utf8))
            exit(stop.exitStatus)
        }
        FileHandle.standardError.write(Data("braus: \(error)\n".utf8))
        exit(1)
    }
}
application.run()
