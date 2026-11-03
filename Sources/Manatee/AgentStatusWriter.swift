import Foundation
import Darwin

/// 写入 `AgentStatusStore` 读取的状态文件。
///
/// 字段名、目录与过期规则已由读取侧（`AgentStatus.swift`）和 PRD 5.1 修订版定死，
/// 写入侧只负责产出它能解析的 JSON。合法 state 集合直接复用 `AgentActivity`，
/// 不另维护一份字符串，避免两边漂移。
struct AgentStatusWriter {

    /// 状态目录：默认与读取方相同。`MANATEE_STATE_DIR` 只给测试和 `--e2e` 指向
    /// 临时目录，正常运行时不应设置——否则写出去的记录读取方看不到。
    static var resolvedDirectory: URL { AgentStatusStore.resolvedDirectory }

    /// `notification_type` 的合法取值。只放 Claude Code 已验证的两种：
    /// 上游以后加新值时应扩这里，读取侧仍会把未知值降级成「等待中」。
    static let allowedNotificationTypes: Set<String> = ["permission_prompt", "idle_prompt"]

    let directory: URL

    init(directory: URL = AgentStatusWriter.resolvedDirectory) {
        self.directory = directory
    }

    /// 原子写入一个会话的状态。
    ///
    /// 先写同目录的临时文件再 `rename(2)` 覆盖：读取方每个 tick 都在扫这个目录，
    /// 直接原地覆盖会让它读到半截 JSON（计入 skippedCount）。临时文件用 `.tmp`
    /// 扩展名，读取方只认 `.json`，写崩残留也不会被当成坏文件。
    ///
    /// - Returns: 最终文件路径，便于测试和调用方打印。
    @discardableResult
    func write(
        sessionID: String,
        agent: String,
        state: String,
        cwd: String,
        message: String? = nil,
        notificationType: String? = nil,
        now: Date = Date()
    ) throws -> URL {
        // 读取侧的会话 id 只从文件名取，所以它必须是一个安全的单段文件名：
        // 含路径分隔符会写到目录外，`.` 开头会被读取方的 skipsHiddenFiles 忽略，
        // 后者等于静默丢数据，所以一并拒掉。
        let trimmedSession = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSession.isEmpty,
              !sessionID.contains("/"), !sessionID.contains("\\"),
              !sessionID.hasPrefix(".")
        else {
            throw AgentStatusWriterError.invalidSessionID
        }
        guard !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentStatusWriterError.emptyAgent
        }
        guard !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentStatusWriterError.emptyCwd
        }
        guard let activity = AgentActivity(rawValue: state) else {
            throw AgentStatusWriterError.invalidState(state)
        }
        // 空串按没传处理（hook 模板展开出空值时不该整条记录失败）；非法值必须当场拒绝
        let trimmedType = notificationType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (trimmedType?.isEmpty ?? true) ? nil : trimmedType
        if let type, !Self.allowedNotificationTypes.contains(type) {
            throw AgentStatusWriterError.invalidNotificationType(type)
        }

        let payload = Payload(agent: agent, state: activity.rawValue, cwd: cwd,
                              message: message, notificationType: type,
                              updatedAt: now.timeIntervalSince1970)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(payload)
        data.append(0x0A)                     // 直接 cat 时末尾有换行

        let fm = FileManager.default
        // 写入方负责建目录：读取方刻意不建，没开过功能时目录不该凭空出现
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let finalURL = directory.appendingPathComponent("\(sessionID).json")
        // 带随机后缀，同一会话的并发 hook 各写各的临时文件，rename 后仍是完整 JSON
        let tempURL = directory
            .appendingPathComponent("\(sessionID).json.\(UUID().uuidString).tmp")
        try data.write(to: tempURL)
        do {
            // rename 在同一文件系统内原子替换，且目标已存在也不会失败；
            // FileManager.moveItem 遇到已存在的目标会抛错，不能拿来替换。
            guard rename(tempURL.path, finalURL.path) == 0 else {
                throw AgentStatusWriterError.writeFailed(errno: errno)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
        return finalURL
    }

    /// 与 `AgentStatusStore.RawStatus` 对应的可读子集。
    ///
    /// 故意不写 `pid`：hook payload 里没有它，POC 已确认，读取方也只当可选。
    /// 注意 `message` 为 nil 时合成的 `encodeIfPresent` 会整键省略。
    struct Payload: Encodable {
        let agent: String
        let state: String
        let cwd: String
        let message: String?
        let notificationType: String?
        let updatedAt: Double

        private enum CodingKeys: String, CodingKey {
            case agent, state, cwd, message
            case notificationType = "notification_type"
            case updatedAt = "updated_at"
        }
    }
}

/// 写入侧全部拒绝原因。文案直接进 `manatee-hook: <原因>` 那一行 stderr。
enum AgentStatusWriterError: Error, Equatable, CustomStringConvertible {
    case invalidSessionID
    case emptyAgent
    case emptyCwd
    case invalidState(String)
    case invalidNotificationType(String)
    case writeFailed(errno: Int32)

    var description: String {
        switch self {
        case .invalidSessionID:
            return "session 为空或不是合法文件名"
        case .emptyAgent:
            return "agent 不能为空"
        case .emptyCwd:
            return "cwd 不能为空"
        case .invalidState(let state):
            return "非法 state \"\(state)\"（可选 running|waiting|idle|error）"
        case .invalidNotificationType(let type):
            return "非法 notification-type \"\(type)\"（可选 permission_prompt|idle_prompt）"
        case .writeFailed(let code):
            return "写入失败（errno \(code)）"
        }
    }
}
