import Foundation
import AppKit
import Combine

/// 一个 GitHub Release 的精简表示。
struct ReleaseInfo: Equatable {
    let version: String        // 去掉前缀 v 的 tag，比如 "0.7.0"
    let notes: String
    let zipURL: URL?           // 第一个 .zip 资产；没有就回退到下载页
    let pageURL: URL           // release 页面，兜底用
}

/// 版本号比较。只认 `主.次.修订`，多余后缀忽略（0.7.0-beta 按 0.7.0 算）。
enum Semver {
    static func parts(_ s: String) -> [Int] {
        let core = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            .split(separator: "-").first.map(String.init) ?? s
        return core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// a 比 b 新则 true
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// 在线更新：查 GitHub Releases → 下载 zip → 解包 → 换掉 .app → 重启。
///
/// 不用 Sparkle：它的 EdDSA 签名链和 appcast 托管都要额外维护，而这里的更新源
/// 就是发布页本身（GitHub 提供 HTTPS + 不可变 tag + 校验和），够用。
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double)
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var remote: ReleaseInfo?

    private var task: URLSessionDataTask?
    private let lastCheckKey = "update.lastCheck"
    private let skipKey = "update.skip"

    private var apiURL: URL {
        URL(string: "https://api.github.com/repos/\(AppInfo.owner)/\(AppInfo.slug)/releases/latest")!
    }

    // MARK: - 检查

    /// 启动时调用：一天最多查一次，失败静默（不能因为查更新把首屏拖慢）
    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 24 else { return }
        check(silent: true)
    }

    func check(silent: Bool = false) {
        guard !phase.isBusy else { return }
        if !silent { phase = .checking }
        task?.cancel()
        attempt(0, silent: silent)
    }

    /// 三级降级：API → /releases/latest 的 302 跳转 → releases.atom。
    /// GitHub API 未鉴权时按时段限流（403），国内网络尤其容易被限；
    /// 后两条走的是网页本身，正常浏览都能过。
    private func attempt(_ step: Int, silent: Bool) {
        // 所有回调都在后台队列，这里统一回主线程再改状态
        let hop: FetchDone = { [weak self] result in
            // 先解包再进 Task。Swift 5.10 把 `[weak self]` 当成可变捕获，
            // 内层 Task 读它会报 "reference to captured var 'self' in concurrently-executing code"；
            // 解包成不可变的强引用后就不再是「并发读可变捕获」，5.10 和 6.x 都能编过。
            guard let self else { return }
            Task { @MainActor in
                if case .failure(let err) = result, step < 2 {
                    Debug.log("update: 第 \(step + 1) 级失败 \(err.localizedDescription)，降级")
                    self.attempt(step + 1, silent: silent)
                } else {
                    self.apply(result, silent: silent)
                }
            }
        }
        switch step {
        case 0: fetchViaAPI(hop)
        case 1: fetchViaRedirect(hop)
        default: fetchViaAtom(hop)
        }
    }

    /// 网络回调都在后台队列，改 @Published 前必须回主线程。
    private func apply(_ result: Result<ReleaseInfo, Error>, silent: Bool) {
        if !Thread.isMainThread {
            Task { @MainActor in self.apply(result, silent: silent) }
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        switch result {
        case .failure(let err):
            Debug.log("update: 全部失败 \(err.localizedDescription)")
            // 静默检查失败就当作没更新，不打扰用户
            phase = silent ? .idle : .failed(err.localizedDescription)
        case .success(let info):
            remote = info
            let skipped = UserDefaults.standard.string(forKey: skipKey)
            let newer = Semver.isNewer(info.version, than: AppInfo.version)
            phase = (newer && skipped != info.version) ? .available(info.version) : .upToDate
        }
    }

    private typealias FetchDone = @Sendable (Result<ReleaseInfo, Error>) -> Void

    private func fetchViaAPI(_ done: @escaping FetchDone) {
        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 12
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                return done(.failure(NSError(domain: "update", code: code, userInfo: [
                    NSLocalizedDescriptionKey: code == 403
                        ? L10n.t("GitHub 接口限流（未登录请求每小时 60 次）", "GitHub API rate limited")
                        : L10n.t("服务返回 \(code)", "HTTP \(code)")])))
            }
            guard let p = Self.parse(data) else {
                return done(.failure(NSError(domain: "update", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: L10n.t("响应格式不对", "Bad response")])))
            }
            // API 能拿到完整备注和 zip 直链，最好
            let page = URL(string: "https://github.com/\(AppInfo.owner)/\(AppInfo.slug)/releases/tag/v\(p.version)")
            done(.success(ReleaseInfo(version: p.version, notes: p.notes, zipURL: p.zipURL,
                                      pageURL: page ?? AppInfo.releases)))
        }
        task?.resume()
    }

    /// `/releases/latest` 会 302 到 `/releases/tag/vX.Y.Z`，从最终 URL 里抠版本号。
    /// 拿不到备注和资产列表，但足够判断「有没有新版」。
    private func fetchViaRedirect(_ done: @escaping FetchDone) {
        let url = URL(string: "https://github.com/\(AppInfo.owner)/\(AppInfo.slug)/releases/latest")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { return done(.failure(err)) }
            guard let final = resp?.url,
                  let ver = Self.versionFromTagURL(final) else {
                return done(.failure(NSError(domain: "update", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: L10n.t("跳转地址里没有版本号", "No version in redirect")])))
            }
            done(.success(ReleaseInfo(version: ver, notes: "",
                                      zipURL: Self.zipURL(for: ver),
                                      pageURL: final)))
        }.resume()
    }

    /// `releases.atom` 是公开 feed，不带限流。取第一条 entry 的 tag。
    private func fetchViaAtom(_ done: @escaping FetchDone) {
        let url = URL(string: "https://github.com/\(AppInfo.owner)/\(AppInfo.slug)/releases.atom")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failure(err)) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data, let xml = String(data: data, encoding: .utf8),
                  let ver = Self.firstTagFromAtom(xml) else {
                return done(.failure(NSError(domain: "update", code: code == 200 ? -3 : code, userInfo: [
                    NSLocalizedDescriptionKey: L10n.t("atom 解析失败", "Atom parse failed")])))
            }
            let page = URL(string: "https://github.com/\(AppInfo.owner)/\(AppInfo.slug)/releases/tag/v\(ver)")
            done(.success(ReleaseInfo(version: ver, notes: "", zipURL: Self.zipURL(for: ver),
                                      pageURL: page ?? AppInfo.releases)))
        }.resume()
    }

    /// 下载直链是固定格式，知道版本号就能拼出来
    nonisolated static func zipURL(for ver: String) -> URL? {
        URL(string: "https://github.com/\(AppInfo.owner)/\(AppInfo.slug)/releases/download/v\(ver)/Manatee-\(ver).zip")
    }

    /// 从 `.../releases/tag/v0.6.5` 里取 `0.6.5`
    nonisolated static func versionFromTagURL(_ url: URL) -> String? {
        guard let last = url.pathComponents.last, last.hasPrefix("v") else { return nil }
        let v = String(last.dropFirst())
        return v.isEmpty ? nil : v
    }

    /// atom feed 里第一个 `<link ... href=".../releases/tag/vX.Y.Z">`
    nonisolated static func firstTagFromAtom(_ xml: String) -> String? {
        guard let r = xml.range(of: "/releases/tag/v") else { return nil }
        let rest = xml[r.upperBound...]
        let ver = rest.prefix { $0.isNumber || $0 == "." }
        return ver.isEmpty ? nil : String(ver)
    }

    /// 解析 GitHub `releases/latest` 响应。抽成静态方法方便 e2e 用固定 JSON 测。
    nonisolated static func parse(_ data: Data) -> (version: String, notes: String, zipURL: URL?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        let ver = tag.replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
        let notes = (obj["body"] as? String) ?? ""
        var zip: URL?
        for a in (obj["assets"] as? [[String: Any]]) ?? [] {
            guard let n = a["name"] as? String, n.lowercased().hasSuffix(".zip"),
                  let u = a["browser_download_url"] as? String, let url = URL(string: u) else { continue }
            zip = url
            break
        }
        return (ver, notes, zip)
    }

    // MARK: - 下载并安装

    /// 开始更新。返回 false 表示当前环境不能自更新（比如从 build/ 里跑的开发版）。
    func install(completion: ((Bool) -> Void)? = nil) -> Bool {
        guard case .available(let ver) = phase, let info = remote else {
            completion?(false)
            return false
        }
        // 只有装在常见位置才自更新；开发版直接指到下载页
        let target = Bundle.main.bundleURL
        guard Self.isReplaceable(target) else {
            phase = .failed(L10n.t("当前不是安装版，请到发布页下载", "Not an installed copy"))
            completion?(false)
            return false
        }
        guard let zipURL = info.zipURL else {
            NSWorkspace.shared.open(info.pageURL)
            completion?(false)
            return false
        }

        phase = .downloading(0)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: cfg, delegate: ProgressWatcher { [weak self] p in
            Task { @MainActor in
                if case .downloading = self?.phase { self?.phase = .downloading(p) }
            }
        }, delegateQueue: nil)

        session.downloadTask(with: zipURL) { [weak self] tmp, resp, err in
            guard let self else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err == nil, code == 200, let tmp else {
                let msg = err?.localizedDescription ?? L10n.t("下载失败 HTTP \(code)", "Download failed \(code)")
                Task { @MainActor in self.phase = .failed(msg) }
                completion?(false)
                return
            }
            // 移到稳定的临时目录，URLSession 的 tmp 文件在回调返回后会被删
            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("manatee-update-\(ver)")
            try? FileManager.default.removeItem(at: work)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try FileManager.default.moveItem(at: tmp, to: zip)
                let app = try Self.unzip(zip, into: work)
                try Self.validate(app, expecting: ver)
                Task { @MainActor in
                    self.phase = .installing
                    Self.swapAndRelaunch(newApp: app, target: target)
                }
                completion?(true)
            } catch {
                Task { @MainActor in self.phase = .failed(error.localizedDescription) }
                completion?(false)
            }
        }.resume()
        return true
    }

    /// 忽略这个版本，下次不再提示
    func skipCurrent() {
        if case .available(let v) = phase {
            UserDefaults.standard.set(v, forKey: skipKey)
        }
        phase = .upToDate
    }

    /// 只给截图/自检用：把状态强行设成指定值，不联网。
    func debugSet(_ p: Phase, remote: ReleaseInfo? = nil) {
        if let remote { self.remote = remote }
        phase = p
    }

    // MARK: - 安装步骤

    /// 只有位于应用程序目录（或用户自己挪去的稳定路径）才允许原地替换
    nonisolated static func isReplaceable(_ url: URL) -> Bool {
        let p = url.path
        return p.hasPrefix("/Applications/") || p.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    nonisolated static func unzip(_ zip: URL, into dir: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("解包失败", "Unzip failed")])
        }
        // 找第一个 .app（有的包会多一层目录）
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "update", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("包里没有 app", "No .app inside")])
        }
        for case let u as URL in e where u.pathExtension == "app" {
            return u
        }
        throw NSError(domain: "update", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: L10n.t("包里没有 app", "No .app inside")])
    }

    /// 校验：bundle id 对、可执行文件在、版本号不比目标低。
    /// 防止下到别人的包或者半截文件把用户装的应用覆盖掉。
    nonisolated static func validate(_ app: URL, expecting ver: String) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw NSError(domain: "update", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("包里的 Info.plist 读不出来", "Bad Info.plist")])
        }
        let id = d["CFBundleIdentifier"] as? String ?? ""
        guard id == "top.rungundam.manatee" else {
            throw NSError(domain: "update", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("bundle id 不匹配：\(id)", "Bundle id mismatch: \(id)")])
        }
        let bin = d["CFBundleExecutable"] as? String ?? ""
        guard FileManager.default.isExecutableFile(atPath:
            app.appendingPathComponent("Contents/MacOS/\(bin)").path) else {
            throw NSError(domain: "update", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("可执行文件缺失", "Missing executable")])
        }
        let got = d["CFBundleShortVersionString"] as? String ?? "0"
        guard !Semver.isNewer(ver, than: got) else {
            throw NSError(domain: "update", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("包内版本 \(got) 低于 \(ver)", "Bundle is \(got), expected \(ver)")])
        }
    }

    /// 换包脚本：等本进程退出 → 备份 → 换上新包 → 失败回滚 → 重新打开。
    /// 必须在独立进程里跑，否则脚本会把自己正在运行的 app 删掉。
    static func swapAndRelaunch(newApp: URL, target: URL) {
        do {
            let script = try Swap.makeScript(newApp: newApp, target: target,
                                             pid: ProcessInfo.processInfo.processIdentifier)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            // 后台跑：脚本要活过本进程退出
            p.arguments = ["-c", "/bin/sh '\(script.path)' >/tmp/manatee-update.log 2>&1 &"]
            try p.run()
        } catch {
            Debug.log("update: 启动换包脚本失败 \(error)")
            NSWorkspace.shared.open(target)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApplication.shared.terminate(nil)
        }
    }
}

/// 下载进度回调
private final class ProgressWatcher: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    init(_ cb: @escaping (Double) -> Void) { onProgress = cb }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}

enum Debug {
    static var isOn: Bool { ProcessInfo.processInfo.environment["MANATEE_DEBUG"] == "1" }
    static func log(_ s: String) { if isOn { FileHandle.standardError.write(("[manatee] " + s + "\n").data(using: .utf8)!) } }
}
