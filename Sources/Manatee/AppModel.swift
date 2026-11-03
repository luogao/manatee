import Foundation
import AppKit

/// 一次状态目录读取的结果。
///
/// 分开存全量与等待中：`notifier` 需要全量才能判断「非等待 → 等待」的跃迁，
/// 菜单栏与面板只吃过滤后的等待中列表。
struct AgentStatusReadout: Equatable {
    let all: [AgentStatus]
    let waiting: [AgentStatus]

    static let empty = AgentStatusReadout(all: [], waiting: [])
}

final class AppModel: ObservableObject {

    @Published var temperature: Double = 0
    @Published var sensorName: String = ""
    @Published var sessions: [AgentSession] = []
    @Published var cooled: Set<pid_t> = []
    @Published var processCount: Int = 0
    @Published var lastError: String?
    /// 连续满载预警：rootPid → 已持续的秒数
    @Published var alerts: [Int32: TimeInterval] = [:]
    /// 残留的开发服务器
    @Published var devServices: [DevService] = []
    /// 正在等用户输入的会话（只含 `.waiting`，过期的已由 store 降级成 `.idle`）。
    /// 菜单栏的 ⏸ 与面板徽标都读这一份，保证两处计数一致。
    @Published var waitingStatuses: [AgentStatus] = []
    /// 面板是否展开：关着的时候只需要刷新菜单栏温度，不用每 2 秒扫全表
    var panelOpen = false

    private let scanner = ProcessScanner()
    private let temp = TemperatureReader()
    /// 目录不存在 = 功能没开，scan 返回空且不建目录
    private let statusStore: AgentStatusReading
    /// 阈值来自 rules.json 的 alert 段（默认 5 分钟、200% CPU）
    private let history = SessionHistory(threshold: Rules.shared.alert.cpuPercent,
                                         sustain: Rules.shared.alert.sustainSeconds)
    /// 等待态本地通知。裸二进制里 isAvailable == false，整层 no-op，不会崩。
    private let notifier: AgentStatusNotifying
    /// 通知标题用规则表里的展示名（claude → Claude Code）。只算一次，别每 tick 重建。
    private static let agentDisplayNames: [String: String] =
        Dictionary(uniqueKeysWithValues: AgentRegistry.all.map { ($0.id, $0.name) })
    private let queue = DispatchQueue(label: "whoiscooking.scan", qos: .utility)
    private var timer: Timer?
    private var warming = true

    /// `feature.agentStatus.enabled`。启动时从 `Rules.shared` 读一次（内存），
    /// 手改 rules.json 后重启生效——不为热加载每 2 秒读一次文件。
    let agentStatusEnabled: Bool

    init(statusStore: AgentStatusReading = AgentStatusStore(),
         notifier: AgentStatusNotifying = AgentNotifier(),
         agentStatusEnabled: Bool = Rules.shared.feature.agentStatus.enabled) {
        self.statusStore = statusStore
        self.notifier = notifier
        self.agentStatusEnabled = agentStatusEnabled
    }

    func start() {
        _ = scanner.scan()               // 建基线
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// 同步跑一次（给离屏渲染/自检用）
    func loadSync() {
        _ = scanner.scan()
        Thread.sleep(forTimeInterval: 1.0)
        let procs = scanner.scan()
        sessions = SessionAggregator.build(from: procs)
        processCount = procs.count
        devServices = PortScanner.scan()
        waitingStatuses = readAgentStatus().waiting
        if let hot = temp?.hottestSilicon() ?? temp?.hottestAny() {
            temperature = hot.celsius
            sensorName = hot.name
        }
    }

    /// 读一次状态目录。**关闭时零访问**：直接返回空，连一次 readdir 都不做。
    /// 可在后台队列调用（scan 本身不碰 UI）。
    func readAgentStatus(now: Date = Date()) -> AgentStatusReadout {
        guard agentStatusEnabled else { return .empty }
        let statuses = statusStore.scan(now: now).statuses
        // store 已把超 5 分钟的记录降级成 `.idle`，这里再挡一次是防御注入数据
        let waiting = statuses.filter { $0.state == .waiting && !$0.isStale }
        return AgentStatusReadout(all: statuses, waiting: waiting)
    }

    /// 应用一次读取结果。必须在主线程调用（写 @Published、调 notifier）。
    func applyAgentStatus(_ readout: AgentStatusReadout) {
        // 关闭态连 notifier 都不进：readAgentStatus 已返回空，这里再挡一层，
        // 防止以后有人绕过读取侧直接塞数据。
        guard agentStatusEnabled else { return }
        // 数组没变就不发布，避免关面板时每 2 秒白刷一次 SwiftUI
        if waitingStatuses != readout.waiting { waitingStatuses = readout.waiting }
        // 通知在 main 上算：状态推进是单线程的，UNUserNotificationCenter
        // 的权限回调也回 main。裸二进制里 notifier 自己 no-op。
        notifier.evaluate(statuses: readout.all, now: Date(),
                          agentNames: Self.agentDisplayNames)
    }

    private var tickCount = 0
    /// 上次写看板采样的时刻（秒），用来算采样间隔和限流
    private var lastSampleAt: TimeInterval = 0

    private func tick() {
        tickCount += 1
        // 温度 ~25ms，扫描 ~13ms，lsof ~30ms。各自降频，避免三个功能各扫一遍拖垮预算。
        let needTemp = (tickCount % 3 == 1)          // 6 秒
        // 有会话处于降温状态时 6 秒扫一次（要抓 agent 新起的进程），否则关面板 10 秒
        let needScan = panelOpen || (!cooled.isEmpty && tickCount % 3 == 1) || (tickCount % 5 == 1)
        let needPorts = (tickCount % 30 == 1)        // 60 秒
        queue.async { [weak self] in
            guard let self else { return }
            // 等待状态每个 tick 都扫：菜单栏要求 2 秒内可见，不能等 10 秒的进程扫描。
            // 目录通常不存在（功能没开），那只是一次失败的 readdir，不建目录。
            // 开关关闭时 readAgentStatus 直接返回空：零访问、零通知。
            if self.agentStatusEnabled {
                let readout = self.readAgentStatus()
                DispatchQueue.main.async {
                    self.applyAgentStatus(readout)
                }
            }

            guard needTemp || needScan || needPorts else { return }
            let procs = needScan ? self.scanner.scan() : []
            let sessions = needScan ? SessionAggregator.build(from: procs) : self.sessions
            let hot = needTemp ? (self.temp?.hottestSilicon() ?? self.temp?.hottestAny()) : nil
            let ports = needPorts ? PortScanner.scan() : self.devServices

            // 看板采样：面板开 5 秒一次，关着 30 秒一次（跟扫描节奏走，不额外扫表）
            if needScan {
                let now = Date().timeIntervalSince1970
                let gap = now - self.lastSampleAt
                let minGap: TimeInterval = self.panelOpen ? 5 : 30
                if self.lastSampleAt == 0 || gap >= minGap {
                    if self.lastSampleAt > 0 {
                        MetricsStore.shared.record(
                            agents: sessions.map { (id: $0.def.id, cpuPercent: $0.cpuPercent,
                                                    memMB: $0.memMB, procs: $0.pids.count) },
                            temp: self.temperature > 0 ? self.temperature : nil,
                            ports: needPorts ? ports : [],
                            at: Int(now),
                            interval: gap)
                    }
                    self.lastSampleAt = now
                }
            }

            // 历史与预警只在拿到新会话时更新，避免关面板时拿旧数据重复记账
            var nextAlerts: [Int32: TimeInterval]? = nil
            if needScan {
                self.history.record(sessions)
                var found: [Int32: TimeInterval] = [:]
                for s in sessions {
                    if let d = self.history.sustained(pid: s.rootPid) { found[s.rootPid] = d }
                }
                nextAlerts = found
            }

            DispatchQueue.main.async {
                if let hot {
                    self.temperature = hot.celsius
                    self.sensorName = hot.name
                }
                if needScan { self.processCount = procs.count }
                self.sessions = sessions
                if let nextAlerts { self.alerts = nextAlerts }
                if needPorts {
                    self.devServices = ports
                    // 服务类型探测会打一次本地 HTTP，别占住这轮刷新
                    self.queue.async { [weak self] in
                        var enriched = ports
                        for i in enriched.indices {
                            enriched[i].purpose = ServiceProbe.detect(port: enriched[i].port, bind: enriched[i].bind)
                        }
                        DispatchQueue.main.async { self?.devServices = enriched }
                    }
                }

                if needScan {
                    // 清掉已退出进程的降温标记
                    let alive = Set(procs.map(\.pid))
                    self.cooled.formIntersection(alive)

                    self.coolLatecomers(sessions)
                }
                self.lastError = self.temp == nil ? L10n.t("温度传感器不可用", "Temperature sensor unavailable") : nil
            }
        }
    }

    /// 已降温的会话：这轮新冒出来的子进程也补降。
    /// agent 每起一次 build / ffmpeg 都是一个新 pid，不补的话得手动再点一次。
    /// 必须在主线程调用（读 cooled）。
    func coolLatecomers(_ sessions: [AgentSession]) {
        var late: [pid_t] = []
        for s in sessions where s.pids.contains(where: { cooled.contains($0) }) {
            late.append(contentsOf: s.pids.filter { !cooled.contains($0) })
        }
        guard !late.isEmpty else { return }
        cooled.formUnion(late)   // 先占位，避免下一轮重复 fork
        queue.async { [weak self] in
            guard let self else { return }
            let ok = Set(Cooler.cool(pids: late))
            let failed = late.filter { !ok.contains($0) }
            if !failed.isEmpty {
                DispatchQueue.main.async { self.cooled.subtract(failed) }
            }
        }
    }

    func isCooled(_ s: AgentSession) -> Bool {
        s.pids.contains { cooled.contains($0) }
    }

    func toggleCool(_ s: AgentSession) {
        if isCooled(s) {
            Cooler.restore(pids: s.pids)
            cooled.subtract(s.pids)
        } else {
            let ok = Cooler.cool(pids: s.pids)
            cooled.formUnion(ok)
        }
    }

    func coolAll() {
        let all = sessions.flatMap(\.pids).filter { !cooled.contains($0) }
        let ok = Cooler.cool(pids: all)
        cooled.formUnion(ok)
    }

    /// 关掉残留的开发服务（UI 层负责先确认）
    func killDevServices() {
        for s in devServices {
            kill(s.pid, SIGTERM)
        }
        devServices = []
    }

    func restoreAll() {
        Cooler.restore(pids: Array(cooled))
        cooled.removeAll()
    }

    /// 有会话连续满载时的提示文案
    var alertCount: Int { alerts.count }

    /// 温度分档：给状态栏和面板用同一套阈值
    var level: HeatLevel {
        switch temperature {
        case ..<55: return .cool
        case ..<70: return .warm
        case ..<85: return .hot
        default: return .critical
        }
    }
}

enum HeatLevel {
    case cool, warm, hot, critical
    var label: String {
        switch self {
        case .cool: return L10n.t("凉", "Cool")
        case .warm: return L10n.t("温热", "Warm")
        case .hot: return L10n.t("烫", "Hot")
        case .critical: return L10n.t("过热降频", "Throttling")
        }
    }
    /// 菜单栏用的指示点颜色：系统色自带明暗两套，能同时活在浅色和深色菜单栏上。
    /// 面板内的 color 仍是设计稿的深色版（深底上更协调）。
    var menuColor: NSColor {
        switch self {
        case .cool: return .systemGreen
        case .warm: return .systemYellow
        case .hot: return .systemOrange
        case .critical: return .systemRed
        }
    }

    var color: NSColor {
        switch self {
        case .cool: return NSColor(red: 0.15, green: 0.55, blue: 0.45, alpha: 1)
        case .warm: return NSColor(red: 0.85, green: 0.60, blue: 0.15, alpha: 1)
        case .hot: return NSColor(red: 0.88, green: 0.35, blue: 0.15, alpha: 1)
        case .critical: return NSColor(red: 0.80, green: 0.12, blue: 0.12, alpha: 1)
        }
    }
}
