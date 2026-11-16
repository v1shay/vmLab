import Foundation
import Darwin

enum LabError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

enum LocalSocket {
    static let directory = ProcessInfo.processInfo.environment["VMLAB_SOCKET_DIR"] ?? "/tmp/vmlab-\(getuid())"
    static let path = directory + "/control.sock"

    static func prepare() throws {
        guard directory.hasPrefix("/"), path.utf8CString.count <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw LabError.message("Invalid vmLab socket path.")
        }
        if mkdir(directory, 0o700) != 0 && errno != EEXIST {
            throw LabError.message("Could not create vmLab socket directory.")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw LabError.message("Unsafe vmLab socket directory.")
        }
    }

    static func peerAllowed(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func address(_ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8CString.map { UInt8(bitPattern: $0) }) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32, timeout: Int = 10) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: timeout, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            _ = setsockopt(fd, SOL_SOCKET, option, &time, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    static func connect() throws -> Int32 {
        try prepare()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LabError.message("Could not create socket.") }
        configure(fd)
        guard address({ Darwin.connect(fd, $0, $1) }) == 0, peerAllowed(fd) else {
            close(fd)
            throw LabError.message("Open vmLab and retry.")
        }
        return fd
    }

    static func read(_ fd: Int32, limit: Int) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw LabError.message("Socket read failed.") }
            if n == 0 { return result }
            guard result.count + n <= limit else { throw LabError.message("Message too large.") }
            result.append(contentsOf: buffer.prefix(n))
        }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw LabError.message("Connection closed.") }
                offset += n
            }
        }
    }
}
