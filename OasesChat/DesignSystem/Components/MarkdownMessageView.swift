@preconcurrency import SwiftUI
#if canImport(UIKit)
@preconcurrency import UIKit
#endif

struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.sm) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    headingView(level: level, content: content)
                case .codeBlock(let lang, let code):
                    codeBlockView(language: lang, code: code)
                case .blockquote(let lines):
                    blockquoteView(lines: lines)
                case .table(let headers, let rows):
                    tableView(headers: headers, rows: rows)
                case .orderedList(let items):
                    orderedListView(items: items)
                case .unorderedList(let items):
                    unorderedListView(items: items)
                case .thematicBreak:
                    Divider()
                        .background(OasesColor.border.opacity(0.5))
                        .padding(.vertical, OasesSpacing.xs)
                case .paragraph(let content):
                    inlineRichText(content)
                }
            }
        }
    }

    // MARK: - Block Views

    @ViewBuilder
    private func headingView(level: Int, content: String) -> some View {
        let size: CGFloat = switch level {
        case 1: 24
        case 2: 20
        case 3: 18
        default: 16
        }
        Text(parseInlineAttributedString(content))
            .font(.custom(OasesTypography.serifBold, size: size, relativeTo: .headline))
            .foregroundStyle(OasesColor.foreground)
            .lineSpacing(2)
    }

    @ViewBuilder
    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(OasesColor.mutedForeground.opacity(0.8))
                    Spacer()
                    CopyButton(text: code)
                }
                .padding(.horizontal, OasesSpacing.sm)
                .padding(.top, OasesSpacing.xs)
                .padding(.bottom, 4)
            } else {
                HStack {
                    Spacer()
                    CopyButton(text: code)
                }
                .padding(.horizontal, OasesSpacing.sm)
                .padding(.top, OasesSpacing.xs)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(OasesColor.foreground.opacity(0.92))
                    .padding(.horizontal, OasesSpacing.sm)
                    .padding(.bottom, OasesSpacing.sm)
                    .textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                .fill(OasesColor.foreground.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func blockquoteView(lines: [String]) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(OasesColor.primary.opacity(0.5))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: OasesSpacing.xxs) {
                ForEach(lines, id: \.self) { line in
                    Text(parseInlineAttributedString(line))
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineSpacing(4)
                }
            }
            .padding(.leading, OasesSpacing.sm)
        }
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(headers, id: \.self) { header in
                        Text(parseInlineAttributedString(header))
                            .font(.custom(OasesTypography.serifBold, size: 14, relativeTo: .caption))
                            .foregroundStyle(OasesColor.foreground)
                            .padding(.horizontal, OasesSpacing.sm)
                            .padding(.vertical, OasesSpacing.xs)
                            .frame(minWidth: 60, alignment: .leading)
                    }
                }
                .background(OasesColor.primary.opacity(0.08))

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(parseInlineAttributedString(cell))
                                .font(.oasesCallout())
                                .foregroundStyle(OasesColor.foreground)
                                .padding(.horizontal, OasesSpacing.sm)
                                .padding(.vertical, OasesSpacing.xs)
                                .frame(minWidth: 60, alignment: .leading)
                        }
                    }
                    Divider().background(OasesColor.border.opacity(0.4))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.5), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func unorderedListView(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: OasesSpacing.xs) {
                    Text("•")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .frame(width: 12, alignment: .center)
                    Text(parseInlineAttributedString(item))
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                        .lineSpacing(4)
                }
            }
        }
    }

    @ViewBuilder
    private func orderedListView(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: OasesSpacing.xs) {
                    Text("\(index + 1).")
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .frame(width: 20, alignment: .trailing)
                    Text(parseInlineAttributedString(item))
                        .font(.oasesBody())
                        .foregroundStyle(OasesColor.foreground)
                        .lineSpacing(4)
                }
            }
        }
    }

    @ViewBuilder
    private func inlineRichText(_ content: String) -> some View {
        Text(parseInlineAttributedString(content))
            .font(.oasesBody())
            .foregroundStyle(OasesColor.foreground)
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Copy Button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Haptics.tap()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                if copied {
                    Text("已复制")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(copied ? OasesColor.primary : OasesColor.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(OasesColor.background.opacity(0.7))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Block Parser

private enum MarkdownBlock: Hashable {
    case heading(level: Int, content: String)
    case codeBlock(language: String?, code: String)
    case blockquote(lines: [String])
    case table(headers: [String], rows: [[String]])
    case orderedList(items: [String])
    case unorderedList(items: [String])
    case thematicBreak
    case paragraph(content: String)
}

private func parseBlocks(_ input: String) -> [MarkdownBlock] {
    let lines = input.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]

        // Code block
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            let lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                codeLines.append(lines[i])
                i += 1
            }
            blocks.append(.codeBlock(language: lang.isEmpty ? nil : lang, code: codeLines.joined(separator: "\n")))
            continue
        }

        // Heading
        if let match = line.wholeMatch(of: /^(#{1,4})\s+(.+)$/) {
            let level = match.output.1.count
            blocks.append(.heading(level: level, content: String(match.output.2)))
            i += 1
            continue
        }

        // Thematic break
        if line.wholeMatch(of: /^(\*{3,}|-{3,}|_{3,})\s*$/) != nil {
            blocks.append(.thematicBreak)
            i += 1
            continue
        }

        // Blockquote
        if line.hasPrefix("> ") || line == ">" {
            var quoteLines: [String] = []
            while i < lines.count && (lines[i].hasPrefix("> ") || lines[i] == ">") {
                let content = lines[i].hasPrefix("> ") ? String(lines[i].dropFirst(2)) : ""
                quoteLines.append(content)
                i += 1
            }
            blocks.append(.blockquote(lines: quoteLines))
            continue
        }

        // Unordered list
        if line.wholeMatch(of: /^[\-\*\+]\s+.+$/) != nil {
            var items: [String] = []
            while i < lines.count, let m = lines[i].wholeMatch(of: /^[\-\*\+]\s+(.+)$/) {
                items.append(String(m.output.1))
                i += 1
            }
            blocks.append(.unorderedList(items: items))
            continue
        }

        // Ordered list
        if line.wholeMatch(of: /^\d+\.\s+.+$/) != nil {
            var items: [String] = []
            while i < lines.count, let m = lines[i].wholeMatch(of: /^\d+\.\s+(.+)$/) {
                items.append(String(m.output.1))
                i += 1
            }
            blocks.append(.orderedList(items: items))
            continue
        }

        // Table
        if line.contains("|") && i + 1 < lines.count && lines[i + 1].wholeMatch(of: /^\|?[\s\-:|]+\|?$/) != nil {
            let headerCells = splitTableRow(line)
            i += 2 // skip separator
            var rows: [[String]] = []
            while i < lines.count && lines[i].contains("|") {
                rows.append(splitTableRow(lines[i]))
                i += 1
            }
            blocks.append(.table(headers: headerCells, rows: rows))
            continue
        }

        // Empty line
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            i += 1
            continue
        }

        // Paragraph (collect consecutive non-empty lines)
        var paraLines: [String] = []
        while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
            && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("#")
            && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```")
            && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("> ")
            && lines[i].wholeMatch(of: /^[\-\*\+]\s+.+$/) == nil
            && lines[i].wholeMatch(of: /^\d+\.\s+.+$/) == nil
        {
            paraLines.append(lines[i])
            i += 1
        }
        if !paraLines.isEmpty {
            blocks.append(.paragraph(content: paraLines.joined(separator: "\n")))
        }
    }

    return blocks
}

private func splitTableRow(_ line: String) -> [String] {
    line
        .trimmingCharacters(in: CharacterSet(charactersIn: "| "))
        .components(separatedBy: "|")
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

// MARK: - Inline Parser (AttributedString)

@MainActor
private func parseInlineAttributedString(_ input: String) -> AttributedString {
    var result = AttributedString()

    let scanner = Scanner(string: input)
    scanner.charactersToBeSkipped = nil

    while !scanner.isAtEnd {
        // Bold **text** or __text__
        if let match = scanner.scanUpToString("`"), match.contains("**") {
            // Try inline formatting
        }

        // Simple approach: process character by character for inline formatting
        break
    }

    // Fallback: use regex-based approach
    let processed = input
    var segments: [(String, InlineStyle)] = []
    var remaining = processed

    while !remaining.isEmpty {
        if remaining.hasPrefix("**") {
            remaining = String(remaining.dropFirst(2))
            if let end = remaining.range(of: "**") {
                let bold = String(remaining[..<end.lowerBound])
                segments.append((bold, .bold))
                remaining = String(remaining[end.upperBound...])
            } else {
                segments.append(("**", .normal))
            }
        } else if remaining.hasPrefix("__") {
            remaining = String(remaining.dropFirst(2))
            if let end = remaining.range(of: "__") {
                let bold = String(remaining[..<end.lowerBound])
                segments.append((bold, .bold))
                remaining = String(remaining[end.upperBound...])
            } else {
                segments.append(("__", .normal))
            }
        } else if remaining.hasPrefix("*") || remaining.hasPrefix("_") {
            let marker = remaining.hasPrefix("*") ? "*" : "_"
            remaining = String(remaining.dropFirst())
            if let end = remaining.range(of: marker) {
                let italic = String(remaining[..<end.lowerBound])
                segments.append((italic, .italic))
                remaining = String(remaining[end.upperBound...])
            } else {
                segments.append((marker, .normal))
            }
        } else if remaining.hasPrefix("`") {
            remaining = String(remaining.dropFirst())
            if let end = remaining.range(of: "`") {
                let code = String(remaining[..<end.lowerBound])
                segments.append((code, .code))
                remaining = String(remaining[end.upperBound...])
            } else {
                segments.append(("`", .normal))
            }
        } else if remaining.hasPrefix("[") {
            // [text](url)
            remaining = String(remaining.dropFirst())
            if let bracketEnd = remaining.range(of: "](") {
                let linkText = String(remaining[..<bracketEnd.lowerBound])
                remaining = String(remaining[bracketEnd.upperBound...])
                if let parenEnd = remaining.range(of: ")") {
                    let url = String(remaining[..<parenEnd.lowerBound])
                    segments.append((linkText, .link(url: url)))
                    remaining = String(remaining[parenEnd.upperBound...])
                } else {
                    segments.append(("[" + linkText, .normal))
                }
            } else {
                segments.append(("[", .normal))
            }
        } else {
            // Find next special character
            let specialChars = ["**", "`", "*", "_", "["]
            var nextIndex = remaining.endIndex
            for char in specialChars {
                if let range = remaining.range(of: char) {
                    if range.lowerBound < nextIndex {
                        nextIndex = range.lowerBound
                    }
                }
            }
            let normal = String(remaining[..<nextIndex])
            if !normal.isEmpty {
                segments.append((normal, .normal))
            }
            remaining = String(remaining[nextIndex...])
        }
    }

    for (text, style) in segments {
        #if canImport(UIKit)
        let nsSegment = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        switch style {
        case .normal:
            break
        case .bold:
            nsSegment.addAttribute(.font, value: uiFont(named: OasesTypography.serifBold, size: 15, fallback: .boldSystemFont(ofSize: 15)), range: range)
        case .italic:
            nsSegment.addAttribute(.font, value: italicUIFont(size: 15), range: range)
        case .code:
            nsSegment.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range)
            nsSegment.addAttribute(.foregroundColor, value: UIColor(OasesColor.foreground.opacity(0.92)), range: range)
            nsSegment.addAttribute(.backgroundColor, value: UIColor(OasesColor.foreground.opacity(0.08)), range: range)
        case .link(let url):
            nsSegment.addAttribute(.foregroundColor, value: UIColor(OasesColor.primary), range: range)
            nsSegment.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            if let linkURL = URL(string: url) {
                nsSegment.addAttribute(.link, value: linkURL, range: range)
            }
        }
        let seg = AttributedString(nsSegment)
        result += seg
        #else
        result += AttributedString(text)
        #endif
    }

    return result
}

private enum InlineStyle {
    case normal, bold, italic, code, link(url: String)
}

#if canImport(UIKit)
private func uiFont(named name: String, size: CGFloat, fallback: UIFont) -> UIFont {
    UIFont(name: name, size: size) ?? fallback
}

private func italicUIFont(size: CGFloat) -> UIFont {
    let base = uiFont(named: OasesTypography.serif, size: size, fallback: .systemFont(ofSize: size))
    guard let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.traitItalic)) else {
        return .italicSystemFont(ofSize: size)
    }
    return UIFont(descriptor: descriptor, size: size)
}
#endif

#Preview {
    ScrollView {
        // i18n-ignore: preview sample markdown
        MarkdownMessageView(text: """
        # 标题一

        这是一段**粗体**和*斜体*的文字，还有`行内代码`。

        ## 标题二

        - 列表项一
        - 列表项二
        - 列表项三

        > 这是一段引用文字

        ```swift
        let greeting = "Hello, Oases!"
        print(greeting)
        ```

        | 功能 | 状态 |
        |------|------|
        | 聊天 | 已完成 |
        | 图像 | 开发中 |

        ---

        普通段落文字，包含[链接](https://oaseschat.com)。
        """)
        .padding()
    }
    .background(OasesColor.background)
    .preferredColorScheme(.dark)
}
