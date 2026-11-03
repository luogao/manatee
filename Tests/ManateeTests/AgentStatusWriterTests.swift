import Foundation
import Testing
@testable import Manatee

/// 固定的「现在」：避免测试依赖真实时钟，也和读取侧测试的过期边界解耦。
private let writerNow = Date(timeIntervalSince1970: 1_760_000_000)

// MARK: - 临时目录工具

/// 每个测试用独立临时目录，跑完删干净；绝不碰真实的 Application Support。
private func withWriterTempDir(_ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ManateeAgentStatusWriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

/// 断言写入抛出的正是期望的那个错误，避免 `catch` 把无关错误也当成通过。
private func expectWriterError(_ expected: AgentStatusWriterError,
                               _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("应当抛出 \(expected)，但没有报错")
    } catch let error as AgentStatusWriterError {
        #expect(error == expected)
    } catch {
        Issue.record("抛出了非预期错误：\(error)")
    }
}

/// 目录里的临时文件（写完不该留下任何一个）。
private func tempLeftovers(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".tmp") }
}

// MARK: - 测试

@Suite("AgentStatusWriter 写入状态目录")
struct AgentStatusWriterTests {

    @Test("目录不存在 → 自动创建目录并落盘")
    func 自动建目录() throws {
        // 故意多一层不存在的父目录，验证 withIntermediateDirectories
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManateeAgentStatusWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("nested/agent-state", isDirectory: true)

        let url = try AgentStatusWriter(directory: dir).write(
            sessionID: "s1", agent: "claude-code", state: "waiting", cwd: "/tmp", now: writerNow)

        #expect(url.lastPathComponent == "s1.json")
        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("连写两次 → 内容是后一次，且不留 .tmp")
    func 覆盖写入() throws {
        try withWriterTempDir { dir in
            let writer = AgentStatusWriter(directory: dir)
            try writer.write(sessionID: "s1", agent: "claude-code", state: "waiting",
                             cwd: "/tmp/first", now: writerNow)
            try writer.write(sessionID: "s1", agent: "claude-code", state: "running",
                             cwd: "/tmp/second", now: writerNow)

            let scan = AgentStatusStore(directory: dir).scan(now: writerNow)
            let status = try #require(scan.statuses.first)
            #expect(scan.statuses.count == 1)
            #expect(status.state == .running)
            #expect(status.cwd == "/tmp/second")
            #expect(try tempLeftovers(in: dir).isEmpty)
        }
    }

    @Test("非法 state / 空 cwd / 空 session → 抛错且不产生文件")
    func 拒绝非法输入() throws {
        // 目录本身也不该被创建：校验排在建目录之前
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManateeAgentStatusWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("state", isDirectory: true)
        let writer = AgentStatusWriter(directory: dir)

        expectWriterError(.invalidState("nope")) {
            try writer.write(sessionID: "s2", agent: "x", state: "nope", cwd: "/tmp", now: writerNow)
        }
        expectWriterError(.emptyCwd) {
            try writer.write(sessionID: "s3", agent: "x", state: "waiting", cwd: "  ", now: writerNow)
        }
        expectWriterError(.emptyAgent) {
            try writer.write(sessionID: "s4", agent: "", state: "waiting", cwd: "/tmp", now: writerNow)
        }
        expectWriterError(.invalidSessionID) {
            try writer.write(sessionID: "a/b", agent: "x", state: "waiting", cwd: "/tmp", now: writerNow)
        }
        // `.` 开头会被读取方的 skipsHiddenFiles 悄悄忽略，宁可当场报错
        expectWriterError(.invalidSessionID) {
            try writer.write(sessionID: ".hidden", agent: "x", state: "waiting", cwd: "/tmp", now: writerNow)
        }

        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    /// 跨卡契约：读侧（`AgentStatusStore`）必须能原样扫回写侧产出的文件。
    @Test("读写成对 → .waiting、cwd 一致、不过期")
    func 读写成对() throws {
        try withWriterTempDir { dir in
            try AgentStatusWriter(directory: dir).write(
                sessionID: "s1", agent: "claude-code", state: "waiting",
                cwd: "/Users/x/project", now: writerNow)

            let scan = AgentStatusStore(directory: dir).scan(now: writerNow)
            #expect(scan.skippedCount == 0)

            let status = try #require(scan.statuses.first)
            #expect(status.sessionID == "s1")
            #expect(status.agent == "claude-code")
            #expect(status.state == .waiting)
            #expect(status.cwd == "/Users/x/project")
            #expect(status.isStale == false)
            #expect(status.updatedAt == writerNow)
            #expect(status.pid == nil)
            #expect(status.message == nil)
        }
    }

    @Test("notification_type 落盘并原样读回；不传时整键省略")
    func 等待细分() throws {
        try withWriterTempDir { dir in
            let writer = AgentStatusWriter(directory: dir)
            let typed = try writer.write(sessionID: "s1", agent: "claude-code", state: "waiting",
                                         cwd: "/tmp", notificationType: "idle_prompt", now: writerNow)
            try writer.write(sessionID: "s2", agent: "claude-code", state: "waiting",
                             cwd: "/tmp", now: writerNow)

            let scan = AgentStatusStore(directory: dir).scan(now: writerNow)
            let byID = Dictionary(uniqueKeysWithValues: scan.statuses.map { ($0.sessionID, $0) })
            #expect(byID["s1"]?.notificationType == "idle_prompt")
            #expect(byID["s2"]?.notificationType == nil)

            // 键名必须和读取侧/Claude Code hook 对齐
            let data = try Data(contentsOf: typed)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["notification_type"] as? String == "idle_prompt")
        }
    }

    @Test("非法 notification-type → 抛错，不建目录也不写文件")
    func 拒绝非法细分() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManateeAgentStatusWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("state", isDirectory: true)

        expectWriterError(.invalidNotificationType("nope")) {
            try AgentStatusWriter(directory: dir).write(
                sessionID: "s5", agent: "x", state: "waiting", cwd: "/tmp",
                notificationType: "nope", now: writerNow)
        }
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    @Test("JSON 字段与读取方对齐：updated_at 是 epoch 秒，不写 pid")
    func 字段契约() throws {
        try withWriterTempDir { dir in
            let url = try AgentStatusWriter(directory: dir).write(
                sessionID: "s1", agent: "claude-code", state: "error",
                cwd: "/tmp", message: "审批：rm -rf /tmp/x", now: writerNow)

            let data = try Data(contentsOf: url)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

            #expect(Set(json.keys) == ["agent", "state", "cwd", "message", "updated_at"])
            #expect(json["pid"] == nil)
            #expect(json["state"] as? String == "error")
            let updated = try #require(json["updated_at"] as? Double)
            #expect(updated == writerNow.timeIntervalSince1970)
            // CLI 不做截断、不改写，含中文和空格也要原样落地
            #expect(json["message"] as? String == "审批：rm -rf /tmp/x")
        }
    }
}
