import Foundation
import AppKit
import SwiftUI

/// `--e2e` 关闭态探针：真被调用就返回一条等待记录，让漏掉的调用在菜单栏文案上露出来。
private final class E2EStatusReader: AgentStatusReading {
    var scanCount = 0

    func scan(now: Date) -> AgentStatusStore.ScanResult {
        scanCount += 1
        return AgentStatusStore.ScanResult(statuses: [
            AgentStatus(sessionID: "e2e-closed", agent: "claude", state: .waiting,
                        cwd: "/Users/e2e/project", message: nil,
                        notificationType: "permission_prompt", pid: nil,
                        updatedAt: now, isStale: false),
        ], skippedCount: 0)
    }
}

/// `Manatee --e2e`：不需要窗口、不需要辅助功能权限的自检。
/// 覆盖「启动链路能不能走通、视图能不能建、存储能不能读写」，
/// 用来兜住 CI 里最容易漏的那类回归（崩在启动、视图空白、SQL 写坏）。
enum E2E {
    private static var failures = 0

    static func run() -> Int32 {
        failures = 0
        print("\(AppInfo.name) e2e")

        // 1) 规则表
        let rules = Rules.shared.agents
        check("规则表", rules.count >= 10, "\(rules.count) 项")

        // 2) 进程扫描
        let procs = ProcessScanner().scan()
        check("进程扫描", procs.count > 10, "\(procs.count) 个进程")

        // 3) 会话聚合不崩
        let sessions = SessionAggregator.build(from: procs)
        check("会话聚合", true, "\(sessions.count) 个会话")

        // 4) 存储读写
        let dbPath = NSTemporaryDirectory() + "manatee-e2e-\(UUID().uuidString).sqlite"
        let store = MetricsStore(path: dbPath)
        let now = Int(Date().timeIntervalSince1970)
        store.record(agents: [(id: "e2e", cpuPercent: 100, memMB: 1, procs: 1)],
                     temp: 66, ports: [], at: now, interval: 1)
        store.flush()
        let totals = store.agentTotals(since: now - 60)
        check("存储写入/查询", totals.count == 1 && abs(totals[0].cpuSeconds - 1) < 0.01,
              String(format: "%.2fs", totals.first?.cpuSeconds ?? -1))
        try? FileManager.default.removeItem(atPath: dbPath)

        // 5) 三个视图能建出来并且有内容
        MainActor.assumeIsolated {
            let model = AppModel()
            check("面板视图", renders(PanelView(model: model, scrollable: true), in: CGSize(width: 340, height: 580)),
                  "340×580")
            check("设置页视图", renders(SettingsView(onClose: {}, scrollable: true), in: CGSize(width: 640, height: 760)),
                  "640×760")
            check("看板视图", renders(DashboardView(), in: CGSize(width: 640, height: 760)),
                  "640×760")
        }

        // 6) 等待态：菜单栏文案拼装 + 等待中的面板能建出来
        let waitingLabel = MenuBarLabel.make(temperature: 48, waitingCount: 2)
        check("菜单栏等待文案", waitingLabel == "48° ⏸2", waitingLabel)
        MainActor.assumeIsolated {
            let model = AppModel()
            model.waitingStatuses = [
                AgentStatus(sessionID: "e2e-wait-perm", agent: "claude", state: .waiting,
                            cwd: "/Users/e2e/project-one", message: nil,
                            notificationType: "permission_prompt", pid: nil,
                            updatedAt: Date(), isStale: false),
                AgentStatus(sessionID: "e2e-wait-input", agent: "codex", state: .waiting,
                            cwd: "/Users/e2e/project-two", message: nil,
                            notificationType: "idle_prompt", pid: nil,
                            updatedAt: Date(), isStale: false),
            ]
            check("等待态面板视图",
                  renders(PanelView(model: model, scrollable: true), in: CGSize(width: 340, height: 580)),
                  "2 个 waiting")
        }

        // 6a) 长等待：6 分钟前的 waiting 已 isStale，但进程还在 → 菜单栏仍该亮 ⏸；
        //     进程没了 → 不可见。纯函数断言，保证打包态（.app 内跑 e2e）也覆盖到。
        let sixMinutesAgo = Date().addingTimeInterval(-360)
        let longWait = AgentStatus(sessionID: "e2e-long-wait", agent: "claude-code",
                                   state: .waiting, cwd: "/Users/e2e/long-wait", message: nil,
                                   notificationType: "permission_prompt", pid: nil,
                                   updatedAt: sixMinutesAgo, isStale: true)
        let liveDef = AgentDef(id: "claude", name: "Claude Code", symbol: "circle",
                               patterns: [], excludes: [], bin: nil, detect: [])
        let liveSession = AgentSession(def: liveDef, rootPid: 4242, cpuPercent: 0,
                                       pids: [4242], busyChildren: [], cooled: false,
                                       hasOtherUid: false, cwd: "/Users/e2e/long-wait")
        check("长等待+活会话仍可见",
              WaitingPolicy.visibleWaiting([longWait], liveSessions: [liveSession],
                                           now: Date()).map(\.sessionID) == ["e2e-long-wait"])
        check("长等待+无会话不可见",
              WaitingPolicy.visibleWaiting([longWait], liveSessions: [], now: Date()).isEmpty)

        // 6b) 关闭态：spy 里有等待记录也不会被读到，菜单栏不能出现 ⏸。
        //     探针被调用就返回一条 waiting——如果哪天短路被去掉，这条会立刻挂。
        let closedSpy = E2EStatusReader()
        MainActor.assumeIsolated {
            let closed = AppModel(statusStore: closedSpy,
                                  notifier: AgentNotifier(bundleIdentifier: nil),
                                  agentStatusEnabled: false)
            closed.applyAgentStatus(closed.readAgentStatus(now: Date()))
            let label = MenuBarLabel.make(temperature: 48,
                                          waitingCount: closed.waitingStatuses.count)
            check("关闭态菜单栏无 ⏸", label == "48°", label)
        }
        check("关闭态零访问状态目录", closedSpy.scanCount == 0, "\(closedSpy.scanCount) 次")

        // 7) 通知层门禁：裸二进制（本机 .build/debug/Manatee）下必须自认不可用，
        //    且调用不崩。用 nil bundle id 构造，CI 里即使 e2e 跑在 Manatee.app 内
        //    （见 ci.yml）也覆盖得到这条路径，不会去碰系统通知中心。
        let bareNotifier = AgentNotifier(bundleIdentifier: nil)
        check("裸二进制下通知层不可用", !bareNotifier.isAvailable)
        bareNotifier.evaluate(statuses: [
            AgentStatus(sessionID: "e2e-notify", agent: "claude", state: .waiting,
                        cwd: "/Users/e2e/project", message: nil,
                        notificationType: "permission_prompt", pid: nil,
                        updatedAt: Date(), isStale: false),
        ])
        check("裸二进制下通知调用不崩", bareNotifier.pendingCount == 0)
        // 反过来：装进 .app 后 bundle id 存在，门禁必须放行。CI 里 e2e 就是在
        // Manatee.app 内跑的（见 ci.yml），这条能在真实打包产物上验证门禁的另一面。
        if Bundle.main.bundleIdentifier != nil {
            check("打包后通知层可用", AgentNotifier().isAvailable)
        } else {
            skip("打包后通知层可用（需要 .app 环境）")
        }

        // 8) 在线更新：版本比较 + release 解析 + 包校验
        check("版本比较 0.7.0 > 0.6.5", Semver.isNewer("0.7.0", than: "0.6.5"))
        check("版本比较 0.6.10 > 0.6.9", Semver.isNewer("0.6.10", than: "0.6.9"))
        check("版本比较 同版本不更新", !Semver.isNewer("0.6.5", than: "0.6.5"))
        check("版本比较 旧版不更新", !Semver.isNewer("0.5.9", than: "0.6.5"))
        check("版本比较 v 前缀", Semver.isNewer("v0.8.0", than: "0.6.5"))

        let sample = """
        {"tag_name":"v0.9.0","body":"修了什么","assets":[
          {"name":"notes.txt","browser_download_url":"https://example.com/a.txt"},
          {"name":"Manatee-0.9.0.zip","browser_download_url":"https://example.com/Manatee-0.9.0.zip"}]}
        """.data(using: .utf8)!
        let rel = Updater.parse(sample)
        check("release 解析版本", rel?.version == "0.9.0", rel?.version ?? "nil")
        check("release 解析 zip", rel?.zipURL?.lastPathComponent == "Manatee-0.9.0.zip",
              rel?.zipURL?.lastPathComponent ?? "nil")
        check("release 坏 JSON 不崩", Updater.parse(Data("{}".utf8)) == nil)

        // 包校验：拿当前安装的 app 当正样本，改 id 当负样本。
        // 裸二进制（.build/debug/Manatee、CI 的 e2e）下 Bundle.main 不是 .app，没有
        // Contents/Info.plist，validate 必然抛错——那是选错了样本，不是校验有问题。
        // 所以跳过并标 [skip]（不计失败），打包后的验收里仍照旧真校验。
        let selfApp = Bundle.main.bundleURL
        if selfApp.pathExtension == "app" {
            var badBundle = false
            do { try Updater.validate(selfApp, expecting: AppInfo.version) } catch { badBundle = true }
            check("包校验 正样本通过", !badBundle, selfApp.lastPathComponent)
            check("包校验 拒绝低版本",
                  { do { try Updater.validate(selfApp, expecting: "99.0.0"); return false }
                    catch { return true } }())
        } else {
            skip("包校验 正样本通过（需要 .app 环境）")
            skip("包校验 拒绝低版本（需要 .app 环境）")
        }

        // 9) release notes：真 markdown 要切成块；长备注在设置页里走内层滚动封顶，
        //    不能把整页撑成几千像素（设置页自身还在外层 ScrollView 里，双层滚动是这里的风险）
        MainActor.assumeIsolated {
            let doc = MarkdownDocument.parse(DebugFixtures.releaseNotesV080)
            check("长备注解析成块", doc.blocks.count >= 12, "\(doc.blocks.count) 块")

            let full = NSHostingView(rootView: ReleaseNotesView(notes: DebugFixtures.releaseNotesV080,
                                                                scrollable: false))
            full.frame = NSRect(origin: .zero, size: CGSize(width: 464, height: 900))
            full.appearance = NSAppearance(named: .darkAqua)
            full.layoutSubtreeIfNeeded()
            check("长备注长图模式整段展开", full.fittingSize.height > 300,
                  "\(Int(full.fittingSize.height))pt")

            let capped = NSHostingView(rootView: ReleaseNotesView(notes: DebugFixtures.releaseNotesV080))
            capped.frame = NSRect(origin: .zero, size: CGSize(width: 464, height: 900))
            capped.appearance = NSAppearance(named: .darkAqua)
            capped.layoutSubtreeIfNeeded()
            check("长备注在设置页里封顶", capped.fittingSize.height <= 260,
                  "\(Int(capped.fittingSize.height))pt")
        }

        print(failures == 0 ? "e2e passed" : "e2e failed: \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    /// 离屏布局一次，返回视图是否建出了实际内容
    @MainActor
    private static func renders<V: View>(_ view: V, in size: CGSize) -> Bool {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        return !host.subviews.isEmpty && host.fittingSize.height > 20
    }

    /// 环境不具备时跳过：不打印 [fail]，也不计入失败数
    private static func skip(_ name: String) {
        print("  [skip] \(name)")
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  [ok] \(name)\(detail.isEmpty ? "" : "  \(detail)")")
        } else {
            failures += 1
            print("  [fail] \(name)\(detail.isEmpty ? "" : "  \(detail)")")
        }
    }
}
