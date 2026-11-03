import Foundation
import Testing
@testable import Manatee

/// 固定的「现在」，避免测试依赖真实时钟
private let now = Date(timeIntervalSince1970: 1_760_000_000)

// MARK: - 注入点 spy

/// 只负责数调用次数：关闭态要求「一次都没扫过目录」，扫了再丢不算数。
private final class SpyStatusReader: AgentStatusReading {
    private(set) var scanCount = 0
    let result: AgentStatusStore.ScanResult

    init(result: AgentStatusStore.ScanResult = .empty) {
        self.result = result
    }

    func scan(now: Date) -> AgentStatusStore.ScanResult {
        scanCount += 1
        return result
    }
}

private final class SpyNotifier: AgentStatusNotifying {
    private(set) var evaluateCount = 0
    private(set) var lastStatuses: [AgentStatus] = []

    func evaluate(statuses: [AgentStatus], now: Date, agentNames: [String: String]) {
        evaluateCount += 1
        lastStatuses = statuses
    }
}

// MARK: - 测试数据

private func waitingStatus(id: String = "session-waiting",
                           agent: String = "claude") -> AgentStatus {
    AgentStatus(sessionID: id, agent: agent, state: .waiting,
                cwd: "/Users/e2e/project", message: nil,
                notificationType: "permission_prompt", pid: nil,
                updatedAt: now, isStale: false)
}

private func scanResult(_ statuses: [AgentStatus]) -> AgentStatusStore.ScanResult {
    AgentStatusStore.ScanResult(statuses: statuses, skippedCount: 0)
}

/// 老用户真实形态的 rules.json：默认顶层没有 `feature` 键。
/// 一段一段写成字面量，避免用编码器生成——编码器一定会带上新字段，
/// 那样测不到「手写的老文件能不能解码」。
/// - Parameter feature: 传 nil 就是完全老的文件；传 JSON 片段模拟用户手写的 feature 段。
private func rulesJSON(feature: String? = nil) -> String {
    let featureLine = feature.map { ",\n  \"feature\": \($0)" } ?? ""
    return """
    {
      "version": 2,
      "agents": [
        {
          "id": "claude",
          "name": "Claude Code",
          "symbol": "asterisk",
          "patterns": ["claude", ".claude/local"],
          "excludes": ["Claude.app"],
          "enabled": true
        },
        {
          "id": "my-custom-agent",
          "name": "公司内部 agent",
          "symbol": "hammer",
          "patterns": ["internal-agent"],
          "enabled": false
        }
      ],
      "devServerCommands": ["node", "vite", "uvicorn"],
      "ignorePortCommands": ["redis", "postgres"],
      "alert": { "cpuPercent": 150, "sustainSeconds": 120 }\(featureLine)
    }
    """
}

/// 不带 feature 键的老配置
private let legacyRulesJSON = rulesJSON()

private func decodeRules(_ json: String) throws -> Rules {
    try JSONDecoder().decode(Rules.self, from: Data(json.utf8))
}

// MARK: - 默认值

@Suite("feature.agentStatus 默认值")
struct AgentStatusFeatureDefaultTests {

    @Test("Rules.default 默认关闭")
    func 默认关闭() {
        #expect(Rules.default.feature.agentStatus.enabled == false)
    }
}

// MARK: - 老配置兼容

@Suite("rules.json 向后兼容")
struct AgentStatusFeatureDecodingTests {

    @Test("没有 feature 键的老文件能解码，其余字段逐一相符，开关为 false")
    func 老配置兼容() throws {
        let rules = try decodeRules(legacyRulesJSON)

        // 解码成功本身就是最关键的一条：如果 feature 是必填字段，
        // 这里会抛错 → load() 走 catch → 备份并回退默认，用户配置整体丢失。
        #expect(rules.feature.agentStatus.enabled == false)
        #expect(rules.version == 2)
        #expect(rules.devServerCommands == ["node", "vite", "uvicorn"])
        #expect(rules.ignorePortCommands == ["redis", "postgres"])
        #expect(rules.alert.cpuPercent == 150)
        #expect(rules.alert.sustainSeconds == 120)
        #expect(rules.agents.count == 2)

        let claude = try #require(rules.agents.first { $0.id == "claude" })
        #expect(claude.name == "Claude Code")
        #expect(claude.patterns == ["claude", ".claude/local"])
        #expect(claude.excludes == ["Claude.app"])
        #expect(claude.enabled == true)

        let custom = try #require(rules.agents.first { $0.id == "my-custom-agent" })
        #expect(custom.name == "公司内部 agent")
        #expect(custom.patterns == ["internal-agent"])
        #expect(custom.enabled == false)
    }

    @Test("文件里已有 enabled: true → 原样保留，不被默认值覆盖")
    func 不覆盖用户值() throws {
        let rules = try decodeRules(rulesJSON(feature: #"{ "agentStatus": { "enabled": true } }"#))

        #expect(rules.feature.agentStatus.enabled == true)
    }

    @Test("feature / agentStatus 段存在但缺 enabled → 按关处理，不报错")
    func 缺少enabled键() throws {
        #expect(try decodeRules(rulesJSON(feature: #"{ "agentStatus": {} }"#))
            .feature.agentStatus.enabled == false)

        #expect(try decodeRules(rulesJSON(feature: "{}"))
            .feature.agentStatus.enabled == false)
    }

    @Test("编码后再解码，用户开的开关不丢")
    func 编码往返() throws {
        var loaded = try decodeRules(rulesJSON(feature: #"{ "agentStatus": { "enabled": true } }"#))
        // 模拟 load() 的补 agent 步骤：用户已有字段一律不动
        loaded.mergeNewAgents()
        loaded.migrateIfNeeded()

        let roundTripped = try JSONDecoder().decode(Rules.self, from: JSONEncoder().encode(loaded))
        #expect(roundTripped.feature.agentStatus.enabled == true)
        #expect(roundTripped.alert.cpuPercent == 150)
    }
}

// MARK: - AppModel 开 / 关

@Suite("AppModel 开关短路")
struct AgentStatusFeatureModelTests {

    @Test("开：扫一次、等待态发布、菜单栏出 ⏸、通知被调用")
    @MainActor
    func 开启态() {
        let spy = SpyStatusReader(result: scanResult([waitingStatus()]))
        let notifier = SpyNotifier()
        let model = AppModel(statusStore: spy, notifier: notifier, agentStatusEnabled: true)

        let readout = model.readAgentStatus(now: now)
        model.applyAgentStatus(readout)

        #expect(spy.scanCount == 1)
        #expect(model.waitingStatuses.count == 1)
        #expect(model.waitingStatuses.first?.sessionID == "session-waiting")
        #expect(notifier.evaluateCount == 1)
        #expect(MenuBarLabel.make(temperature: 48, waitingCount: model.waitingStatuses.count) == "48° ⏸")
    }

    @Test("关：spy 调用次数为 0、等待态为空、菜单栏无 ⏸、通知不被调用")
    @MainActor
    func 关闭态() {
        let spy = SpyStatusReader(result: scanResult([waitingStatus()]))
        let notifier = SpyNotifier()
        let model = AppModel(statusStore: spy, notifier: notifier, agentStatusEnabled: false)

        let readout = model.readAgentStatus(now: now)
        model.applyAgentStatus(readout)

        // 关键断言：不是「扫了但结果为空」，而是一次都没访问目录
        #expect(spy.scanCount == 0)
        #expect(model.waitingStatuses.isEmpty)
        #expect(readout == .empty)
        #expect(notifier.evaluateCount == 0)
        #expect(MenuBarLabel.make(temperature: 48, waitingCount: model.waitingStatuses.count) == "48°")
    }

    @Test("关：即使被硬塞进读取结果，也不发布、不通知")
    @MainActor
    func 关闭态双保险() {
        let spy = SpyStatusReader()
        let notifier = SpyNotifier()
        let model = AppModel(statusStore: spy, notifier: notifier, agentStatusEnabled: false)

        let status = waitingStatus()
        model.applyAgentStatus(AgentStatusReadout(all: [status], waiting: [status]))

        #expect(spy.scanCount == 0)
        #expect(model.waitingStatuses.isEmpty)
        #expect(notifier.evaluateCount == 0)
        #expect(MenuBarLabel.make(temperature: 48, waitingCount: model.waitingStatuses.count) == "48°")
    }

    @Test("长等待：AppModel 把活会话快照交给 WaitingPolicy 决定可见性")
    @MainActor
    func 长等待靠进程存活() {
        let stale = AgentStatus(sessionID: "session-long", agent: "claude-code",
                                state: .waiting, cwd: "/w/app", message: nil,
                                notificationType: "permission_prompt", pid: nil,
                                updatedAt: now.addingTimeInterval(-360), isStale: true)
        let spy = SpyStatusReader(result: scanResult([stale]))
        let model = AppModel(statusStore: spy, notifier: SpyNotifier(), agentStatusEnabled: true)

        let def = AgentDef(id: "claude", name: "Claude Code", symbol: "circle",
                           patterns: [], excludes: [], bin: nil, detect: [])
        let live = AgentSession(def: def, rootPid: 900, cpuPercent: 0, pids: [900],
                                busyChildren: [], cooled: false, hasOtherUid: false,
                                cwd: "/w/app")

        // 进程还在 → 仍算在等；进程没了 → 不再显示
        #expect(model.readAgentStatus(now: now, liveSessions: [live]).waiting
            .map(\.sessionID) == ["session-long"])
        #expect(model.readAgentStatus(now: now).waiting.isEmpty)
    }
}
