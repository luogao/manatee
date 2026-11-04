import SwiftUI
import AppKit

/// 设置页 04「版本」：显示当前版本、检查更新、下载进度、跳过此版本。
/// 面板底栏的更新提示也复用这里的动作，避免两处逻辑分叉。
struct UpdateSection: View {
    @ObservedObject private var up = Updater.shared
    @State private var hoverCheck = false

    /// 截图/长图模式传 false：备注整段摊开，不套内层滚动（离屏渲染 ScrollView 会空白）
    var scrollable: Bool = true

    private var current: String { AppInfo.version }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead(n: "04", title: L10n.t("版本", "Version"))

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("当前版本", "Current version"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                    Text("v\(current)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 0)
                Text(statusText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 58)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }

            // 有新版：说明 + 两个按钮
            if case .available(let v) = up.phase {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("新版本 v\(v) 已发布", "Version \(v) is available"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    // GitHub 的 body 是真 markdown；以前当裸文本截断，用户看到一堆 `##` 和反引号
                    if let notes = up.remote?.notes, !notes.isEmpty {
                        ReleaseNotesView(notes: notes, scrollable: scrollable)
                            .padding(.top, 2)
                    }
                    HStack(spacing: 10) {
                        Button {
                            _ = up.install()
                        } label: {
                            Text(L10n.t("下载并安装", "Download & install"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(red: 21/255, green: 14/255, blue: 4/255))
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accent))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let u = up.remote?.pageURL { NSWorkspace.shared.open(u) }
                        } label: {
                            Text(L10n.t("查看发布页", "Release page"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button {
                            up.skipCurrent()
                        } label: {
                            Text(L10n.t("跳过此版本", "Skip"))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink2.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            // 下载/安装进度
            if case .downloading(let p) = up.phase {
                progressBar(p)
            } else if case .installing = up.phase {
                progressBar(nil)
            }

            // 检查按钮
            HStack(spacing: 12) {
                Button {
                    up.check()
                } label: {
                    Text(up.phase == .checking ? L10n.t("检查中…", "Checking…")
                                               : L10n.t("检查更新", "Check for updates"))
                        .font(.system(size: 12))
                        .foregroundStyle(hoverCheck ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.white.opacity(hoverCheck ? 0.24 : 0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(up.phase.isBusy)
                .onHover { hoverCheck = $0 }

                if case .failed(let msg) = up.phase {
                    Text(msg)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
    }

    private var statusText: String {
        switch up.phase {
        case .idle:        return L10n.t("未检查", "Not checked")
        case .checking:    return L10n.t("检查中…", "Checking…")
        case .upToDate:    return L10n.t("已是最新", "Up to date")
        case .available:   return L10n.t("有新版本", "Update available")
        case .downloading(let p): return L10n.t("下载 \(Int(p * 100))%", "Downloading \(Int(p * 100))%")
        case .installing:  return L10n.t("正在安装…", "Installing…")
        case .failed:      return L10n.t("检查失败", "Check failed")
        }
    }

    private var statusColor: Color {
        switch up.phase {
        case .available: return Theme.accent
        case .failed:    return Theme.danger
        case .upToDate:  return Theme.ink2
        default:         return Theme.ink3.opacity(0.8)
        }
    }

    private func progressBar(_ p: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent)
                        .frame(width: p.map { g.size.width * max(0.02, min(1, $0)) } ?? g.size.width * 0.35)
                        .opacity(p == nil ? 0.6 : 1)
                }
            }
            .frame(height: 3)
            Text(p == nil ? L10n.t("正在替换应用，完成后会自动重启", "Replacing app, will relaunch")
                          : L10n.t("下载中，完成后自动安装", "Downloading, will install automatically"))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.top, 12)
    }
}

/// 面板底栏用的一行更新提示：只在「有新版」时出现，点一下开始装。
struct UpdateBanner: View {
    @ObservedObject private var up = Updater.shared
    @State private var hover = false

    var body: some View {
        if case .available(let v) = up.phase {
            Button {
                _ = up.install()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 9))
                    Text(L10n.t("有新版 v\(v)", "v\(v) available"))
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundStyle(hover ? Theme.ink : Theme.accent)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.accent.opacity(hover ? 0.2 : 0.12))
                )
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(L10n.t("点击下载并安装 v\(v)", "Click to download and install v\(v)"))
        } else if case .downloading(let p) = up.phase {
            Text(L10n.t("更新 \(Int(p * 100))%", "Updating \(Int(p * 100))%"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.accent)
        } else if up.phase == .installing {
            Text(L10n.t("正在安装…", "Installing…"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.accent)
        }
    }
}
