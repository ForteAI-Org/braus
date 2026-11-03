//
//  TurnImage.swift
//  Braus
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/11/2026.
//

import Foundation
import ImageIO

/// TurnImage carries one tool result's encoded picture without retaining the MCP envelope.
/// It is deliberately not Codable: conversation storage keeps text placeholders, never pixels.
public struct TurnImage: Sendable, Hashable {

    public let data     : Data
    public let mediaType: String

    /// Accepts nonempty bytes labeled PNG, JPEG, WebP or GIF. The caller decodes MCP's base64 first;
    /// an unsupported media type or empty payload returns nil instead of reaching a provider.
    public init?(
        data     : Data,
        mediaType: String
    ) {
        guard !data.isEmpty,
              ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mediaType) else { return nil }
        self.data      = data
        self.mediaType = mediaType
    }

    /// Small crops use Gemini's low resolution; unknown dimensions keep the provider's default.
    /// Read only the header, without decoding pixels. Both edges must fit within 768 pixels.
    var isSmall: Bool {
        guard let source = CGImageSourceCreateWithData(
                  data as CFData,
                  nil
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return (1...768).contains(width) && (1...768).contains(height)
    }
}
