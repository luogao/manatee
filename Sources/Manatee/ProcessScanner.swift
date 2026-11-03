import Foundation
import Darwin

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let uid: uid_t
    let comm: String        // 可执行名（短）
    let path: String        // 完整路径
    let args: String        // 命令行
    var cpuTimeNs: UInt64 = 0
    var cpuPercent: Double = 0
    var memBytes: UInt64 = 0
    var otherUid = false    // 属于别的用户（无权限降级）
}

/// 进程当前工作目录。
///
/// 两个地方要用：端口列表判断服务属于哪个项目；agent 会话把 hook 上报的 `cwd`
/// 对到具体进程。`PROC_PIDVNODEPATHINFO` 同用户免 root，拿不到（别人家的进程、
/// 已退出）返回 nil。
enum ProcessCwd {
    static func of(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }
}

/// 用 libproc 直接扫全表，不 fork ps。
final class ProcessScanner {

    private var lastSample: [pid_t: UInt64] = [:]
    private var lastTime: UInt64 = 0

    private static let nsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private static let clockPerSec: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 / (Double(info.numer) / Double(info.denom))
    }()

    func scan() -> [ProcInfo] {
        var pids = [pid_t](repeating: 0, count: 8192)
        // 注意：proc_listallpids 的返回值是「pid 个数」，不是字节数
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }

        var result: [ProcInfo] = []
        result.reserveCapacity(count)
        let myUid = getuid()

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = proc_bsdinfo()
            let sz = MemoryLayout<proc_bsdinfo>.size
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(sz)) == Int32(sz) else { continue }

            let path = withUnsafeBytes(of: info.pbi_comm) { raw -> String in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            var fullPath = ""
            var pathBuf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &pathBuf, 4096) > 0 {
                fullPath = String(cString: pathBuf)
            }
            var cpuNs: UInt64 = 0
            var memBytes: UInt64 = 0
            var raw = [UInt8](repeating: 0, count: MemoryLayout<rusage_info_v4>.size)
            let kr = raw.withUnsafeMutableBytes { buf -> Int32 in
                proc_pid_rusage(pid, RUSAGE_INFO_V4,
                                buf.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
            }
            if kr == 0 {
                let rv = raw.withUnsafeBytes { $0.load(as: rusage_info_v4.self) }
                // 坑：ri_*_time 返回的是 mach absolute time 单位，不是 ns，必须按 timebase 换算
                let ticks = rv.ri_user_time + rv.ri_system_time
                cpuNs = UInt64(Double(ticks) * Self.nsPerTick)
                memBytes = rv.ri_resident_size
            }

            let args = Self.arguments(pid: pid)
            result.append(ProcInfo(
                pid: pid,
                ppid: pid_t(info.pbi_ppid),
                pgid: pid_t(info.pbi_pgid),
                uid: info.pbi_uid,
                comm: path,
                path: fullPath.isEmpty ? path : fullPath,
                args: args,
                cpuTimeNs: cpuNs,
                memBytes: memBytes,
                otherUid: info.pbi_uid != myUid
            ))
        }

        // 算瞬时 CPU%（两次采样差）
        let now = mach_absolute_time()
        let elapsed = lastTime == 0 ? 0 : Double(now - lastTime) / Self.clockPerSec
        if elapsed > 0.05 {
            for i in result.indices {
                if let prev = lastSample[result[i].pid], result[i].cpuTimeNs >= prev {
                    let delta = Double(result[i].cpuTimeNs - prev) / 1e9
                    result[i].cpuPercent = delta / elapsed * 100
                }
            }
        }
        lastSample = Dictionary(uniqueKeysWithValues: result.map { ($0.pid, $0.cpuTimeNs) })
        lastTime = now
        return result
    }

    /// 读进程 argv（sysctl KERN_PROCARGS2），同用户免 root
    static func arguments(pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 1 << 20 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        var argc: Int32 = 0
        memcpy(&argc, buf, 4)
        guard argc > 0, argc < 4096 else { return "" }
        var i = 4
        // 跳过 exec path
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        var parts: [String] = []
        var n: Int32 = 0
        while i < size && n < argc {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            if i > start, let s = String(bytes: buf[start..<i], encoding: .utf8) {
                parts.append(s.truncatingRemainder(dividingBy: 512))
            }
            i += 1
            n += 1
        }
        return parts.joined(separator: " ")
    }
}

private extension String {
    func truncatingRemainder(dividingBy n: Int) -> String {
        count <= n ? self : String(prefix(n))
    }
}
