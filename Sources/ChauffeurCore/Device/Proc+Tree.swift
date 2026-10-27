import Darwin
import Foundation

extension Proc {
    /// The parent of `pid`; nil when it is gone.
    public static func parent(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The process's name (up to 32 characters, enough for `com.apple.WebKit.Networking`); nil when it is gone.
    public static func name(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Running processes called `name` whose parent is `parent`: how a simulator's WebKit networking process is
    /// found, as the app's sibling under the device's launchd_sim (M4b Findings §2).
    public static func children(of parent: Int32, named name: String) -> [Int32] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return pids.prefix(max(count, 0)).filter { $0 > 0 && Self.parent($0) == parent && Self.name($0) == name }
    }
}
