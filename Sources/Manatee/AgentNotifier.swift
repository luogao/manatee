import Foundation
import UserNotifications

// MARK: - 规划层（纯函数，能脱离 UI 单测）

/// 一条待投递的本地通知。
///
/// 只允许装三样东西：agent 名、cwd 最后一级目录、固定标签。
/// payload 里的 `last_assistant_message` / `background_tasks[].command` /
/// `transcript_path` 是隐私红线（PRD 5.5），所以这里连字段都不留，
/// 防止以后有人为了「更详细」顺手把原文透传出去。
struct PlannedNotification: Equatable, Sendable {
    let sessionID: String
    let title: String
    let subtitle: String?
    let body: String
}

/// 一次 tick 的规划结果。
///
/// 除了要投递的通知，还把下一 tick 需要的状态一起带回来：规划保持纯函数，
/// 同样的输入永远得到同样的输出，不读写任何全局状态，测试不需要模拟时钟。
struct NotificationPlan: Equatable, Sendable {
    let notifications: [PlannedNotification]
    /// 下一 tick 判断「上一轮是否已在等待」用的集合。
    let waiting: Set<String>
    /// 下一 tick 的冷却表：sessionID → 最近一次真正产生通知的时刻。
    let cooldowns: [String: Date]
}

enum NotificationPlanner {

    /// PRD 5.5：同一会话 5 分钟内不重复。
    /// 实测 `Stop` 之后约 60s 必来一条 `idle_prompt`，冷却必须把它吃掉，
    /// 否则一次「完成」会弹两条通知。
    static let cooldown: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - previousWaiting: 上一 tick 处于等待的 sessionID 集合。
    ///   - statuses: 这一 tick 扫描到的全部状态（不只等待）。
    ///   - cooldowns: 上一 tick 返回的冷却表。
    ///   - agentNames: 规则 id → 展示名（如 `claude` → `Claude Code`）。
    ///     由调用方注入而不是直接读 `AgentRegistry`，这样单测不会碰用户目录里的 rules.json。
    static func plan(previousWaiting: Set<String>,
                     statuses: [AgentStatus],
                     cooldowns: [String: Date],
                     now: Date,
                     agentNames: [String: String] = [:]) -> NotificationPlan {
        // stale / idle / running / error 一律不产生通知。AppModel 也过滤过一次，
        // 这里是纯函数自己的约束：别依赖调用方已经过滤干净。
        let waitingStatuses = statuses.filter { $0.state == .waiting && !$0.isStale }
        let waiting = Set(waitingStatuses.map(\.sessionID))

        // 过期冷却顺手清掉，表不会随运行时长无限长（24h 后每个 session 一条是上限）
        var nextCooldowns = cooldowns.filter { now.timeIntervalSince($0.value) < cooldown }

        var notifications: [PlannedNotification] = []
        var seen = Set<String>()
        for status in waitingStatuses {
            // 一个 sessionID 对应一个状态文件，正常不会重复；防御脏数据
            guard seen.insert(status.sessionID).inserted else { continue }
            // 已在等待 → 不发。只有「非等待 → 等待」的跃迁才算一次新事件。
            guard !previousWaiting.contains(status.sessionID) else { continue }
            // 冷却内再次跃迁（典型：Stop 后 60s 的 idle_prompt）静默吃掉。
            // 不更新冷却时间：否则 60s 那条会把窗口再往后推 5 分钟。
            if let last = nextCooldowns[status.sessionID],
               now.timeIntervalSince(last) < cooldown { continue }

            nextCooldowns[status.sessionID] = now
            notifications.append(make(status, agentNames: agentNames))
        }

        return NotificationPlan(notifications: notifications,
                                waiting: waiting,
                                cooldowns: nextCooldowns)
    }

    static func make(_ status: AgentStatus, agentNames: [String: String] = [:]) -> PlannedNotification {
        let name = displayName(for: status.agent, agentNames: agentNames)
        // 副标题只要最后一级目录名：全路径会带出用户名和项目之外的目录结构
        let last = (status.cwd as NSString).lastPathComponent
        // 正文只能是固定标签，复用面板徽标文案，避免两处措辞各写一份后漂移
        let body = AgentStatusBadge.make(for: status)?.label ?? AgentStatusBadge.waiting.label
        return PlannedNotification(
            sessionID: status.sessionID,
            title: L10n.t("\(name) 在等你", "\(name) is waiting for you"),
            subtitle: last.isEmpty ? nil : last,
            body: body)
    }

    /// hook 上报的 agent 名可能是 `claude-code` / `Codex CLI`，规则 id 是 `claude` / `codex`。
    /// 先精确比，再按分隔符切 token 比（与 `AgentStatusJoiner.agentMatches` 同思路），
    /// 避免 `pi` 这类短 id 被子串误伤。对不上就用上报的原值，绝不省略成空标题。
    static func displayName(for reported: String, agentNames: [String: String]) -> String {
        let got = reported.lowercased()
        if let exact = agentNames.first(where: { $0.key.lowercased() == got })?.value {
            return exact
        }
        let tokens = Set(got.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.lowercased() })
        if let match = agentNames.first(where: { tokens.contains($0.key.lowercased()) })?.value {
            return match
        }
        return reported
    }
}

// MARK: - 投递层

/// 本地通知投递。
///
/// **裸二进制保护（硬要求）**：`--e2e` / `--dump` / `--render` / hook 跑的裸 SPM 二进制
/// 没有 bundle，调 `UNUserNotificationCenter.current()` 会抛
/// `bundleProxyForCurrentProcess is nil`。那是 Objective-C 异常，Swift 的 `try/catch`
/// 接不住，进程直接崩。所以所有入口先看 `isAvailable`：拿不到 bundle id 就整层 no-op。
final class AgentNotifier: NSObject {

    enum Authorization: Equatable {
        case undetermined
        case granted
        case denied
    }

    let isAvailable: Bool
    private(set) var authorization: Authorization = .undetermined

    private var previousWaiting: Set<String> = []
    private var cooldowns: [String: Date] = [:]
    /// 权限还没落定时先攒着：授权完成后补投，避免第一条通知因为等待弹窗而丢掉。
    private var pending: [PlannedNotification] = []
    private var isResolvingAuthorization = false
    private var center: UNUserNotificationCenter?

    /// 给测试断言「不可用时真的什么都没做」；不暴露内容，避免测试耦合文案。
    var pendingCount: Int { pending.count }

    /// - Parameter bundleIdentifier: 默认取 `Bundle.main`。测试 / `--e2e` 传 nil
    ///   模拟裸二进制，能验证门禁而完全不碰系统通知中心。
    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        isAvailable = bundleIdentifier != nil
        super.init()
    }

    /// 每个 tick 调一次。不可用时是真 no-op：连状态都不推进，绝不读取系统通知中心。
    func evaluate(statuses: [AgentStatus], now: Date = Date(),
                  agentNames: [String: String] = [:]) {
        guard isAvailable else { return }
        let plan = NotificationPlanner.plan(previousWaiting: previousWaiting,
                                            statuses: statuses,
                                            cooldowns: cooldowns,
                                            now: now,
                                            agentNames: agentNames)
        previousWaiting = plan.waiting
        cooldowns = plan.cooldowns
        guard !plan.notifications.isEmpty else { return }
        pending.append(contentsOf: plan.notifications)
        flush()
    }

    private func flush() {
        switch authorization {
        case .granted:
            postPending()
        case .denied:
            // 用户拒绝 → 静默降级为只做菜单栏 ⏸：不弹错、不每 tick 重试
            pending.removeAll()
        case .undetermined:
            resolveAuthorizationIfNeeded()
        }
    }

    /// 只问一次。
    ///
    /// 先 `getNotificationSettings` 而不是直接 `requestAuthorization`：
    /// 用户上次已拒绝时系统状态是 `.denied`，这里直接降级，下次启动也不会再弹窗。
    private func resolveAuthorizationIfNeeded() {
        guard !isResolvingAuthorization else { return }
        isResolvingAuthorization = true
        let center = notificationCenter()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.finish(.granted)
            case .denied:
                self.finish(.denied)
            default:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    // 系统回调可能来自任意队列，状态统一回 main 改（evaluate 也在 main）
                    self.finish(granted ? .granted : .denied)
                }
            }
        }
    }

    private func finish(_ result: Authorization) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.authorization = result
            self.isResolvingAuthorization = false
            if result == .granted {
                self.postPending()
            } else {
                self.pending.removeAll()
            }
        }
    }

    private func postPending() {
        guard !pending.isEmpty else { return }
        let center = notificationCenter()
        let items = pending
        pending.removeAll()
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            if let subtitle = item.subtitle { content.subtitle = subtitle }
            content.body = item.body
            content.sound = .default
            // id 带 sessionID：同一会话的旧横幅被替换，不会在通知中心堆一串
            let request = UNNotificationRequest(identifier: "manatee.waiting.\(item.sessionID)",
                                                content: content, trigger: nil)
            // 投递失败只能静默：通知不是核心功能，不能影响菜单栏与面板
            center.add(request)
        }
    }

    private func notificationCenter() -> UNUserNotificationCenter {
        if let center { return center }
        let created = UNUserNotificationCenter.current()
        // 菜单栏 app 通常不在前台；不设 delegate 的话 app 内横幅会被系统吞掉
        created.delegate = self
        center = created
        return created
    }
}

extension AgentNotifier: UNUserNotificationCenterDelegate {

    /// 前台也显示横幅，方便 `--demo` 手工验收时不用切到别的 app
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// 通知层的注入点。`feature.agentStatus.enabled == false` 时 AppModel 连
/// `evaluate` 都不该调——状态都不扫，自然也没有「非等待 → 等待」的跃迁可报。
protocol AgentStatusNotifying: AnyObject {
    func evaluate(statuses: [AgentStatus], now: Date, agentNames: [String: String])
}

extension AgentNotifier: AgentStatusNotifying {}
