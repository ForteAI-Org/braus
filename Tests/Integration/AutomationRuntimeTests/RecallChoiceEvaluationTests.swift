//
//  RecallChoiceEvaluationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 12/10/2026.
//

@testable import AutomationMCP
@testable import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import SQLiteMemory
import Testing

/// RecallChoiceEvaluationTests measure experiment A against the automatic selector on the development corpus v4, by the
/// protocol fixed before any result (`.scratch/brain-memory-recall/experiment-a/protocol.md`). For each query and condition:
/// the proposal through `memory_task begin` (experiment enabled); a real agent's choice, a fresh ephemeral session of the
/// provider configured on this Mac (the Claude or Codex CLI as Mecum invokes it, tools off), which receives Mecum's instructions, the
/// task as it resolved it, its begin call and the tool's answer, and nothing of the corpus's expectations; the choice through
/// `memory_task choose`, one retry after a refusal; the automatic selector on the same search, as the control. The corpus's
/// expectations judge both (`RecallJudge`); the model never judges. Gated: `MECUM_RECALL_EVAL=choice4` and the models.
///
/// - `MECUM_RECALL_CHOICE_AGENT`: `claude` (default: the Claude CLI as Mecum invokes it), `codex`, or `none` (no model call:
///   the plumbing only, every case an agent failure).
/// - `MECUM_RECALL_CHOICE_MODEL`, `MECUM_RECALL_CHOICE_EFFORT`: default `claude-sonnet-5-5`, `max` for Claude (Haiku takes no
///   effort, as Mecum leaves it out); `gpt-6-astra`, `ultra` for Codex.
/// - `MECUM_RECALL_CHOICE_ONLY`: query ids, comma-separated, for a smoke run.
/// - `MECUM_RECALL_CHOICE_CORPUS`, `MECUM_RECALL_CHOICE_SPLIT`: another corpus by absolute path and its split (default v4,
///   `dev`). Outside v4 a query is judged on the minimal archive too when it names a `bootstrap`.
/// - `MECUM_RECALL_CHOICE_CHECK_ONLY=1`: the corpus check alone (the archives and their unknown entry states), no agent and
///   no query.
/// - `MECUM_RECALL_CHOICE_STOP_ON_DEFECT=1`: a structural defect (a choice not recorded, the memory unavailable, a provider
///   failure) stops the run.
@MainActor
@Suite("Experiment A measured: the agent's choice against the automatic selector", .serialized)
struct RecallChoiceEvaluationTests {
    typealias E = RecallEvaluationTests
    typealias V = RecallEvaluationV2Tests
    typealias P = ProcedureLearningTests

    nonisolated static var mode: String? { E.environment["MECUM_RECALL_EVAL"] }
    nonisolated static var agent: String { E.environment["MECUM_RECALL_CHOICE_AGENT"] ?? "claude" }
    nonisolated static var model: String { E.environment["MECUM_RECALL_CHOICE_MODEL"] ?? (agent == "codex" ? "gpt-6-astra" : "claude-sonnet-5-5") }
    nonisolated static var effort: String { E.environment["MECUM_RECALL_CHOICE_EFFORT"] ?? (agent == "codex" ? "ultra" : "max") }
    static let configurationName = "hybrid0.2/granite-107m/recall-document-1/uniform"

    /// AgentCall is one model call: what was sent, what came back, what it cost, how long it took.
    nonisolated struct AgentCall: Sendable, Codable {
        var promptBytes = 0
        var instructionsBytes = 0
        var text = ""
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0
        var costUSD = 0.0
        var milliseconds = 0.0
        var error: String?
    }

    /// CaseRecord is one query in one condition, both arms.
    nonisolated struct CaseRecord: Sendable, Codable {
        var id = ""
        var condition = ""
        var kind = ""
        var language = ""
        var critical = false
        var positive = false
        var shortlist: [String] = []
        var acceptedShortlisted: Bool?
        var proposalText = ""
        var prompt = ""
        var proposalBytes = 0
        var proposalTokensEstimate = 0
        var proposalMS = 0.0
        var calls: [AgentCall] = []
        var plans: [String] = []
        var refusals: [String] = []
        var admitted = false
        var agentFailure: String?
        /// The provider gave no answer at all (an outage, not a decision of the agent): the case is not scored.
        var providerFailure: String?
        var chooseMS = 0.0
        var deliveredBytes = 0
        var exchanges = 0
        var preparationMS = 0.0
        var answerA = ""
        var verdictA = RecallJudge.Verdict()
        var answerControl = ""
        var verdictControl = RecallJudge.Verdict()
        var controlMS = 0.0
    }

    @Test("experiment A against the automatic selector on corpus v4, by the protocol fixed before the run",
          .enabled(if: mode == "choice4", "MECUM_RECALL_EVAL=choice4 asks for the measure of experiment A"))
    func measure() async throws {
        let models = try #require(E.models, "MECUM_RECALL_MODELS names the pinned models")
        let corpus = try RecallCorpus.load(E.environment["MECUM_RECALL_CHOICE_CORPUS"] ?? "recall-corpus-v4")
        let only = Set((E.environment["MECUM_RECALL_CHOICE_ONLY"] ?? "").split(separator: ",").map(String.init))
        let checkOnly = E.environment["MECUM_RECALL_CHOICE_CHECK_ONLY"] == "1"
        let all = corpus.queries(split: E.environment["MECUM_RECALL_CHOICE_SPLIT"] ?? "dev")
            .filter { only.isEmpty || only.contains($0["id"].string ?? "") }
        // v4 and its development successor v5 judge on minimal archives only their newer families; another corpus (a
        // holdout) every query with a bootstrap.
        let minimal = all.filter { query in
            let id = query["id"].string ?? "", bootstrapped = !(query["bootstrap"].array ?? []).isEmpty
            return ["recall-corpus-v4", "recall-corpus-v5"].contains(corpus.version)
                ? ["f3-", "a-", "a5-"].contains { id.hasPrefix($0) } && (corpus.version == "recall-corpus-v4" || bootstrapped)
                : bootstrapped
        }
        let conditions = try await V.conditions(corpus, queries: all, bootstrapFrom: minimal)
        let configuration = try #require(V.allConfigurations.first { $0.name == Self.configurationName })
        let url = try #require(Bundle.module.url(forResource: "recall-calibration-v3", withExtension: "json"))
        let calibration = try JSONDecoder().decode(V.Calibration.self, from: try Data(contentsOf: url))
        let thresholds = try #require(calibration.thresholds[Self.configurationName])
        var recall = configuration.configuration(models: models)
        recall.hybridThresholds = thresholds
        let output = E.output ?? FileManager.default.temporaryDirectory.appendingPathComponent("recall-choice-eval", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lines = output.appendingPathComponent("choice-cases.jsonl")
        if !FileManager.default.fileExists(atPath: lines.path) { FileManager.default.createFile(atPath: lines.path, contents: nil) }
        let instructions = AgentChoiceExperiment.$enabled.withValue(true) { AutomationTools.instructions }
        // Cases already answered in this folder are kept, not run again: a run stopped by an outage of the provider resumes.
        let done = Set((try String(contentsOf: lines, encoding: .utf8)).split(separator: "\n").compactMap { line -> String? in
            guard let record = try? JSONDecoder().decode(CaseRecord.self, from: Data(line.utf8)), record.providerFailure == nil else { return nil }
            return "\(record.id)|\(record.condition)"
        })
        var records: [CaseRecord] = []
        var unknownEntries: [String: [String]] = [:]
        for condition in conditions {
            let archive = try await E.archive(from: condition.base, learned: condition.learned, corpus: condition.corpus, configuration: recall)
            let service = RecallService.shared(for: archive.memory)
            for version in archive.learned.sorted(by: { $0.key < $1.key }).flatMap({ known in known.value.revisions.map { (known.key, $0) } }) {
                let source = try await archive.memory.perform { try await $0.recall.sources([version.1]) }.first
                let unknown = source?.steps.filter { if case .unknown = $0.entry { true } else { false } }.map { String($0.position + 1) } ?? []
                if !unknown.isEmpty { unknownEntries[condition.name, default: []].append("\(version.0): steps \(unknown.joined(separator: ", "))") }
            }
            for query in condition.queries where !checkOnly {
                let key = "\(query["id"].string ?? "")|\(condition.name.hasPrefix("minimal") ? "minimal" : "full")"
                if done.contains(key) { continue }
                let record = try await Self.run(query, condition: condition.name, archive: archive, service: service, thresholds: thresholds,
                                                instructions: instructions)
                records.append(record)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let handle = try FileHandle(forWritingTo: lines)
                handle.seekToEndOfFile()
                handle.write(try encoder.encode(record) + Data("\n".utf8))
                try handle.close()
                print("RECALL-CHOICE \(condition.name) \(record.id): A \(record.verdictA.correct ? "ok" : "wrong") [\(record.answerA)] | control "
                      + "\(record.verdictControl.correct ? "ok" : "wrong") [\(record.answerControl)]")
                // A structural defect stops the run (protocol v5): it is recorded, never scored, and fixed first.
                if E.environment["MECUM_RECALL_CHOICE_STOP_ON_DEFECT"] == "1",
                   let defect = record.providerFailure ?? record.refusals.first(where: { $0.contains("choice_not_recorded") || $0.contains("memory_unavailable") }) {
                    Issue.record("structural defect, run stopped at \(record.id) (\(condition.name)): \(defect)")
                    return
                }
            }
            await E.close(archive)
        }
        let summary: [String: JSONValue] = [
            "corpus": .string(corpus.version), "corpus_digest": .string(corpus.digest), "configuration": .string(Self.configurationName),
            "agent": .string(checkOnly ? "none (corpus check only)" : Self.agent), "model": .string(Self.model), "effort": .string(Self.effort),
            "cases": .number(Double(records.count)),
            "unknown_entry_states": .object(unknownEntries.mapValues { .array($0.map(JSONValue.string)) }),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(JSONValue.object(summary)).write(to: output.appendingPathComponent("choice-run.json"))
    }

    /// One query in one condition: the proposal, the agent's choice (one retry after a refusal), Engine's answer, and the
    /// control on the same search.
    static func run(_ query: JSONValue, condition: String, archive: E.Archive, service: RecallService, thresholds: SelectionThresholds,
                    instructions: String) async throws -> CaseRecord {
        var record = CaseRecord()
        record.id = query["id"].string ?? ""
        record.condition = condition.hasPrefix("minimal") ? "minimal" : "full"
        record.kind = query["kind"].string ?? ""
        record.language = query["language"].string ?? ""
        record.critical = query["critical"].bool == true
        let expect = query["expect"]
        let accepted = Set(((expect["accept"].array ?? []) + (expect["accept_plans"].array ?? []).flatMap { $0.array ?? [] }
                            + (expect["needs"].array ?? []).flatMap { $0["accept"].array ?? [] }).compactMap { $0["knowledge"].string })
        record.positive = !accepted.isEmpty
        let session = LearningSession(directory: archive.directory)
        let tools = P.tools(session, source: .app, stream: "evaluator-\(record.id)-\(record.condition)")
        guard case .object(var begin) = RecallCorpus.begin(query) else { return record }
        begin["recall_mode"] = .string("propose")
        var clock = ContinuousClock.now
        let answer = try await AgentChoiceExperiment.$enabled.withValue(true) { try await tools.call("memory_task", .object(begin)) }.payload
        record.proposalMS = E.milliseconds(clock.duration(to: .now))
        record.exchanges = 1
        let proposal = answer["recall_proposal"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        record.proposalText = String(decoding: (try? encoder.encode(proposal)) ?? Data(), as: UTF8.self)
        record.proposalBytes = record.proposalText.utf8.count
        record.proposalTokensEstimate = record.proposalBytes / 4
        let byRoute = Dictionary(archive.learned.flatMap { known in known.value.revisions.map { ($0, known.key) } }, uniquingKeysWith: { a, _ in a })
        record.shortlist = (proposal["sources"].array ?? []).map { source in
            "\(source["source"].string ?? "?")=\(byRoute[source["version"].string ?? ""] ?? "?")"
        }
        if record.positive { record.acceptedShortlisted = record.shortlist.contains { accepted.contains(String($0.split(separator: "=").last ?? "")) } }
        let taskID = answer["task"].string ?? "", attemptID = answer["attempt"].string ?? ""
        var outcomesA: [NeedOutcome] = []
        var sourcesA: [String: RecallSource] = [:]
        if let proposalID = proposal["proposal"].string {
            var prompt = Self.prompt(begin: .object(begin), answer: answer)
            record.prompt = prompt
            var admitted: JSONValue?
            var plan: JSONValue?
            for _ in 0..<2 {
                clock = .now
                var call = AgentCall(error: "no agent (plumbing run)")
                if Self.agent != "none" {
                    // An outage of the provider is retried, never scored as the agent's answer.
                    for retry in 0..<3 {
                        call = Self.agent == "codex" ? await Self.invoke(prompt: prompt, instructions: instructions)
                            : await Self.invokeClaude(prompt: prompt, instructions: instructions)
                        guard call.text.isEmpty, call.error != nil else { break }
                        record.calls.append(call)
                        if retry < 2 { try? await Task.sleep(for: .seconds(60)) }
                    }
                }
                record.calls.append(call)
                record.preparationMS += call.milliseconds
                if call.text.isEmpty, let error = call.error, Self.agent != "none" {
                    record.providerFailure = error
                    break
                }
                guard case .object(var arguments)? = Self.object(in: call.text) else {
                    record.agentFailure = call.error ?? "the reply holds no JSON object"
                    break
                }
                if arguments["operation"] == nil { arguments["operation"] = .string("choose") }
                record.plans.append(String(decoding: (try? encoder.encode(JSONValue.object(arguments))) ?? Data(), as: UTF8.self))
                clock = .now
                let result = try await AgentChoiceExperiment.$enabled.withValue(true) { try await tools.call("memory_task", .object(arguments)) }
                record.chooseMS += E.milliseconds(clock.duration(to: .now))
                record.exchanges += 1
                if result["isError"] == .bool(true) {
                    let refusal = String(decoding: (try? encoder.encode(result.payload)) ?? Data(), as: UTF8.self)
                    record.refusals.append(refusal)
                    prompt += "\n\nmemory_task answered:\n\(refusal)\n\nReply with only the JSON arguments of your corrected memory_task choose call."
                    continue
                }
                admitted = result.payload
                plan = .object(arguments)
                break
            }
            if let admitted, let plan {
                record.admitted = true
                record.deliveredBytes = (try? encoder.encode(admitted["recall"]).count) ?? 0
                (outcomesA, sourcesA) = try await Self.outcomes(of: plan, proposalID: proposalID, taskID: taskID, attemptID: attemptID,
                                                                 stream: "evaluator-\(record.id)-\(record.condition)", memory: archive.memory)
            } else if record.agentFailure == nil, !record.refusals.isEmpty {
                record.agentFailure = "refused twice"
            }
        }
        record.preparationMS += record.proposalMS + record.chooseMS
        let request = try RecallCorpus.request(query)
        if outcomesA.isEmpty {
            outcomesA = request.searchedNeeds.enumerated().map {
                NeedOutcome(position: $0.offset, need: $0.element, coverage: .absent, reason: nil, selected: nil, alternatives: [])
            }
        }
        let values = request.values
        record.verdictA = RecallJudge.judge(query, outcomes: outcomesA, sources: sourcesA, values: values, learned: archive.learned).query
        record.answerA = RecallJudge.describe(outcomesA, learned: archive.learned)
        _ = try? await tools.call("memory_task", P.json(#"{"operation":"end","outcome":"abandoned"}"#))
        // The control: the automatic selector on the same search of the same archive.
        clock = .now
        let prepared = try await service.prepare(request)
        let control = service.outcomes(prepared, thresholds: thresholds)
        record.controlMS = E.milliseconds(clock.duration(to: .now))
        let controlSources = Dictionary(uniqueKeysWithValues: prepared.sources.map { ($0.routeID, $0) })
        record.verdictControl = RecallJudge.judge(query, outcomes: control, sources: controlSources, values: values, learned: archive.learned).query
        record.answerControl = RecallJudge.describe(control, learned: archive.learned)
        return record
    }

    /// The outcomes Engine admitted for the plan, read through the same validation the tool ran, for the judge.
    static func outcomes(of plan: JSONValue, proposalID: String, taskID: String, attemptID: String, stream: String,
                         memory: MemoryService) async throws -> ([NeedOutcome], [String: RecallSource]) {
        let request = try AgentChoiceExperiment.$enabled.withValue(true) {
            try MemoryTaskTool.decode(plan, minimization: ValueMinimization(), messageRef: nil)
        }
        guard case .choose(let decoded) = request,
              let recorded = try await memory.perform({ try await $0.recall.proposal(proposalID) }) else { return ([], [:]) }
        let producer = try TaskProducer(source: .app, streamID: stream)
        let revision = try await memory.perform { try await $0.tasks.revision(recorded.proposal.revision, of: taskID, for: producer) }
        let routes = Array(Set(recorded.proposal.shortlisted.map(\.routeID)))
        let sources = Dictionary(uniqueKeysWithValues: try await memory.perform { try await $0.recall.sources(routes) }.map { ($0.routeID, $0) })
        let context = RecallSelector.Context(values: revision?.content.inputs ?? [], constraints: revision?.content.constraints ?? [],
                                             needs: recorded.proposal.needs)
        let normalized = RecallChoice.Plan(proposalID: decoded.proposalID, needs: decoded.needs.sorted { $0.position < $1.position })
        switch RecallChoice.validate(normalized, against: recorded.proposal, sources: sources, superseded: [], producer: producer,
                                     attemptID: attemptID, revision: recorded.proposal.revision, context: context,
                                     nowMS: recorded.proposal.recordedAtMS) {
            case .success(let chosen): return (chosen.map(\.outcome), sources)
            case .failure: return ([], sources)
        }
    }

    /// What the agent receives: the task as it resolved it, its begin call, the tool's answer, and the arguments of choose.
    nonisolated static func prompt(begin: JSONValue, answer: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let call = String(decoding: (try? encoder.encode(begin)) ?? Data(), as: UTF8.self)
        let tool = String(decoding: (try? encoder.encode(answer)) ?? Data(), as: UTF8.self)
        return """
            You are preparing a task for the person on their Mac, before any app action. From the conversation you resolved the \
            task as: \(begin["remaining"].string ?? begin["goal"].string ?? "")

            You called memory_task with:
            \(call)

            memory_task answered:
            \(tool)

            Your next call is memory_task with operation "choose". Its arguments: {"operation":"choose","proposal":"<the proposal's \
            id>","plan":[{"need":<need number from 1>,"tracts":[{"source":"<s1, s2, …>","from":<first step>,"to":<last step>}],\
            "covered":"all"|"part"|"none"|"ambiguous","uncovered":"<what remains, in your words, when covered is part or none; the \
            question for the person when ambiguous>","alternatives":[<the options as tracts, only when covered is ambiguous>],\
            "settled_by":"<the person's own words in the request that settle a fixed choice, only when they do>"}]}. Answer every \
            need. Reply with only that JSON object, nothing else.
            """
    }

    /// The first JSON object in a reply, fences and prose around it ignored.
    nonisolated static func object(in text: String) -> JSONValue? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text[start...end].utf8)), value.object != nil else { return nil }
        return value
    }

    /// One fresh Claude CLI session as Mecum invokes it (`--append-system-prompt` with Mecum's instructions, the model and
    /// effort), without the MCP server, with every tool off, no settings or session kept.
    nonisolated static func invokeClaude(prompt: String, instructions: String) async -> AgentCall {
        await Task.detached { () -> AgentCall in
            var call = AgentCall()
            call.promptBytes = prompt.utf8.count
            call.instructionsBytes = instructions.utf8.count
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recall-choice-agent-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let input = folder.appendingPathComponent("prompt.txt"), output = folder.appendingPathComponent("out.json"),
                    errors = folder.appendingPathComponent("err.txt")
                try Data(prompt.utf8).write(to: input)
                FileManager.default.createFile(atPath: output.path, contents: nil)
                FileManager.default.createFile(atPath: errors.path, contents: nil)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.currentDirectoryURL = folder
                process.arguments = ["claude", "-p", "--output-format", "json", "--tools", "", "--setting-sources", "",
                                     "--no-session-persistence", "--disable-slash-commands", "--no-chrome", "--permission-mode", "dontAsk",
                                     "--append-system-prompt", instructions, "--model", RecallChoiceEvaluationTests.model]
                    // Haiku has no effort levels: Mecum leaves the flag out for it.
                    + (RecallChoiceEvaluationTests.model.contains("haiku") ? [] : ["--effort", RecallChoiceEvaluationTests.effort])
                let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
                process.environment = ["HOME": home, "USER": ProcessInfo.processInfo.environment["USER"] ?? "",
                                       "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                       "TMPDIR": FileManager.default.temporaryDirectory.path]
                process.standardInput = try FileHandle(forReadingFrom: input)
                process.standardOutput = try FileHandle(forWritingTo: output)
                process.standardError = try FileHandle(forWritingTo: errors)
                let started = ContinuousClock.now
                try process.run()
                let deadline = ContinuousClock.now + .seconds(600)
                while process.isRunning {
                    if ContinuousClock.now > deadline { process.terminate(); call.error = "timed out after 600 s"; break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                call.milliseconds = RecallEvaluationTests.milliseconds(started.duration(to: .now))
                let text = try String(contentsOf: output, encoding: .utf8)
                if let result = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
                    func count(_ value: JSONValue) -> Int { if case .number(let number) = value { Int(number) } else { 0 } }
                    let usage = result["usage"]
                    call.cachedInputTokens = count(usage["cache_read_input_tokens"])
                    call.inputTokens = count(usage["input_tokens"]) + count(usage["cache_creation_input_tokens"]) + call.cachedInputTokens
                    call.outputTokens = count(usage["output_tokens"])
                    call.reasoningTokens = count(usage["output_tokens_details"]["thinking_tokens"])
                    if case .number(let cost) = result["total_cost_usd"] { call.costUSD = cost }
                    if result["is_error"] == .bool(true) {
                        call.error = "claude: " + (result["result"].string ?? "error").prefix(300)
                    } else {
                        call.text = result["result"].string ?? ""
                    }
                } else if call.error == nil {
                    call.error = "claude exited \(process.terminationStatus): " + (try String(contentsOf: errors, encoding: .utf8)).prefix(300)
                }
            } catch {
                call.error = "\(error)"
            }
            return call
        }.value
    }

    /// One fresh, ephemeral Codex session as Mecum invokes it, without the MCP server and with every tool off.
    nonisolated static func invoke(prompt: String, instructions: String) async -> AgentCall {
        await Task.detached { () -> AgentCall in
            var call = AgentCall()
            call.promptBytes = prompt.utf8.count
            call.instructionsBytes = instructions.utf8.count
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("recall-choice-agent-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let input = folder.appendingPathComponent("prompt.txt"), output = folder.appendingPathComponent("out.jsonl"),
                    errors = folder.appendingPathComponent("err.txt")
                try Data(prompt.utf8).write(to: input)
                FileManager.default.createFile(atPath: output.path, contents: nil)
                FileManager.default.createFile(atPath: errors.path, contents: nil)
                let quote = { (text: String) -> String in
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.withoutEscapingSlashes]
                    return String(decoding: (try? encoder.encode(text)) ?? Data(), as: UTF8.self)
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["codex", "exec", "--ephemeral", "--ignore-user-config", "--strict-config", "--json", "--skip-git-repo-check",
                                     "-C", folder.path, "-s", "read-only", "-c", "approval_policy=\"never\"",
                                     "-c", "features.shell_tool=false", "-c", "features.unified_exec=false", "-c", "features.apps=false",
                                     "-c", "features.plugins=false", "-c", "features.computer_use=false", "-c", "features.browser_use=false",
                                     "-c", "features.view_image=false", "-c", "features.image_generation=false", "-c", "web_search=\"disabled\"",
                                     "-c", "developer_instructions=\(quote(instructions))", "--model", RecallChoiceEvaluationTests.model,
                                     "-c", "model_reasoning_effort=\(quote(RecallChoiceEvaluationTests.effort))", "-"]
                let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
                process.environment = ["HOME": home, "USER": ProcessInfo.processInfo.environment["USER"] ?? "",
                                       "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8",
                                       "TMPDIR": FileManager.default.temporaryDirectory.path]
                process.standardInput = try FileHandle(forReadingFrom: input)
                process.standardOutput = try FileHandle(forWritingTo: output)
                process.standardError = try FileHandle(forWritingTo: errors)
                let started = ContinuousClock.now
                try process.run()
                let deadline = ContinuousClock.now + .seconds(600)
                // Polled, never waitUntilExit: that waits on a run loop this detached task does not have, and can hang after the
                // process has ended. A provider that has given up reconnecting ends the call.
                while process.isRunning {
                    if ContinuousClock.now > deadline { process.terminate(); call.error = "timed out after 600 s"; break }
                    if let text = try? String(contentsOf: output, encoding: .utf8), text.contains("Reconnecting... 5/5") {
                        process.terminate(); call.error = "the provider could not be reached (reconnecting 5/5)"; break
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                call.milliseconds = RecallEvaluationTests.milliseconds(started.duration(to: .now))
                for line in (try String(contentsOf: output, encoding: .utf8)).split(separator: "\n") {
                    guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
                    if event["type"].string == "item.completed", event["item"]["type"].string == "agent_message" {
                        call.text = event["item"]["text"].string ?? ""
                    }
                    if event["type"].string == "turn.completed" {
                        let usage = event["usage"]
                        func count(_ key: String) -> Int { if case .number(let value) = usage[key] { Int(value) } else { 0 } }
                        call.inputTokens = count("input_tokens")
                        call.cachedInputTokens = count("cached_input_tokens")
                        call.outputTokens = count("output_tokens")
                        call.reasoningTokens = count("reasoning_output_tokens")
                    }
                    if event["type"].string == "turn.failed" || event["type"].string == "error" {
                        call.error = String(describing: event).prefix(400).description
                    }
                }
                if process.terminationStatus != 0, call.error == nil {
                    call.error = "codex exited \(process.terminationStatus): " + (try String(contentsOf: errors, encoding: .utf8)).prefix(400)
                }
            } catch {
                call.error = "\(error)"
            }
            return call
        }.value
    }
}
