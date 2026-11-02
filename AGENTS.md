# AGENTS.md

给接手的 AI agent / 协作者：这个仓库是什么、怎么跑、别踩哪些坑。

## 项目

**Manatee** —— macOS 菜单栏小工具。显示哪个 AI agent（Claude Code / Codex / Cursor…）正在占满 CPU 并烤热机器，并把它降到能效核降温，不中断任务。

灵感来自 [WhoIsCooking](https://whoiscooking.site)，独立实现，MIT。当前 0.7.0：菜单栏常驻、面板 / 设置页、一键降温、连续满载提醒、开发端口、资源看板、在线更新都已落地（M1 / M2）；刘海形态（PRD F7）留到下期。

## 目录

```
Package.swift                     SPM 定义，单 executableTarget，macOS 13+，Swift 5.9 工具链
Sources/Manatee/
├── main.swift                    入口 + 所有命令行自检分支；无参数时进 GUI
├── AppDelegate.swift             NSStatusItem + 无箭头 NSPanel（贴状态栏定位）+ 右键菜单
├── AppModel.swift                状态与轮询（后台队列扫描，回 main 更新）
├── PanelView.swift               SwiftUI 主面板（Instrument 视觉）；AppInfo 是项目名唯一来源
├── SettingsView.swift            设置页（三栏：通用 / agent 规则 / 版本）
├── DashboardView.swift           资源看板（手绘图表，不引 Swift Charts）
├── TemperatureReader.swift       IOHID 私有 API 读芯片温度（免 sudo）
├── ProcessScanner.swift          libproc 全表扫描 + rusage 差分算 CPU%
├── AgentRegistry.swift           AgentDef 定义与会话聚合；all 由 Rules 派生
├── Rules.swift                   可编辑规则表：内置默认 + rules.json 读写与回退
├── Cooler.swift                  taskpolicy 降级 / 恢复
├── PortScanner.swift             监听端口的开发服务（含「残留」判定）
├── ServiceProbe.swift            探端口背后是什么服务（Server 头 + HTML 特征）
├── SessionHistory.swift          每个会话 6 分钟 CPU 窗口 → 连续满载预警
├── MetricsStore.swift            SQLite 采样与聚合（看板数据源）
├── L10n.swift                    中英双语，运行时切换
├── Icons.swift                   品牌图标（Resources/Icons/*.png，template 渲染）
├── ScrollFade.swift              通用滚动容器（隐藏滚动条 + 底部渐隐提示）
├── E2E.swift                     --e2e 无窗口、免权限自检
├── Updater.swift                 GitHub Release 在线更新（下载 / 校验 / 替换 / 回滚）
├── UpdateSection.swift           设置页「版本」分区
└── UpdateSelfTest.swift          --update-selftest 更新链路自检
Tests/ManateeTests/
├── AgentMatchingTests.swift      agent 指纹匹配
├── SessionAndMetricsTests.swift  会话聚合与看板存储
├── L10nTests.swift               双语字符串
└── SmokeTests.swift              冒烟
Resources/
├── Info.plist                    bundle 元信息（版本号源之一）
├── AppIcon.icns / icon-1024.png  应用图标
└── Icons/                        各 agent 的单色图标
Casks/manatee.rb                  Homebrew Cask
scripts/
├── bundle.sh                     打包 .app（ad-hoc 签名，不需要开发者账号）
├── check.sh                      本地自检：build + test + e2e（CI 同款）
└── make_icon.swift               图标导出
docs/
├── POC-REPORT.md                 实测数据与实验方法
├── DASHBOARD.md                  资源看板设计
├── PRD-agent-status.md           下期功能：agent 等待状态（尚未实现）
├── RELEASE-v*.md                 各版本发布说明
├── ui/                           设计稿与各状态渲染截图
└── brand/                        品牌图标源文件与多尺寸导出
PRD.md                            需求文档（可行性 / 功能清单 / 架构 / 风险 / 里程碑）
.github/workflows/ci.yml          swift build / test / release build / --e2e
```

运行时数据都在 `~/Library/Application Support/Manatee/`：`rules.json` 是用户可编辑的规则表（首次启动写出，损坏时回退内置默认），`metrics.sqlite` 是看板采样库（可用 `MANATEE_METRICS_DB` 指到临时文件，避免污染真实数据）。

## 构建与自检

```bash
swift build
swift test
.build/debug/Manatee --e2e        # 无窗口、免权限的启动 / 视图 / 存储自检，CI 同款
scripts/check.sh                  # 上面三步一次跑完
```

调试分支（全部在 `main.swift` 里按 `argv.contains(...)` 分派）：

```bash
.build/debug/Manatee --dump        # 温度 + 规则表 + agent 会话 + Top CPU（先跑这个）
.build/debug/Manatee --bench       # 扫描 / 温度读取耗时
.build/debug/Manatee --ports       # 当前监听端口的开发服务
.build/debug/Manatee --cool-test   # 对最烫的 agent 降温 25s 再恢复，打印温度变化
.build/debug/Manatee --late-test   # 验证降温后新起的子进程会被自动补降
.build/debug/Manatee --render      # 离屏渲染面板 PNG，不依赖屏幕录制权限
.build/debug/Manatee --demo        # 起 GUI 并自动展开面板（截图 / 验收用）
```

`--render` 的常用修饰：`--out=<path>`、`--settings`、`--dashboard`、`--snapshot`（滚动版走 NSHostingView）、`--size=640x1600`（整页长图）、`--lang=en|zh`、`--tab=ports`、`--port-open`，以及状态注入 `--fake=<温度>` / `--empty` / `--alert` / `--dev` / `--many` / `--cooled` / `--update=available|downloading|installing|uptodate`。`--render --demo` 会注入「单会话 340%、连续满载 12 分钟」的演示数据。

更新链路自检：`--update-check`（只跑一次联网检查后退出）、`--update-selftest <zip> [目标目录]`（在临时沙盒里走解包 / 校验 / 回滚）。`--seed-metrics` 造 24 小时假看板数据，配合 `MANATEE_METRICS_DB` 指向临时库。

改完代码先跑 `--dump` 确认数据层没坏，再跑 `--e2e`，最后看 UI。

## 代码约定

- **Core 层不 import SwiftUI**：`TemperatureReader` / `ProcessScanner` / `AgentRegistry` / `Cooler`（以及 `Rules` / `SessionHistory` / `PortScanner`）必须能脱离 UI 单测。
- 轮询在后台队列，UI 更新回 main；不要在 `scan()` 里碰 UI。`AppModel.tick` 里各功能各自降频（温度 6s、扫描面板开 2s / 关 10s、端口 60s），加功能先想预算。
- 新增 agent 只需改 `Rules.swift` 的内置默认表（`AgentRegistry.all` 由它派生），不要改聚合逻辑；老用户的 `rules.json` 会自动补齐新 agent。
- 项目名唯一来源是 `AppInfo`（`PanelView.swift`）和 `Resources/Info.plist`，改名两处一起改。
- 注释写「为什么」，尤其系统 API 的坑（见下）。
- 文档引用源码要给 `文件:行号`，改代码后同步更新本文件和 PRD。

## 三条必踩的系统 API 坑

1. `proc_listallpids` 返回**个数**不是字节数（`ProcessScanner.swift:38-39`）。按字节除会少算 4 倍。
2. `proc_pid_rusage` 的 `ri_*_time` 是 **mach absolute time**，不是纳秒（`ProcessScanner.swift:70-72`）。必须乘 `numer/denom`，否则 CPU% 小 41.67 倍。
3. `pbi_comm` 只有 15 字节，`browser_crashpad_handler` 会被截成 `browser_crashpa`（`AgentRegistry.swift:43-45`）。噪音过滤用 `crash` 不用 `crashpad`。

## 验证「降温」时看温度，不看 CPU%

单线程降到 Background QoS 后仍然显示 100% CPU，只是跑在能效核上。要证明效果：升温 40s、降温 25s 再读数，进程数应保持不变。

参考数据（`docs/POC-REPORT.md`）：10 进程满载 791% / 58.1℃ → 降 QoS 25s 后 528% / 49.1℃（-9.0℃），恢复全速 20s 回到 55.6℃ / 778%；更极端的一组 8 进程 70.6℃ → 44.9℃（-25.7℃）。

## 造测试负载

不要拿真实 agent 试。用 `/tmp/claude` 这样的假会话脚本（脚本名就是被测指纹）：

```sh
#!/bin/sh
yes > /dev/null &
yes > /dev/null &
sleep 600        # 不要用 exec sleep，exec 会替换 shell 丢掉 argv 指纹
```

起停走 Python `start_new_session=True` + `os.killpg`，确保子进程一起清掉。

## 待办（按优先级）

1. **agent 等待状态**：菜单栏追加 `⏸`（多会话显示数量），面板该行显示「等待确认」。设计见 `docs/PRD-agent-status.md`，尚未实现。
2. **刘海形态**（PRD F7）：`NSScreen.safeAreaInsets.top > 0` 时贴刘海，无刘海继续走菜单栏。本机 Mac mini 无刘海，无法验收，暂列下期。

## 提交规范

`type: 简述`，type ∈ {feat, fix, perf, docs, chore}。
示例：`fix: 修正 rusage 时间单位换算`、`docs: 补 POC 实测数据`。

## 不要做

- 不要引入需要付费账号的依赖
- 不要联网、不要加埋点（README 承诺了纯本地）
- 不要用私有 API 之外的方式读温度导致需要 sudo（会毁掉零权限体验）
