import AppKit
import SwiftUI
import ServiceManagement

/// 无箭头面板：NSPopover 会画一个指向菜单栏的三角箭头，且无法关掉。
/// 换成 borderless NSPanel，自己画圆角（PanelView 自带），外面只留阴影。
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var panel: PanelWindow?
    private let model = AppModel()
    private let settings = SettingsWindowController()
    private let dashboard = DashboardWindowController()
    private var titleTimer: Timer?
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        MetricsStore.shared.rollupAndPurge()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.title = "—°"
            btn.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            btn.action = #selector(statusItemClicked)
            btn.target = self
            // 左键开面板，右键开盘菜单（开机自启 / 退出）
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NotificationCenter.default.addObserver(forName: .hotPotOpenSettings, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }
        NotificationCenter.default.addObserver(forName: .hotPotOpenDashboard, object: nil, queue: .main) { [weak self] _ in
            self?.closePanel()
            self?.dashboard.show()
        }

        titleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshTitle()
        }
        RunLoop.main.add(titleTimer!, forMode: .common)

        // 查更新：一天一次，失败静默。延迟 8 秒，别跟首屏抢 IO。
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            Updater.shared.checkIfDue()
        }

        // POC 用：启动后自动展开面板，方便截图/验收
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.togglePanel()
            }
        }
    }

    /// 上次写入的「标题 + 等待数」。只比文字不够：温度不变、等待数变化时
    /// 也必须重绘，否则菜单栏会卡在没有 ⏸ 的旧文案上。
    private var lastTitleKey = ""

    private func refreshTitle() {
        guard let btn = statusItem.button else { return }
        let t = model.temperature
        let waitingCount = model.waitingStatuses.count
        let text = MenuBarLabel.make(temperature: t, waitingCount: waitingCount)
        let key = "\(text)|\(waitingCount)"
        // 菜单栏重绘不便宜：只有标题或等待数变了才写 attributedTitle
        guard key != lastTitleKey else { return }
        lastTitleKey = key
        // 菜单栏是毛玻璃/深浅壁纸叠加，彩色文字会糊掉。文字一律用 labelColor
        // （系统自动反色），档位信息交给前面的小圆点。
        // 温度档位圆点的语义与颜色一律不动：等待标记只追加在文字末尾。
        btn.image = t > 0 ? Self.dot(color: model.level.menuColor) : nil
        btn.imagePosition = .imageLeading
        btn.imageScaling = .scaleNone
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: model.temperature >= 85 ? NSColor.systemRed : NSColor.labelColor,
        ]
        btn.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        btn.toolTip = L10n.t("\(AppInfo.name) · 芯片 \(Int(t))℃ · \(model.sessions.count) 个 agent 在跑",
                            "\(AppInfo.name) · Chip \(Int(t))℃ · \(model.sessions.count) agents")
    }

    // MARK: - 点击与菜单

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if isRight {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        closePanel()
        guard let btn = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.t("打开面板", "Open panel"),
                     action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let login = NSMenuItem(title: L10n.t("开机自启", "Launch at login"),
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = isLaunchAtLogin ? .on : .off
        menu.addItem(login)

        menu.addItem(withTitle: L10n.t("资源看板…", "Dashboard…"),
                     action: #selector(openDashboard), keyEquivalent: "").target = self
        menu.addItem(withTitle: L10n.t("偏好设置…", "Settings…"),
                     action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L10n.t("编辑规则文件…", "Edit rules file…"),
                     action: #selector(openRules), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.t("退出 \(AppInfo.name)", "Quit \(AppInfo.name)"),
                     action: #selector(quit), keyEquivalent: "q").target = self

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: btn.bounds.height + 4),
                   in: btn)
    }

    /// 5pt 实心圆，不随菜单栏反色（颜色本身是语义）
    private static func dot(color: NSColor) -> NSImage {
        let d: CGFloat = 6
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        closePanel()
        settings.show()
    }

    @objc private func openDashboard() {
        closePanel()
        dashboard.show()
    }

    @objc private func openRules() {
        NSWorkspace.shared.open(Rules.path)
    }

    // MARK: - 开机自启（默认关，用户从右键菜单开）

    private var isLaunchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.t("设置开机自启失败", "Could not change login item")
            alert.informativeText = L10n.t(
                "把 \(AppInfo.name) 拖进 /Applications 再试。\n\(error.localizedDescription)",
                "Move \(AppInfo.name) into /Applications and try again.\n\(error.localizedDescription)")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - 面板（NSPanel，无箭头）

    @objc private func togglePanel() {
        if let w = panel, w.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let btn = statusItem.button, let btnWindow = btn.window else { return }

        let size = NSSize(width: 340, height: 580)
        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        let host = NSHostingController(rootView: PanelView(model: model))
        // NSHostingController 的 preferredContentSize 是 0，会把窗口压成 0×0，必须显式给尺寸
        host.preferredContentSize = size
        w.contentViewController = host
        w.setContentSize(size)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.isMovable = false
        w.hidesOnDeactivate = false

        // 贴在图标正下方，左右钳进屏幕可见区
        let btnOnScreen = btnWindow.convertToScreen(btn.convert(btn.bounds, to: nil))
        let screen = btnWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = btnOnScreen.midX - size.width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - size.width - 8))
        var y = btnOnScreen.minY - size.height - 6
        if y < visible.minY + 8 { y = visible.minY + 8 }
        w.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)

        w.makeKeyAndOrderFront(nil)
        if CommandLine.arguments.contains("--diagnose") {
            FileHandle.standardError.write(Data("[panel] frame=\(w.frame) visible=\(w.isVisible) btn=\(btnOnScreen) screen=\(visible)\n".utf8))
        }
        panel = w
        model.panelOpen = true
        installDismissMonitors()
    }

    private func closePanel() {
        guard panel != nil else { return }
        panel?.orderOut(nil)
        panel = nil
        model.panelOpen = false
        removeDismissMonitors()
    }

    /// 点面板以外的地方、或按 Esc 就收起来（相当于 popover 的 .transient）
    private func installDismissMonitors() {
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // 点在状态栏图标上交给 statusItemClicked 处理，这里不抢
            if let btn = self.statusItem.button, let bw = btn.window {
                let r = bw.convertToScreen(btn.convert(btn.bounds, to: nil))
                if r.contains(NSEvent.mouseLocation) { return }
            }
            self.closePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self, let w = self.panel else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.closePanel(); return nil }   // Esc
                return e
            }
            if e.window !== w { self.closePanel() }
            return e
        }
    }

    private func removeDismissMonitors() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }
}
