//
//  ScriptedWorkerRun.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import AutomationRuntime
import CoreGraphics
import Foundation
import ImageIO
import LocalMCP
import ModelTransports

/// ScriptedWorkerRun owns one turn's transport and append-only result audit. Only a valid isolated
/// launch with BRAUS_SCRIPTED_WORKER set can construct one. Invalid scripts fail before any provider
/// is selected. Logs contain real tool results, so they stay in the disposable support directory.
@MainActor
final class ScriptedWorkerRun {

    struct Report: Codable {
        var completed             = false
        var roundsPlayed          = 0
        var errors: [String]       = []
        var launchToFirstToolMs: Double?
    }

    private static var launchedAt = ContinuousClock.now

    let transport: ScriptedWorkerTransport
    private let log: URL
    private var imageCount = 0
    private(set) var report = Report()

    /// Records entry time and explicitly reports overrides that cannot activate in this process.
    static func noteLaunch() {
        launchedAt = .now
        if case .isolated = LaunchIsolation.current { return }
        let environment = ProcessInfo.processInfo.environment
        for variable in ["BRAUS_SCRIPTED_WORKER", "BRAUS_SCRIPTED_CHECK"] where environment[variable] != nil {
            FileHandle.standardError.write(Data("\(variable) ignored: this is not a valid isolated run.\n".utf8))
        }
    }

    static func scriptURL(
        isolation  : LaunchIsolation,
        environment: [String: String]
    ) throws -> URL? {
        guard case .isolated = isolation else { return nil }
        guard let path = environment["BRAUS_SCRIPTED_WORKER"] else { return nil }
        guard path.hasPrefix("/") else {
            throw AutomationFailure("BRAUS_SCRIPTED_WORKER must name an absolute JSON script path.")
        }
        return URL(fileURLWithPath: path)
    }

    static func openIfRequested() throws -> ScriptedWorkerRun? {
        guard let url = try scriptURL(
            isolation  : .current,
            environment: ProcessInfo.processInfo.environment
        ), case .isolated(let support) = LaunchIsolation.current else { return nil }
        return try ScriptedWorkerRun(
            script : ScriptedWorkerScript(data: Data(contentsOf: url)),
            support: support
        )
    }

    init(
        script : ScriptedWorkerScript,
        support: URL
    ) throws {
        transport = ScriptedWorkerTransport(script: script)
        log       = support.appending(path: "scripted-tools.jsonl")
        try FileManager.default.createDirectory(
            at                         : support,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: log.path) {
            try Data().write(
                to     : log,
                options: .withoutOverwriting
            )
        }
    }

    /// Appends one result after the real tool returns. Audit failures fail the turn as well.
    func record(
        call     : ToolCall,
        result   : JSONValue,
        startedAt: ContinuousClock.Instant
    ) throws {
        let elapsed = Self.milliseconds(startedAt.duration(to: .now))
        let text    = (result["content"].array ?? []).compactMap { $0["text"].string }.joined(separator: "\n")
        let isError = result["isError"].bool == true
        if isError { report.errors.append("\(call.name): \(text)") }
        if report.launchToFirstToolMs == nil {
            report.launchToFirstToolMs = Self.milliseconds(Self.launchedAt.duration(to: startedAt))
        }
        var images: [JSONValue] = []
        for block in result["content"].array ?? [] where !isError && block["mimeType"] == .string("image/png") {
            guard block["type"] == .string("image"), let encoded = block["data"].string,
                  let data = Data(base64Encoded: encoded),
                  let source = CGImageSourceCreateWithData(
                      data as CFData,
                      nil
                  ),
                  let image = CGImageSourceCreateImageAtIndex(
                      source,
                      0,
                      nil
                  ) else {
                throw AutomationFailure("The scripted PNG result could not be decoded for its audit.")
            }
            imageCount += 1
            let file = "image-\(imageCount).png"
            try data.write(to: log.deletingLastPathComponent().appending(path: file))
            images.append(.object([
                "file": .string(file),
                "width": .number(Double(image.width)),
                "height": .number(Double(image.height)),
                "bytes": .number(Double(data.count))
            ]))
        }
        let entry: JSONValue = .object([
            "round"       : .number(Double(transport.roundsPlayed)),
            "tool"        : .string(call.name),
            "arguments"   : try JSONDecoder().decode(
                JSONValue.self,
                from: call.arguments
            ),
            "result"      : .string(text),
            "error"       : isError ? .string(text) : .null,
            "hasImage"    : .bool((result["content"].array ?? []).contains { $0["type"].string == "image" }),
            "images"      : .array(images),
            "durationMs"  : .number(elapsed),
            "sinceLaunchMs": .number(Self.milliseconds(Self.launchedAt.duration(to: startedAt))),
        ])
        var data = try JSONEncoder().encode(entry)
        data.append(0x0a)
        let handle = try FileHandle(forWritingTo: log)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    func finish(error: (any Error)? = nil) {
        report.roundsPlayed = transport.roundsPlayed
        report.completed    = error == nil && transport.isFinished
        if let error { report.errors.append(String(describing: error)) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
