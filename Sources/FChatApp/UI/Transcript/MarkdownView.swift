import SwiftUI
import Markdown

/// Renders a CommonMark / GFM markdown source as a vertical stack of SwiftUI
/// views. Inline runs are composed into a single `AttributedString` per
/// paragraph so wrapping behaves naturally; block elements (headings, lists,
/// code blocks, blockquotes, tables, rules) get bespoke layouts.
struct MarkdownView: View {
    let source: String

    var body: some View {
        let document = Document(parsing: source, options: [.parseBlockDirectives])
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blockChildren.enumerated()), id: \.offset) { _, block in
                BlockRenderer(block: block)
            }
        }
    }
}

private struct BlockRenderer: View {
    let block: any BlockMarkup

    var body: some View {
        switch block {
        case let heading as Heading:
            Text(InlineRenderer.attributed(from: heading.inlineChildren))
                .font(headingFont(for: heading.level))
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .padding(.top, heading.level == 1 ? 8 : 4)

        case let paragraph as Paragraph:
            Text(InlineRenderer.attributed(from: paragraph.inlineChildren))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let list as UnorderedList:
            ListView(items: Array(list.listItems), ordered: false, startIndex: nil)

        case let list as OrderedList:
            ListView(items: Array(list.listItems), ordered: true, startIndex: Int(list.startIndex))

        case let code as CodeBlock:
            CodeBlockView(language: code.language, source: code.code)

        case let quote as BlockQuote:
            BlockQuoteView(quote: quote)

        case is ThematicBreak:
            Divider().padding(.vertical, 4)

        case let table as Markdown.Table:
            MarkdownTableView(table: table)

        case let htmlBlock as HTMLBlock:
            Text(htmlBlock.rawHTML)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

        default:
            // Fallback: render the raw text. Catches block directives, custom
            // extensions, and anything swift-markdown adds in the future.
            Text(block.format())
                .textSelection(.enabled)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        case 4: return .headline
        case 5: return .subheadline.bold()
        default: return .body.bold()
        }
    }
}

private struct ListView: View {
    let items: [ListItem]
    let ordered: Bool
    let startIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bullet(for: index))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                            BlockRenderer(block: child)
                        }
                    }
                }
            }
        }
    }

    private func bullet(for index: Int) -> String {
        if ordered {
            return "\((startIndex ?? 1) + index)."
        }
        return "•"
    }
}

private struct CodeBlockView: View {
    let language: String?
    let source: String

    var body: some View {
        let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.10))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(trimmed)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct BlockQuoteView: View {
    let quote: BlockQuote

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.4))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(quote.blockChildren.enumerated()), id: \.offset) { _, child in
                    BlockRenderer(block: child)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct MarkdownTableView: View {
    let table: Markdown.Table

    var body: some View {
        let rows = Array(table.body.rows)
        let headerCells = Array(table.head.cells).map { Array($0.inlineChildren) }
        VStack(alignment: .leading, spacing: 0) {
            if !headerCells.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(headerCells.enumerated()), id: \.offset) { _, inlines in
                        Text(InlineRenderer.attributed(from: inlines))
                            .font(.callout.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color.gray.opacity(0.12))
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(InlineRenderer.attributed(from: Array(cell.inlineChildren)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.gray.opacity(0.05))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

enum InlineRenderer {
    static func attributed(from inlines: some Sequence<InlineMarkup>) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result += render(inline)
        }
        return result
    }

    private static func render(_ inline: InlineMarkup) -> AttributedString {
        switch inline {
        case let text as Markdown.Text:
            return AttributedString(text.string)

        case let emphasis as Emphasis:
            var s = attributed(from: emphasis.inlineChildren)
            s.runs.forEach { run in
                let range = run.range
                var current = s[range].inlinePresentationIntent ?? []
                current.insert(.emphasized)
                s[range].inlinePresentationIntent = current
            }
            return s

        case let strong as Strong:
            var s = attributed(from: strong.inlineChildren)
            s.runs.forEach { run in
                let range = run.range
                var current = s[range].inlinePresentationIntent ?? []
                current.insert(.stronglyEmphasized)
                s[range].inlinePresentationIntent = current
            }
            return s

        case let strike as Strikethrough:
            var s = attributed(from: strike.inlineChildren)
            s.runs.forEach { run in
                let range = run.range
                var current = s[range].inlinePresentationIntent ?? []
                current.insert(.strikethrough)
                s[range].inlinePresentationIntent = current
            }
            return s

        case let code as InlineCode:
            var s = AttributedString(code.code)
            s.inlinePresentationIntent = .code
            return s

        case let link as Markdown.Link:
            var s = attributed(from: link.inlineChildren)
            if let dest = link.destination, let url = URL(string: dest) {
                s.link = url
            }
            return s

        case let image as Markdown.Image:
            // Inline image — fall back to alt-text in the text run; the
            // assistant rarely emits raw inline image markup in chat, and
            // bespoke inline image rendering is out of scope.
            let altParts: [String] = image.inlineChildren.compactMap { ($0 as? Markdown.Text)?.string }
            let alt = altParts.joined()
            let label: String
            if !alt.isEmpty {
                label = alt
            } else if let title = image.title, !title.isEmpty {
                label = title
            } else if let source = image.source, !source.isEmpty {
                label = source
            } else {
                label = "image"
            }
            var s = AttributedString("[\(label)]")
            s.inlinePresentationIntent = .emphasized
            return s

        case is LineBreak:
            return AttributedString("\n")

        case is SoftBreak:
            return AttributedString(" ")

        case let html as InlineHTML:
            // Render raw HTML as literal text — most chat HTML is decorative
            // (<br>, <details>) and we'd rather show it than silently strip.
            var s = AttributedString(html.rawHTML)
            s.inlinePresentationIntent = .code
            return s

        case let symbol as SymbolLink:
            return AttributedString(symbol.destination ?? "")

        default:
            return AttributedString(inline.format())
        }
    }
}
