import Foundation
import AppKit
import SwiftUI

// ── POC 入口：--dump 走命令行自检，其余进 GUI ──

let argv = CommandLine.arguments

// agent hook 调用：写一个状态文件就退出，必须排在所有 GUI 初始化之前
if argv.contains("--hook") {
    exit(runHook(argv))
}

if argv.contains("--dump") {
    runDump()
    exit(0)
}

if argv.contains("--late-test") {
    // 自检：补降 —— 降温后 agent 又起了新子进程，看它是否被自动纳入
    let model = AppModel()
    model.loadSync()
    // 只动测试用的 pi 会话，别把用户正在跑的 agent 降级
    for sess in model.sessions where sess.def.id == "pi" {
        model.cooled.formUnion(Cooler.cool(pids: sess.pids))
    }
    Thread.sleep(forTimeInterval: 0.8)
    print("[late] 首轮 cooled=\(model.cooled.count) sessions=\(model.sessions.map { "\($0.def.id):\($0.pids.count)" })")
    for i in 1...6 {
        Thread.sleep(forTimeInterval: 1.5)
        model.loadSync()
        model.coolLatecomers(model.sessions)
        Thread.sleep(forTimeInterval: 0.7)
        print("[late] 第\(i)轮 cooled=\(model.cooled.count) sessions=\(model.sessions.map { "\($0.def.id):\($0.pids.count)" })")
    }
    model.restoreAll()
    print("[late] 已恢复")
    exit(0)
}

if argv.contains("--cool-test") {
    // 自检：把 CPU 最高的 agent 会话整体降温，观察 CPU/温度变化，再恢复
    let scanner = ProcessScanner()
    let temp = TemperatureReader()
    _ = scanner.scan()
    Thread.sleep(forTimeInterval: 1.0)

    func snapshot(_ tag: String) -> (Double, [AgentSession]) {
        let s = SessionAggregator.build(from: scanner.scan())
        let t = temp?.hottestSilicon()?.celsius ?? 0
        let top = s.first
        print(String(format: "  [%@] 最高温 %.1f℃ | %@ %.0f%% (%d 进程)",
                     tag, t, top?.def.name ?? "无", top?.cpuPercent ?? 0, top?.pids.count ?? 0))
        return (t, s)
    }

    print("=== 降温前 ===")
    let (_, before) = snapshot("before")
    guard let top = before.first else { print("没有检测到 agent"); exit(1) }
    print("  目标: \(top.def.name) pid=\(top.rootPid) 进程数=\(top.pids.count)")

    let ok = Cooler.cool(pids: top.pids)
    print("  已降级 \(ok.count)/\(top.pids.count) 个进程")

    print("=== 降级后 25s ===")
    Thread.sleep(forTimeInterval: 25)
    _ = snapshot("cooled")

    Cooler.restore(pids: ok)
    print("=== 已恢复全速 ===")
    Thread.sleep(forTimeInterval: 20)
    _ = snapshot("restored")
    exit(0)
}

if argv.contains("--e2e") {
    // 需要 NSApplication 才能建 NSHostingView
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    exit(E2E.run())
}

// 只跑一次联网检查，打印结果后退出（排查「点了检查更新没反应」用）
if argv.contains("--update-check") {
    // 顶层代码本身就跑在主线程，只是编译器不认它属于 MainActor。
    // 不能再用 DispatchQueue.main.sync——主线程同步等主队列会直接 trap。
    var rc: Int32 = 1
    MainActor.assumeIsolated { rc = UpdateSelfTest.liveCheck() }
    exit(rc)
}

// 真跑更新链路：--update-selftest <zip 路径> [目标目录]
// 解包 → 校验 → 在隔离目录里做一次完整的「替换 + 回滚」演练，不碰真实安装。
if let i = argv.firstIndex(of: "--update-selftest"), argv.count > i + 1 {
    exit(UpdateSelfTest.run(zip: argv[i + 1],
                            targetDir: argv.count > i + 2 ? argv[i + 2] : nil))
}

if argv.contains("--seed-metrics") {
    // 造 24 小时假数据，给截图/验证用（配合 MANATEE_METRICS_DB 指向临时库）
    let store = MetricsStore.shared
    let now = Int(Date().timeIntervalSince1970)
    for i in stride(from: 24 * 3600, through: 0, by: -300) {
        let ts = now - i
        let phase = Double(i) / 3600.0
        let claude = 25 + 45 * abs(sin(phase * 1.3))
        let codex = 12 + 30 * abs(sin(phase * 0.7 + 1.1))
        let ffmpeg = max(0, 70 * sin(phase * 2.4 - 0.6))
        let gemini = max(0, 18 * sin(phase * 0.4 + 2))
        store.record(agents: [
            (id: "claude", cpuPercent: claude, memMB: 820, procs: 7),
            (id: "codex", cpuPercent: codex, memMB: 540, procs: 4),
            (id: "ffmpeg", cpuPercent: ffmpeg, memMB: 300, procs: 2),
            (id: "gemini", cpuPercent: gemini, memMB: 260, procs: 3),
        ], temp: 45 + 24 * abs(sin(phase * 0.9 + 0.3)),
           ports: Int(phase) % 3 == 0 ? [
               DevService(pid: 90001, port: 5173, command: "node", uptime: 3600, stray: false,
                          cwd: "/Users/gaogao/Documents/Hermes/video-studio-agent/packages/web"),
               DevService(pid: 90002, port: 3000, command: "node", uptime: 7200, stray: true,
                          cwd: "/Users/gaogao/Documents/Hermes/manatee-website"),
           ] : [],
           at: ts, interval: 300)
    }
    Thread.sleep(forTimeInterval: 2.0)
    print("seeded")
    exit(0)
}

if argv.contains("--render") {
    // 离屏渲染面板 PNG（不需要屏幕录制权限）
    // --lang=en|zh 临时覆盖界面语言，用来出两版截图
    if let f = argv.first(where: { $0.hasPrefix("--lang=") }) {
        let v = String(f.dropFirst(7))
        LangStore.shared.current = (v == "zh") ? .zh : .en
    }
    let model = AppModel()
    model.loadSync()
    // 演示用状态注入：--fake=91 覆盖温度，--empty 清空列表，--cooled 把第一行标为已降温
    if let f = argv.first(where: { $0.hasPrefix("--fake=") }), let v = Double(f.dropFirst(7)) {
        model.temperature = v
        if model.sensorName.isEmpty { model.sensorName = "PMU tdie8" }
    }
    if argv.contains("--empty") { model.sessions = [] }
    if argv.contains("--alert"), let first = model.sessions.first {
        model.alerts = [first.rootPid: 312]
    }
    if argv.contains("--dev") {
        model.devServices = [
            DevService(pid: 90001, port: 3000, command: "node", uptime: 5400, stray: true,
                       bind: "127.0.0.1", argv: "node server.js --port 3000",
                       cwd: "/Users/gaogao/Documents/Hermes/manatee-website", parentName: "launchd", parentPid: 1,
                       purpose: "Express"),
            DevService(pid: 90002, port: 5173, command: "node", uptime: 2100, stray: true,
                       bind: "::1", argv: "node .../vite/bin/vite.js --port 5173",
                       cwd: "/Users/gaogao/Documents/Hermes/video-studio-agent/packages/web",
                       parentName: "pnpm", parentPid: 77241, purpose: "Vite"),
            DevService(pid: 90003, port: 8000, command: "python", uptime: 720, stray: false,
                       bind: "*", argv: "python3 manage.py runserver 8000",
                       cwd: "/Users/gaogao/Documents/Hermes/netflav_crawler", parentName: "zsh", parentPid: 9901,
                       purpose: "Netflav 数据浏览器"),
        ]
    }
    if argv.contains("--many"), let seed = model.sessions.first {
        // 造一堆会话让列表溢出，用来验证底部渐隐提示
        model.sessions = (0..<14).map { i in
            var s = seed
            s.cpuPercent = Double(90 - i * 6)
            s.busyChildren = i % 3 == 0 ? [("node", Double(80 - i * 5))] : []
            s.pids = [seed.rootPid]
            return s
        }
        model.processCount = 612
    }
    if argv.contains("--cooled"), let first = model.sessions.first {
        model.cooled = Set(first.pids)
    }
    // 官网/README 用图：造一个「一个会话 340%、已连续满载 12 分钟」的状态，
    // 和落地页第二屏的对照文案必须一致，别用两条不同的假数据
    if argv.contains("--demo") {
        model.temperature = 43
        if model.sensorName.isEmpty { model.sensorName = "PMU tdie12" }
        let seed = model.sessions.first
        let def = seed?.def ?? AgentRegistry.all.first!
        var hot = seed ?? AgentSession(def: def, rootPid: 77245, cpuPercent: 340, pids: [77245],
                                       busyChildren: [("node", 340)], cooled: false, hasOtherUid: false)
        hot.cpuPercent = 340
        hot.busyChildren = [("node", 340)]
        hot.pids = (0..<14).map { pid_t(77245 + $0) }
        hot.cooled = false
        let idle = AgentSession(def: def, rootPid: 6086, cpuPercent: 0, pids: [6086],
                                busyChildren: [], cooled: false, hasOtherUid: false)
        let codex = AgentSession(def: AgentRegistry.all.first { $0.id == "codex" } ?? def,
                                 rootPid: 78120, cpuPercent: 62, pids: [78120, 78121],
                                 busyChildren: [("node", 62)], cooled: false, hasOtherUid: false)
        model.sessions = [hot, codex, idle]
        model.alerts = [hot.rootPid: 720]
        model.processCount = 869
    }
    // 等待态种子：--waiting 塞 2 个 waiting，菜单栏出 "43° ⏸2"、面板出两个徽标。
    // 放在 --demo 之后，才能对到演示用的会话；带 pid 是让演示数据精确命中，
    // 真实 hook payload 没有 pid，走 cwd + agent 匹配。
    if argv.contains("--waiting") {
        let now = Date()
        let types: [String?] = ["permission_prompt", "idle_prompt"]
        let targets = Array(model.sessions.prefix(2))
        model.waitingStatuses = (0..<2).map { i in
            let session = targets.indices.contains(i) ? targets[i] : nil
            return AgentStatus(sessionID: "render-waiting-\(i + 1)",
                               agent: session?.def.id ?? (i == 0 ? "claude" : "codex"),
                               state: .waiting,
                               cwd: session?.cwd ?? "/Users/gaogao/Documents/Hermes/manatee",
                               message: nil,
                               notificationType: types[i],
                               pid: session.map { Int($0.rootPid) },
                               updatedAt: now,
                               isStale: false)
        }
    }
    let out = (argv.first(where: { $0.hasPrefix("--out=") })?.dropFirst(6)).map(String.init)
        ?? "/Users/gaogao/Documents/Hermes/manatee/poc-panel.png"
    // 截图用：--update=available|downloading|installing|uptodate，伪造更新状态。
    // 备注默认用 v0.8.0 的发布原文（真 markdown，含 `##`/列表/代码块），
    // --notes-file=<path> 可以换成本地文件，免得每改一次备注就动源码。
    let updateArg = argv.first(where: { $0.hasPrefix("--update=") })?.dropFirst(9)
    if let updateArg {
        let notesPath = argv.first(where: { $0.hasPrefix("--notes-file=") })?.dropFirst(13)
        let notes = notesPath
            .flatMap { try? String(contentsOf: URL(fileURLWithPath: String($0)), encoding: .utf8) }
            ?? DebugFixtures.releaseNotesV080
        let fake = ReleaseInfo(
            version: "0.8.0",
            notes: notes,
            zipURL: URL(string: "https://example.com/Manatee-0.8.0.zip")!,
            pageURL: URL(string: "https://github.com/luogao/manatee/releases/tag/v0.8.0")!)
        MainActor.assumeIsolated {
            switch updateArg {
            case "available":   Updater.shared.debugSet(.available("0.8.0"), remote: fake)
            case "downloading": Updater.shared.debugSet(.downloading(0.42), remote: fake)
            case "installing":  Updater.shared.debugSet(.installing, remote: fake)
            case "uptodate":    Updater.shared.debugSet(.upToDate, remote: fake)
            default:            break
            }
        }
    }
    let renderSettings = argv.contains("--settings")
    let renderDashboard = argv.contains("--dashboard")
    MainActor.assumeIsolated {
        // 离屏渲染时 ScrollView 会整块空白，两张图各自关掉滚动
        let initialTab: PanelTab = argv.contains("--tab=ports") ? .ports : .agents
        let openPort = argv.contains("--port-open") ? model.devServices.first?.id : nil
        let panel = PanelView(model: model, scrollable: argv.contains("--snapshot"),
                              initialTab: initialTab, initialPort: openPort)
        // --waiting 出图时在面板上方垫一条真实菜单栏，一张图同时看到 ⏸ 与面板徽标
        let showMenuBar = argv.contains("--waiting")
        let view = renderDashboard
            ? AnyView(DashboardView(preload: true))
            : renderSettings
            ? AnyView(SettingsView(onClose: {}, scrollable: false))
            : showMenuBar
            ? AnyView(VStack(spacing: 0) {
                MenuBarPreview(temperature: model.temperature,
                               waitingCount: model.waitingStatuses.count,
                               level: model.level)
                panel
            })
            : AnyView(panel)
        if showMenuBar {
            print("menubar: \(MenuBarLabel.make(temperature: model.temperature, waitingCount: model.waitingStatuses.count))")
        }
        // ImageRenderer 渲染 ScrollView 会整块空白，滚动版走 NSHostingView 离屏快照
        let useHost = argv.contains("--snapshot")
        if useHost {
            let host = NSHostingView(rootView: view)
            var win = (renderSettings || renderDashboard) ? NSSize(width: 640, height: 760) : NSSize(width: 340, height: 580)
            // --size=640x1600：出整页长图（滚动区内容全摊开），方便验收看不见的分区
            if let f = argv.first(where: { $0.hasPrefix("--size=") }) {
                let parts = f.dropFirst(7).split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    win = NSSize(width: w, height: h)
                    // 设置页自身写死了高度，长图模式要同步告诉它
                    UserDefaults.standard.set(h, forKey: "render.windowHeight")
                }
            }
            host.frame = NSRect(origin: .zero, size: win)
            host.appearance = NSAppearance(named: .darkAqua)
            host.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            if let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(host.bounds.width * scale),
                pixelsHigh: Int(host.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
                rep.size = host.bounds.size
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    print("rendered -> \(out)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
                }
            }
            exit(0)
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            print("rendered -> \(out)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
        } else {
            print("render failed")
        }
    }
    exit(0)
}

if argv.contains("--ports") {
    let list = PortScanner.scan()
    if list.isEmpty { print("没有检测到开发服务占端口") }
    for s in list.prefix(6) {
        let probe = ServiceProbe.detect(port: s.port, bind: s.bind) ?? "-"
        print(":\(s.port) \(s.command) pid=\(s.pid) bind=\(s.bind) dir=\(s.shortDir.isEmpty ? "-" : s.shortDir) parent=\(s.parentName)(\(s.parentPid)) purpose=\(probe)")
        if !s.argv.isEmpty { print("    argv: \(s.argv.prefix(110))") }
    }
    exit(0)
}

if argv.contains("--bench") {
    let s = ProcessScanner()
    for i in 0..<4 {
        let t0 = Date()
        let p = s.scan()
        print(String(format: "scan %d: %6.1f ms  %d procs", i, Date().timeIntervalSince(t0) * 1000, p.count))
    }
    if let t = TemperatureReader() {
        for i in 0..<6 {
            let t0 = Date()
            let r = t.readAll()
            print(String(format: "temp %d: %6.1f ms  %d sensors", i, Date().timeIntervalSince(t0) * 1000, r.count))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// ── 自检输出 ──

func runDump() {
    print("=== 温度 ===")
    if let t = TemperatureReader() {
        if let hot = t.hottestSilicon() {
            print(String(format: "  芯片最高: %.1f℃ (%@)", hot.celsius, hot.name))
        }
        let all = t.readAll().sorted { $0.celsius > $1.celsius }.prefix(5)
        for s in all { print(String(format: "    %-16@ %5.1f℃", s.name as NSString, s.celsius)) }
    } else {
        print("  ✗ IOHID 初始化失败")
    }

    print("\n=== 诊断: rusage ===")
    do {
        var b = [UInt8](repeating: 0, count: 512)
        let kr = b.withUnsafeMutableBytes { raw -> Int32 in
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4,
                            raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        let v = b.withUnsafeBytes { $0.load(as: rusage_info_v4.self) }
        print("  self kr=\(kr) user=\(v.ri_user_time) sys=\(v.ri_system_time)")
        // 挑一个同用户的别的进程
        let probe = ProcessScanner()
        let ps = probe.scan()
        if let other = ps.first(where: { $0.uid == getuid() && $0.pid != getpid() }) {
            var b2 = [UInt8](repeating: 0, count: 512)
            let kr2 = b2.withUnsafeMutableBytes { raw -> Int32 in
                proc_pid_rusage(other.pid, RUSAGE_INFO_V4,
                                raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            print("  other(\(other.comm) pid=\(other.pid)) kr=\(kr2)")
        }
    }

    print("\n=== 规则 ===")
    print("  \(Rules.shared.agents.count) 个: " + Rules.shared.agents.map(\.id).joined(separator: ", "))

    print("\n=== Agent 会话 ===")
    let scanner = ProcessScanner()
    _ = scanner.scan()                    // 第一次采样只建基线
    Thread.sleep(forTimeInterval: 1.0)
    let procs = scanner.scan()
    print("  进程总数: \(procs.count)")

    let sessions = SessionAggregator.build(from: procs)
    if sessions.isEmpty { print("  (无)") }
    for s in sessions {
        print(String(format: "  %@ %-13@ %6.1f%%  %d 进程  %@",
                     s.def.id as NSString, s.def.name as NSString, s.cpuPercent,
                     s.pids.count, s.summary))
        if !s.busyChildren.isEmpty {
            let kids = s.busyChildren.prefix(4).map { String(format: "%@ %.0f%%", $0.name, $0.cpu) }
            print("       子进程: " + kids.joined(separator: " | "))
        }
    }

    print("\n=== Agent 状态 ===")
    // 与写入方走同一套目录解析，MANATEE_STATE_DIR 才能让 --dump 看临时目录；
    // 默认仍是真实路径，没设置时行为和 AgentStatusStore() 一致
    let statusScan = AgentStatusStore(directory: AgentStatusWriter.resolvedDirectory).scan()
    if statusScan.statuses.isEmpty { print("  (无)") }
    for status in statusScan.statuses {
        // 读取方保留原始 state，过期只体现在 isStale 上；这里用 (stale) 标出来，
        // 「waiting (stale)」= 事件旧了，但进程若还活着菜单栏仍会显示 ⏸
        var line = "  \(status.sessionID)  \(status.agent)  \(status.state.rawValue)  \(status.cwd)"
        if let type = status.notificationType { line += "  [\(type)]" }
        if let message = status.message { line += "  \(message)" }
        if status.isStale { line += " (stale)" }
        print(line)
    }
    if statusScan.skippedCount > 0 {
        print("  跳过 \(statusScan.skippedCount) 个坏文件")
    }

    print("\n=== Top CPU 进程（不限 agent）===")
    for p in procs.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(6) {
        print(String(format: "  %-24@ %6.1f%%  pid=%d", SessionAggregator.shortName(p) as NSString, p.cpuPercent, p.pid))
    }
}

// ── Agent 状态上报（hook CLI）──

/// `Manatee --hook --state <s> --agent <id> --cwd <path> --session <id> [--message <text>]
///            [--notification-type permission_prompt|idle_prompt]`
///
/// 由 agent 的 hook 调用（PRD 5.1）：写一个状态文件就退出，不碰 AppKit。
/// 成功返回 0；参数有问题返回 2，stderr 只打一行，避免污染 hook 的上层提示。
func runHook(_ argv: [String]) -> Int32 {
    // 解析放在 HookCommand 里：本文件顶层 let 按文本顺序初始化，而本函数被
    // 顶层首行调用，那时后文声明的全局变量还没赋值（会 EXC_BAD_ACCESS）。
    switch HookCommand.parse(argv) {
    case .failure(let reason):
        return hookFail(reason.description)
    case .success(let cmd):
        do {
            try AgentStatusWriter().write(sessionID: cmd.session, agent: cmd.agent,
                                          state: cmd.state, cwd: cmd.cwd,
                                          message: cmd.message,
                                          notificationType: cmd.notificationType)
        } catch let error as AgentStatusWriterError {
            return hookFail(error.description)
        } catch {
            return hookFail("\(error)")
        }
        return 0
    }
}

/// 失败统一出口：stderr 一行 + 退出码 2（参数错误，不是崩溃）。
func hookFail(_ reason: String) -> Int32 {
    FileHandle.standardError.write(Data("manatee-hook: \(reason)\n".utf8))
    return 2
}
