import SwiftUI
import AppKit
import ServiceManagement

/// C 方案「三栏参数台」：左栏导航 + 右侧参数区，深色，和主面板同源。
/// 640 × 760（内容区）：字号按桌面阅读距离放大，左栏三项可点、跳转到对应分区。
struct SettingsView: View {
    @ObservedObject private var lang = LangStore.shared
    @State private var rules: Rules
    @State private var launchAtLogin: Bool
    @State private var dirty = false
    @State private var selected = 1

    private let onClose: () -> Void
    private let scrollable: Bool
    @State private var showUninstalled = false

    init(onClose: @escaping () -> Void, scrollable: Bool = true) {
        _rules = State(initialValue: Rules.shared)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
        self.onClose = onClose
        self.scrollable = scrollable
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    rail(proxy)
                    mainScroll(proxy)
                }
                .frame(width: 640, height: max(120, windowHeight - 34), alignment: .top)
                .clipped()
                footer
            }
        }
        .frame(width: 640, height: windowHeight)
        .background(Theme.bg)
    }

    /// 默认 760；截图/长图模式可传入更大的高度，把下面几个分区一起出图。
    private var windowHeight: CGFloat {
        let h = CGFloat(UserDefaults.standard.double(forKey: "render.windowHeight"))
        return h > 200 ? h : 760
    }

    // MARK: - 左栏（可点跳转）

    private func rail(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(AppInfo.name.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(Theme.ink3.opacity(0.75))
            Text(L10n.t("设置", "Settings"))
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2)
                .padding(.top, 4)

            VStack(spacing: 0) {
                RailItem(n: "01", label: L10n.t("通用", "General"), count: "1",
                         selected: selected == 1) {
                    selected = 1
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(1, anchor: .top) }
                }
                RailItem(n: "02", label: L10n.t("预警", "Alerts"), count: "2",
                         selected: selected == 2) {
                    selected = 2
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(2, anchor: .top) }
                }
                RailItem(n: "03", label: "Agent", count: "\(rules.agents.count)",
                         selected: selected == 3) {
                    selected = 3
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(3, anchor: .top) }
                }
                RailItem(n: "04", label: L10n.t("版本", "Version"), count: "",
                         selected: selected == 4, isLast: true) {
                    selected = 4
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(4, anchor: .top) }
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                RailLink(title: L10n.t("打开规则文件", "Open rules file")) {
                    NSWorkspace.shared.open(Rules.path)
                }
                RailLink(title: L10n.t("恢复默认", "Reset defaults")) {
                    rules = .default
                    dirty = true
                }
                Button {
                    save()
                } label: {
                    Text(dirty ? L10n.t("保存并重启", "Save & restart") : L10n.t("保存", "Save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 21/255, green: 14/255, blue: 4/255))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 14, bottom: 26, trailing: 14))
        .frame(width: 152, height: 726, alignment: .topLeading)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
        }
    }

    // MARK: - 右侧滚动区

    @ViewBuilder
    private func mainScroll(_ proxy: ScrollViewProxy) -> some View {
        if scrollable {
            ScrollFade(space: "settingsScroll", tint: Theme.bg, bottomInset: 24) {
                sections
                    .padding(EdgeInsets(top: 20, leading: 24, bottom: 0, trailing: 24))
            }
        } else {
            sections
                .padding(EdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 22) {
            generalSection.id(1)
            alertSection.id(2)
            agentsSection.id(3)
            UpdateSection(scrollable: scrollable).id(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 01 通用

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(n: "01", title: L10n.t("通用", "General"))
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("开机自启", "Launch at login"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                    Text(L10n.t("登录后自动驻留菜单栏", "Stay in the menu bar after login"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
                PillToggle(on: Binding(
                    get: { launchAtLogin },
                    set: { applyLaunchAtLogin($0) }
                ))
            }
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("语言", "Language"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                    Text(L10n.t("界面文案语言，重启后窗口尺寸自适应", "Interface language. Restart to resize windows."))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
                LangPicker()
            }
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
        }
    }

    // MARK: - 02 预警

    private var alertSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(n: "02", title: L10n.t("异常预警", "Alerts"))
            Text(L10n.t("agent 持续超过阈值时，面板顶部标红并显示已持续多久。",
                        "When an agent stays above the threshold, the panel flags it."))
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.bottom, 6)

            StepperRow(label: L10n.t("CPU 阈值", "CPU threshold"),
                       value: "\(Int(rules.alert.cpuPercent))",
                       unit: "%",
                       dec: { bumpCPU(-50) },
                       inc: { bumpCPU(+50) })

            StepperRow(label: L10n.t("持续时长", "Sustained for"),
                       value: "\(Int(rules.alert.sustainSeconds / 60))",
                       unit: L10n.t("分钟", "min"),
                       dec: { bumpSustain(-1) },
                       inc: { bumpSustain(+1) })
        }
    }

    private func bumpCPU(_ delta: Double) {
        rules.alert.cpuPercent = min(800, max(100, rules.alert.cpuPercent + delta))
        dirty = true
    }

    private func bumpSustain(_ delta: Double) {
        rules.alert.sustainSeconds = min(900, max(60, rules.alert.sustainSeconds + delta * 60))
        dirty = true
    }

    // MARK: - 03 Agent

    /// 已安装的排在前面；未安装的默认折叠，别占着列表位
    private var visibleAgentIndices: [(idx: Int, installed: Bool)] {
        rules.agents.enumerated()
            .map { (idx: $0.offset, installed: isInstalled($0.element)) }
            .filter { showUninstalled || $0.installed }
            .sorted { a, b in
                if a.installed != b.installed { return a.installed && !b.installed }
                return a.idx < b.idx
            }
    }

    private var uninstalledCount: Int {
        rules.agents.filter { !isInstalled($0) }.count
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(n: "03", title: L10n.t("识别的 Agent", "Detected agents"),
                        trailing: L10n.t("\(installedCount) 已安装", "\(installedCount) installed"))
            ForEach(Array(visibleAgentIndices.enumerated()), id: \.element.idx) { pos, item in
                agentRow(idx: item.idx, agent: $rules.agents[item.idx],
                         installed: item.installed, first: pos == 0)
            }
            if uninstalledCount > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { showUninstalled.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showUninstalled ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                        Text(showUninstalled
                             ? L10n.t("收起 \(uninstalledCount) 个未安装", "Hide \(uninstalledCount) not installed")
                             : L10n.t("还有 \(uninstalledCount) 个未安装", "\(uninstalledCount) not installed"))
                            .font(.system(size: 10.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.ink2.opacity(0.6))
                    .frame(height: 34)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func agentRow(idx: Int, agent: Binding<AgentRule>,
                          installed: Bool, first: Bool) -> some View {
        let rule = agent.wrappedValue
        return HStack(spacing: 12) {
            HStack(spacing: 9) {
                AgentIcon(id: rule.id, symbol: rule.symbol ?? "circle.dashed", size: 15,
                          dim: !(rule.enabled ?? true))
                Text(rule.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle((rule.enabled ?? true) ? Theme.ink : Theme.ink2.opacity(0.8))
                    .lineLimit(1)
                if !installed {
                    Text(L10n.t("未安装", "not installed"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.ink2.opacity(0.45))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Theme.ink2.opacity(0.2), lineWidth: 1)
                        )
                }
            }
            Spacer(minLength: 0)
            Text((rule.enabled ?? true) ? "ON" : "OFF")
                .font(.system(size: 10, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle((rule.enabled ?? true) ? Theme.ink3 : Theme.ink2)
                .frame(width: 44, alignment: .trailing)
            PillToggle(on: Binding(
                get: { agent.wrappedValue.enabled ?? true },
                set: { agent.wrappedValue.enabled = $0; dirty = true }
            ))
        }
        .frame(height: 34)
        .opacity(installed ? 1 : 0.72)
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
        }
    }

    private var installedCount: Int {
        rules.agents.filter(isInstalled).count
    }

    private func isInstalled(_ rule: AgentRule) -> Bool {
        let paths = (rule.detect ?? []).map { ($0 as NSString).expandingTildeInPath }
        // 没写 detect 的老规则：无法判断，按已安装处理，别把它误标成「未安装」
        if paths.isEmpty { return true }
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 8) {
            Text(AppInfo.copyright)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink2.opacity(0.6))
            Spacer(minLength: 0)
            LinkText(title: "v" + AppInfo.version, url: AppInfo.releases, size: 10)
            Text("·").font(.system(size: 10)).foregroundStyle(Theme.ink2.opacity(0.4))
            LinkText(title: "github.com/\(AppInfo.owner)/\(AppInfo.slug)", url: AppInfo.repo, size: 10)
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
        }
    }

    // MARK: - 动作

    private func save() {
        guard dirty else { onClose(); return }
        Rules.shared = rules
        rules.save()
        relaunch()
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            // 失败就回滚开关，别显示一个不成立的状态
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let alert = NSAlert()
            alert.messageText = L10n.t("设置开机自启失败", "Could not change login item")
            alert.informativeText = L10n.t(
                "把 \(AppInfo.name) 拖进 /Applications 再试。\n\(error.localizedDescription)",
                "Move \(AppInfo.name) into /Applications and try again.\n\(error.localizedDescription)")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 组件

private struct RailItem: View {
    let n: String
    let label: String
    let count: String
    let selected: Bool
    var isLast: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(n)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.accent.opacity(selected ? 1 : 0.7))
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink3)
                Spacer(minLength: 0)
                Text(count)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 7)
            .frame(height: 42)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? Color.white.opacity(0.06)
                          : (hover ? Color.white.opacity(0.03) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            if isLast {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            }
        }
    }
}

private struct RailLink: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(hover ? Theme.ink : Theme.ink2)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SectionHead: View {
    let n: String
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 7) {
            Text(n)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 11.5))
                .tracking(0.9)
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .frame(height: 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
        }
    }
}

private struct StepperRow: View {
    let label: String
    let value: String
    let unit: String
    let dec: () -> Void
    let inc: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Text(unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(width: 84, alignment: .trailing)

            // 两个按钮合成一组，中间一条分隔线：命中区 28×28，比图标本身大
            HStack(spacing: 0) {
                StepButton(symbol: "minus", action: dec)
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18)
                StepButton(symbol: "plus", action: inc)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
        }
        .frame(height: 64)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }
}

private struct StepButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Theme.accent : Theme.ink2)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hover ? Color.white.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 34×18 胶囊开关：ON 时琥珀描边 + 淡填充 + 圆钮右移
struct PillToggle: View {
    @Binding var on: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { on.toggle() }
        } label: {
            Capsule()
                .fill(on ? Theme.accent.opacity(0.16) : Color.clear)
                .overlay(
                    Capsule().stroke(on ? Theme.accent.opacity(0.55) : Color.white.opacity(0.18),
                                     lineWidth: 1)
                )
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(on ? Theme.accent : Color.white.opacity(0.35))
                        .frame(width: 12, height: 12)
                        .padding(2)
                }
                .frame(width: 34, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 窗口

/// 语言选择：三段胶囊，和整体风格一致（不用原生 Picker，避免系统灰底）
private struct LangPicker: View {
    @ObservedObject private var store = LangStore.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppLang.allCases) { lang in
                let on = store.current == lang
                Button {
                    store.current = lang
                } label: {
                    Text(lang == .system ? L10n.t("自动", "Auto") : lang.shortLabel)
                        .font(.system(size: 11, weight: on ? .medium : .regular))
                        .foregroundStyle(on ? Theme.accent : Theme.ink2)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? Theme.accent.opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        // 窗口复用会让 @State 留着上次没保存的改动，看起来像「自己保存了」。
        // 每次打开都重建 rootView，回到磁盘上的真实状态。
        if let w = window {
            if let host = w.contentViewController as? NSHostingController<SettingsView> {
                host.rootView = SettingsView(onClose: { [weak self] in self?.window?.close() })
            }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(onClose: { [weak self] in
            self?.window?.close()
        }))
        let w = NSWindow(contentViewController: hosting)
        w.title = L10n.t("\(AppInfo.name) 设置", "\(AppInfo.name) Settings")
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(red: 12/255, green: 12/255, blue: 13/255, alpha: 1)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
