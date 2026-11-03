import Foundation

/// 用户可编辑的规则表。第一次启动会在
/// `~/Library/Application Support/<AppName>/rules.json` 写出一份，之后以文件为准。
/// 文件缺失或解析失败时回退到内置默认值，不让用户改坏 JSON 导致 app 起不来。
struct AgentRule: Codable {
    var id: String
    var name: String
    var symbol: String?
    var patterns: [String]
    var excludes: [String]?
    /// 设置页里的开关。旧文件没有这个字段时按启用处理。
    var enabled: Bool?
    /// 可执行名，**精确**比对 basename。两三个字母的名字（pi）靠 contains 会撞 pip / ping / python。
    var bin: String?
    /// 安装位置（支持 ~ 开头）。任一存在即视为「已安装」，设置页据此标注。
    var detect: [String]?
}

struct AlertRule: Codable {
    /// CPU% 阈值，100 = 一个核
    var cpuPercent: Double
    /// 连续多久算异常
    var sustainSeconds: Double
}

/// `rules.json` 顶层的 `feature` 段：按功能拆开关。
///
/// 老用户的文件里没有这一整段，所以解码必须容忍缺失（见 `Rules.init(from:)`）。
struct FeatureRules: Codable, Equatable {
    var agentStatus: AgentStatusFeature

    static let `default` = FeatureRules(agentStatus: .default)

    init(agentStatus: AgentStatusFeature = .default) {
        self.agentStatus = agentStatus
    }
}

extension FeatureRules {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentStatus = try c.decodeIfPresent(AgentStatusFeature.self, forKey: .agentStatus) ?? .default
    }
}

/// agent 等待态功能的总开关。默认 **关**：不读状态目录、不显示 ⏸、不发通知。
/// 写入侧 `--hook` 不受影响，开关只管读 / 渲染 / 通知。
struct AgentStatusFeature: Codable, Equatable {
    var enabled: Bool

    static let `default` = AgentStatusFeature(enabled: false)

    init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

extension AgentStatusFeature {
    /// `{"agentStatus": {}}` 也要能解码，缺 `enabled` 时按关处理。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

struct Rules: Codable {
    var version: Int
    var agents: [AgentRule]
    var devServerCommands: [String]
    var ignorePortCommands: [String]
    var alert: AlertRule
    /// 功能开关。**不能是解码必填字段**：老文件没有 `feature` 键，非可选字段会让
    /// 整份 rules.json 解码失败 → `load()` 走 catch → 备份并回退默认，等于把用户
    /// 已有配置整体停用。见 `Rules.init(from:)` 与 AgentStatusFeatureFlagTests。
    var feature: FeatureRules = .default

    static let path: URL = URL(fileURLWithPath: AppInfo.supportPath)
        .appendingPathComponent("rules.json")

    /// 设置页保存后要在进程内立即可读，所以是 var
    static var shared: Rules = load()

    // MARK: - 默认值

    static let `default` = Rules(
        version: 2,
        agents: [
            AgentRule(id: "claude", name: "Claude Code", symbol: "asterisk",
                      patterns: ["claude", ".claude/local"],
                      excludes: ["Claude.app", "Claude Helper", "claude.ai"], enabled: true, detect: ["~/.claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]),
            AgentRule(id: "codex", name: "Codex CLI", symbol: "terminal",
                      patterns: ["codex"], excludes: ["Codex.app/Contents/Frameworks"], enabled: true, detect: ["~/.codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]),
            AgentRule(id: "cursor", name: "Cursor", symbol: "cursorarrow",
                      patterns: ["cursor-agent", "Cursor Helper (Renderer)"], excludes: [], enabled: true, detect: ["/Applications/Cursor.app", "~/.cursor"]),
            AgentRule(id: "gemini", name: "Gemini CLI", symbol: "sparkles",
                      patterns: ["gemini"], excludes: ["Gemini.app"], enabled: true, detect: ["~/.gemini", "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]),
            AgentRule(id: "aider", name: "Aider", symbol: "curlybraces",
                      patterns: ["aider"], excludes: [], enabled: true, detect: ["~/.aider.conf.yml", "/opt/homebrew/bin/aider", "/usr/local/bin/aider"]),
            AgentRule(id: "copilot", name: "Copilot CLI", symbol: "person.crop.circle",
                      patterns: ["copilot"], excludes: [], enabled: true, detect: ["~/.copilot", "/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"]),
            AgentRule(id: "pi", name: "Pi", symbol: "p.circle",
                      patterns: ["pi-coding-agent"], excludes: [],
                      enabled: true, bin: "pi",
                      detect: ["~/.pi/agent", "~/.bun/bin/pi", "~/.npm-global/bin/pi",
                               "/opt/homebrew/bin/pi", "/usr/local/bin/pi"]),
            AgentRule(id: "ollama", name: "Ollama", symbol: "circle.hexagongrid",
                      patterns: ["ollama"], excludes: [], enabled: true, detect: ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama"]),
            AgentRule(id: "lmstudio", name: "LM Studio", symbol: "cube",
                      patterns: ["LM Studio", "lms "], excludes: [], enabled: true, detect: ["/Applications/LM Studio.app", "~/.lmstudio", "~/.cache/lm-studio"]),
            AgentRule(id: "xcode", name: "Xcode Build", symbol: "hammer",
                      patterns: ["xcodebuild", "swift-build", "swift-frontend", "clang"],
                      excludes: ["SourceKit", "clangd"], enabled: true, detect: ["/Applications/Xcode.app"]),
            AgentRule(id: "ffmpeg", name: "ffmpeg", symbol: "film",
                      patterns: ["ffmpeg"], excludes: [], enabled: true, detect: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]),
            AgentRule(id: "docker", name: "Docker", symbol: "shippingbox",
                      patterns: ["com.docker", "docker"], excludes: ["Docker Desktop"], enabled: true, detect: ["/Applications/Docker.app", "/usr/local/bin/docker", "~/.docker"]),
        ],
        devServerCommands: [
            "node", "python", "ruby", "php", "deno", "bun", "java",
            "vite", "next", "nuxt", "webpack", "uvicorn", "gunicorn",
            "flask", "django", "rails", "puma", "hugo", "jekyll",
        ],
        ignorePortCommands: [
            "redis", "rapportd", "tailscaled", "jellyfin", "postgres", "mysqld",
            "mongod", "dockerd", "ollama", "sshd", "nginx",
        ],
        alert: AlertRule(cpuPercent: 200, sustainSeconds: 300)
    )

    // MARK: - 读写

    static func load() -> Rules {
        let url = path
        guard let data = try? Data(contentsOf: url) else {
            writeDefault(to: url)
            return .default
        }
        do {
            var loaded = try JSONDecoder().decode(Rules.self, from: data)
            loaded.mergeNewAgents()
            loaded.migrateIfNeeded()
            return loaded
        } catch {
            // 用户改坏了：保留坏文件备份，回退默认，不覆盖他的编辑
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("rules.broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            return .default
        }
    }

    /// 内置规则表新增了 agent（比如 Pi）时，老用户的 rules.json 里没有它。
    /// 按 id 补进去，用户自己的条目和开关状态一律不动。
    /// 内置图标 / 字段升级：version 2 起统一用新的 symbol 名（Aider 的 `</>` 太宽）。
    /// 只覆盖 symbol，用户的 patterns / excludes / enabled 一律不动。
    mutating func migrateIfNeeded() {
        guard version < 2 else { return }
        let defaults = Dictionary(uniqueKeysWithValues: Rules.default.agents.map { ($0.id, $0) })
        for i in agents.indices {
            if let d = defaults[agents[i].id], let sym = d.symbol {
                agents[i].symbol = sym
            }
        }
        version = 2
    }

    mutating func mergeNewAgents() {
        let known = Set(agents.map(\.id))
        for d in Rules.default.agents where !known.contains(d.id) {
            agents.append(d)
        }
    }

    private static func writeDefault(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(Rules.default) {
            try? data.write(to: url)
        }
    }

    /// 把当前内存里的规则写回文件（用户点了「恢复默认」时用）
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Rules.path)
        }
    }
}

extension Rules {
    /// 手写解码只为 `feature` 的向后兼容：缺失时补默认，其余字段照旧严格解码
    /// （坏 JSON 仍然 fail fast，走 `load()` 的备份回退）。
    ///
    /// 放在 extension 里而不是结构体正文：Swift 只在正文里声明过初始化器时
    /// 才吞掉逐成员初始化器，而 `Rules.default` 和测试都在用那个初始化器。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        agents = try c.decode([AgentRule].self, forKey: .agents)
        devServerCommands = try c.decode([String].self, forKey: .devServerCommands)
        ignorePortCommands = try c.decode([String].self, forKey: .ignorePortCommands)
        alert = try c.decode(AlertRule.self, forKey: .alert)
        // 缺 feature 段 → 默认全关；用户自己写的 enabled 一律原样保留
        feature = try c.decodeIfPresent(FeatureRules.self, forKey: .feature) ?? .default
    }
}
