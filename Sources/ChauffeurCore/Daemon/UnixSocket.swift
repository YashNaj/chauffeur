import Darwin
import Foundation

enum UnixSocket {
    struct Failure: Error, CustomStringConvertible {
        var description: String
        var code: Int32 = 0
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Failure(description: "socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    private static func errno(_ what: String) -> Failure {
        let code = Darwin.errno
        return Failure(description: "\(what): \(String(cString: strerror(code)))", code: code)
    }

    /// Inode of the file at `path` (not following symlinks), or nil.
    static func inode(_ path: String) -> UInt64? {
        var st = stat()
        return lstat(path, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    /// Removes `path` only if it is still the socket this process bound (C1: never delete a successor's socket).
    static func unlink(_ path: String, ifInode expected: UInt64?) {
        guard let expected, inode(path) == expected else { return }
        Darwin.unlink(path)
    }

    static func listen(path: String) throws -> Int32 {
        var addr = try address(path)
        Darwin.unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw errno("socket") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw errno("bind \(path)")
        }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            close(fd)
            throw errno("listen")
        }
        return fd
    }

    static func connect(path: String, timeout: Double) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw errno("socket") }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw errno("connect \(path)")
        }
        setTimeout(fd, timeout)
        return fd
    }

    static func setTimeout(_ fd: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// One newline-terminated message, without the newline. Nil on EOF, timeout or more than `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int = 4 << 20) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            if let nl = chunk[0..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: chunk[0..<nl])
                return data
            }
            data.append(contentsOf: chunk[0..<n])
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
