import Testing
import Foundation
@testable import Manatee

// MARK: - 工具

/// 固定时刻，别让测试依赖真实时钟
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func status(_ state: AgentActivity,
                    type: String? = nil,
                    agent: String = "claude-code",
                    cwd: String = "/Users/x/project",
                    sid: String = "s",
                    stale: Bool = false,
                    message: String? = nil) -> AgentStatus {
    AgentStatus(sessionID: sid, agent: agent, state: state, cwd: cwd,
                message: message, notificationType: type, pid: nil,
                updatedAt: t0, isStale: stale)
}

private func plan(previous: Set<String>,
                  _ statuses: [AgentStatus],
                  cooldowns: [String: Date] = [:],
                  at now: Date) -> NotificationPlan {
    NotificationPlanner.plan(previousWaiting: previous,
                             statuses: statuses,
                             cooldowns: cooldowns,
                             now: now)
}

// MARK: - 跃迁与冷却

@Suite("通知规划：跃迁")
struct NotificationPlannerTransitionTests {

    @Test("running → waiting 发一条；waiting → waiting 不发")
    func 进入等待只发一次() {
        let waiting = status(.waiting, type: "permission_prompt", sid: "s1")

        // 上一 tick 不在等待 → 本条是跃迁，发
        let first = plan(previous: [], [waiting], at: t0)
        #expect(first.notifications.count == 1)
        #expect(first.notifications.first?.sessionID == "s1")
        #expect(first.waiting == ["s1"])

        // 上一 tick 已在等待 → 状态没变，不发；冷却表也不该被无谓地刷新
        let second = plan(previous: first.waiting, [waiting],
                          cooldowns: first.cooldowns, at: t0.addingTimeInterval(2))
        #expect(second.notifications.isEmpty)
        #expect(second.cooldowns == first.cooldowns)
    }

    @Test("同一 sessionID 5 分钟内第二次进入等待不发；超过 5 分钟发")
    func 五分钟冷却() {
        let waiting = status(.waiting, type: "permission_prompt", sid: "s1")
        let first = plan(previous: [], [waiting], at: t0)
        #expect(first.notifications.count == 1)

        // 299 秒时重新进入等待（上一 tick 已不在等待，所以这是一次真跃迁）
        let early = plan(previous: [], [waiting], cooldowns: first.cooldowns,
                         at: t0.addingTimeInterval(299))
        #expect(early.notifications.isEmpty)

        // 被冷却吃掉的那条不能把窗口再往后推：仍以第一次投递时刻为准
        let onTime = plan(previous: [], [waiting], cooldowns: early.cooldowns,
                          at: t0.addingTimeInterval(300))
        #expect(onTime.notifications.count == 1)
    }

    @Test("Stop 后 60s 的 idle_prompt 被冷却吃掉，通知总数仍是 1")
    func idle提示与完成合并() {
        // tick 1：runner → waiting(permission_prompt)
        let t1 = status(.waiting, type: "permission_prompt", sid: "s1")
        let first = plan(previous: [], [t1], at: t0)
        #expect(first.notifications.count == 1)

        // tick 2：Stop 写来 idle（非等待），跃迁状态复位
        let t2 = status(.idle, sid: "s1")
        let stopped = plan(previous: first.waiting, [t2],
                           cooldowns: first.cooldowns, at: t0.addingTimeInterval(1))
        #expect(stopped.notifications.isEmpty)
        #expect(stopped.waiting.isEmpty)

        // tick 3：约 60s 后必来一条 idle_prompt。它是新跃迁，但仍在 5 分钟窗口内 → 吃掉。
        let t3 = status(.waiting, type: "idle_prompt", sid: "s1")
        let late = plan(previous: stopped.waiting, [t3],
                        cooldowns: stopped.cooldowns, at: t0.addingTimeInterval(60))
        #expect(late.notifications.isEmpty)

        let total = first.notifications.count + stopped.notifications.count + late.notifications.count
        #expect(total == 1, "一次完成只能收到一条通知")
    }

    @Test("多个会话同时进入等待 → 每个会话各一条，不合并")
    func 多会话不合并() {
        let result = plan(previous: [], [
            status(.waiting, type: "permission_prompt", sid: "a"),
            status(.waiting, type: "idle_prompt", sid: "b"),
        ], at: t0)

        #expect(result.notifications.count == 2)
        #expect(Set(result.notifications.map(\.sessionID)) == ["a", "b"])
    }
}

// MARK: - 不该发通知的状态

@Suite("通知规划：过滤")
struct NotificationPlannerFilterTests {

    @Test("isStale 的 waiting 不发")
    func 过期不发() {
        let result = plan(previous: [],
                          [status(.waiting, type: "permission_prompt", stale: true)],
                          at: t0)
        #expect(result.notifications.isEmpty)
        // 过期记录也不能留在 waiting 集合里，否则它会一直压住下一次真等待
        #expect(result.waiting.isEmpty)
    }

    @Test("idle / running / error 一律不发")
    func 非等待不发() {
        for state in [AgentActivity.idle, .running, .error] {
            let result = plan(previous: [], [status(state, sid: "s1")], at: t0)
            #expect(result.notifications.isEmpty, "\(state) 不该产生通知")
        }
    }

    @Test("同一 tick 里重复的 sessionID 只算一条")
    func 重复数据防御() {
        let result = plan(previous: [], [
            status(.waiting, type: "permission_prompt", sid: "dup"),
            status(.waiting, type: "idle_prompt", sid: "dup"),
        ], at: t0)
        #expect(result.notifications.count == 1)
    }
}

// MARK: - 文案与隐私

@Suite("通知文案")
struct NotificationContentTests {

    @Test("标题用 Agent 展示名，副标题只给目录名，正文复用徽标标签")
    func 文案复用() {
        let notify = NotificationPlanner.make(
            status(.waiting, type: "permission_prompt",
                   cwd: "/Users/alice/secret-org/project-alpha", sid: "priv"),
            agentNames: ["claude": "Claude Code"])

        #expect(notify.title == L10n.t("Claude Code 在等你", "Claude Code is waiting for you"))
        #expect(notify.subtitle == "project-alpha")
        #expect(notify.body == AgentStatusBadge.waitingPermission.label)
    }

    @Test("没有任何 payload 原文或全路径泄漏到通知")
    func 隐私红线() {
        // message 就是 PRD 里点名不许外泄的 last_assistant_message
        let leakedMessage = "rm -rf ~/Documents && cat transcript.jsonl"
        let notify = NotificationPlanner.make(
            status(.waiting, type: "permission_prompt",
                   cwd: "/Users/alice/secret-org/project-alpha",
                   message: leakedMessage),
            agentNames: ["claude": "Claude Code"])

        let visible = [notify.title, notify.subtitle ?? "", notify.body].joined(separator: "\n")
        for secret in ["/Users", "alice", "secret-org", "rm -rf", "transcript"] {
            #expect(!visible.contains(secret), "通知里出现了 \(secret)")
        }
    }

    @Test("旧状态文件没有 notification_type → 正文降级为「等待中」")
    func 无细分类型() {
        let notify = NotificationPlanner.make(status(.waiting))
        #expect(notify.body == AgentStatusBadge.waiting.label)
    }

    @Test("agent 名按 token 匹配规则 id，匹配不上就用上报原值")
    func 展示名解析() {
        let names = ["claude": "Claude Code", "pi": "Pi"]
        #expect(NotificationPlanner.displayName(for: "claude-code", agentNames: names) == "Claude Code")
        #expect(NotificationPlanner.displayName(for: "Pi", agentNames: names) == "Pi")
        // 短 id 不能被子串误伤
        #expect(NotificationPlanner.displayName(for: "pint", agentNames: names) == "pint")
        // 对不上就保留原值，绝不生成空标题
        #expect(NotificationPlanner.displayName(for: "future-agent", agentNames: names) == "future-agent")
    }

    @Test("cwd 为空时不给副标题，不显示空字符串")
    func 空目录() {
        #expect(NotificationPlanner.make(status(.waiting, cwd: "")).subtitle == nil)
    }
}

// MARK: - 裸二进制门禁

@Suite("通知层门禁")
struct AgentNotifierGateTests {

    @Test("拿不到 bundle id 时 isAvailable == false，调用是 no-op 且不崩")
    func 裸二进制() {
        // 传 nil 模拟 .build/debug/Manatee：真实调用会抛 bundleProxyForCurrentProcess is nil。
        // 这里只验证门禁；只要 evaluate 里先判断 isAvailable，就永远摸不到系统通知中心。
        let notifier = AgentNotifier(bundleIdentifier: nil)
        #expect(notifier.isAvailable == false)

        notifier.evaluate(statuses: [status(.waiting, type: "permission_prompt")], now: t0)
        #expect(notifier.pendingCount == 0)
        #expect(notifier.authorization == .undetermined)
    }
}
