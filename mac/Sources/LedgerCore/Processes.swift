import Foundation
import Darwin

public struct ProcessSnapshot: Sendable, Equatable, Hashable {
    public var pid: Int32
    public var ppid: Int32
    /// Process start time, Unix epoch milliseconds. PID plus start time identifies a process
    /// without PID-reuse mistakes.
    public var startedAt: Double
    public var path: String
    public var args: [String]
}

public enum Processes {
    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    public static func parentPID(of pid: Int32) -> Int32? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    public static func startTime(of pid: Int32) -> Double? {
        guard let k = kinfo(pid) else { return nil }
        let tv = k.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000
    }

    public static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Command-line arguments via KERN_PROCARGS2 (same-user processes only).
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 } // executable path
        while i < size && buf[i] == 0 { i += 1 }
        var args: [String] = []
        while i < size && args.count < Int(argc) {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    public static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 > 0 }
    }

    public static func snapshot(_ pid: Int32) -> ProcessSnapshot? {
        guard let k = kinfo(pid), let path = path(of: pid) else { return nil }
        let tv = k.kp_proc.p_un.__p_starttime
        return ProcessSnapshot(pid: pid, ppid: k.kp_eproc.e_ppid,
                               startedAt: Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000,
                               path: path, args: arguments(of: pid))
    }
}
