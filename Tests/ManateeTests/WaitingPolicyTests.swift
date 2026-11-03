import Foundation
import Testing
@testable import Manatee

/// 固定的「现在」，避免测试依赖真实时钟
private let now = Date(timeIntervalSince1970: 1_760_000_000)

private func def(_ id: String) -> AgentDef {
    AgentDef(id: id, name: id, symbol: "circle", patterns: [],
             excludes: [], bin: nil, detect: [])
}

private func session(_ agent: String, pid: pid_t, cwd: String) -> AgentSession {
    AgentSession(def: def(agent), rootPid: pid, cpuPercent: 0, pids: [pid],
                 busyChildren: [], cooled: false, hasOtherUid: false, cwd: cwd)
}

private func status(_ state: AgentActivity,
                    agent: String = "claude-code",
                    cwd: String = "/Users/x/project",
                    sid: String = "s",
                    ago: TimeInterval,
                    stale: Bool) -> AgentStatus {
    AgentStatus(sessionID: sid, agent: agent, state: state, cwd: cwd,
                message: nil, notificationType: "permission_prompt", pid: nil,
                updatedAt: now.addingTimeInterval(-ago), isStale: stale)
}

private let liveClaude = session("claude", pid: 100, cwd: "/Users/x/project")

@Suite("等待可见性（进程存活佐证）")
struct WaitingPolicyTests {

    @Test("6 分钟前的 waiting + 能 join 到活会话 → 仍可见")
    func 过期但进程还在() {
        let statuses = [status(.waiting, ago: 360, stale: true)]

        let visible = WaitingPolicy.visibleWaiting(statuses, liveSessions: [liveClaude], now: now)

        #expect(visible.map(\.sessionID) == ["s"])
    }

    @Test("6 分钟前的 waiting + join 不上任何会话 → 不可见")
    func 过期且进程没了() {
        let statuses = [status(.waiting, ago: 360, stale: true)]

        let visible = WaitingPolicy.visibleWaiting(statuses, liveSessions: [], now: now)

        #expect(visible.isEmpty)
    }

    @Test("5 小时前的 waiting + 活会话 → 不可见（4 小时硬上限）")
    func 硬上限() {
        let statuses = [status(.waiting, ago: 5 * 60 * 60, stale: true)]

        let visible = WaitingPolicy.visibleWaiting(statuses, liveSessions: [liveClaude], now: now)

        #expect(visible.isEmpty)
        #expect(WaitingPolicy.hardLimit == 4 * 60 * 60)
    }

    @Test("2 分钟前的 waiting → 可见（不需要进程佐证）")
    func 未过期() {
        let statuses = [status(.waiting, ago: 120, stale: false)]

        let visible = WaitingPolicy.visibleWaiting(statuses, liveSessions: [], now: now)

        #expect(visible.map(\.sessionID) == ["s"])
    }

    @Test("waiting 但 cwd 与所有会话都对不上 → 不可见")
    func 对不上进程() {
        // agent 也不同：否则 AgentStatusJoiner 会退化成「按 agent 兜底」
        let statuses = [status(.waiting, agent: "codex", cwd: "/other/dir",
                               ago: 360, stale: true)]

        let visible = WaitingPolicy.visibleWaiting(statuses, liveSessions: [liveClaude], now: now)

        #expect(visible.isEmpty)
    }

    @Test("running / idle / error 不受影响：不进入等待可见列表")
    func 非等待状态() {
        let statuses = [
            status(.running, ago: 10, stale: false),
            status(.idle, ago: 10, stale: false),
            status(.error, ago: 10, stale: false),
            status(.waiting, ago: 10, stale: false),
        ]

        let visible = WaitingPolicy.visibleWaiting(statuses, liveSessions: [liveClaude], now: now)

        #expect(visible.map(\.state) == [.waiting])
    }
}
