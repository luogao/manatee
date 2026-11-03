import Foundation

/// `Manatee --hook` 的参数。
///
/// 解析单独抽出来，是为了能脱离 GUI 单测「非法参数必须 exit 2」这条契约：
/// `main.swift` 的顶层代码被首行调用时，同文件后面的全局变量还没初始化，
/// 把逻辑留在那里既难测也容易踩初始化顺序的坑。
struct HookCommand: Equatable {
    let state: String
    let agent: String
    let cwd: String
    let session: String
    let message: String?
    let notificationType: String?

    /// 参数名 → 归一化键。`--hook` 是唯一的无值开关，单独处理。
    private static let flags: [String: String] = [
        "--state": "state",
        "--agent": "agent",
        "--cwd": "cwd",
        "--session": "session",
        "--message": "message",
        "--notification-type": "notificationType",
    ]

    /// - Returns: 失败时给出一行 stderr 文案，由调用方统一映射成退出码 2。
    static func parse(_ argv: [String]) -> Result<HookCommand, HookParseError> {
        var options: [String: String] = [:]
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            guard arg.hasPrefix("--") else { return .failure(HookParseError("无法识别的参数 \(arg)")) }
            i += 1
            if arg == "--hook" { continue }

            let key: String
            let value: String
            if let eq = arg.firstIndex(of: "=") {
                key = String(arg[arg.startIndex..<eq])
                value = String(arg[arg.index(after: eq)...])
            } else {
                guard i < argv.count else { return .failure(HookParseError("\(arg) 缺少取值")) }
                key = arg
                value = argv[i]
                i += 1
            }
            guard let canonical = flags[key] else { return .failure(HookParseError("未知参数 \(key)")) }
            options[canonical] = value
        }

        // 空值按缺参数处理：读取方会把空字段当坏文件跳过，报错比静默写坏文件清楚
        guard let state = options["state"], !state.isEmpty else { return .failure(HookParseError("缺少 --state")) }
        guard let agent = options["agent"], !agent.isEmpty else { return .failure(HookParseError("缺少 --agent")) }
        guard let cwd = options["cwd"], !cwd.isEmpty else { return .failure(HookParseError("缺少 --cwd")) }
        guard let session = options["session"], !session.isEmpty else { return .failure(HookParseError("缺少 --session")) }

        // 空串视为没传（hook 模板展开出空值时不该整条记录失败），非法值当场拒绝
        let rawType = options["notificationType"]
        let notificationType = (rawType?.isEmpty ?? true) ? nil : rawType
        if let notificationType,
           !AgentStatusWriter.allowedNotificationTypes.contains(notificationType) {
            return .failure(HookParseError(
                AgentStatusWriterError.invalidNotificationType(notificationType).description))
        }

        return .success(HookCommand(state: state, agent: agent, cwd: cwd, session: session,
                                    message: options["message"],
                                    notificationType: notificationType))
    }
}

/// 参数错误。`description` 原样进 `manatee-hook: <原因>` 那一行 stderr。
struct HookParseError: Error, Equatable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
