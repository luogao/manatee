import Foundation

/// agent 自己上报的活动状态。文件里可能出现的四种取值，原样映射。
enum AgentActivity: String, Sendable {
    case running
    case waiting
    case idle
    case error
}

/// 一个会话在某一时刻的状态快照。
///
/// `message` 来自 hook payload（如 `last_assistant_message`），可能含命令、
/// 路径等隐私内容：只允许展示在面板里，禁止写日志或外发。
struct AgentStatus: Equatable, Sendable {
    /// 取自状态文件名去掉 `.json`。hook payload 里的 `session_id` 也是它。
    let sessionID: String
    let agent: String
    /// 已应用过期规则后的状态：文件超 5 分钟未更新时这里会是 `.idle`。
    let state: AgentActivity
    let cwd: String
    let message: String?
    /// Claude Code `Notification` 的细分：`permission_prompt` / `idle_prompt`。
    /// 旧状态文件没有这个键时保持 nil（界面按「等待中」降级，不能当成等权限）。
    let notificationType: String?
    /// hook payload 里没有 pid，通用 CLI 才可能带，所以可选。
    let pid: Int?
    let updatedAt: Date
    /// `now - updated_at > 300` 时为 true（严格大于，见 PRD 5.2）。
    let isStale: Bool
}

/// 读取 `~/Library/Application Support/Manatee/agent-state/*.json`。
///
/// 只做扫描与过期判定，不写 UI、不建目录。目录由写入方（hook CLI）负责创建；
/// 读取方在没有状态目录时必须保持静默，不能因为功能开启就凭空建目录。
final class AgentStatusStore: Sendable {

    /// 一次扫描的结果。
    ///
    /// 用返回值而不是 `skippedCount` 属性：store 本身无可变状态，调用方拿到的
    /// 是这一次 tick 的完整快照，并发调用或跨队列传递都不会读到上一次的计数。
    struct ScanResult: Equatable, Sendable {
        let statuses: [AgentStatus]
        let skippedCount: Int

        static let empty = ScanResult(statuses: [], skippedCount: 0)
    }

    /// 超过 5 分钟没有更新 → 按 idle 处理，避免菜单栏卡在「等待」。
    static let staleAfter: TimeInterval = 300
    /// 超过 24 小时的文件在扫描时顺手清掉，避免目录无限增长。
    static let expireAfter: TimeInterval = 24 * 60 * 60

    /// 真实路径。构造时可以换成任意目录（测试用临时目录）。
    static let defaultDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Manatee", isDirectory: true)
            .appendingPathComponent("agent-state", isDirectory: true)
    }()

    /// 实际读取的目录。`MANATEE_STATE_DIR` 只给测试和 `--e2e` 指向临时目录；
    /// 写入方也复用这一处，避免读写两侧对同一个环境变量有两种解释。
    static var resolvedDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MANATEE_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultDirectory
    }

    let directory: URL

    /// - Note: 不创建目录。目录不存在是正常状态（功能未开启或还没人上报）。
    init(directory: URL = AgentStatusStore.resolvedDirectory) {
        self.directory = directory
    }

    /// 扫描一次状态目录。
    ///
    /// 目录不存在、无权限等任何读取失败都返回空结果，不抛错、不建目录；
    /// 单个文件解析失败只影响该文件，计入 `skippedCount`。
    func scan(now: Date = Date()) -> ScanResult {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var statuses: [AgentStatus] = []
        var skipped = 0

        for url in entries where url.pathExtension.lowercased() == "json" {
            let sessionID = url.deletingPathExtension().lastPathComponent
            guard !sessionID.isEmpty else {
                skipped += 1
                continue
            }

            switch load(url, sessionID: sessionID, now: now) {
            case .status(let status):
                statuses.append(status)
            case .expired:
                // 已从磁盘删除，也不再出现在结果里
                try? fm.removeItem(at: url)
            case .invalid:
                skipped += 1
            }
        }

        // 按会话 id 排序，结果稳定，便于测试与 UI diff
        statuses.sort { $0.sessionID < $1.sessionID }
        return ScanResult(statuses: statuses, skippedCount: skipped)
    }

    private enum LoadOutcome {
        case status(AgentStatus)
        case expired
        case invalid
    }

    private func load(_ url: URL, sessionID: String, now: Date) -> LoadOutcome {
        // 文件可能在列目录之后被写入方替换/删除：读失败一律当坏文件跳过
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(RawStatus.self, from: data)
        else {
            return .invalid
        }

        // 必填字段缺失由 Decodable 兜住；这里再挡掉「有键但为空」的无效记录
        let agent = raw.agent.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = raw.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !agent.isEmpty, !cwd.isEmpty,
              let parsedState = AgentActivity(rawValue: raw.state),
              raw.updatedAt.isFinite
        else {
            return .invalid
        }

        let updatedAt = Date(timeIntervalSince1970: raw.updatedAt)
        let age = now.timeIntervalSince(updatedAt)

        if age > Self.expireAfter {
            return .expired
        }

        let stale = age > Self.staleAfter
        let message = raw.message.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }
        // 空字符串按「没写」处理；未知取值原样保留，界面再降级成「等待中」
        let notificationType = raw.notificationType.flatMap { text -> String? in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return .status(AgentStatus(
            sessionID: sessionID,
            agent: agent,
            state: stale ? .idle : parsedState,
            cwd: cwd,
            message: message,
            notificationType: notificationType,
            pid: raw.pid,
            updatedAt: updatedAt,
            isStale: stale
        ))
    }

    /// 只声明读哪些字段；多余字段 Decodable 默认忽略，Claude Code 以后加字段
    /// 不会让整条记录解析失败。
    private struct RawStatus: Decodable {
        let agent: String
        let state: String
        let cwd: String
        let message: String?
        let notificationType: String?
        let pid: Int?
        let updatedAt: Double

        private enum CodingKeys: String, CodingKey {
            case agent, state, cwd, message, pid
            case notificationType = "notification_type"
            case updatedAt = "updated_at"
        }
    }
}
