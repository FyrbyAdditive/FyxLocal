// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import ZIPFoundation
import SwiftSoup

/// Extracts text from `.epub` books: chapters in OPF spine order, one
/// `ParsedSection` per chapter, XHTML flattened with SwiftSoup (no JS, so no
/// WKWebView round-trip). DRM'd or malformed books fail with a clean
/// `decodeFailure` that surfaces in the ingest failures list.
public struct EpubParser: DocumentParser {
    public let supportedExtensions = ["epub"]
    public init() {}

    /// Books shouldn't have thousands of spine items; cap the walk.
    static let maxChapters = 500

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParserError.decodeFailure("epub is not a valid zip: \(error.localizedDescription)")
        }

        // 1. META-INF/container.xml → the OPF package path.
        guard let containerData = try DocxParser.extract(entry: "META-INF/container.xml", from: archive) else {
            throw DocumentParserError.decodeFailure("epub missing META-INF/container.xml")
        }
        let containerWalker = ContainerWalker()
        let containerParser = XMLParser(data: containerData)
        containerParser.shouldResolveExternalEntities = false   // XXE-safe (see DocxParser)
        containerParser.delegate = containerWalker
        _ = containerParser.parse()
        guard let opfPath = containerWalker.opfPath else {
            throw DocumentParserError.decodeFailure("epub container.xml names no rootfile")
        }

        // 2. OPF → manifest (id → href, media-type) + spine (idref order).
        guard let opfData = try DocxParser.extract(entry: opfPath, from: archive) else {
            throw DocumentParserError.decodeFailure("epub missing OPF package at \(opfPath)")
        }
        let opfWalker = OPFWalker()
        let opfParser = XMLParser(data: opfData)
        opfParser.shouldResolveExternalEntities = false   // XXE-safe
        opfParser.delegate = opfWalker
        _ = opfParser.parse()

        let opfDirectory = (opfPath as NSString).deletingLastPathComponent
        var sections: [ParsedSection] = []
        for (index, idref) in opfWalker.spine.prefix(Self.maxChapters).enumerated() {
            guard let item = opfWalker.manifest[idref],
                  item.mediaType.contains("html") else { continue }
            let chapterPath = opfDirectory.isEmpty
                ? item.href
                : (opfDirectory as NSString).appendingPathComponent(item.href)
            guard let chapterData = (try? DocxParser.extract(entry: chapterPath, from: archive)) ?? nil,
                  let html = String(data: chapterData, encoding: .utf8) else { continue }

            guard let document = try? SwiftSoup.parse(html) else { continue }
            let title = Self.chapterTitle(document) ?? "Chapter \(index + 1)"
            let text = Self.blockText(document)
            guard !text.isEmpty else { continue }
            sections.append(ParsedSection(title: title, page: nil, text: text))
        }

        guard !sections.isEmpty else {
            throw DocumentParserError.decodeFailure("epub contains no readable chapters (DRM-protected?)")
        }

        let fullText = sections
            .map { ($0.title.map { "# \($0)\n" } ?? "") + $0.text }
            .joined(separator: "\n\n")
        return ParsedDocument(kind: .epub, fullText: fullText, sections: sections)
    }

    private static func chapterTitle(_ document: Document) -> String? {
        if let title = try? document.title(), !title.isEmpty { return title }
        for selector in ["h1", "h2"] {
            if let heading = try? document.select(selector).first(),
               let text = try? heading.text(), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Body text with block-level separation: paragraphs/headings/list items
    /// become their own lines rather than one run-on string.
    private static func blockText(_ document: Document) -> String {
        guard let body = document.body() else { return "" }
        var lines: [String] = []
        if let blocks = try? body.select("p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, td") {
            for block in blocks {
                if let text = try? block.text(), !text.isEmpty {
                    lines.append(text)
                }
            }
        }
        if lines.isEmpty, let flat = try? body.text(), !flat.isEmpty {
            return flat
        }
        return lines.joined(separator: "\n")
    }
}

/// Reads `<rootfile full-path="…">` from META-INF/container.xml.
private final class ContainerWalker: NSObject, XMLParserDelegate {
    private(set) var opfPath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile", opfPath == nil, let path = attributeDict["full-path"] {
            opfPath = path
        }
    }
}

/// Reads the OPF manifest (`<item id href media-type>`) and spine
/// (`<itemref idref>` order).
private final class OPFWalker: NSObject, XMLParserDelegate {
    struct ManifestItem {
        var href: String
        var mediaType: String
    }

    private(set) var manifest: [String: ManifestItem] = [:]
    private(set) var spine: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = ManifestItem(
                    href: href.removingPercentEncoding ?? href,
                    mediaType: attributeDict["media-type"] ?? ""
                )
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        default:
            break
        }
    }
}
