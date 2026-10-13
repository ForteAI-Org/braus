//
//  ProviderCatalog+Catalogue.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import Foundation

extension ProviderCatalog {

    // MARK: Catalogue

    /// Every model the provider offers this account or server, with the efforts each accepts.
    ///
    /// Codex answers from `codex debug models`, its own catalogue, which also
    /// names each model's levels; a hidden model is left out. Claude Code
    /// answers the `initialize` request of its stream-json mode with the models
    /// the installed version and the account take, before any turn starts. The
    /// API providers are read page by page to the end. Ollama lists what the
    /// local server has pulled.
    public static func catalogue(
        _ provider: ModelProvider,
        settings  : ProviderSettings
    ) async throws -> [ModelInfo] {
        switch provider {
            
            case .codex:
                let result = try await CodexCLIClient.run(
                    executable: CodexCLIClient.executableURL(),
                    arguments : ["debug", "models"],
                    input     : Data(),
                    schema    : nil,
                    timeout   : 20
                )
                guard result.status == 0 else {
                    throw CodexClientError.failed("codex debug models exited \(result.status)")
                }
                return try codexCatalogue(from: result.output)
            
            case .claudeCode:
                let request = #"{"type":"control_request","request_id":"models","request":{"subtype":"initialize"}}"#
                let result  = try await CodexCLIClient.run(
                    executable: ClaudeCLIClient.executableURL(),
                    arguments : [
                        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                        "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
                    ],
                    input     : Data((request + "\n").utf8),
                    schema    : nil,
                    timeout   : 20
                )
                return try claudeCatalogue(from: result.output)
            case .anthropic:
                return try await anthropicCatalogue(apiKey: settings.anthropicAPIKey)
            case .gemini:
                return try await geminiCatalogue(apiKey: settings.geminiAPIKey)
            case .ollama:
                return try await OllamaClient.models(host: settings.ollamaHost).map { .known($0, provider: provider) }
        }
    }

    /// The listed models of `codex debug models`, in the catalogue's own order of priority.
    /// A level this app does not know is left out rather than guessed at.
    static func codexCatalogue(from data: Data) throws -> [ModelInfo] {
        guard let json   = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { throw CodexClientError.failed("codex debug models printed no catalogue") }

        return models
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model -> ModelInfo? in
                guard let slug = model["slug"] as? String else { return nil }
                let levels = model["supported_reasoning_levels"] as? [[String: Any]] ?? []
                return ModelInfo(
                    id           : slug,
                    title        : model["display_name"] as? String,
                    efforts      : levels.compactMap { ($0["effort"] as? String).flatMap(ReasoningEffort.init(rawValue:)) },
                    defaultEffort: (model["default_reasoning_level"] as? String).flatMap(ReasoningEffort.init(rawValue:))
                )
            }
    }

    /// A Claude model id without the snapshot date some listings append, "claude-haiku-4-5-20251001"
    /// read as "claude-haiku-4-5", and without the "[1m]" tag of the 1M-token window: the alias the
    /// command line and the API both take, and the id a worker keeps, so one model is never listed
    /// twice or missed under its other name. A model with a native 1M window runs it whatever the
    /// tag; for the others the tag is dropped and the standard window is used.
    static func claudeID(_ id: String) -> String {
        id.replacing(/\[1[mM]\]$/, with: "").replacing(/-\d{8}$/, with: "")
    }

    /// The models of Claude Code's answer to `initialize`, in its own order, each once by the id it
    /// resolves to. The `default` row names the model the account starts on: that model comes first,
    /// so the first of the catalogue is the one the command line itself would use.
    static func claudeCatalogue(from data: Data) throws -> [ModelInfo] {
        let lines  = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let answer = lines.lazy
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .first { $0["type"] as? String == "control_response" }
        guard let response = answer?["response"] as? [String: Any],
              let models   = (response["response"] as? [String: Any])?["models"] as? [[String: Any]]
        else { throw ClaudeClientError.failed("claude listed no models") }

        var seen    = Set<String>()
        var listed  = [ModelInfo]()
        var started : ModelInfo?
        for model in models {
            let isDefault = model["value"] as? String == "default"
            let named = model["resolvedModel"] as? String ?? (isDefault ? nil : model["value"] as? String)
            guard let id = named.map(claudeID) else { continue }
            let levels = model["supportedEffortLevels"] as? [String] ?? []
            let info   = ModelInfo(
                id     : id,
                title  : isDefault ? nil : model["displayName"] as? String,
                efforts: levels.compactMap(ReasoningEffort.init(rawValue:))
            )
            if isDefault {
                started = info
            } else if seen.insert(id).inserted {
                listed.append(info)
            }
        }
        // The default row is named "Default (recommended)", so the model keeps the name of its own row.
        if let started {
            var first = started
            if let index = listed.firstIndex(where: { $0.id == started.id }) {
                first = listed.remove(at: index)
            }
            listed.insert(first, at: 0)
        }
        return listed
    }

    /// What a provider's catalogue is once `listing`, the result of asking it, is known: the live
    /// list when it came, else the catalogue kept from an earlier listing, else the provider's fixed
    /// `defaultModels`. A command line that is not installed and a key that is missing are not a
    /// listing that failed: that error is thrown for the connection's own state to explain, and so is
    /// the failure of a provider with nothing kept and nothing fixed (Ollama).
    public static func resolvedCatalogue(
        _ listing   : Result<[ModelInfo], any Error>,
        for provider: ModelProvider,
        kept        : [ModelInfo]?
    ) throws -> [ModelInfo] {
        
        switch listing {
            case .success(let live): return live
        
            case .failure(let error):
                switch error {
                    case ClaudeClientError.unavailable,
                         CodexClientError .unavailable,
                         ProviderError    .missingAPIKey: throw error
                        
                    default: break
                }
                if let kept, !kept.isEmpty { return kept }
                
                let fixed = provider.defaultModels.map {
                    ModelInfo.known($0, provider: provider)
                }
                
                if fixed.isEmpty { throw error }
                return fixed
        }
    }

    /// Every page of `/v1/models`, newest first as the API returns them, each model once by `claudeID`.
    private static func anthropicCatalogue(apiKey: String) async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.anthropic) }

        var models: [ModelInfo] = []
        var seen  = Set<String>()
        var after : String?
        repeat {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let json = try await HTTPTransport.getJSON(request)
            let page = json["data"] as? [[String: Any]] ?? []
            models += page.compactMap { entry -> ModelInfo? in
                guard let id = (entry["id"] as? String).map(claudeID), seen.insert(id).inserted else { return nil }
                return .known(
                    id,
                    provider     : .anthropic,
                    title        : entry["display_name"] as? String,
                    contextWindow: entry["max_input_tokens"] as? Int
                )
            }
            after = json["has_more"] as? Bool == true ? json["last_id"] as? String : nil
        } while after != nil
        return models
    }

    /// Every page of the Generative Language API's models that can generate content.
    private static func geminiCatalogue(apiKey: String) async throws -> [ModelInfo] {
        guard !apiKey.isEmpty else { throw ProviderError.missingAPIKey(.gemini) }

        var models: [ModelInfo] = []
        var token : String?
        repeat {
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
                + (token.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            var request = URLRequest(url: components.url!, timeoutInterval: 15)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let json = try await HTTPTransport.getJSON(request)
            let page = json["models"] as? [[String: Any]] ?? []
            models += page.compactMap { entry -> ModelInfo? in
                guard let methods = entry["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                      let name = entry["name"] as? String
                else { return nil }
                let id = name.hasPrefix("models/") ? String(name.dropFirst(7)) : name
                return .known(
                    id,
                    provider     : .gemini,
                    title        : entry["displayName"] as? String,
                    contextWindow: entry["inputTokenLimit"] as? Int
                )
            }
            token = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while token != nil
        return models
    }
}
