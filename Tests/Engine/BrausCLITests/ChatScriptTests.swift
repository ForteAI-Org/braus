//
//  ChatScriptTests.swift
//  Braus
//
//  Created by Tommaso Mazzarini on 13/10/2026.
//

import ChatCore
import FileConversations
import Foundation
import LocalMCP
import Testing
@testable import braus

/// The pure parts of `braus chat --script`: the requests a file holds, the tasks a conversation's tool lines name, and
/// the differences a preflight reports. No provider, no process.
@Suite("Chat script: requests, task ids and the preflight's differences")
struct ChatScriptTests {

    @Test("requests are blocks of lines separated by empty lines; comments belong to no block; blank space around a request is dropped")
    func requestsOfAScript() {
        let text = """
        # The first task
        Rotate campione_A.png in Preview by 90 degrees
          and save it as immagine_A.png in Outputs/A.

        # a comment between blocks, then an empty line


        Open the folder Laboratorio in Finder.
        \t
        # trailing comment
        """
        #expect(ChatScript.requests(in: text).map(\.text) == [
            "Rotate campione_A.png in Preview by 90 degrees\n  and save it as immagine_A.png in Outputs/A.",
            "Open the folder Laboratorio in Finder.",
        ])
        #expect(ChatScript.requests(in: text).allSatisfy { !$0.continuesPrevious })
        #expect(ChatScript.requests(in: "").isEmpty && ChatScript.requests(in: "# only comments\n\n#\n").isEmpty)
        #expect(ChatScript.requests(in: "one\r\n\r\ntwo").map(\.text) == ["one", "two"], "CRLF separates lines too")
    }

    @Test("a block starting with > continues the conversation before it, without the >; the first block never continues anything")
    func continuedRequests() {
        let requests = ChatScript.requests(in: "> first, with a stray marker\n\nPrepare the delivery.\n\n>  Also a PDF of it, please,\nin Partial.\n\nAnother task.")
        #expect(requests == [
            ChatScript.Request(text: "first, with a stray marker", continuesPrevious: false),
            ChatScript.Request(text: "Prepare the delivery.", continuesPrevious: false),
            ChatScript.Request(text: "Also a PDF of it, please,\nin Partial.", continuesPrevious: true),
            ChatScript.Request(text: "Another task.", continuesPrevious: false),
        ])
    }

    @Test("the tasks named by the memory's answers, each once, in order; other tool lines and requests are not read")
    func taskIDsOfAConversation() {
        var conversation = Conversation(provider: .claude, model: nil)
        conversation.append(.user, "do it")
        conversation.append(.tool, #"→ memory_task {"operation":"begin","goal":"do it"}"#)
        conversation.append(.tool, #"← memory_task {"status":"begun","task":"T-1","attempt":"A-1"}"#)
        conversation.append(.tool, #"→ act {"session":"S","target":"Save"}"#)
        conversation.append(.tool, #"← act {"status":"found_acted","message":"clicked"}"#)
        conversation.append(.tool, #"← memory_task {"status":"ended","task":"T-1"}"#)
        conversation.append(.tool, #"← memory_task {"status":"begun","task":"T-2"}"#)
        conversation.append(.tool, #"← memory_task not json at all"#)
        conversation.append(.tool, #"← memory_task {"error":"no_task"}"#)
        #expect(ChatScript.taskIDs(in: conversation.entries) == ["T-1", "T-2"])
        #expect(ChatScript.taskIDs(in: []).isEmpty)
    }

    @Test("a preflight compares only the keys it names, nested objects key by key; a missing key is absent; a scalar differs whole")
    func differencesOfAPreflight() throws {
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"archive":"/root/AppSupport/Knowledge/memory.sqlite",
             "recall":{"channel":"hybrid","owns_index":true,"model":"ibm-granite/granite-embedding-107m-multilingual@d6cffd33"},
             "measure_ablation":["recall"]}
            """#.utf8))
        let found = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"status":"no open task","archive":"/root/AppSupport/Knowledge/memory.sqlite",
             "recall":{"channel":"lexical","owns_index":true,"format":"recall-document-1"}}
            """#.utf8))
        let differences = ChatScript.differences(expected: expected, found: found)
        #expect(differences.map(\.path) == ["measure_ablation", "recall.channel", "recall.model"], "\(differences)")
        #expect(differences.first { $0.path == "recall.channel" }?.found == "\"lexical\"")
        #expect(differences.first { $0.path == "recall.model" }?.found == "absent")
        #expect(differences.first { $0.path == "measure_ablation" }?.found == "absent")
        #expect(ChatScript.differences(expected: expected, found: expected).isEmpty, "an answer equal to the expectation differs nowhere")
        #expect(ChatScript.differences(expected: .string("a"), found: .string("b")).map(\.description) == ["value: expected \"a\", found \"b\""])
    }

    @Test("a summary says where a failure came from in fields: the provider with its kind, a signal, or Braus")
    @MainActor
    func failureOfARequest() {
        #expect(ChatEvidence.failure(nil, signal: nil) == nil)
        let stopped = ChatEvidence.failure(nil, signal: 15)
        #expect(stopped?["source"] as? String == "signal" && stopped?["signal"] as? Int == 15)
        let limited = ChatEvidence.failure(ProviderFailure(kind: .rateLimited, message: "API Error: 429", apiStatus: 429,
                                                           exitStatus: 1), signal: nil)
        #expect(limited?["source"] as? String == "provider" && limited?["kind"] as? String == "rate_limited")
        #expect(limited?["retryable"] as? Bool == true && limited?["api_status"] as? Int == 429 && limited?["exit_status"] as? Int == 1)
        let other = ChatEvidence.failure(ChatMenu.problem("transcript not saved"), signal: nil)
        #expect(other?["source"] as? String == "braus" && other?["retryable"] as? Bool == false)
    }

    @Test("the longest run of identical calls names its tool; a call with other arguments breaks the run; answers do not count")
    @MainActor
    func repeatedCalls() {
        var conversation = Conversation(provider: .claude, model: nil)
        conversation.append(.tool, #"→ observe {"session":"S"}"#)
        for _ in 0..<3 {
            conversation.append(.tool, #"→ act {"session":"S","target":"OK"}"#)
            conversation.append(.tool, #"← act {"status":"honest_miss"}"#)
        }
        conversation.append(.tool, #"→ act {"session":"S","target":"Annulla"}"#)
        let repeated = ChatEvidence.longestRepeat(in: conversation.entries)
        #expect(repeated["count"] as? Int == 3 && repeated["tool"] as? String == "act")
        #expect(ChatEvidence.longestRepeat(in: [])["count"] as? Int == 0)
    }

    @Test("a request's tokens add its provider runs (the interpretation reminder is a second one); a session total is a difference")
    @MainActor
    func tokensOfARequest() throws {
        let folder = URL.temporaryDirectory.appending(path: "chat-tokens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try ConversationStore(directory: folder)
        let claude = ChatTranscript(conversation: Conversation(provider: .claude, model: nil), store: store)
        claude.beginRequest()
        try claude.event(.usage(ProviderUsage(tokens: ProviderUsage.Tokens(input: 100, output: 10))))
        try claude.event(.usage(ProviderUsage(tokens: ProviderUsage.Tokens(input: 40, output: 5))))
        #expect(claude.requestTokens == ProviderUsage.Tokens(input: 140, output: 15))
        claude.beginRequest()
        #expect(claude.requestTokens == nil)
        let codex = ChatTranscript(conversation: Conversation(provider: .codex, model: nil), store: store)
        codex.beginRequest()
        try codex.event(.usage(ProviderUsage(tokens: ProviderUsage.Tokens(input: 1_000, output: 100), isSessionTotal: true)))
        codex.beginRequest()
        try codex.event(.usage(ProviderUsage(tokens: ProviderUsage.Tokens(input: 1_500, output: 130), isSessionTotal: true)))
        #expect(codex.requestTokens == ProviderUsage.Tokens(input: 500, output: 30))
    }

    @Test("a script stopped by a provider failure exits 3, by any other failure 1")
    func exitOfAStoppedScript() {
        #expect(ChatCommand.ScriptStop(message: "m", provider: true).exitStatus == 3)
        #expect(ChatCommand.ScriptStop(message: "m", provider: false).exitStatus == 1)
    }

    @Test("a tool's answer is read out of the router's wrapping; a value that is not wrapped is itself")
    func payloadOfAResult() throws {
        let inner = "{\"status\":\"no open task\",\"archive\":\"/k/memory.sqlite\"}"
        let wrapped: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string(inner)])]),
                                          "isError": .bool(false)])
        #expect(ChatScript.payload(of: wrapped)["archive"].string == "/k/memory.sqlite")
        let plain: JSONValue = .object(["status": .string("ok")])
        #expect(ChatScript.payload(of: plain) == plain)
        let notJSON: JSONValue = .object(["content": .array([.object(["type": .string("text"), "text": .string("not json")])])])
        #expect(ChatScript.payload(of: notJSON) == notJSON)
    }
}
