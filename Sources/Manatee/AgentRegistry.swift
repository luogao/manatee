import Foundation

struct AgentDef {
    let id: String
    let name: String
    let symbol: String      // SF Symbol 名（单色线条图标，不用 emoji）
    /// 命中任一即认为是该 agent 的主进程
    let patterns: [String]
    /// 命中任一则排除（避免把 IDE 的渲染进程当成 agent 本体）
    let excludes: [String]
    /// 精确比对 basename 的可执行名（pi / pi-desktop 这类短名不能用子串匹配）
    let bin: String?
    /// 安装位置（已展开 ~），设置页用它标「已安装」
    let detect: [String]
}

/// 规则表来自 `~/Library/Application Support/Manatee/rules.json`，
/// 文件缺失或解析失败时回退 Rules.default（内置 11 项）。
enum AgentRegistry {
    static let all: [AgentDef] = Rules.shared.agents
        .filter { $0.enabled != false }
        .map { rule in
        AgentDef(id: rule.id,
                 name: rule.name,
                 symbol: rule.symbol ?? "circle.dashed",
                 patterns: rule.patterns,
                 excludes: rule.excludes ?? [],
                 bin: rule.bin,
                 detect: (rule.detect ?? []).map { ($0 as NSString).expandingTildeInPath })
    }

    /// 已安装检测：配置目录 / 可执行文件任一存在。用于设置页标注，不参与归因。
    static func isInstalled(_ d: AgentDef) -> Bool {
        d.detect.contains { FileManager.default.fileExists(atPath: $0) }
    }

    static func match(_ p: ProcInfo, rules: [AgentDef]? = nil) -> AgentDef? {
        let pool = rules ?? all
        let base = (p.path as NSString).lastPathComponent.lowercased()
        let args = p.args.lowercased()

        // 噪声：崩溃上报、Electron 辅助进程、框架内部进程一律不参与归因
        // 注意 comm 只有 15 字节，"browser_crashpad" 会被截成 "browser_crashpa"，所以用 crash
        let noise = ["crash", "helper", "framework", "xpcservice", "webcontent"]
        if noise.contains(where: { base.contains($0) }) { return nil }
        // IDE 里跑的扩展进程（Copilot SDK）不算 CLI agent
        if base.contains("code helper") || args.contains("visual studio code.app") { return nil }

        let hay = base + " " + args
        // 排除规则要看完整路径：Claude 桌面端的 app 包名只在 path 里，
        // base 是 "Claude"、args 为空，只看 base+args 会漏排
        let fullHay = p.path.lowercased() + " " + args
        for d in pool {
            if d.excludes.contains(where: { fullHay.contains($0.lowercased()) }) { continue }
            // 精确名优先：pi 是 node CLI，真正的进程是 node，靠 args 里的脚本路径认。
            // 逐个 token 比 basename，避免 "/bin/pi" 的子串误伤 "/bin/ping"。
            if let bin = d.bin?.lowercased() {
                if base == bin { return d }
                for tok in p.args.split(separator: " ") {
                    if (String(tok) as NSString).lastPathComponent.lowercased() == bin { return d }
                }
            }
            if d.patterns.contains(where: { hay.contains($0.lowercased()) }) { return d }
        }
        return nil
    }
}

struct AgentSession {
    let def: AgentDef
    let rootPid: pid_t
    var cpuPercent: Double
    var memMB: Double = 0
    var pids: [pid_t]
    var busyChildren: [(name: String, cpu: Double)]
    var cooled: Bool
    var hasOtherUid: Bool
    /// 根进程的工作目录。hook 上报的 `cwd` 只有对上它，才能确定是哪个会话在等。
    /// 拿不到（进程已退出 / 别人的进程）时为空串。
    var cwd: String = ""

    var summary: String {
        if busyChildren.isEmpty { return L10n.t("空闲", "idle") }
        let names = busyChildren.prefix(3).map { $0.name }.joined(separator: ", ")
        return L10n.t("运行中：", "running: ") + names
    }
}

enum SessionAggregator {

    /// 把进程表压成「一个 agent 会话一行」
    static func build(from procs: [ProcInfo], rules: [AgentDef]? = nil) -> [AgentSession] {
        let byPid = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0) })

        // 1) 找出所有命中规则的进程
        var matched: [pid_t: AgentDef] = [:]
        for p in procs {
            if let d = AgentRegistry.match(p, rules: rules) { matched[p.pid] = d }
        }
        guard !matched.isEmpty else { return [] }

        // 2) 只保留「最上层」的命中进程作为会话根，避免父子重复
        func hasMatchedAncestor(_ pid: pid_t) -> Bool {
            var cur = pid
            var depth = 0
            while let p = byPid[cur], p.ppid > 1, depth < 40 {
                if matched[p.ppid] != nil { return true }
                cur = p.ppid
                depth += 1
            }
            return false
        }
        let roots = matched.keys.filter { !hasMatchedAncestor($0) }

        // 3) 每个进程归给最近的根（先走 ppid 链，再按 pgid 兜底）
        var owner: [pid_t: pid_t] = [:]
        func findOwner(_ pid: pid_t) -> pid_t? {
            var cur = pid
            var depth = 0
            while depth < 40 {
                if roots.contains(cur) { return cur }
                guard let p = byPid[cur], p.ppid > 1 else { break }
                cur = p.ppid
                depth += 1
            }
            return nil
        }
        var pgidRoot: [pid_t: pid_t] = [:]
        for r in roots { if let p = byPid[r] { pgidRoot[p.pgid] = r } }

        for p in procs {
            if let o = findOwner(p.pid) {
                owner[p.pid] = o
            } else if let r = pgidRoot[p.pgid] {
                owner[p.pid] = r
            }
        }

        // 4) 汇总
        var acc: [pid_t: (cpu: Double, mem: Double, pids: [pid_t], kids: [(String, Double)], otherUid: Bool)] = [:]
        for p in procs {
            guard let o = owner[p.pid] else { continue }
            var e = acc[o] ?? (0, 0, [], [], false)
            e.cpu += p.cpuPercent
            e.mem += Double(p.memBytes) / 1024 / 1024
            e.pids.append(p.pid)
            if p.cpuPercent >= 3, p.pid != o {
                e.kids.append((shortName(p), p.cpuPercent))
            }
            if p.otherUid { e.otherUid = true }
            acc[o] = e
        }

        return roots.compactMap { r -> AgentSession? in
            guard let d = matched[r], let e = acc[r] else { return nil }
            return AgentSession(
                def: d,
                rootPid: r,
                cpuPercent: (e.cpu * 10).rounded() / 10,
                memMB: (e.mem * 10).rounded() / 10,
                pids: e.pids.sorted(),
                busyChildren: e.kids.sorted { $0.1 > $1.1 },
                cooled: false,
                hasOtherUid: e.otherUid,
                // 会话数 ≤10，每个 tick 每个根一次 syscall 可以接受；
                // 没有它，hook 的 cwd 就只能靠猜，面板会把徽标挂错行
                cwd: ProcessCwd.of(r) ?? ""
            )
        }
        .sorted { $0.cpuPercent > $1.cpuPercent }
    }

    static func shortName(_ p: ProcInfo) -> String {
        let base = (p.path as NSString).lastPathComponent
        if base.hasPrefix("node"), let first = p.args.split(separator: " ").dropFirst().first {
            return (String(first) as NSString).lastPathComponent
        }
        return base
    }
}
