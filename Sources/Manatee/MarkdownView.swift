import SwiftUI
import AppKit

/// 把解析好的块画成设置页排版。只负责「怎么画」，不碰解析（解析在 MarkdownBlocks.swift）。
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                row(for: block, first: i == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Theme.accent)
        // 链接统一走浏览器：设置窗口在面板/app 里都能点，不依赖系统默认的响应链
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder
    private func row(for block: MarkdownBlock, first: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text, size: headingSize(level)))
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(level <= 2 ? Theme.ink : Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, first ? 0 : (level <= 2 ? 10 : 6))

        case .paragraph(let text):
            Text(inline(text, size: 11))
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink2)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(["•", "◦", "▪"][depth % 3])
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3.opacity(0.55))
                Text(inline(text, size: 11))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .ordered(let depth, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.ink3.opacity(0.55))
                    .frame(minWidth: 14, alignment: .trailing)
                Text(inline(text, size: 11))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .code(_, let code):
            // 语言标记不显示，代码本身等宽、不参与行内解析
            Text(code)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.045)))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .textSelection(.enabled)
                .padding(.vertical, 2)

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                Rectangle()
                    .fill(Theme.accent.opacity(0.4))
                    .frame(width: 2)
                Text(inline(text, size: 11))
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 14
        case 2: return 12.5
        case 3: return 11.5
        default: return 11
        }
    }

    /// 行内代码在 SwiftUI 里不会自动变等宽，逐段补字体；其余（粗体/斜体/链接）
    /// 由 markdown 的 presentationIntent 交给 Text 处理。
    private func inline(_ text: AttributedString, size: CGFloat) -> AttributedString {
        var out = text
        let codeRanges = out.runs.compactMap { run -> Range<AttributedString.Index>? in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            out[range].font = .system(size: size - 0.5, design: .monospaced)
        }
        return out
    }
}

/// 检查更新里展示的 release notes：内容超过固定高度就在这个框里滚动，
/// 免得一份长备注把设置页撑到几千像素。
struct ReleaseNotesView: View {
    let notes: String
    /// 截图/长图模式（`--render --settings --snapshot`）关掉内层滚动：
    /// 离屏渲染 ScrollView 会整块空白，长图本身也不需要再滚。
    var scrollable: Bool = true

    /// 固定高度。理由：设置页本身在 ScrollFade 的外层 ScrollView 里，
    /// 这里再放一块不限高的内容会让外层滚动条失真；超过这个高度才开内层滚动。
    private static let maxHeight: CGFloat = 236

    @State private var contentHeight: CGFloat?

    var body: some View {
        let doc = MarkdownDocument.parse(notes)
        // 还没量到高度时按「溢出」处理：先封顶，避免长备注在首帧把整页撑开再回弹
        let overflows = (contentHeight ?? .greatestFiniteMagnitude) > Self.maxHeight
        Group {
            if scrollable && overflows {
                ScrollFade(space: "updateNotesScroll", tint: Theme.bg, bottomInset: 6) {
                    content(doc)
                }
                .frame(height: Self.maxHeight)
            } else {
                content(doc)
            }
        }
        .onPreferenceChange(NotesHeightKey.self) { h in
            if contentHeight.map({ abs(h - $0) > 0.5 }) ?? true { contentHeight = h }
        }
    }

    @ViewBuilder
    private func content(_ doc: MarkdownDocument) -> some View {
        Group {
            if doc.blocks.isEmpty {
                // 解析不出任何块（全空白或纯怪字符）时退回纯文本，绝不显示一块空白
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownText(blocks: doc.blocks)
            }
        }
        // 量的是内容自然高度：fixedSize 让它不受外层 frame 压缩，溢出判定才准
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: NotesHeightKey.self, value: g.size.height)
            }
        )
    }
}

private struct NotesHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
