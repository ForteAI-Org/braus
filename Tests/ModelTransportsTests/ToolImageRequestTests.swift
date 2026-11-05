//
//  ToolImageRequestTests.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ModelTransports

@Suite("Tool pictures in provider request bodies")
struct ToolImageRequestTests {

    private let call = ToolCall(
        id       : "picture_1",
        name     : "picture",
        arguments: Data("{}".utf8)
    )

    @Test(arguments: ["image/png", "image/jpeg", "image/webp", "image/gif"])
    func anthropicPicturesAreInsideTheirToolResult(mediaType: String) throws {
        let image = try #require(TurnImage(
            data     : Data([1, 2, 3]),
            mediaType: mediaType
        ))
        let body = try AnthropicClient(
            model : "claude-sonnet-4-5",
            effort: .high,
            apiKey: "test"
        ).requestBody(
            messages: messages(images: [image, image]),
            tools   : []
        )
        let turns = try #require(try serialized(body)["messages"] as? [[String: Any]])
        let result = try #require((turns.last?["content"] as? [[String: Any]])?.first)
        let blocks = try #require(result["content"] as? [[String: Any]])
        #expect(turns.last?["role"] as? String == "user")
        #expect(result["tool_use_id"] as? String == call.id)
        #expect(result["is_error"] as? Bool == true)
        #expect(blocks.count == 3)
        #expect(blocks[0]["text"] as? String == "Before and after")
        for block in blocks.dropFirst() {
            let source = try #require(block["source"] as? [String: Any])
            #expect(block["type"] as? String == "image")
            #expect(source["type"] as? String == "base64")
            #expect(source["media_type"] as? String == mediaType)
            #expect(source["data"] as? String == image.data.base64EncodedString())
        }
    }

    @Test(arguments: ["gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-2.5-flash"])
    func geminiPicturesJoinTheFunctionResponseTurn(model: String) throws {
        let small = try png(
            width : 384,
            height: 192
        )
        let large = try png(
            width : 769,
            height: 20
        )
        let body = try GeminiClient(
            model : model,
            effort: .high,
            apiKey: "test"
        ).requestBody(
            messages: messages(images: [small, large]),
            tools   : []
        )
        let turns = try #require(try serialized(body)["contents"] as? [[String: Any]])
        let parts = try #require(turns.last?["parts"] as? [[String: Any]])
        let response = try #require(parts[0]["functionResponse"] as? [String: Any])
        #expect(turns.last?["role"] as? String == "user")
        #expect(response["name"] as? String == call.name)
        #expect(response["id"] as? String == call.id)
        #expect((response["response"] as? [String: Any])?["error"] as? String == "Before and after")
        #expect(parts.count == 3)
        for (part, image) in zip(
            parts.dropFirst(),
            [small, large]
        ) {
            let inline = try #require(part["inlineData"] as? [String: Any])
            #expect(inline["mimeType"] as? String == image.mediaType)
            #expect(inline["data"] as? String == image.data.base64EncodedString())
            #expect(part["inline_data"] == nil)
        }
        if model.hasPrefix("gemini-2.") {
            #expect(parts[1]["mediaResolution"] == nil)
        } else {
            let resolution = try #require(parts[1]["mediaResolution"] as? [String: Any])
            #expect(resolution["level"] as? String == "MEDIA_RESOLUTION_LOW")
        }
        #expect(parts[2]["mediaResolution"] == nil)
    }

    @Test(arguments: ["image/png", "image/jpeg", "image/webp", "image/gif"])
    func geminiKeepsEachPicturesMediaType(mediaType: String) throws {
        let image = try #require(TurnImage(
            data     : Data([1, 2, 3]),
            mediaType: mediaType
        ))
        let body = try GeminiClient(
            model : "gemini-2.5-flash",
            effort: .low,
            apiKey: "test"
        ).requestBody(
            messages: messages(images: [image]),
            tools   : []
        )
        let turns = try #require(try serialized(body)["contents"] as? [[String: Any]])
        let parts = try #require(turns.last?["parts"] as? [[String: Any]])
        let inline = try #require(parts[1]["inlineData"] as? [String: Any])
        #expect(inline["mimeType"] as? String == mediaType)
        #expect(inline["data"] as? String == "AQID")
    }

    @Test(arguments: ["image/png", "image/jpeg", "image/webp", "image/gif"])
    func ollamaPicturesAreBase64OnTheToolMessage(mediaType: String) throws {
        let image = try #require(TurnImage(
            data     : Data([1, 2, 3]),
            mediaType: mediaType
        ))
        let body = try OllamaClient(
            model   : "vision-model",
            effort  : .low,
            settings: ProviderSettings()
        ).requestBody(
            messages: messages(images: [image, image]),
            tools   : [],
            stream  : true,
            show    : ["capabilities": ["tools", "vision"]]
        )
        let turns = try #require(try serialized(body)["messages"] as? [[String: Any]])
        let result = try #require(turns.last)
        #expect(result["role"] as? String == "tool")
        #expect(result["tool_name"] as? String == call.name)
        #expect(result["content"] as? String == "Before and after")
        #expect(result["images"] as? [String] == ["AQID", "AQID"])
    }

    @Test func modelsWithoutVisionReceiveTextAndOneOmissionLine() throws {
        let image = try png(
            width : 1,
            height: 1
        )
        let history = messages(images: [image, image])
        let ollama = try OllamaClient(
            model   : "text-model",
            effort  : .low,
            settings: ProviderSettings()
        ).requestBody(
            messages: history,
            tools   : [],
            stream  : true,
            show    : ["capabilities": ["tools"]]
        )
        let gemini = try GeminiClient(
            model : "gemini-2.5-flash-preview-tts",
            effort: .low,
            apiKey: "test"
        ).requestBody(
            messages: history,
            tools   : []
        )
        for body in [ollama, gemini] {
            let encoded = String(
                decoding: try JSONSerialization.data(withJSONObject: body),
                as      : UTF8.self
            )
            #expect(encoded.contains("Before and after"))
            #expect(encoded.components(separatedBy: "picture omitted: this model does not read images").count == 2)
            #expect(!encoded.contains(image.data.base64EncodedString()))
            #expect(!encoded.contains("inlineData"))
            #expect(!encoded.contains("\"images\""))
        }
    }

    @Test func laterHistoryReplacesEveryPictureAndPreservesTheCallAndFailure() throws {
        let image = try png(
            width : 1,
            height: 1
        )
        let result = try #require(messages(images: [image, image]).last)
        let later = result.forHistory
        #expect(later.images.isEmpty)
        #expect(later.text == "Before and after\n"
            + "[picture omitted from earlier turn]\n[picture omitted from earlier turn]")
        #expect(later.call == call)
        #expect(later.isError)
        #expect(later.forHistory == later)
        #expect(result.images.count == 2)
        for body in [
            try AnthropicClient(
                model : "claude-sonnet-4-5",
                effort: .high,
                apiKey: "test"
            ).requestBody(
                messages: [later],
                tools   : []
            ),
            try GeminiClient(
                model : "gemini-3-flash-preview",
                effort: .high,
                apiKey: "test"
            ).requestBody(
                messages: [later],
                tools   : []
            ),
            try OllamaClient(
                model   : "vision-model",
                effort  : .low,
                settings: ProviderSettings()
            ).requestBody(
                messages: [later],
                tools   : [],
                stream  : true,
                show    : ["capabilities": ["vision"]]
            )
        ] {
            let encoded = String(
                decoding: try JSONSerialization.data(withJSONObject: body),
                as      : UTF8.self
            )
            #expect(encoded.contains("[picture omitted from earlier turn]"))
            #expect(!encoded.contains(image.data.base64EncodedString()))
        }
    }

    @Test func unsupportedAndEmptyPicturesAreRefused() {
        #expect(TurnImage(
            data     : Data([1]),
            mediaType: "application/pdf"
        ) == nil)
        #expect(TurnImage(
            data     : Data(),
            mediaType: "image/png"
        ) == nil)
    }

    @Test(arguments: ["gemini-2.5-flash", "gemini-3-pro-preview", "gemini-3.1-pro-preview", "unknown-model"])
    func geminiClaimsVisionOnlyForKnownMultimodalFamilies(model: String) async throws {
        let capabilities = try await GeminiClient(
            model : model,
            effort: .low,
            apiKey: "test"
        ).capabilities()
        #expect(capabilities.supportsVision == model.hasPrefix("gemini-"))
    }

    private func messages(images: [TurnImage]) -> [TurnMessage] {
        [
            TurnMessage(
                role: .user,
                text: "Read the picture"
            ),
            TurnMessage(
                role     : .assistant,
                text     : "",
                toolCalls: [call]
            ),
            TurnMessage(
                result : "Before and after",
                of     : call,
                isError: true,
                images : images
            )
        ]
    }

    /// Round-trips the body through JSON, as the HTTP boundary does, before inspecting its fields.
    private func serialized(_ body: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func png(
        width : Int,
        height: Int
    ) throws -> TurnImage {
        let context = try #require(CGContext(
            data            : nil,
            width           : width,
            height          : height,
            bitsPerComponent: 8,
            bytesPerRow     : width * 4,
            space           : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo      : CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            bitmap,
            nil
        )
        #expect(CGImageDestinationFinalize(destination))
        return try #require(TurnImage(
            data     : data as Data,
            mediaType: "image/png"
        ))
    }
}
