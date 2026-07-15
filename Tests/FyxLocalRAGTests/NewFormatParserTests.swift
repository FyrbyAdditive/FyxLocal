// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Tim Ellis / Fyrby Additive Manufacturing & Engineering

import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import FyxLocalCore
import ZIPFoundation
@testable import FyxLocalRAG

// MARK: - Fixture builders

/// Zips a dictionary of path → content into an in-memory archive, matching
/// the makeDocx pattern used by the office tests.
private func makeZip(_ entries: [(path: String, content: String)]) throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let outURL = dir.appendingPathComponent("out.zip")
    let archive = try Archive(url: outURL, accessMode: .create)
    for entry in entries {
        let data = Data(entry.content.utf8)
        try archive.addEntry(
            with: entry.path,
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        )
    }
    return try Data(contentsOf: outURL)
}

@Suite("XlsxParser")
struct XlsxParserTests {
    private func fixture() throws -> Data {
        try makeZip([
            ("xl/sharedStrings.xml", """
            <?xml version="1.0"?>
            <sst><si><t>Name</t></si><si><r><t>Am</t></r><r><t>ount</t></r></si><si><t>Widget</t></si></sst>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0"?>
            <workbook><sheets><sheet name="Budget" sheetId="1"/><sheet name="Notes" sheetId="2"/></sheets></workbook>
            """),
            ("xl/worksheets/sheet1.xml", """
            <?xml version="1.0"?>
            <worksheet><sheetData>
            <row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row>
            <row><c t="s"><v>2</v></c><c><v>42.5</v></c></row>
            <row><c t="inlineStr"><is><t>inline cell</t></is></c></row>
            </sheetData></worksheet>
            """),
            ("xl/worksheets/sheet2.xml", """
            <?xml version="1.0"?>
            <worksheet><sheetData><row><c><v>7</v></c></row></sheetData></worksheet>
            """),
        ])
    }

    @Test func parsesSheetsSharedAndInlineStrings() async throws {
        let parsed = try await XlsxParser().parse(data: fixture(), filename: "book.xlsx")
        #expect(parsed.kind == .xlsx)
        #expect(parsed.sections.count == 2)
        #expect(parsed.sections[0].title == "Budget")
        #expect(parsed.sections[0].page == 1)
        // Rich-run shared string reassembles; cells tab-joined.
        #expect(parsed.sections[0].text.contains("Name\tAmount"))
        #expect(parsed.sections[0].text.contains("Widget\t42.5"))
        #expect(parsed.sections[0].text.contains("inline cell"))
        #expect(parsed.sections[1].title == "Notes")
    }

    @Test func sheetNameCountMismatchFallsBackToNumbers() async throws {
        let data = try makeZip([
            ("xl/workbook.xml", #"<workbook><sheets><sheet name="Only"/></sheets></workbook>"#),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c><v>1</v></c></row></sheetData></worksheet>"),
            ("xl/worksheets/sheet2.xml", "<worksheet><sheetData><row><c><v>2</v></c></row></sheetData></worksheet>"),
        ])
        let parsed = try await XlsxParser().parse(data: data, filename: "b.xlsx")
        #expect(parsed.sections.map(\.title) == ["Sheet 1", "Sheet 2"])
    }

    @Test func rejectsNonZip() async throws {
        await #expect(throws: DocumentParserError.self) {
            _ = try await XlsxParser().parse(data: Data("nope".utf8), filename: "x.xlsx")
        }
    }
}

@Suite("EpubParser")
struct EpubParserTests {
    private func fixture() throws -> Data {
        try makeZip([
            ("META-INF/container.xml", """
            <?xml version="1.0"?>
            <container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """),
            ("OEBPS/content.opf", """
            <?xml version="1.0"?>
            <package><manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="css" href="style.css" media-type="text/css"/>
            </manifest><spine><itemref idref="ch2"/><itemref idref="ch1"/></spine></package>
            """),
            ("OEBPS/ch1.xhtml", """
            <html><head><title>The End</title></head><body><p>Closing thoughts.</p></body></html>
            """),
            ("OEBPS/ch2.xhtml", """
            <html><head><title></title></head><body><h1>The Beginning</h1><p>Once upon a time.</p><p>It was dark.</p></body></html>
            """),
            ("OEBPS/style.css", "p { color: red }"),
        ])
    }

    @Test func parsesChaptersInSpineOrder() async throws {
        let parsed = try await EpubParser().parse(data: fixture(), filename: "book.epub")
        #expect(parsed.kind == .epub)
        #expect(parsed.sections.count == 2)
        // Spine order: ch2 first.
        #expect(parsed.sections[0].title == "The Beginning")
        #expect(parsed.sections[0].text.contains("Once upon a time."))
        #expect(parsed.sections[0].text.contains("It was dark."))
        #expect(parsed.sections[1].title == "The End")
    }

    @Test func missingContainerFailsCleanly() async throws {
        let data = try makeZip([("mimetype", "application/epub+zip")])
        await #expect(throws: DocumentParserError.self) {
            _ = try await EpubParser().parse(data: data, filename: "b.epub")
        }
    }

    @Test func rejectsNonZip() async throws {
        await #expect(throws: DocumentParserError.self) {
            _ = try await EpubParser().parse(data: Data("nope".utf8), filename: "b.epub")
        }
    }
}

@Suite("ImageOCRParser")
struct ImageOCRParserTests {
    /// Renders a line of large black text on white into PNG bytes.
    private func textImage(_ text: String, width: Int = 600, height: Int = 120) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 20, y: 40)
        CTLineDraw(line, context)

        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    @Test func recognizesRenderedText() async throws {
        let data = try textImage("HELLO WORLD 42")
        let parsed = try await ImageOCRParser().parse(data: data, filename: "shot.png")
        #expect(parsed.kind == .image)
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].page == nil)
        let upper = parsed.fullText.uppercased()
        #expect(upper.contains("HELLO"))
        #expect(upper.contains("WORLD"))
        #expect(upper.contains("42"))
    }

    @Test func blankImageYieldsEmptyTextNotError() async throws {
        let data = try textImage(" ")
        let parsed = try await ImageOCRParser().parse(data: data, filename: "blank.png")
        #expect(parsed.sections.count == 1)
        #expect(parsed.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func garbageBytesFailCleanly() async throws {
        await #expect(throws: DocumentParserError.self) {
            _ = try await ImageOCRParser().parse(data: Data("not an image".utf8), filename: "x.png")
        }
    }
}

@Suite("FileIngestor new format routing")
struct FileIngestorNewFormatTests {
    @Test func newExtensionsAreRegistered() {
        let extensions = FileIngestor().supportedExtensions
        #expect(extensions.contains("xlsx"))
        #expect(extensions.contains("epub"))
        #expect(extensions.contains("png"))
        #expect(extensions.contains("heic"))
        #expect(extensions.contains("tiff"))
    }
}
