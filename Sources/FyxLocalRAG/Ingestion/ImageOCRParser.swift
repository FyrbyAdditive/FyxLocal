// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
#if canImport(Vision) && canImport(ImageIO)
import Vision
import ImageIO

/// OCRs raster images (screenshots, scans, photos of documents) into
/// searchable text via the Vision framework — on-device, no MLX involvement
/// (embedding happens afterwards like any other parser output). Multi-frame
/// TIFFs produce one `ParsedSection` per frame with `page` set; an image
/// with no recognizable text yields an empty section (a photo without text
/// is not an error).
public struct ImageOCRParser: DocumentParser {
    public let supportedExtensions = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif"]
    public init() {}

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw DocumentParserError.decodeFailure("not a decodable image")
        }
        let frameCount = CGImageSourceGetCount(source)

        var sections: [ParsedSection] = []
        for frame in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, frame, nil) else { continue }
            let text = try await TextRecognizer.recognize(image)
            sections.append(ParsedSection(
                title: nil,
                page: frameCount > 1 ? frame + 1 : nil,
                text: text
            ))
        }
        guard !sections.isEmpty else {
            throw DocumentParserError.decodeFailure("image contains no decodable frames")
        }

        let fullText = sections.map(\.text).joined(separator: "\n\n")
        return ParsedDocument(kind: .image, fullText: fullText, sections: sections)
    }
}

/// Thin Vision wrapper, factored out so a future scanned-PDF fallback can
/// reuse it (render page images → recognize).
enum TextRecognizer {
    /// The app's shipped UI locales; en-GB is covered by en-US for
    /// recognition purposes.
    static let recognitionLanguages = ["en-US", "sv-SE", "da-DK", "nb-NO", "es-ES"]

    /// Runs accurate-mode recognition off the calling actor and returns the
    /// recognized lines joined with newlines (empty string when the image
    /// holds no text).
    static func recognize(_ image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = recognitionLanguages

        return try await Task.detached(priority: .utility) {
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                throw DocumentParserError.decodeFailure("OCR failed: \(error.localizedDescription)")
            }
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

#else

/// Non-Apple platforms: the extension list is empty so the ingestor never
/// routes files here.
public struct ImageOCRParser: DocumentParser {
    public let supportedExtensions: [String] = []
    public init() {}
    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        throw DocumentParserError.decodeFailure("image OCR unavailable on this platform")
    }
}

#endif
