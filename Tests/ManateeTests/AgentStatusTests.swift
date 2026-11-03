import Foundation
import Testing
@testable import Manatee

/// 固定的「现在」，避免测试依赖真实时钟
private let now = Date(timeIntervalSince1970: 1_760_000_000)

// MARK: - 临时目录工具

/// 每个测试用独立的临时目录，跑完删干净；绝不碰真实的 Application Support。
private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ManateeAgentStatusTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

@discardableResult
private func writeStatus(
    _ name: String,
    in dir: URL,
    agent: String = "claude-code",
    state: String = "waiting",
    cwd: String = "/Users/x/project",
    message: String? = nil,
    pid: Int? = nil,
    updatedAt: Date = now,
    extra: [String: Any] = [:]
) throws -> URL {
    var fields: [String: Any] = [
        "agent": agent,
        "state": state,
        "cwd": cwd,
        "updated_at": updatedAt.timeIntervalSince1970,
    ]
    if let message { fields["message"] = message }
    if let pid { fields["pid"] = pid }
    fields.merge(extra) { _, new in new }

    let data = try JSONSerialization.data(withJSONObject: fields)
    let url = dir.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

@discardableResult
private func writeRaw(_ name: String, in dir: URL, _ text: String) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

// MARK: - 测试

@Suite("AgentStatusStore 状态目录")
struct AgentStatusTests {

    @Test("两个 waiting 文件 → 返回两条 .waiting")
    func 两个等待文件() throws {
        try withTempDir { dir in
            try writeStatus("session-a.json", in: dir)
            try writeStatus("session-b.json", in: dir)

            let result = AgentStatusStore(directory: dir).scan(now: now)

            #expect(result.statuses.count == 2)
            #expect(result.statuses.allSatisfy { $0.state == .waiting })
            #expect(result.statuses.allSatisfy { $0.isStale == false })
            #expect(Set(result.statuses.map(\.sessionID)) == ["session-a", "session-b"])
            #expect(result.skippedCount == 0)
        }
    }

    @Test("过期阈值取「严格大于 300 秒」：300 秒整不过期，301 秒过期")
    func 过期阈值边界() throws {
        try withTempDir { dir in
            try writeStatus("edge-300.json", in: dir, updatedAt: now.addingTimeInterval(-300))
            try writeStatus("edge-301.json", in: dir, updatedAt: now.addingTimeInterval(-301))

            let result = AgentStatusStore(directory: dir).scan(now: now)
            let byID = Dictionary(uniqueKeysWithValues: result.statuses.map { ($0.sessionID, $0) })

            #expect(byID["edge-300"]?.state == .waiting)
            #expect(byID["edge-300"]?.isStale == false)
            #expect(byID["edge-301"]?.state == .idle)
            #expect(byID["edge-301"]?.isStale == true)
            #expect(result.skippedCount == 0)
        }
    }

    @Test("6 分钟前的文件 → .idle + isStale = true")
    func 六分钟过期() throws {
        try withTempDir { dir in
            try writeStatus("old.json", in: dir, updatedAt: now.addingTimeInterval(-360))

            let result = AgentStatusStore(directory: dir).scan(now: now)

            #expect(result.statuses.count == 1)
            #expect(result.statuses.first?.state == .idle)
            #expect(result.statuses.first?.isStale == true)
        }
    }

    @Test("25 小时前的文件 → 扫描时从磁盘删除")
    func 二十四小时清理() throws {
        try withTempDir { dir in
            let expired = try writeStatus("expired.json", in: dir,
                                          updatedAt: now.addingTimeInterval(-25 * 3600))
            try writeStatus("fresh.json", in: dir)

            let result = AgentStatusStore(directory: dir).scan(now: now)

            #expect(FileManager.default.fileExists(atPath: expired.path) == false)
            #expect(result.statuses.map(\.sessionID) == ["fresh"])
            #expect(result.skippedCount == 0)
        }
    }

    @Test("坏 JSON / 缺 cwd → 跳过并计入 skippedCount，其余文件照常返回")
    func 坏文件隔离() throws {
        try withTempDir { dir in
            try writeRaw("broken.json", in: dir, "{ not json")
            try writeRaw("no-cwd.json", in: dir,
                         #"{"agent":"claude-code","state":"waiting","updated_at":1760000000}"#)
            try writeStatus("good.json", in: dir)

            let result = AgentStatusStore(directory: dir).scan(now: now)

            #expect(result.statuses.map(\.sessionID) == ["good"])
            #expect(result.skippedCount == 2)
        }
    }

    @Test("目录不存在 → 返回空且不创建目录")
    func 目录不存在() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManateeAgentStatusTests-missing-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = AgentStatusStore(directory: dir).scan(now: now)

        #expect(result.statuses.isEmpty)
        #expect(result.skippedCount == 0)
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test("多余字段不影响解析；pid / message 缺省为 nil")
    func 容忍多余字段() throws {
        try withTempDir { dir in
            try writeStatus("future.json", in: dir, extra: [
                "transcript_path": "/private/tmp/transcript.jsonl",
                "hook_event_name": "Notification",
                "notification_type": "permission_prompt",
                "background_tasks": [["command": "swift build"]],
            ])

            let result = AgentStatusStore(directory: dir).scan(now: now)

            #expect(result.statuses.count == 1)
            #expect(result.skippedCount == 0)
            #expect(result.statuses.first?.pid == nil)
            #expect(result.statuses.first?.message == nil)
        }
    }

    @Test("pid / message / 非 waiting 状态原样读出")
    func 字段透传() throws {
        try withTempDir { dir in
            try writeStatus("error-session.json", in: dir,
                            state: "error", message: "boom", pid: 12345)

            let result = AgentStatusStore(directory: dir).scan(now: now)

            let status = try #require(result.statuses.first)
            #expect(status.state == .error)
            #expect(status.message == "boom")
            #expect(status.pid == 12345)
            #expect(status.cwd == "/Users/x/project")
            #expect(status.updatedAt == now)
        }
    }
}
