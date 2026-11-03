import Testing
import Foundation
@testable import Manatee

// MARK: - 工具

private func status(_ state: AgentActivity,
                    type: String? = nil,
                    agent: String = "claude-code",
                    cwd: String = "/Users/x/project",
                    pid: Int? = nil,
                    sid: String = "s",
                    stale: Bool = false) -> AgentStatus {
    AgentStatus(sessionID: sid, agent: agent, state: state, cwd: cwd,
                message: nil, notificationType: type, pid: pid,
                updatedAt: Date(), isStale: stale)
}

private func def(_ id: String) -> AgentDef {
    AgentDef(id: id, name: id, symbol: "circle", patterns: [],
             excludes: [], bin: nil, detect: [])
}

private func session(_ agent: String, pid: pid_t, cwd: String) -> AgentSession {
    AgentSession(def: def(agent), rootPid: pid, cpuPercent: 0, pids: [pid],
                 busyChildren: [], cooled: false, hasOtherUid: false, cwd: cwd)
}

// MARK: - 菜单栏文案

@Suite("菜单栏等待标记")
struct MenuBarLabelTests {

    @Test("没有等待 → 与现有外观完全一致")
    func 零个等待() {
        #expect(MenuBarLabel.make(temperature: 48, waitingCount: 0) == "48°")
    }

    @Test("1 个等待 → ⏸ 不带数字")
    func 一个等待() {
        #expect(MenuBarLabel.make(temperature: 48, waitingCount: 1) == "48° ⏸")
    }

    @Test("多个等待 → ⏸ 后跟数量")
    func 多个等待() {
        #expect(MenuBarLabel.make(temperature: 48, waitingCount: 2) == "48° ⏸2")
        // 温度四舍五入后再拼接，小数不能漏到菜单栏
        #expect(MenuBarLabel.make(temperature: 47.6, waitingCount: 3) == "48° ⏸3")
    }

    @Test("温度 ≤ 0（传感器不可用）→ 破折号，等待数照常")
    func 温度无效() {
        #expect(MenuBarLabel.make(temperature: 0, waitingCount: 0) == "—°")
        #expect(MenuBarLabel.make(temperature: 0, waitingCount: 1) == "—° ⏸")
        #expect(MenuBarLabel.make(temperature: -5, waitingCount: 2) == "—° ⏸2")
    }
}

// MARK: - 徽标

@Suite("等待徽标映射")
struct AgentStatusBadgeTests {

    @Test("waiting + permission_prompt → 等待权限确认")
    func 等权限() {
        let badge = AgentStatusBadge.make(for: status(.waiting, type: "permission_prompt"))
        #expect(badge == .waitingPermission)
        #expect(badge?.label == L10n.t("等待权限确认", "Waiting for permission"))
    }

    @Test("waiting + idle_prompt → 等待输入")
    func 等输入() {
        let badge = AgentStatusBadge.make(for: status(.waiting, type: "idle_prompt"))
        #expect(badge == .waitingInput)
        #expect(badge?.label == L10n.t("等待输入", "Waiting for input"))
    }

    @Test("waiting 没有细分 / 未知细分 → 等待中，不猜成等权限")
    func 等待中() {
        #expect(AgentStatusBadge.make(for: status(.waiting)) == .waiting)
        #expect(AgentStatusBadge.make(for: status(.waiting, type: "future_type")) == .waiting)
        #expect(AgentStatusBadge.waiting.label == L10n.t("等待中", "Waiting"))
    }

    @Test("running / error 各有一档")
    func 运行与异常() {
        #expect(AgentStatusBadge.make(for: status(.running)) == .running)
        #expect(AgentStatusBadge.make(for: status(.error)) == .error)
        #expect(AgentStatusBadge.running.label == L10n.t("运行中", "Running"))
        #expect(AgentStatusBadge.error.label == L10n.t("异常", "Error"))
    }

    @Test("idle 与过期记录不出徽标")
    func 空闲与过期() {
        #expect(AgentStatusBadge.make(for: status(.idle)) == nil)
        #expect(AgentStatusBadge.make(for: status(.waiting, type: "permission_prompt", stale: true)) == nil)
    }
}

// MARK: - 状态对进程

@Suite("等待状态对会话")
struct AgentStatusJoinerTests {

    @Test("同 cwd 多会话时用 agent 收窄，挂到唯一那行")
    func 同目录收窄() {
        let sessions = [session("claude", pid: 100, cwd: "/w/app"),
                        session("codex", pid: 200, cwd: "/w/app")]
        let join = AgentStatusJoiner.join(
            statuses: [status(.waiting, agent: "claude-code", cwd: "/w/app")],
            sessions: sessions)

        #expect(join.byRootPid[100] != nil)
        #expect(join.byRootPid[200] == nil)
        #expect(join.unmatched.isEmpty)
    }

    @Test("同 cwd 两个同名 agent → 不猜，进未匹配")
    func 同目录歧义() {
        let sessions = [session("claude", pid: 100, cwd: "/w/app"),
                        session("claude", pid: 101, cwd: "/w/app")]
        let join = AgentStatusJoiner.join(
            statuses: [status(.waiting, agent: "claude-code", cwd: "/w/app")],
            sessions: sessions)

        #expect(join.byRootPid.isEmpty)
        #expect(join.unmatched.count == 1)
    }

    @Test("cwd 对不上但 agent 只有一个 → 用 agent 兜底")
    func agent兜底() {
        let sessions = [session("claude", pid: 100, cwd: "/w/app")]
        let join = AgentStatusJoiner.join(
            statuses: [status(.waiting, agent: "claude-code", cwd: "/other/dir")],
            sessions: sessions)

        #expect(join.byRootPid[100] != nil)
        #expect(join.unmatched.isEmpty)
    }

    @Test("cwd 和 agent 都对不上 → 未匹配，绝不硬挂")
    func 对不上() {
        let join = AgentStatusJoiner.join(
            statuses: [status(.waiting, agent: "codex", cwd: "/other/dir")],
            sessions: [session("claude", pid: 100, cwd: "/w/app")])

        #expect(join.byRootPid.isEmpty)
        #expect(join.unmatched.map(\.sessionID) == ["s"])
    }

    @Test("带 pid 时 pid 精确匹配优先于 cwd")
    func pid优先() {
        let sessions = [session("claude", pid: 100, cwd: "/w/a"),
                        session("claude", pid: 200, cwd: "/w/b")]
        // cwd 指向 200，但 pid 说自己是 100：pid 是精确证据
        let join = AgentStatusJoiner.join(
            statuses: [status(.waiting, agent: "claude-code", cwd: "/w/b", pid: 100)],
            sessions: sessions)

        #expect(join.byRootPid[100] != nil)
        #expect(join.byRootPid[200] == nil)
    }

    @Test("非 waiting 与过期状态不参与匹配")
    func 非等待忽略() {
        let join = AgentStatusJoiner.join(
            statuses: [status(.running, agent: "claude-code", cwd: "/w/app"),
                       status(.waiting, agent: "claude-code", cwd: "/w/app", stale: true)],
            sessions: [session("claude", pid: 100, cwd: "/w/app")])

        #expect(join.byRootPid.isEmpty)
        #expect(join.unmatched.isEmpty)
    }

    @Test("兜底行文案带上 agent 与 cwd 最后一级")
    func 兜底文案() {
        let text = WaitingFallback.text(agent: "claude-code", cwd: "/Users/x/projects/workshop")
        #expect(text.contains("claude-code"))
        #expect(text.contains("workshop"))
        #expect(text.contains(L10n.t("未匹配到进程的等待", "Waiting with no matching process")))
        // 空 cwd 不能显示成空字符串
        #expect(WaitingFallback.text(agent: "codex", cwd: "").contains("—"))
    }
}

// MARK: - Hook 参数

@Suite("--hook 参数")
struct HookCommandTests {

    private let base = ["Manatee", "--hook",
                        "--state", "waiting",
                        "--agent", "claude-code",
                        "--cwd", "/tmp",
                        "--session", "s1"]

    @Test("合法 notification-type 透传")
    func 合法值() throws {
        let cmd = try HookCommand.parse(base + ["--notification-type", "permission_prompt"]).get()
        #expect(cmd.notificationType == "permission_prompt")
        #expect(cmd.state == "waiting")
    }

    @Test("非法 notification-type → 解析失败（main 映射成 exit 2）")
    func 非法值() {
        let result = HookCommand.parse(base + ["--notification-type", "nope"])
        switch result {
        case .success:
            Issue.record("非法值不应通过")
        case .failure(let error):
            #expect(error.description.contains("notification-type"))
        }
    }

    @Test("不传或空串 → nil，旧 hook 模板不用改")
    func 缺省与空串() throws {
        #expect(try HookCommand.parse(base).get().notificationType == nil)
        #expect(try HookCommand.parse(base + ["--notification-type", ""]).get().notificationType == nil)
    }

    @Test("--flag=value 写法同样可用")
    func 等号写法() throws {
        let cmd = try HookCommand.parse(base + ["--notification-type=idle_prompt"]).get()
        #expect(cmd.notificationType == "idle_prompt")
    }

    @Test("未知参数仍然失败")
    func 未知参数() {
        switch HookCommand.parse(base + ["--nope", "x"]) {
        case .success:
            Issue.record("未知参数不应通过")
        case .failure(let error):
            #expect(error.description.contains("未知参数"))
        }
    }
}
