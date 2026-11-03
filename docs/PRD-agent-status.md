# PRD：Agent 等待状态落到菜单栏

> 状态：draft（待评审）· 作者：Hermes · 日期：2026-11-01
> 来源线索：工坊 issue #11（AC Bridge — agent 卡在等确认时，在另一个房间也知道）
> 归属：并进 Manatee，不做独立 app

## 1. 背景

用户跑 Claude Code / Codex 时，最常见的浪费不是模型慢，是**agent 停下来等人，人在做别的事**。平均要等几分钟到几十分钟才发现。

Manatee 已经在菜单栏常驻，并且已经知道有哪些 agent 在跑（`Sources/Manatee/AgentRegistry.swift:37` 的 `match()` 按进程路径与参数识别 11 类 agent）。但它现在只知道「在跑」，不知道「在等你」。

所以这个需求不是新 app，是给已有信号补一个维度：**从「谁在占用你的 Mac」扩展到「谁在等你」。**

## 2. 目标与非目标

**目标**

- **hook 事件落盘后 2 秒内**菜单栏可见（Manatee 读取链路实测 1235 ms）。这是 Manatee 自身的口径，不是端到端：从权限框出现到 hook 落盘的耗时由上游决定，见「9.1 已知限制」
- 用户处理完，5 秒内标记消失
- 不打断当前工作的情况下，能知道「有几个在等、是哪个」

**非目标（本期不做）**

- 自动跳到对应终端窗口（涉及聚焦/唤起 App，v2 再评估）
- 智能灯联动、HomeKit（AC Bridge 的卖点，但对单人使用是过度设计）
- 跨设备推送（手机通知）
- Windows / Linux

## 3. 用户故事

1. 作为同时开 3 个 agent 的人，我希望能一眼看到「有 2 个在等我」，而不用挨个切窗口。
2. 作为在另一个房间的人，我希望能收到一条系统通知，知道哪个项目在等。
3. 作为不想被噪音打扰的人，我希望这个功能可以关，关掉后完全不读状态目录。

## 4. 状态定义

| 状态 | 含义 | 触发 |
|---|---|---|
| `running` | 正在干活 | agent 上报 tool 执行中，或心跳在跑 |
| `waiting` | 等人（权限确认 / 追问 / 回合结束） | agent hook 上报 `Notification` / `Stop` |
| `idle` | 没有活动会话 | 状态文件超时，或显式上报 |
| `error` | 异常退出 | 状态文件里 `state=error` |

`waiting` 是唯一会改变菜单栏外观的状态。

## 5. 功能需求

### 5.1 信号来源（主动上报，不靠猜）

**明确不做 CPU 猜测。** CPU 低不等于在等人，agent 可能在等网络、在思考、或者已经挂了。

三条上报路径：

1. **Claude Code hooks** — 在 `~/.claude/settings.json` 注册 `Notification`（需要权限/等待输入时触发）与 `Stop`（回合结束）。payload 字段已在本机 Claude Code 2.1.316 实测验证，见本节末尾「已验证 payload」。
2. **Codex** — `~/.codex/config.toml` 的 `notify` 命令，同样走下面的通用 CLI。
3. **通用 CLI** — 提供 `manatee-agent-hook --state waiting --agent <id> --cwd <path> [--message <text>]`，任何 agent 都能调。也是前两条最终落到的东西。

统一写到：

```
~/Library/Application Support/Manatee/agent-state/<session-id>.json
{
  "agent": "claude-code",
  "state": "waiting",
  "cwd": "/Users/gaogao/Documents/Hermes/workshop",
  "message": "等待权限确认",
  "updated_at": 1761955200
}
```

进程映射由现有 `ProcessScanner` 按 `cwd` 对齐；hooks 只负责状态，不写进程号。

**已验证 payload**（DYVI-31，2026-11-02，Claude Code 2.1.316，13 条原始 JSON）

- 事件：`Notification`（`notification_type` = `permission_prompt` | `idle_prompt`）、`Stop`
- 两类事件都带 `session_id` / `cwd` / `transcript_path` / `prompt_id` / `hook_event_name`；**没有 `pid`**
- 状态映射：`Stop` → 已完成；`Notification` + `permission_prompt` → 等待权限确认；`Notification` + `idle_prompt` → 等待输入。只看事件名会把「等输入」误判成「等权限」，必须两者一起看
- `Notification.message` 只有通用文案（`Claude needs your permission` / `Claude is waiting for your input`），不含命令

### 5.2 读取与过期

- 复用现有 2 秒 tick（`Sources/Manatee/AppModel.swift:31`），扫一次状态目录，不引入 FSEvents（当前代码里没有文件监听，为了一个低频信号引入监听复杂度不划算）
- `updated_at` 超过 5 分钟未更新 → 标记 `stale`，**但不改写原始 `state`**；是否仍显示「等待」由进程存活决定（`WaitingPolicy`）：过期且能对上活着的会话 → 继续显示；对不上任何会话 → 不显示；文件超过 4 小时一律不显示（硬上限）
  - 为什么要这样：Claude Code 一次等待只发一条 `Notification`、之后不刷新 `updated_at`，只按时间过期会把最该被看见的长等待（开会 20 分钟）先丢掉标记
- 状态文件超过 24 小时 → 清理

### 5.3 菜单栏呈现

现状：温度数字 + 左侧档位圆点（`Sources/Manatee/AppDelegate.swift:74` 的 `btn.image`，颜色来自 `model.level.menuColor`），tooltip 里已经有「N 个 agent 在跑」（`:82`）。

**圆点已经承载温度档位语义，不能挪用。** 等待态用独立标记：

- `waiting` 时在温度数字后追加 `⏸`（或 SF Symbol `hourglass`），并在同一 tick 内与纯数字交替闪烁（2 秒周期），保证在毛玻璃背景上可辨
- 多个会话同时等待 → 显示数量，如 `48° ⏸2`
- 无等待 → 与现有外观完全一致，零视觉变化

### 5.4 面板

- 每个 agent 行增加状态徽标：`运行中` / `等待权限确认` / `等待输入` / `已完成`
- 等待行只显示固定标签 `等待权限确认` / `等待输入` / `已完成`，不展开命令内容——payload 里没有命令文本，硬做就得读 transcript，与隐私约束冲突
- 等待行置顶排序

### 5.5 通知

Manatee 目前没有通知能力（全仓库 `UNUserNotification` 命中 0 处），需要新增：

- 状态 非等待 → 等待 时发一条本地通知，标题「Claude Code 在等你」，副标题为项目目录名
- **按 `session_id` 做 5 分钟冷却**：同一会话 5 分钟内不重复发。实测 `Stop` 之后约 60s（60063ms / 60068ms）必来一条 `idle_prompt`，不做冷却一次「完成」会弹两条；**`Stop` 与随后 60s 内的 `idle_prompt` 合并为一次**
- 通知正文只允许 `Notification.message` 原文或固定标签（`等待权限确认` / `等待输入` / `已完成`），不含命令全文
- **硬约束**：`Stop` 的 `last_assistant_message` / `background_tasks[].command` / `transcript_path` 一律不进通知、不进日志、不进面板
- 首次使用需要引导用户授权通知权限，拒绝授权则静默降级为只做菜单栏标记

### 5.6 开关

在 `rules.json` 增加 `feature.agentStatus.enabled`（配置体系见 `Sources/Manatee/Rules.swift:35`），默认 `false`，用户主动开启。

关闭时：不读状态目录、不渲染标记、不发通知，性能开销为零。

## 6. 边界与异常

| 场景 | 期望行为 |
|---|---|
| 用户没装 hook | 功能开启但永远无 waiting；设置页显示「未检测到 hooks，点击安装」 |
| hook 执行失败 | 不影响 agent 本身（hook 脚本必须 exit 0，异常吞掉） |
| 同一目录多会话 | 各自独立文件，面板分行显示，菜单栏只显示总数 |
| 状态文件损坏 | 跳过该文件，不崩溃，debug log 记录 |
| agent 崩溃未清状态 | 进程对不上即不显示等待；残留文件超过 4 小时硬上限后一律不显示 |
| 会话 id 冲突 | 用 `pid + cwd` 哈希兜底（pid 由 `ProcessScanner` 补齐，见下） |

会话 key 的优先级（与 DYVI-31 裁决一致）：

1. 有 `session_id` → 直接用 `session_id`
2. 没有，但 `ProcessScanner` 按 `cwd` 只匹配到 1 个 agent 进程 → `pc-<sha256(realpath(cwd) + "\0" + pid)[0:16]>`
3. 对不上或多于 1 个 → `cw-<sha256(realpath(cwd))[0:16]>`，同目录多会话合并成一个，明确标注为降级

hooks payload 本身没有 `pid`，第 2 条的 pid 只能由 `ProcessScanner` 按 `cwd` 反查补齐；哈希用小写十六进制，同一 key 后到覆盖先到。

## 7. 验收标准

1. Claude Code 触发一次权限确认 → **hook 事件落盘后 2 秒内**菜单栏出现 `⏸`，面板该行显示「等待权限确认」。计时起点是 hook 写入状态文件的那一刻，**不是**权限框在终端渲染的时刻；从权限框到 hook 落盘约 6 秒属上游行为，见「9.1 已知限制」
2. 点「允许」→ **5 秒内**标记消失，面板回到运行中
3. 两个会话同时等待 → 菜单栏显示 `⏸2`
4. 手动写一个 `updated_at` 为 6 分钟前的状态文件 → 标记不出现（过期生效）
5. 关闭开关 → `lsof` 或日志确认不再访问 `agent-state/` 目录
6. 同一会话持续等待 10 分钟 → 只收到 1 条通知
7. 拒绝通知权限 → 菜单栏功能正常，无弹窗报错

## 8. 工作量

| 项 | 估时 |
|---|---|
| POC：抓 Claude Code / Codex 真实 hook 事件，确认字段 | 0.5 天 |
| 通用 CLI + 状态文件写入/清理 | 0.5 天 |
| 状态读取模型 + 过期逻辑 | 0.5 天 |
| 菜单栏渲染 + 面板行 | 1 天 |
| 通知（含权限流程） | 0.5 天 |
| 开关 + 设置页引导 | 0.5 天 |
| 联调 + 验收 | 0.5 天 |
| **合计** | **4 天**（一人） |

比「一周做一个独立 app」省一半，且不用用户再装第二个东西。

## 9. 风险

1. **hook payload 只验证了 Claude Code 的一条路径**——`Notification` / `Stop` 字段已在 2.1.316 实测（DYVI-31），剩余不确定性在 Codex `notify` 与前台 TUI 权限框（只用 `--bg` 证明了同一事件路径）。这两块补验前，不要对外宣称全路径已支持。
2. **Claude Code 版本迭代**——hooks 字段可能变；实现要做「解析失败不影响 agent」，并记录最近一次成功事件时间。
3. **菜单栏空间**——温度数字 + 圆点 + 等待标记，在 1080p 外接屏上可能过挤；需要真机截图确认，必要时把数量并入 tooltip。
4. **功能稀释 Manatee 定位**——「温度归因」和「agent 等待」是两个概念。默认关闭 + 独立开关是缓解手段，但长期需要明确产品主线。

### 9.1 已知限制

以下是当前实现与上游的真实边界。写在这里，是为了避免把「Manatee 链路快」误读成「端到端快」——文中关于**可见性**的「2 秒」都指 hook 落盘之后，不是从用户看到权限框算起（§5.2 / §5.3 里的「2 秒」是轮询 tick 与闪烁周期，与延迟承诺无关）。

1. **Claude Code 权限框 → `Notification` 约 6 秒（上游行为）**——2026-11-03 在 Claude Code 2.1.316 上两次独立实测，从权限框渲染到 hook 事件触发分别为 **6035 ms / 6044 ms**；Manatee 从 hook 落盘到菜单栏出 `⏸` 为 **1235 ms**。端到端约 7 秒，Manatee 侧无法优化，也不把这 6 秒算进自身指标。
2. **一次等待只发一条 `Notification`，且不刷新 `updated_at`**——同一个等待期内 Claude Code 只触发一次该事件，之后 `updated_at` 不再变化。因此过期判据已改为「进程存活佐证 + 4 小时硬上限」（DYVI-71 / PR #13 已合并），§5.2 / §6 已同步。
3. **通知横幅需要用户手动授权**——首次使用要用户在系统弹窗里允许 Manatee 发通知；拒绝或未授权时静默降级，只保留菜单栏 `⏸` 与面板徽标，不重复弹窗、不报错（行为同 §5.5 末条）。

## 10. 开放问题

1. 等待标记用文字 `⏸` 还是 SF Symbol？毛玻璃背景下哪个更清楚，需要真机对比。
2. 是否需要「一键切到等待的会话」？技术上要 AppleScript/辅助功能授权，体验收益不确定。
3. 通知是否要带「快速允许」按钮？涉及 agent 自身的确认通道，本期不碰。
