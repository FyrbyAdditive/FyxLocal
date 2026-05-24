import Foundation
import FChatCore

/// .docx and .pptx are ZIP archives containing OOXML. A proper implementation
/// unzips the document, parses `word/document.xml` (or each `ppt/slides/slide*.xml`)
/// with `XMLParser`, and extracts text from `<w:t>` / `<a:t>` elements while
/// preserving heading style for sectioning.
///
/// This is mechanical but ~200 LOC per format, plus a ZIP reader. Marked as a
/// follow-up so we keep the v1 layer architecture honest. Callers that hit
/// these parsers in the meantime get a typed `parserNotImplemented` error
/// the UI can surface clearly.
public struct DocxParser: DocumentParser {
    public let supportedExtensions = ["docx"]
    public init() {}
    public func parse(data: Data, filename: String) throws -> ParsedDocument {
        throw DocumentParserError.parserNotImplemented(".docx parser pending implementation")
    }
}

public struct PptxParser: DocumentParser {
    public let supportedExtensions = ["pptx"]
    public init() {}
    public func parse(data: Data, filename: String) throws -> ParsedDocument {
        throw DocumentParserError.parserNotImplemented(".pptx parser pending implementation")
    }
}
