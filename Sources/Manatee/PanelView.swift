import SwiftUI
import AppKit

// 视觉规格来自 Open Design 的 A 方案「Instrument」：
// 340 宽，深色 #0C0C0D，等宽大数字，20 格温度刻度，单色线条图标，唯一强调色琥珀。

enum Theme {
    static let bg     = Color(red: 12/255,  green: 12/255,  blue: 13/255)   // #0C0C0D
    static let ink    = Color(red: 242/255, green: 242/255, blue: 239/255)  // #F2F2EF
    static let ink2   = Color(red: 150/255, green: 150/255, blue: 143/255)  // #96968F
    static let ink3   = Color(red: 216/255, green: 216/255, blue: 210/255)  // #D8D8D2
    static let accent = Color(red: 232/255, green: 162/255, blue: 48/255)   // #E8A230
    static let danger = Color(red: 217/255, green: 79/255,  blue: 61/255)   // #D94F3D
    static let track  = Color(red: 38/255,  green: 38/255,  blue: 42/255)   // #26262A
    static let line   = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.07)
}

/// 项目名的唯一来源：改名只改这里的 `name` / `slug`，
/// 窗口标题、菜单、提示、版权、链接、支持目录、bundle id 全部跟着变。
enum AppInfo {
    static let name = "Manatee"
    /// 用作 repo 名、brew cask 名、支持目录名（小写无空格）
    static let slug = "manatee"
    static let owner = "luogao"
    static let homepage = "https://manatee.rungundam.top"

    /// 旧名字。改名前的配置目录会被自动迁移过来，用户无感升级。
    static let legacyNames = ["HotPot"]

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static var repo: URL { URL(string: "https://github.com/\(owner)/\(slug)")! }
    static var releases: URL { repo.appendingPathComponent("releases") }
    static var copyright: String { "© 2026 \(name)" }
    static var appSupportDir: String { "Application Support/\(name)" }

    /// 支持目录的完整路径，第一次访问时顺手把旧目录搬过来
    static var supportPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let target = base.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) {
            for old in legacyNames {
                let src = base.appendingPathComponent(old)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.moveItem(at: src, to: target)
                    break
                }
            }
        }
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target.path
    }
}

enum PanelTab { case agents, ports }

struct PanelView: View {
    @ObservedObject var model: AppModel
    /// 离屏渲染时 ScrollView 会整块空白，--render 传 false 走普通 VStack
    var scrollable: Bool = true
    @State private var tab: PanelTab
    @State private var showIdle = false
    @State private var expandedPort: String?
    @State private var confirmingKill = false

    init(model: AppModel, scrollable: Bool = true,
         initialTab: PanelTab = .agents, initialPort: String? = nil) {
        self.model = model
        self.scrollable = scrollable
        _tab = State(initialValue: initialTab)
        _expandedPort = State(initialValue: initialPort)
    }

    private var isDanger: Bool { model.temperature >= 85 }
    private var accent: Color { isDanger ? Theme.danger : Theme.accent }

    var body: some View {
        VStack(spacing: 0) {
            header
            readout
            tabsBar
            listBody
            footer
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
        .frame(width: 340, height: 580)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
    }

    // MARK: 顶部状态 + 主按钮（固定）

    private var header: some View {
        HStack(spacing: 8) {
            let alerting = model.alertCount > 0
            Circle()
                .fill(alerting ? Theme.danger : accent)
                .frame(width: 5, height: 5)
            Text(alerting ? L10n.t("\(model.alertCount) 个持续满载", "\(model.alertCount) sustained") : model.level.label)
                .font(.system(size: 11))
                .tracking(0.6)
                .foregroundStyle((alerting || isDanger) ? Theme.danger : Theme.ink2)
            Spacer(minLength: 8)
            if model.cooled.isEmpty {
                OutlineButton(title: L10n.t("全部降温", "Cool all"), tint: accent) { model.coolAll() }
            } else {
                OutlineButton(title: L10n.t("恢复全速", "Restore"), tint: accent) { model.restoreAll() }
            }
        }
        .frame(height: 30)
    }

    // MARK: 温度读数（固定）

    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.temperature > 0 ? "\(Int(model.temperature.rounded()))" : "—")
                    .font(.system(size: 72, weight: .medium, design: .monospaced))
                    .tracking(-3.6)
                    .foregroundStyle(isDanger ? Theme.danger : Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                Text("°C")
                    .font(.system(size: 19, design: .monospaced))
                    .foregroundStyle(isDanger ? Theme.danger.opacity(0.7) : Theme.ink2)
            }
            .padding(.bottom, -4)

            Text(L10n.t("最热传感器", "hottest sensor") + " · " + (model.sensorName.isEmpty ? "—" : model.sensorName))
                .font(.system(size: 10, design: .monospaced))
                .tracking(0.2)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .padding(.top, 5)

            ScaleBar(celsius: model.temperature, color: accent)
                .padding(.top, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    // MARK: 分段切换

    private var tabsBar: some View {
        HStack(spacing: 22) {
            tabButton(.agents, label: L10n.t("Agent", "Agents"), count: model.sessions.count)
            tabButton(.ports, label: L10n.t("端口", "Ports"), count: model.devServices.count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func tabButton(_ t: PanelTab, label: String, count: Int) -> some View {
        let active = tab == t
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { tab = t }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                    .tracking(0.4)
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
                Text(String(count))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(active ? Theme.accent.opacity(0.9) : Theme.ink2.opacity(0.6))
            }
            .frame(height: 32)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(active ? Theme.accent : Color.clear).frame(height: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 可滚动区：agent 会话 + 端口

    @ViewBuilder
    private var listBody: some View {
        if scrollable {
            ScrollFade(space: "panelScroll", tint: Theme.bg) {
                listContent
            }
        } else {
            listContent
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch tab {
        case .agents: agentsList
        case .ports:  portsList
        }
    }

    /// 等待状态对到会话的结果。面板与菜单栏都从这里取，保证「⏸2」一定能看到两处标记。
    /// `waitingStatuses` 已由 `WaitingPolicy` 判过可见性（含靠进程存活保住的长等待），
    /// 这里必须把过期记录也纳入匹配，否则菜单栏的计数会比面板标记多。
    private var waitingJoin: AgentStatusJoin {
        AgentStatusJoiner.join(statuses: model.waitingStatuses, sessions: model.sessions,
                               includeStale: true)
    }

    /// 0% CPU 且没有任何忙的子进程 = 空闲（只是挂着没干活），默认不占列表位置。
    /// 正在等待的会话不算空闲：它虽然 CPU 是 0，但必须留在列表里。
    private func isIdle(_ s: AgentSession) -> Bool {
        waitingJoin.byRootPid[s.rootPid] == nil
            && !model.isCooled(s) && s.cpuPercent < 0.3 && s.busyChildren.isEmpty
    }

    private var idleCount: Int { model.sessions.filter { isIdle($0) }.count }

    private var visibleSessions: [AgentSession] {
        let filtered = showIdle ? model.sessions : model.sessions.filter { !isIdle($0) }
        let waiting = waitingJoin.byRootPid
        // 等待行排最前：菜单栏出现 ⏸ 时，一眼就能在面板里找到对应会话。
        // Swift 的 sorted 不保证稳定，用原下标兜底保持同组内原有 CPU 顺序。
        return filtered.enumerated().sorted { a, b in
            let aw = waiting[a.element.rootPid] != nil
            let bw = waiting[b.element.rootPid] != nil
            if aw != bw { return aw }
            return a.offset < b.offset
        }.map(\.element)
    }

    private var sessionsSection: some View {
        let join = waitingJoin
        let rows = visibleSessions
        let total = rows.count + join.unmatched.count
        return VStack(spacing: 0) {
            // 对不上进程的等待单独成行，绝不挂到任意一行上。
            // 少了这些行，菜单栏的计数就会比面板看到的标记多。
            ForEach(Array(join.unmatched.enumerated()), id: \.element.sessionID) { i, status in
                UnmatchedWaitingRow(status: status)
                if i < total - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.rootPid) { i, s in
                SessionRow(session: s,
                           cooled: model.isCooled(s),
                           alert: model.alerts[s.rootPid],
                           waiting: join.byRootPid[s.rootPid],
                           accent: accent,
                           action: { model.toggleCool(s) })
                if join.unmatched.count + i < total - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
            if idleCount > 0 {
                idleToggle
            }
        }
    }

    private var idleToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { showIdle.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showIdle ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(showIdle
                     ? L10n.t("收起 \(idleCount) 个空闲", "Hide \(idleCount) idle")
                     : L10n.t("还有 \(idleCount) 个空闲", "\(idleCount) idle"))
                    .font(.system(size: 9.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.ink2.opacity(0.7))
            .padding(.horizontal, 2)
            .frame(height: 26)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if !visibleSessions.isEmpty {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("当前没有 agent 在跑", "No agents running"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(L10n.t("Claude Code / Codex / Pi 一启动就会出现在这里", "They show up here as soon as you start one"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 2)
    }

    private var agentsList: some View {
        let hasUnmatchedWaiting = !waitingJoin.unmatched.isEmpty
        return VStack(spacing: 0) {
            if model.sessions.isEmpty && !hasUnmatchedWaiting {
                emptyState
            } else if visibleSessions.isEmpty && !hasUnmatchedWaiting {
                idleOnlyState
            } else {
                sessionsSection
            }
        }
        .padding(.top, 2)
    }

    private var idleOnlyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("没有 agent 在干活", "Nothing is cooking"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(L10n.t("\(idleCount) 个 agent 挂着但 CPU 是 0", "\(idleCount) agents alive, all at 0%"))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink2)
            Button {
                withAnimation(.easeOut(duration: 0.14)) { showIdle = true }
            } label: {
                Text(L10n.t("显示它们", "Show them"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 30)
        .padding(.horizontal, 2)
    }

    // MARK: 端口列表

    private var portsList: some View {
        VStack(spacing: 0) {
            if model.devServices.isEmpty {
                emptyPorts
            } else {
                ForEach(Array(model.devServices.enumerated()), id: \.element.id) { i, s in
                    portRow(s, first: i == 0)
                }
                if model.devServices.contains(where: { $0.stray }) {
                    HStack {
                        Spacer(minLength: 0)
                        Button(L10n.t("关闭残留服务", "Kill stray")) { confirmingKill = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 2)
                }
            }
        }
        .padding(.top, 2)
        .alert(L10n.t("关闭残留的开发服务？", "Kill stray dev services?"), isPresented: $confirmingKill) {
            Button(L10n.t("关闭进程", "Kill processes"), role: .destructive) { model.killDevServices() }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(model.devServices.filter(\.stray).map { ":\($0.port) \($0.command)" }.joined(separator: "、"))
        }
    }

    private func portRow(_ s: DevService, first: Bool) -> some View {
        let open = expandedPort == s.id
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expandedPort = open ? nil : s.id }
            } label: {
                HStack(spacing: 8) {
                    Text(":" + String(s.port))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 48, alignment: .leading)
                    Text(s.command)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                    Spacer(minLength: 4)
                    if let p = s.purpose, !p.isEmpty {
                        Text(p)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.ink2.opacity(0.72))
                            .lineLimit(1)
                            .padding(.trailing, 2)
                    }
                    Text(s.uptimeText)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.ink2.opacity(0.65))
                    if s.stray {
                        Text(L10n.t("残留", "stray"))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(Theme.ink2.opacity(0.45))
                        .frame(width: 9)
                }
                .padding(.horizontal, 2)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open { portDetail(s) }
        }
        .overlay(alignment: .top) {
            if !first {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }

    private func portDetail(_ s: DevService) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !s.cwd.isEmpty {
                detailLine(L10n.t("目录", "dir"), s.shortDir)
            }
            if !s.argv.isEmpty {
                detailLine(L10n.t("命令", "cmd"), shorten(s.argv, 120))
            }
            detailLine(L10n.t("进程", "pid"),
                       "PID \(s.pid) · " + L10n.t("父", "parent") + " " +
                       (s.parentName.isEmpty ? "launchd" : "\(s.parentName) (\(s.parentPid))"))
            if !s.bind.isEmpty {
                detailLine(L10n.t("监听", "bind"), "\(s.bind):\(s.port)")
            }
        }
        .padding(.leading, 58)
        .padding(.trailing, 4)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(key)
                .font(.system(size: 9))
                .foregroundStyle(Theme.ink2.opacity(0.5))
                .frame(width: 24, alignment: .leading)
            Text(value)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func shorten(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    private var emptyPorts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("没有开发服务在占端口", "No dev servers listening"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(L10n.t("node / vite / python 起来后会出现在这里", "They show up once node, vite or python starts"))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 36)
        .padding(.horizontal, 2)
    }

    // MARK: 底部（固定）

    private var footer: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Theme.line).frame(height: 1)

            // 第一行只留「运行状态 + 操作」，版本和版权下沉到第二行，别和齿轮挤在一起
            HStack(spacing: 10) {
                Text(L10n.t("\(model.processCount) 进程 · \(model.cooled.count) 已降温",
                            "\(model.processCount) procs · \(model.cooled.count) cooled"))
                    .font(.system(size: 10, design: .monospaced))
                    .tracking(0.2)
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 0)
                UpdateBanner()
                Button {
                    NotificationCenter.default.post(name: .hotPotOpenDashboard, object: nil)
                } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink2.opacity(0.8))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("资源看板", "Dashboard"))
                SettingsButton()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink2.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(L10n.t("退出 \(AppInfo.name)", "Quit \(AppInfo.name)"))
            }
            .frame(height: 18)
            .padding(.top, 4)

            HStack(spacing: 6) {
                LinkText(title: "v" + AppInfo.version, url: AppInfo.releases, size: 9)
                Text("·").font(.system(size: 9)).foregroundStyle(Theme.ink2.opacity(0.4))
                LinkText(title: "GitHub", url: AppInfo.repo, size: 9)
                Text("·").font(.system(size: 9)).foregroundStyle(Theme.ink2.opacity(0.4))
                Text(AppInfo.copyright)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.ink2.opacity(0.65))
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 可点文字链

struct LinkText: View {
    let title: String
    let url: URL
    var size: CGFloat = 9
    @State private var hover = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text(title)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(hover ? Theme.accent : Theme.ink2.opacity(0.75))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 刻度

/// 20 格温度刻度：30–100°C 线性映射（与设计稿一致）
struct ScaleBar: View {
    let celsius: Double
    let color: Color
    private let count = 20

    private var lit: Int {
        guard celsius > 0 else { return 0 }
        let ratio = (celsius - 30) / 70
        return max(0, min(count, Int((ratio * Double(count)).rounded())))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? color : Theme.track)
                    .frame(maxWidth: .infinity)
                    .frame(height: 10)
            }
        }
        .frame(height: 10)
    }
}

// MARK: - 会话行

struct SessionRow: View {
    let session: AgentSession
    let cooled: Bool
    /// 连续满载已持续的秒数（未达阈值时 nil）
    let alert: TimeInterval?
    /// 这一行对应的等待状态（对不上时为 nil，由 UnmatchedWaitingRow 单独显示）
    let waiting: AgentStatus?
    let accent: Color
    let action: () -> Void

    @State private var hover = false
    @State private var btnHover = false
    @State private var expanded = false

    private var alerting: Bool { alert != nil && !cooled }

    private var subtitle: String {
        if session.hasOtherUid { return L10n.t("root 进程 · 无法降温", "root process · cannot cool") }
        if cooled { return L10n.t("已降到能效核 · 任务继续跑", "On efficiency cores · still running") }
        if let alert { return L10n.t("连续满载 \(Self.duration(alert))", "Sustained \(Self.duration(alert))") }
        let n = session.pids.count
        return L10n.t("\(session.summary) · \(n) 进程",
                      "\(session.summary) · \(n) " + (n == 1 ? "proc" : "procs"))
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return L10n.isChinese ? (m > 0 ? "\(m) 分 \(sec) 秒" : "\(sec) 秒") : (m > 0 ? "\(m)m \(sec)s" : "\(sec)s")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded { detail }
        }
        // 预警用左侧竖条标记，不用整块底色：底块会读成「卡片」，和面板的无卡片语言冲突
        .overlay(alignment: .leading) {
            if alerting {
                Rectangle()
                    .fill(Theme.danger)
                    .frame(width: 2)
                    .offset(x: -9)
            }
        }
        .opacity(session.hasOtherUid ? 0.55 : 1)
    }

    private var mainRow: some View {
        HStack(spacing: 9) {
            AgentIcon(id: session.def.id, symbol: session.def.symbol, size: 15,
                      dim: !cooled && session.cpuPercent < 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.def.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let waiting, let badge = AgentStatusBadge.make(for: waiting) {
                        StatusBadgeView(badge: badge).fixedSize()
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(alerting ? Theme.danger.opacity(0.9) : Theme.ink2)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(String(format: "%.0f%%", session.cpuPercent))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(alerting ? Theme.danger : Theme.ink3)
                .frame(width: 48, alignment: .trailing)

            // 降温按钮：默认就给一个淡底和描边，让人看出这里能点
            Button(action: action) {
                Image(systemName: "snowflake")
                    .font(.system(size: 11.5))
                    .foregroundStyle(cooled || btnHover ? accent : Theme.ink2)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(cooled ? accent.opacity(0.14)
                                  : (btnHover ? accent.opacity(0.12) : Color.white.opacity(0.05)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(cooled ? accent.opacity(0.45) : Color.white.opacity(0.10), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(session.hasOtherUid)
            .onHover { btnHover = $0 }
            .help(session.hasOtherUid
                  ? L10n.t("root 进程无法降温", "root process cannot be cooled")
                  : (cooled ? L10n.t("恢复全速", "Restore full speed")
                            : L10n.t("降到能效核，不中断任务", "Move to efficiency cores, keep running")))

            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.ink2.opacity(hover || expanded ? 0.9 : 0.35))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 8)
                .animation(.easeOut(duration: 0.15), value: expanded)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hover ? Color.white.opacity(0.035) : Color.clear)
                .padding(.horizontal, -6)
        )
        .onHover { hover = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
        }
    }

    // MARK: 展开明细

    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if session.busyChildren.isEmpty {
                Text(L10n.t("没有活跃的子进程", "no active subprocesses"))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.ink2.opacity(0.8))
            } else {
                ForEach(Array(session.busyChildren.prefix(6).enumerated()), id: \.offset) { _, kid in
                    HStack(spacing: 8) {
                        Text(kid.name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(String(format: "%.0f%%", kid.cpu))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.ink2)
                    }
                }
            }
            Divider().overlay(Theme.line).padding(.vertical, 1)
            Text(L10n.t("根 PID \(session.rootPid) · 共 \(session.pids.count) 个进程",
                        "root pid \(session.rootPid) · \(session.pids.count) processes"))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.ink2.opacity(0.75))
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .padding(.bottom, 11)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - 等待徽标

/// 行内小徽标。只表达状态，不展开任何命令内容（payload 里也没有）。
struct StatusBadgeView: View {
    let badge: AgentStatusBadge

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: badge == .running ? "play.fill"
                  : (badge == .error ? "exclamationmark" : "pause.fill"))
                .font(.system(size: 6, weight: .bold))
            Text(badge.label)
                .font(.system(size: 8.5, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(badge == .error ? Theme.danger : Theme.accent)
        .padding(.horizontal, 4)
        .frame(height: 15)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill((badge == .error ? Theme.danger : Theme.accent).opacity(0.13))
        )
    }
}

/// 菜单栏有 ⏸，但进程表里找不到对应会话时的那一行。
/// 宁可单独列出来，也不把徽标挂到别的 agent 上。
struct UnmatchedWaitingRow: View {
    let status: AgentStatus

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "pause.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 15)
            Text(WaitingFallback.text(agent: status.agent, cwd: status.cwd))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 6)
    }
}

// MARK: - 菜单栏预览（仅 --render 截图用）

/// 把真实的 `MenuBarLabel` 文案画成一条菜单栏，垫在面板上方。
/// 只用于 `--render --waiting` 出验收图：面板本身看不到菜单栏，
/// 没有这一条就没法用一张图证明 `⏸` 在温度数字后面。产品运行时不用。
struct MenuBarPreview: View {
    let temperature: Double
    let waitingCount: Int
    let level: HeatLevel

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if temperature > 0 {
                Circle()
                    .fill(Color(nsColor: level.menuColor))
                    .frame(width: 6, height: 6)
            }
            Text(MenuBarLabel.make(temperature: temperature, waitingCount: waitingCount))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.92))
        }
        .padding(.trailing, 16)
        .frame(width: 340, height: 30)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
    }
}

// MARK: - 描边按钮

/// 面板里的设置入口。面板本身拿不到 AppDelegate，用通知让上层开窗口。
struct SettingsButton: View {
    @State private var hover = false
    var body: some View {
        Button {
            NotificationCenter.default.post(name: .hotPotOpenSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10.5))
                .foregroundStyle(hover ? Theme.ink : Theme.ink2.opacity(0.8))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L10n.t("设置", "Settings"))
    }
}

extension Notification.Name {
    static let hotPotOpenDashboard = Notification.Name("hotPotOpenDashboard")
    static let hotPotOpenSettings = Notification.Name("hotpot.openSettings")
}

struct OutlineButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(hover ? Theme.bg : tint)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(hover ? tint : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
