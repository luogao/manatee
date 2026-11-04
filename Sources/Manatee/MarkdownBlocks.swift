import Foundation

/// release notes 里的一段。行内样式（粗体、行内代码、链接）交给 Foundation 的
/// markdown 解析；块级结构（标题层级、列表缩进、代码块）必须自己切，因为
/// `AttributedString` 的 `presentationIntent` 交给 SwiftUI 只会变成一段连续文字，
/// 排不出标题和列表的视觉层级。
///
/// 这个文件只 import Foundation：解析能脱离 UI 单测（见 MarkdownBlocksTests）。
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case bullet(depth: Int, text: AttributedString)
    case ordered(depth: Int, number: Int, text: AttributedString)
    case code(language: String?, code: String)
    case quote(AttributedString)
    case rule
}

extension MarkdownBlock {
    /// 去掉行内样式后的纯文本，单测和「解析失败回退」都用它
    var plainText: String {
        switch self {
        case .heading(_, let t), .paragraph(let t), .quote(let t):
            return String(t.characters)
        case .bullet(_, let t), .ordered(_, _, let t):
            return String(t.characters)
        case .code(_, let code):
            return code
        case .rule:
            return ""
        }
    }
}

/// 把 GitHub release 的 `body` 切成块。故意不追求完整 CommonMark：
/// release notes 只会用到标题、列表、代码块、引用、链接这几种，够用且好测。
struct MarkdownDocument: Equatable {
    var blocks: [MarkdownBlock] = []

    /// 列表每级缩进的格子数。GitHub 用 2～4 空格都认，这里按 2 折算
    private static let spacesPerLevel = 2
    private static let maxDepth = 3

    static func parse(_ markdown: String) -> MarkdownDocument {
        var doc = MarkdownDocument()
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            doc.blocks.append(.paragraph(inline(text)))
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 围栏代码块：内容原样保留，里面的 `#`、`- ` 都不是标记。
            // 没有收尾围栏也照样出块（截断的备注不能整段消失）。
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let body = lines[i]
                    if body.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    code.append(body)
                    i += 1
                }
                doc.blocks.append(.code(language: lang.isEmpty ? nil : lang,
                                        code: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let h = Self.heading(trimmed) {
                flushParagraph()
                doc.blocks.append(.heading(level: h.level, text: inline(h.text)))
                i += 1
                continue
            }

            if Self.isRule(trimmed) {
                flushParagraph()
                doc.blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix(">") else { break }
                    var q = String(l.dropFirst())
                    if q.hasPrefix(" ") { q.removeFirst() }
                    quoted.append(q)
                    i += 1
                }
                doc.blocks.append(.quote(inline(quoted.joined(separator: "\n"))))
                continue
            }

            if let item = Self.listItem(trimmed) {
                flushParagraph()
                let depth = indentDepth(of: line)
                if item.ordered {
                    doc.blocks.append(.ordered(depth: depth, number: item.number,
                                               text: inline(item.text)))
                } else {
                    doc.blocks.append(.bullet(depth: depth, text: inline(item.text)))
                }
                i += 1
                continue
            }

            // 软换行保留：中文备注按句手动折行时，合并成空格会在句中多出空格
            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return doc
    }

    /// 行内解析：粗体/斜体/行内代码/链接。`inlineOnlyPreservingWhitespace` 不做块级解析，
    /// 也不会吃掉换行；解析失败就退回原文字面量，绝不丢内容。
    static func inline(_ raw: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        if let s = try? AttributedString(markdown: raw, options: options) {
            return s
        }
        return AttributedString(raw)
    }

    // MARK: - 单行识别

    /// `## 标题` → (2, "标题")。结尾可选的闭合 `###` 按 GitHub 规则吃掉。
    private static func heading(_ s: String) -> (level: Int, text: String)? {
        var level = 0
        for ch in s {
            guard ch == "#" else { break }
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        let rest = s.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        var text = String(rest).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (level, text.trimmingCharacters(in: .whitespaces))
    }

    /// `---` / `***` / `___`（允许中间带空格）
    private static func isRule(_ s: String) -> Bool {
        let marks = s.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `- 项` / `1. 项` / `1) 项`。`-foo` 这种没有空格的算正文，不是列表。
    private static func listItem(_ s: String) -> (ordered: Bool, number: Int, text: String)? {
        if let first = s.first, "-*+".contains(first) {
            let rest = s.dropFirst()
            guard rest.first == " " || rest.first == "\t" else { return nil }
            return (false, 0, String(rest).trimmingCharacters(in: .whitespaces))
        }
        var idx = s.startIndex
        var digits = 0
        while idx < s.endIndex, s[idx].isNumber, digits < 9 {
            idx = s.index(after: idx)
            digits += 1
        }
        guard digits > 0, idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
        let after = s.index(after: idx)
        guard after < s.endIndex, s[after] == " " || s[after] == "\t" else { return nil }
        let number = Int(s[s.startIndex..<idx]) ?? 1
        return (true, number, String(s[after...]).trimmingCharacters(in: .whitespaces))
    }

    /// 前导空格决定嵌套层级；tab 按 4 空格算
    private static func indentDepth(of line: String) -> Int {
        var columns = 0
        for ch in line {
            if ch == " " { columns += 1 }
            else if ch == "\t" { columns += 4 }
            else { break }
        }
        return min(columns / spacesPerLevel, maxDepth)
    }
}
