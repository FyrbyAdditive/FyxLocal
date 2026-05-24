import Foundation
import FChatCore

public struct PlainTextParser: DocumentParser {
    public let supportedExtensions = ["txt", "log", "csv", "json", "yaml", "yml", "toml", "ini"]
    public init() {}

    public func parse(data: Data, filename: String) throws -> ParsedDocument {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw DocumentParserError.decodeFailure("non-text encoding for \(filename)")
        }
        return ParsedDocument(kind: .text, fullText: text, sections: [ParsedSection(text: text)])
    }
}

public struct MarkdownParser: DocumentParser {
    public let supportedExtensions = ["md", "markdown", "mdx"]
    public init() {}

    public func parse(data: Data, filename: String) throws -> ParsedDocument {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentParserError.decodeFailure("non-utf8 for \(filename)")
        }
        let sections = splitByHeading(text)
        return ParsedDocument(kind: .markdown, fullText: text, sections: sections)
    }

    private func splitByHeading(_ text: String) -> [ParsedSection] {
        var sections: [ParsedSection] = []
        var currentTitle: String?
        var currentBuffer: [String] = []

        func flush() {
            let bodyText = currentBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !bodyText.isEmpty || currentTitle != nil {
                sections.append(ParsedSection(title: currentTitle, text: bodyText))
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line)
            if let title = headingTitle(trimmed) {
                flush()
                currentTitle = title
                currentBuffer.removeAll()
            } else {
                currentBuffer.append(trimmed)
            }
        }
        flush()
        return sections.isEmpty ? [ParsedSection(text: text)] : sections
    }

    private func headingTitle(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let trimmed = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodeParser: DocumentParser {
    public let supportedExtensions = [
        "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt", "scala",
        "c", "cc", "cpp", "h", "hpp", "m", "mm", "rb", "php", "sh", "bash", "zsh",
        "lua", "html", "css", "sql",
    ]
    public init() {}

    public func parse(data: Data, filename: String) throws -> ParsedDocument {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentParserError.decodeFailure("non-utf8 for \(filename)")
        }
        return ParsedDocument(kind: .code, fullText: text, sections: [ParsedSection(title: filename, text: text)])
    }
}
