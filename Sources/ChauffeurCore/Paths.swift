import Darwin
import Foundation

/// Per-simulator state under $TMPDIR/chauffeur (spec §6.9).
public enum StatePaths {
    public static var dir: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("chauffeur", isDirectory: true)
    }
    static func stem(_ udid: String) -> String { String(udid.prefix(8)) }
    public static func socket(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".sock") }
    public static func pidfile(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".pid") }
    public static func log(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".log") }
    public static func level(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".level") }
    public static func lock(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".lock") }
    /// The app `chauffeur launch` started, so a restarted daemon keeps following it.
    public static func app(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".app.json") }
    /// Every command the daemon ran, one JSON line each.
    public static func trace(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid) + ".trace.jsonl") }
    /// Files an agent reads by path: screenshots, the full log.
    public static func artifacts(_ udid: String) -> URL { dir.appendingPathComponent(stem(udid), isDirectory: true) }

    /// Creates `url` (0700), or checks that an existing one is a real directory owned by this user and tightens its
    /// mode to 0700. Sockets, logs, screenshots and traces all live under it.
    public static func ensureDir(_ url: URL = dir) throws {
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw ChauffeurError.daemon("cannot read \(path)") }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            throw ChauffeurError.daemon("\(path) is not a directory (a symlink?); remove it and retry")
        }
        guard st.st_uid == getuid() else {
            throw ChauffeurError.daemon("\(path) belongs to another user; remove it and retry")
        }
        if st.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 {
            throw ChauffeurError.daemon("cannot make \(path) private (chmod 700 failed)")
        }
    }
}
