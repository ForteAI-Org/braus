//
//  DoctorCommand.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AppKit
import AutomationRuntime
import Foundation
import PrivateSymbols
import SeatCore
import SQLiteMemory

/// DoctorCommand checks, before a run, every component a live test needs on this Mac, and says of each
/// whether it is ready: the knowledge folder and its archive, the SQLite linked in, the Recall's index and model, what
/// a measure turned off, the permissions of the terminal that launches `braus`, the provider CLIs installed, the Braus
/// app and the MCP bridge registered in the clients, and the disk. It reads and runs nothing of the person's: the
/// archive is read as `braus memory --status` reads it, the provider CLIs are asked their version and their MCP
/// registrations, nothing is opened, migrated, signed in or sent. The exit status is non zero when a check fails.
enum DoctorCommand {

    /// Check is one component with its state and what was found.
    struct Check {
        enum State: String { case ok, warn, fail }
        let name: String
        let state: State
        let detail: String
    }

    /// Failure is the summary of the checks that failed, as the process's exit says it.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ invocation: Invocation) async throws {
        let knowledge = Runtime.knowledgeDirectory(invocation)
        let archive = knowledge.appendingPathComponent("memory.sqlite")
        var checks: [Check] = []
        checks.append(folder(knowledge))
        checks.append(sqlite())
        checks.append(contentsOf: self.archive(archive))
        checks.append(recallIndex(archive))
        checks.append(contentsOf: recallModel())
        checks.append(permissions())
        checks.append(contentsOf: providers())
        checks.append(app())
        checks.append(contentsOf: bridgeRegistrations())
        checks.append(disk(knowledge))
        if invocation.flags.contains("json") {
            let objects = checks.map { ["check": $0.name, "state": $0.state.rawValue, "detail": $0.detail] }
            if let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            for check in checks { print("\(check.state.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0))  \(check.name): \(check.detail)") }
        }
        let failed = checks.filter { $0.state == .fail }
        let warned = checks.filter { $0.state == .warn }
        let summary = "\(checks.count) checks: \(checks.count - failed.count - warned.count) ok, \(warned.count) to look at, \(failed.count) failed"
        if !invocation.flags.contains("json") { print(summary) }
        if !failed.isEmpty { throw Failure(description: summary + ": " + failed.map(\.name).joined(separator: ", ")) }
    }

    // MARK: The checks

    private static func folder(_ knowledge: URL) -> Check {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: knowledge.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return Check(name: "knowledge folder", state: .fail, detail: "\(knowledge.path) is a file, not a folder") }
            return Check(name: "knowledge folder", state: manager.isWritableFile(atPath: knowledge.path) ? .ok : .fail,
                         detail: knowledge.path + (manager.isWritableFile(atPath: knowledge.path) ? ", writable" : ", not writable"))
        }
        return Check(name: "knowledge folder", state: .ok, detail: "\(knowledge.path) does not exist yet; Braus's memory would create it")
    }

    private static func sqlite() -> Check {
        if let unmet = SQLiteLibrary.unmetRequirement() {
            return Check(name: "sqlite", state: .fail, detail: "\(SQLiteLibrary.version) linked, below the memory's requirement \(unmet.minimumVersion)")
        }
        return Check(name: "sqlite", state: .ok, detail: "\(SQLiteLibrary.version) linked into this braus (\(SQLiteLibrary.sourceID))")
    }

    private static func archive(_ url: URL) -> [Check] {
        let report = SQLiteMemoryInspection.inspect(url)
        let known = SQLiteMemoryInspection.supportedVersion
        let version = report.schemaVersion.map { "schema \($0)" } ?? "no schema"
        let size = report.bytes.map { ", \($0) bytes" } ?? ""
        switch report.shape {
            case .missing:
                return [Check(name: "archive", state: .ok, detail: "none at \(url.path); Braus's memory would create it at schema \(known)")]
            case .empty:
                return [Check(name: "archive", state: .warn, detail: "\(url.path) is a database with no schema yet; a reader refuses it, Braus's memory creates its schema in it")]
            case .current:
                let counts = SQLiteMemoryInspection.countedTables.compactMap { table in report.counts[table].map { "\(table) \($0)" } }
                return [Check(name: "archive", state: .ok, detail: "\(url.path), \(version)\(size); " + counts.joined(separator: ", ")
                              + (report.backups.isEmpty ? "" : "; copies: " + report.backups.joined(separator: ", ")))]
            case .migratable(let from):
                return [Check(name: "archive", state: .warn, detail: "\(url.path) is at schema \(from); Braus's next open migrates it to \(known) after a verified copy; a reader refuses it until then")]
            case .refused(let mismatch):
                return [Check(name: "archive", state: .fail, detail: "\(url.path) is refused by this build and left as it is: \(mismatch)")]
            case .unreadable(let why):
                return [Check(name: "archive", state: .fail, detail: "\(url.path) cannot be read as a database: \(why)")]
            case .unavailable(let why):
                return [Check(name: "archive", state: .fail, detail: "\(url.path) was not read: \(why)")]
            case .interruptedRecovery(let why):
                return [Check(name: "archive", state: .fail, detail: "\(url.path): \(why); Braus's memory opens nothing until a recovery completes it")]
        }
    }

    private static func recallIndex(_ url: URL) -> Check {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Check(name: "recall index", state: .ok, detail: "no archive yet, so no index yet; the first learned procedure starts one")
        }
        switch SQLiteMemoryInspection.recallIndex(in: url) {
            case .unavailable(let why):
                return Check(name: "recall index", state: .warn, detail: "not read: \(why)")
            case .found(let report):
                let ready = report.generations.first { $0.status == "ready" }
                let generations = report.generations.map { "\($0.status) \($0.id) (\($0.format), space \($0.spaceID ?? "lexical only"), revision \($0.revision))" }
                if report.generations.isEmpty {
                    return Check(name: "recall index", state: .ok, detail: "no generation yet; the first learned procedure starts one")
                }
                let detail = generations.joined(separator: "; ") + "; entries \(report.entries), vectors still to compute \(report.vectorBacklog), "
                    + "work pending \(report.pendingWork)"
                let state: Check.State = ready == nil || report.vectorBacklog > 0 || report.pendingWork > 0 ? .warn : .ok
                return Check(name: "recall index", state: state, detail: detail + (state == .warn ? "; a running memory finishes it" : ""))
        }
    }

    private static func recallModel() -> [Check] {
        let identity = RecallIdentity.resolved()
        var checks = [Check(name: "recall model", state: identity.modelReady ? .ok : .fail,
                            detail: "channel \(identity.channel), model \(identity.model ?? "none"), format \(identity.format), owns the index: \(identity.ownsIndex)"
                                + (identity.modelsFolder.map { "; models folder \($0.path); files \(identity.modelFilesSentence)" } ?? ""))]
        checks.append(Check(name: "measure ablation", state: identity.ablation.isEmpty ? .ok : .warn,
                            detail: identity.ablation.isEmpty ? "none: the Recall and the Brain are on"
                                : identity.ablation.joined(separator: ", ") + " turned off by \(MeasureAblation.variable): a measure's control, not a test of the product"))
        return checks
    }

    private static func permissions() -> Check {
        let screen = Permissions.preflight(.screenRecording), access = Permissions.preflight(.accessibility), post = Permissions.preflight(.postEvent)
        let words = [("Screen Recording", screen), ("Accessibility", access), ("input events", post)]
        let missing = words.filter { !$0.1 }.map(\.0)
        return Check(name: "permissions", state: missing.isEmpty ? .ok : .fail,
                     detail: missing.isEmpty ? "Screen Recording, Accessibility and input events granted to the application that launched this braus"
                         : "missing for the application that launched this braus: " + missing.joined(separator: ", ")
                           + "; grant them in System Settings › Privacy & Security to that application (the terminal or the app running it)")
    }

    private static func providers() -> [Check] {
        var checks: [Check] = []
        var agents = 0
        for (name, role) in [("claude", "chat provider"), ("codex", "chat provider"), ("gemini", "not a chat provider of braus yet"), ("ollama", "local models; not a chat provider of braus yet")] {
            guard let executable = ChatMenu.executable(name) else {
                checks.append(Check(name: "provider \(name)", state: role.hasPrefix("chat") ? .warn : .ok, detail: "not in PATH (\(role))"))
                continue
            }
            if role.hasPrefix("chat") { agents += 1 }
            let version = Subprocess.run(executable, ["--version"], timeout: 8).map { $0.output.trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "no answer to --version in 8 s"
            checks.append(Check(name: "provider \(name)", state: .ok, detail: "\(executable.path), \(version.split(separator: "\n").first.map(String.init) ?? version) (\(role); sign-in is proven by a turn, not here)"))
        }
        if agents == 0 { checks.append(Check(name: "chat providers", state: .fail, detail: "neither claude nor codex is in PATH: braus chat cannot run a turn")) }
        return checks
    }

    private static func app() -> Check {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.forte.Braus")
        if let app = running.first {
            return Check(name: "braus app", state: .ok, detail: "running, pid \(app.processIdentifier)" + (app.bundleURL.map { ", \($0.path)" } ?? "")
                         + "; an MCP client reaches it through braus-bridge; braus chat does not need it")
        }
        return Check(name: "braus app", state: .ok, detail: "not running; needed only by an MCP client (Claude Code, Codex) through braus-bridge, not by braus chat")
    }

    private static func bridgeRegistrations() -> [Check] {
        var checks: [Check] = []
        if let claude = ChatMenu.executable("claude") {
            if let result = Subprocess.run(claude, ["mcp", "get", "braus"], timeout: 15) {
                let registered = result.status == 0 && result.output.contains("braus-bridge")
                checks.append(Check(name: "mcp bridge in Claude Code", state: registered ? .ok : .warn,
                                    detail: registered ? "registered: " + (result.output.split(separator: "\n").first { $0.contains("braus-bridge") }.map(String.init) ?? "braus-bridge")
                                        : "not registered (claude mcp get braus: " + result.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160) + "); see Documentation/MCPSetup.md"))
            } else {
                checks.append(Check(name: "mcp bridge in Claude Code", state: .warn, detail: "claude mcp get braus gave no answer in 15 s"))
            }
        }
        if let codex = ChatMenu.executable("codex") {
            if let result = Subprocess.run(codex, ["mcp", "list"], timeout: 15) {
                let registered = result.status == 0 && result.output.contains("braus")
                checks.append(Check(name: "mcp bridge in Codex", state: registered ? .ok : .warn,
                                    detail: registered ? "registered" : "not registered (codex mcp list names no braus); see Documentation/MCPSetup.md"))
            } else {
                checks.append(Check(name: "mcp bridge in Codex", state: .warn, detail: "codex mcp list gave no answer in 15 s"))
            }
        }
        return checks
    }

    private static func disk(_ knowledge: URL) -> Check {
        let path = FileManager.default.fileExists(atPath: knowledge.path) ? knowledge.path : NSHomeDirectory()
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? Int64 else {
            return Check(name: "disk", state: .warn, detail: "free space of \(path) not readable")
        }
        let gigabytes = Double(free) / 1_073_741_824
        return Check(name: "disk", state: gigabytes < 10 ? .warn : .ok,
                     detail: String(format: "%.1f GB free on the volume of %@", gigabytes, path) + (gigabytes < 10 ? "; a learned archive and its copies need room" : ""))
    }
}

/// Subprocess runs one executable to its end or a timeout, for the questions the doctor asks the provider CLIs.
enum Subprocess {

    /// The exit status and the output (standard output and error together), or nil when the process did not end
    /// within `timeout` seconds and was terminated.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        nonisolated(unsafe) let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (status: -1, output: "\(error)") }
        nonisolated(unsafe) var timedOut = false
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if timedOut { return nil }
        return (status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
