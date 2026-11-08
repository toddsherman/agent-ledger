import Foundation
import Darwin

/// Append-only JSONL fallback used when the app's socket is unavailable.
public enum Spool {
    /// Appends one already-newline-terminated line under an exclusive lock.
    @discardableResult
    public static func append(role: String, line: Data, dir: URL = LedgerPaths.spoolDir) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("\(role)-\(getpid()).jsonl").path
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return line.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: offset), buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Reads every spool file, truncating each after reading, and returns the parsed messages.
    public static func drain(dir: URL = LedgerPaths.spoolDir) -> [WireMessage] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [WireMessage] = []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "jsonl" {
            let fd = open(file.path, O_RDWR)
            guard fd >= 0 else { continue }
            flock(fd, LOCK_EX)
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            ftruncate(fd, 0)
            flock(fd, LOCK_UN)
            close(fd)
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let msg = try? decoder.decode(WireMessage.self, from: Data(line)) { out.append(msg) }
            }
            // Remove the file if its writer is gone.
            if let pidStr = file.deletingPathExtension().lastPathComponent.split(separator: "-").last,
               let pid = Int32(pidStr), kill(pid, 0) != 0 {
                try? fm.removeItem(at: file)
            }
        }
        return out
    }
}
