import Foundation
import Testing
@testable import Manatee

/// 解析层单测：release notes 的 markdown 必须切成正确的块，行内样式落在 run 上。
/// 这些断言不建视图，所以 Core 不依赖 SwiftUI 的规矩仍然成立。

private func blocks(_ md: String) -> [MarkdownBlock] {
    MarkdownDocument.parse(md).blocks
}

private func paragraphText(_ md: String) -> String {
    blocks(md).first?.plainText ?? ""
}

@Suite("release notes markdown 解析")
struct MarkdownBlocksTests {

    @Test("## 与 ### 分别解析成 2、3 级标题")
    func 标题层级() {
        let b = blocks("## 新增\n### 细节")
        #expect(b.count == 2)
        guard case .heading(let l1, let t1) = b[0],
              case .heading(let l2, let t2) = b[1] else {
            Issue.record("不是两个标题块：\(b)")
            return
        }
        #expect(l1 == 2)
        #expect(String(t1.characters) == "新增")
        #expect(l2 == 3)
        #expect(String(t2.characters) == "细节")
    }

    @Test("结尾的闭合 ### 被吃掉，不留在标题文字里")
    func 标题闭合标记() {
        guard case .heading(let level, let text) = blocks("## 标题 ##").first else {
            Issue.record("没解析成标题")
            return
        }
        #expect(level == 2)
        #expect(String(text.characters) == "标题")
    }

    @Test("无序列表：每项一块，缩进决定嵌套层级")
    func 无序列表与嵌套() {
        let b = blocks("- 甲\n- 乙\n  - 丙")
        #expect(b.count == 3)
        guard case .bullet(let d0, let t0) = b[0],
              case .bullet(let d1, let t1) = b[1],
              case .bullet(let d2, let t2) = b[2] else {
            Issue.record("不是三个列表块：\(b)")
            return
        }
        #expect(d0 == 0 && String(t0.characters) == "甲")
        #expect(d1 == 0 && String(t1.characters) == "乙")
        #expect(d2 == 1 && String(t2.characters) == "丙")
    }

    @Test("有序列表保留原始序号")
    func 有序列表() {
        let b = blocks("1. 甲\n2. 乙")
        #expect(b.count == 2)
        guard case .ordered(let d0, let n0, let t0) = b[0],
              case .ordered(let d1, let n1, let t1) = b[1] else {
            Issue.record("不是有序列表块：\(b)")
            return
        }
        #expect(d0 == 0 && n0 == 1 && String(t0.characters) == "甲")
        #expect(d1 == 0 && n1 == 2 && String(t1.characters) == "乙")
    }

    @Test("粗体与行内代码落在 run 的 presentationIntent 上")
    func 粗体与行内代码() {
        let text: AttributedString
        guard case .paragraph(let t) = blocks("这是 **粗体** 和 `代码`").first else {
            Issue.record("没解析成段落")
            return
        }
        text = t
        #expect(String(text.characters) == "这是 粗体 和 代码")

        let strong = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                && String(text[run.range].characters) == "粗体"
        }
        #expect(strong, "粗体片段缺少 stronglyEmphasized")

        let code = text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
                && String(text[run.range].characters) == "代码"
        }
        #expect(code, "行内代码片段缺少 code intent")
    }

    @Test("代码块：多行原样保留，语言标记单独存，块内不再做行内解析")
    func 代码块() {
        let md = """
        ```json
        "a": { "b": 1 }
        ## 这行不是标题
        ```
        """
        let b = blocks(md)
        #expect(b.count == 1)
        guard case .code(let lang, let code) = b[0] else {
            Issue.record("不是代码块：\(b)")
            return
        }
        #expect(lang == "json")
        #expect(code == "\"a\": { \"b\": 1 }\n## 这行不是标题")
    }

    @Test("链接解析成带 URL 的 run，文字不变")
    func 链接() {
        guard case .paragraph(let text) = blocks("见 [发布页](https://example.com/r)").first else {
            Issue.record("没解析成段落")
            return
        }
        #expect(String(text.characters) == "见 发布页")
        let link = text.runs.first { $0.link != nil }
        #expect(link?.link?.absoluteString == "https://example.com/r")
        if let link {
            #expect(String(text[link.range].characters) == "发布页")
        }
    }

    @Test("空字符串与全空白：不出块，也不崩")
    func 空输入() {
        #expect(blocks("").isEmpty)
        #expect(blocks("   \n\n \t\n").isEmpty)
        #expect(MarkdownDocument.parse("").blocks.isEmpty)
    }

    @Test("没有标记的纯文本当成一个段落")
    func 纯文本() {
        let b = blocks("只是一句话，没有标记")
        #expect(b.count == 1)
        guard case .paragraph(let t) = b[0] else {
            Issue.record("不是段落：\(b)")
            return
        }
        #expect(String(t.characters) == "只是一句话，没有标记")
    }

    @Test("多行连续文本合成一个段落，换行保留")
    func 多行段落() {
        #expect(paragraphText("第一行\n第二行") == "第一行\n第二行")
    }

    @Test("引用块：连续的 > 合成一块")
    func 引用块() {
        let b = blocks("> 引用一\n> 引用二")
        #expect(b.count == 1)
        guard case .quote(let t) = b[0] else {
            Issue.record("不是引用块：\(b)")
            return
        }
        #expect(String(t.characters) == "引用一\n引用二")
    }

    @Test("分隔线识别成 rule，不当成列表")
    func 分隔线() {
        #expect(blocks("---") == [.rule])
        #expect(blocks("***") == [.rule])
    }

    @Test("未闭合的代码块：内容照样出块，不丢字")
    func 未闭合代码块() {
        let b = blocks("```swift\nlet a = 1")
        #expect(b.count == 1)
        guard case .code(let lang, let code) = b[0] else {
            Issue.record("不是代码块：\(b)")
            return
        }
        #expect(lang == "swift")
        #expect(code == "let a = 1")
    }

    @Test("畸形 markdown 回退成纯文本，字符一个不少")
    func 畸形输入回退() {
        // 未闭合的粗体在 Foundation 里可能被部分解析；无论如何文字不能丢
        #expect(paragraphText("**未闭合").contains("未闭合"))
        #expect(paragraphText("`未闭合").contains("未闭合"))
    }

    @Test("v0.8.0 真实备注：看不到裸标记，两个代码块都在")
    func 真实备注() {
        let b = blocks(DebugFixtures.releaseNotesV080)
        #expect(b.count >= 12)

        // 标题有层级：一级标题（##）存在
        let headings = b.compactMap { block -> Int? in
            if case .heading(let level, _) = block { return level }
            return nil
        }
        #expect(headings.contains(2))
        #expect(headings.contains(3))

        // 代码块 2 段：json 与 bash，语言标记都拿到了
        let langs = b.compactMap { block -> String? in
            if case .code(let lang, _) = block { return lang }
            return nil
        }
        #expect(langs == ["json", "bash"])

        // 任何块的可读文字里都不该残留 markdown 符号
        for block in b {
            let text = block.plainText
            #expect(!text.contains("##"))
            #expect(!text.contains("```"))
            #expect(!text.hasPrefix("- "))
            #expect(!text.contains("**"))
        }
    }
}
