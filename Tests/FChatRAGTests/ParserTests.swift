import Testing
import Foundation
@testable import FChatRAG

@Suite("DocumentParsers")
struct ParserTests {
    @Test func plainTextRoundTrip() throws {
        let parser = PlainTextParser()
        let body = "First line\nSecond line\nThird line"
        let parsed = try parser.parse(data: Data(body.utf8), filename: "notes.txt")
        #expect(parsed.kind == .text)
        #expect(parsed.fullText == body)
        #expect(parsed.sections.count == 1)
    }

    @Test func markdownSplitsByHeading() throws {
        let md = """
        # Intro

        Hello there.

        ## Details

        More stuff.

        ## More

        Even more.
        """
        let parsed = try MarkdownParser().parse(data: Data(md.utf8), filename: "doc.md")
        #expect(parsed.kind == .markdown)
        let titles = parsed.sections.compactMap(\.title)
        #expect(titles == ["Intro", "Details", "More"])
    }

    @Test func markdownWithNoHeadingsYieldsOneSection() throws {
        let parsed = try MarkdownParser().parse(data: Data("just words\nno headings".utf8), filename: "x.md")
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].title == nil)
    }

    @Test func codeParserTreatsAsSingleSection() throws {
        let src = "func main() { print(\"hi\") }"
        let parsed = try CodeParser().parse(data: Data(src.utf8), filename: "Main.swift")
        #expect(parsed.kind == .code)
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].title == "Main.swift")
    }

    @Test func ingestorRoutesByExtension() throws {
        let ingestor = FileIngestor()
        let mdParsed = try ingestor.parse(data: Data("# H".utf8), filename: "x.md")
        #expect(mdParsed.kind == .markdown)
        let txtParsed = try ingestor.parse(data: Data("hi".utf8), filename: "x.txt")
        #expect(txtParsed.kind == .text)
        let codeParsed = try ingestor.parse(data: Data("let a = 1".utf8), filename: "Foo.swift")
        #expect(codeParsed.kind == .code)
    }

    @Test func unknownExtensionFallsBackToPlainText() throws {
        let parsed = try FileIngestor().parse(data: Data("unstructured blob".utf8), filename: "thing.weird")
        #expect(parsed.kind == .text)
    }

    @Test func docxParserNotImplemented() throws {
        do {
            _ = try DocxParser().parse(data: Data(), filename: "foo.docx")
            Issue.record("expected throw")
        } catch DocumentParserError.parserNotImplemented {
            // expected
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }
}
