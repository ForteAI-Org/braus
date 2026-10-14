//
//  RecallIdentity.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import AutomationRuntime
import Foundation
import LocalEmbedding
import Memory

/// RecallIdentity is the Recall a process of this build would run on this Mac, resolved as the app and the chat
/// resolve it (`RecallConfiguration.resolved`, from the environment): the channel, the model and whether its files
/// are where they are looked for, the document format, whether the process would own the archive's index, and what
/// a measure turned off. The same facts `memory_task status` answers from a running process; here from the terminal,
/// before any process runs, for `braus memory --status` and `braus doctor`.
struct RecallIdentity {

    /// The model's files under the models folder, as found.
    enum ModelFiles: Equatable {
        /// The three files are there and the weights have the pinned size.
        case installed(bytes: Int)
        /// The files are there, but the weights are not the pinned size: refused at load.
        case wrongSize(found: Int?, pinned: Int)
        /// Some of the files are not there.
        case missing(count: Int, of: Int)
    }

    let channel: String
    let model: String?
    let format: String
    let ownsIndex: Bool
    let modelsFolder: URL?
    let modelFiles: ModelFiles?
    let ablation: [String]

    static func resolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> RecallIdentity {
        let configuration = RecallConfiguration.resolved(environment: environment)
        let model = configuration.channel == .lexical ? nil : configuration.model
        var folder: URL?
        var files: ModelFiles?
        if let model {
            let base = configuration.modelsDirectory ?? RecallConfiguration.defaultModelsDirectory(environment: environment)
            folder = base
            let directory = base.appendingPathComponent(model.directoryName, isDirectory: true)
            let names = ["config.json", "tokenizer.json", model.weightsFile]
            let present = names.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            if present.count < names.count {
                files = .missing(count: names.count - present.count, of: names.count)
            } else {
                let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(model.weightsFile).path))?[.size]
                    as? Int
                files = size == model.weightsBytes ? .installed(bytes: model.weightsBytes) : .wrongSize(found: size, pinned: model.weightsBytes)
            }
        }
        let active = MeasureAblation.active
        let named: [(MeasureAblation, String)] = [(.recall, "recall"), (.brain, "brain")]
        return RecallIdentity(channel: configuration.channel.rawValue, model: model.map { "\($0.modelID)@\($0.revision)" },
                              format: configuration.format.rawValue, ownsIndex: configuration.ownsIndex, modelsFolder: folder,
                              modelFiles: files, ablation: named.filter { active.contains($0.0) }.map(\.1))
    }

    /// Whether the channel configured can answer as configured: lexical, or a semantic model with its files installed.
    var modelReady: Bool {
        if case .installed? = modelFiles { return true }
        return model == nil
    }

    /// The model's files in one sentence.
    var modelFilesSentence: String {
        switch modelFiles {
            case nil:
                return "no model needed"
            case .installed(let bytes)?:
                return "installed, weights \(bytes) bytes as pinned"
            case .wrongSize(let found, let pinned)?:
                return "installed, but the weights are \(found.map(String.init) ?? "unreadable") bytes, not the \(pinned) pinned: refused at load"
            case .missing(let count, let of)?:
                return "missing (\(count) of \(of) files): the lexical index answers and every answer says the semantic channel is "
                    + "unavailable; install with Tools/Engine/Scripts/fetch-recall-model.sh"
        }
    }

    /// The identity as `braus memory --status` prints it.
    var lines: [String] {
        var lines = ["recall of this build: channel \(channel), model \(model ?? "none"), format \(format), owns the index: \(ownsIndex)"]
        if let modelsFolder {
            lines.append("  models folder: \(modelsFolder.path)")
            lines.append("  model files: \(modelFilesSentence)")
        }
        lines.append("measure ablation (\(MeasureAblation.variable)): " + (ablation.isEmpty ? "none" : ablation.joined(separator: ", ")))
        return lines
    }

    /// The identity as JSON, with the keys `memory_task status` uses for the same facts.
    var json: [String: Any] {
        var object: [String: Any] = ["channel": channel, "format": format, "owns_index": ownsIndex, "measure_ablation": ablation,
                                     "model_files": modelFilesSentence]
        object["model"] = model ?? NSNull()
        object["models_folder"] = modelsFolder?.path ?? NSNull()
        return object
    }
}
