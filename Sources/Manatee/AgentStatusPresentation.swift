import Foundation

/// 菜单栏标题拼装。
///
/// 独立成纯函数：`AppDelegate.refreshTitle()` 只负责写 `NSStatusItem`，
/// 文案本身能在单测和 `--e2e` 里直接断言，不用起 GUI。
enum MenuBarLabel {
    /// 0 个等待 → 与现状完全一致的 `48°`；
    /// 1 个 → `48° ⏸`（单个不带数字，省菜单栏宽度）；
    /// N 个 → `48° ⏸N`。温度读不到（≤0）时用 `—°`，等待标记照常显示。
    static func make(temperature: Double, waitingCount: Int) -> String {
        let base = temperature > 0 ? "\(Int(temperature.rounded()))°" : "—°"
        let count = max(0, waitingCount)
        guard count > 0 else { return base }
        return count == 1 ? base + " ⏸" : base + " ⏸\(count)"
    }
}

/// 面板行上的状态徽标。
///
/// 只有 `.waiting` 改变菜单栏外观，但行徽标同时覆盖运行/异常，
/// 让一行状态自解释。`.idle` 与过期记录不出徽标。
enum AgentStatusBadge: Equatable {
    case waitingPermission
    case waitingInput
    case waiting
    case running
    case error

    /// - Returns: nil 表示这一行不画徽标。
    static func make(for status: AgentStatus) -> AgentStatusBadge? {
        // 过期只说明「没有新事件」，不再等于「人已经走了」：长等待能靠进程存活留在
        // `waitingStatuses` 里，这时必须照常出徽标，否则菜单栏有 ⏸、面板却没标记。
        // 其他状态过期后沿用旧行为（不出徽标）。
        if status.isStale && status.state != .waiting { return nil }
        switch status.state {
        case .waiting:
            // 旧状态文件没有 notification_type：按「等待中」降级，不能当成等权限
            switch status.notificationType?.lowercased() {
            case "permission_prompt": return .waitingPermission
            case "idle_prompt":     return .waitingInput
            default:                return .waiting
            }
        case .running: return .running
        case .error:   return .error
        case .idle:    return nil
        }
    }

    var label: String {
        switch self {
        case .waitingPermission: return L10n.t("等待权限确认", "Waiting for permission")
        case .waitingInput:      return L10n.t("等待输入", "Waiting for input")
        case .waiting:           return L10n.t("等待中", "Waiting")
        case .running:           return L10n.t("运行中", "Running")
        case .error:             return L10n.t("异常", "Error")
        }
    }
}

/// 等待状态与进程会话的对应结果。
struct AgentStatusJoin: Equatable {
    /// 会话根 pid → 这条等待记录（每个会话最多一条）。
    var byRootPid: [pid_t: AgentStatus] = [:]
    /// 对不上任何进程的等待记录。面板必须把它们单独列出来，
    /// 否则菜单栏的 `⏸2` 会比面板能看到的标记多，用户会以为丢了一个。
    var unmatched: [AgentStatus] = []
}

/// 把 hook 上报的等待状态对到 `ProcessScanner` 找出的会话。
///
/// hooks 只给 `cwd` / `agent`（没有 pid），所以按 cwd 对、agent 收窄。
/// 任何一步出现多个候选都算对不上：宁可显示「未匹配」行，也不猜错行。
enum AgentStatusJoiner {

    /// - Parameter includeStale: 过期记录是否参与匹配。默认 false（面板/通知只看写实的
    ///   新事件）；`WaitingPolicy` 要拿过期记录反向找活进程，所以传 true。
    static func join(statuses: [AgentStatus], sessions: [AgentSession],
                     includeStale: Bool = false) -> AgentStatusJoin {
        var result = AgentStatusJoin()
        var claimed = Set<pid_t>()

        for status in statuses where status.state == .waiting && (includeStale || !status.isStale) {
            // 通用 CLI 可能带 pid：这是精确证据，优先于 cwd 推断
            if let rawPid = status.pid, let pid = pid_t(exactly: rawPid),
               !claimed.contains(pid),
               sessions.contains(where: { $0.rootPid == pid }) {
                result.byRootPid[pid] = status
                claimed.insert(pid)
                continue
            }

            let free = sessions.filter { !claimed.contains($0.rootPid) }
            // 空 cwd 不参与匹配：读取侧会把空 cwd 当坏文件跳过，这里只防注入的演示数据
            let sameCwd = status.cwd.isEmpty ? [] : free.filter { $0.cwd == status.cwd }
            let pool = sameCwd.isEmpty ? free.filter { agentMatches($0.def, status.agent) } : sameCwd
            // 同一目录开了多个会话时用 agent 收窄；仍不唯一就只能算未匹配
            let narrowed = pool.count > 1 ? pool.filter { agentMatches($0.def, status.agent) } : pool

            if narrowed.count == 1, let session = narrowed.first {
                result.byRootPid[session.rootPid] = status
                claimed.insert(session.rootPid)
            } else {
                result.unmatched.append(status)
            }
        }
        return result
    }

    /// hook 里的 agent 名可能是 `claude-code` / `Codex CLI`，规则 id 是 `claude` / `codex`。
    /// 按分隔符切 token 后精确比对，避免 `pi` 这类短 id 被子串误伤。
    static func agentMatches(_ def: AgentDef, _ reported: String) -> Bool {
        let want = def.id.lowercased()
        let got = reported.lowercased()
        if got == want { return true }
        return got.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .contains(want)
    }
}

/// 面板里「对不上进程」那一行的文案。
enum WaitingFallback {
    static func text(agent: String, cwd: String) -> String {
        let last = (cwd as NSString).lastPathComponent
        let tail = last.isEmpty ? "—" : last
        return L10n.t("未匹配到进程的等待：\(agent) · \(tail)",
                      "Waiting with no matching process: \(agent) · \(tail)")
    }
}

/// 决定哪些 `.waiting` 该出现在菜单栏与面板上。
///
/// 不能只看 `isStale`：Claude Code 一次等待只发**一条** `Notification`，之后不再刷新
/// `updated_at`。把「事件时间旧」当成「人已经走了」，最该被看见的长等待（开会 20 分钟）
/// 反而先丢标记。`updated_at` 只能证明「没有新事件」，进程还在才是更可靠的佐证：
///
/// - 未过期 → 可见（事件刚发生）
/// - 过期但能对上一个活着的会话 → 仍可见（agent 进程还在，大概率还在等）
/// - 过期且对不上任何会话 → 不可见（进程没了，原来的 5 分钟兜底要防的就是这种）
/// - 文件超过 4 小时 → 一律不可见（硬上限，防进程被强杀后残留的僵尸文件永远挂 ⏸）
///
/// 非 `.waiting` 状态不参与：本函数只回答「等待标记该不该亮」。
enum WaitingPolicy {

    /// 等待状态文件的年龄硬上限。4 小时比一次真实的等待（会、饭、下班前挂着）都长，
    /// 同时又能兜住进程被 `kill -9` 后没人清的残留文件。
    static let hardLimit: TimeInterval = 4 * 60 * 60

    /// - Parameter liveSessions: 最近一次 `ProcessScanner` 得到的会话快照；
    ///   调用方应在自己的队列上持有一份值拷贝，不要跨线程读可变状态。
    static func visibleWaiting(_ statuses: [AgentStatus],
                               liveSessions: [AgentSession],
                               now: Date) -> [AgentStatus] {
        let candidates = statuses.filter {
            $0.state == .waiting && now.timeIntervalSince($0.updatedAt) <= hardLimit
        }
        let stale = candidates.filter { isStale($0, now: now) }

        var visible = Set(candidates.filter { !isStale($0, now: now) }.map(\.sessionID))
        if !stale.isEmpty {
            // 过期记录允许参与匹配：这正是「用进程活着反推还在等」的证据来源
            let joined = AgentStatusJoiner.join(statuses: stale, sessions: liveSessions,
                                                includeStale: true)
            visible.formUnion(joined.byRootPid.values.map(\.sessionID))
        }
        // 保持输入顺序（store 已按 sessionID 排序），UI 结果稳定
        return candidates.filter { visible.contains($0.sessionID) }
    }

    /// `isStale` 是 store 按扫描时刻算的；这里再按调用方给的 `now` 判一次，
    /// 保证两条路径结论一致（直接构造的测试数据也不会漏判）。
    private static func isStale(_ status: AgentStatus, now: Date) -> Bool {
        status.isStale || now.timeIntervalSince(status.updatedAt) > AgentStatusStore.staleAfter
    }
}
