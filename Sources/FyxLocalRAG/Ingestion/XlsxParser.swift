// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Foundation
import FyxLocalCore
import ZIPFoundation

/// Extracts text from `.xlsx` spreadsheets (Office Open XML): one
/// `ParsedSection` per worksheet, rows as tab-joined lines. Reuses the
/// hardened ZIP/XML toolkit from `DocxParser` (part-size caps, XXE-safe
/// parsing).
///
/// v1 fidelity limits (documented, deliberate): dates and formula cells
/// surface as their raw serials / cached values, and sheet display names are
/// mapped by order from `xl/workbook.xml` (the rels indirection is skipped —
/// mismatched counts fall back to "Sheet N").
public struct XlsxParser: DocumentParser {
    public let supportedExtensions = ["xlsx"]
    public init() {}

    /// Per-sheet extraction caps — spreadsheets can hold millions of cells,
    /// far beyond any useful RAG corpus contribution.
    static let maxRowsPerSheet = 10_000
    static let maxCellsPerSheet = 50_000

    public func parse(data: Data, filename: String) async throws -> ParsedDocument {
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentParserError.decodeFailure("xlsx is not a valid zip: \(error.localizedDescription)")
        }

        // Shared strings are optional (numeric-only sheets omit the part).
        var sharedStrings: [String] = []
        if let stringsData = try DocxParser.extract(entry: "xl/sharedStrings.xml", from: archive) {
            let walker = SharedStringsWalker()
            let parser = XMLParser(data: stringsData)
            parser.shouldResolveExternalEntities = false   // XXE-safe (see DocxParser)
            parser.delegate = walker
            _ = parser.parse()
            sharedStrings = walker.strings
        }

        let sheetPaths = PptxParser.sortedEntryPaths(in: archive, prefix: "xl/worksheets/sheet", suffix: ".xml")
        guard !sheetPaths.isEmpty else {
            throw DocumentParserError.decodeFailure("xlsx contains no worksheets")
        }

        // Sheet display names, by order. Only trusted when the count matches.
        var sheetNames: [String] = []
        if let workbookData = try DocxParser.extract(entry: "xl/workbook.xml", from: archive) {
            let walker = WorkbookNamesWalker()
            let parser = XMLParser(data: workbookData)
            parser.shouldResolveExternalEntities = false   // XXE-safe
            parser.delegate = walker
            _ = parser.parse()
            sheetNames = walker.names
        }
        let namesUsable = sheetNames.count == sheetPaths.count

        var sections: [ParsedSection] = []
        for (index, path) in sheetPaths.enumerated() {
            guard let sheetData = try DocxParser.extract(entry: path, from: archive) else { continue }
            let walker = SheetWalker(sharedStrings: sharedStrings)
            let parser = XMLParser(data: sheetData)
            parser.shouldResolveExternalEntities = false   // XXE-safe
            parser.delegate = walker
            _ = parser.parse()
            var text = walker.finish()
            if walker.truncated {
                text += "\n[truncated: sheet exceeds extraction caps]"
            }
            let title = namesUsable ? sheetNames[index] : "Sheet \(index + 1)"
            sections.append(ParsedSection(title: title, page: index + 1, text: text))
        }

        let fullText = sections
            .map { ($0.title.map { "# \($0)\n" } ?? "") + $0.text }
            .joined(separator: "\n\n")
        return ParsedDocument(
            kind: .xlsx,
            fullText: fullText,
            sections: sections.isEmpty ? [ParsedSection(text: "")] : sections
        )
    }
}

/// Collects `<si>` entries from `xl/sharedStrings.xml`. Each entry's text is
/// the concatenation of its `<t>` nodes (plain and rich-run forms).
private final class SharedStringsWalker: NSObject, XMLParserDelegate {
    private(set) var strings: [String] = []
    private var currentEntry = ""
    private var collectingText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si":
            currentEntry = ""
        case "t":
            collectingText = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText { currentEntry.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "t":
            collectingText = false
        case "si":
            strings.append(currentEntry)
        default:
            break
        }
    }
}

/// Collects `<sheet name="…">` values from `xl/workbook.xml`, in order.
private final class WorkbookNamesWalker: NSObject, XMLParserDelegate {
    private(set) var names: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "sheet", let name = attributeDict["name"] {
            names.append(name)
        }
    }
}

/// Walks one `xl/worksheets/sheetN.xml`: rows become newline-joined lines,
/// cells within a row are tab-joined. Cell text resolution:
/// `t="s"` → shared-strings index from `<v>`; `t="inlineStr"` → `<is><t>`;
/// anything else → raw `<v>` (numbers, cached formula values, date serials).
private final class SheetWalker: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var lines: [String] = []
    private var rowCells: [String] = []
    private var cellType: String?
    private var valueBuffer = ""
    private var collectingValue = false
    private var collectingInline = false
    private var cellCount = 0
    private(set) var truncated = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard !truncated else { return }
        switch elementName {
        case "row":
            rowCells = []
        case "c":
            cellType = attributeDict["t"]
            valueBuffer = ""
        case "v":
            collectingValue = true
        case "is":
            collectingInline = true
        case "t" where collectingInline:
            collectingValue = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingValue, !truncated { valueBuffer.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !truncated else { return }
        switch elementName {
        case "v", "t":
            collectingValue = false
        case "is":
            collectingInline = false
        case "c":
            let text: String
            if cellType == "s", let index = Int(valueBuffer.trimmingCharacters(in: .whitespaces)),
               index >= 0, index < sharedStrings.count {
                text = sharedStrings[index]
            } else {
                text = valueBuffer
            }
            rowCells.append(text)
            cellCount += 1
            if cellCount >= XlsxParser.maxCellsPerSheet {
                truncated = true
            }
            cellType = nil
            valueBuffer = ""
        case "row":
            let line = rowCells.joined(separator: "\t")
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(line)
            }
            rowCells = []
            if lines.count >= XlsxParser.maxRowsPerSheet {
                truncated = true
            }
        default:
            break
        }
    }

    func finish() -> String {
        lines.joined(separator: "\n")
    }
}
