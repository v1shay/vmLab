import Foundation
import CoreGraphics
import Darwin
import CommonCrypto
import Security

@_silgen_name("vmlab_apple_dh")
private func appleDH(_ generator: UInt32, _ length: Int32, _ modulus: UnsafePointer<UInt8>,
                     _ peer: UnsafePointer<UInt8>, _ publicKey: UnsafeMutablePointer<UInt8>,
                     _ secret: UnsafeMutablePointer<UInt8>) -> Int32

/// A direct RFB connection to Tart's per-VM display. Only raw rectangles and
/// desktop resizing are requested, keeping decoding independent of host UI.
final class RFB {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    private var width = 0, height = 0
    private var pixels = Data()

    func stop() {
        lock.lock()
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }

    func key(_ keysym: UInt32, down: Bool) throws {
        try send([4, down ? 1 : 0, 0, 0] + bytes32(keysym))
    }

    func pointer(x: UInt16, y: UInt16, buttons: UInt8) throws {
        try send([5, buttons] + bytes16(x) + bytes16(y))
    }

    private func bytes16(_ n: UInt16) -> [UInt8] {
        [UInt8(n >> 8), UInt8(truncatingIfNeeded: n)]
    }

    private func bytes32(_ n: UInt32) -> [UInt8] {
        bytes16(UInt16(n >> 16)) + bytes16(UInt16(truncatingIfNeeded: n))
    }

    private func send(_ bytes: [UInt8]) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        lock.lock()
        let descriptor = stopped ? -1 : fd
        lock.unlock()
        guard descriptor >= 0 else { throw LabError.message("Display is disconnected.") }
        try LocalSocket.write(Data(bytes), to: descriptor)
    }

    private func receive(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        try bytes.withUnsafeMutableBytes { p in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, p.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw LabError.message("Guest display disconnected.") }
                offset += n
            }
        }
        return bytes
    }

    private func receive(into pointer: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let received = Darwin.read(fd, pointer.advanced(by: offset), count - offset)
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { throw LabError.message("Guest display disconnected.") }
            offset += received
        }
    }

    private func number(_ count: Int) throws -> Int {
        try receive(count).reduce(0) { ($0 << 8) | Int($1) }
    }

    private func resize(_ w: Int, _ h: Int) throws {
        guard (1...8192).contains(w), (1...8192).contains(h), w * h <= 20_000_000 else {
            throw LabError.message("Guest display is too large.")
        }
        width = w; height = h
        pixels = Data(count: w * h * 4)
    }

    private func authenticate(_ password: String?) throws {
        let challenge = try receive(16)
        guard let password else { throw LabError.message("Guest display requires a password.") }
        var key = Array(password.utf8.prefix(8)).map { byte in
            (0..<8).reduce(UInt8(0)) { $0 | (((byte >> $1) & 1) << (7 - $1)) }
        }
        key += Array(repeating: 0, count: 8 - key.count)
        var result = [UInt8](repeating: 0, count: 16), written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                             CCOptions(kCCOptionECBMode), key, 8, nil, challenge, 16, &result, 16, &written)
        guard status == kCCSuccess, written == 16 else { throw LabError.message("VNC authentication failed.") }
        try send(result)
    }

    private func authenticateMac(_ username: String?, _ password: String?) throws {
        guard let username, let password, !username.isEmpty else {
            throw LabError.message("Sign in with an account allowed to share this Mac’s screen.")
        }
        let user = Array(username.utf8), pass = Array(password.utf8)
        guard user.count < 64, pass.count < 64, !user.contains(0), !pass.contains(0) else {
            throw LabError.message("Mac Screen Sharing credentials must be under 64 UTF-8 bytes.")
        }
        let generator = try number(2), length = try number(2)
        guard (64...512).contains(length) else { throw LabError.message("Invalid Mac authentication parameters.") }
        let modulus = try receive(length), peer = try receive(length)
        var publicKey = [UInt8](repeating: 0, count: length)
        var secret = publicKey
        guard appleDH(UInt32(generator), Int32(length), modulus, peer, &publicKey, &secret) == 1 else {
            throw LabError.message("Mac authentication key exchange failed.")
        }
        var key = [UInt8](repeating: 0, count: 16)
        _ = CC_MD5(secret, CC_LONG(length), &key)
        var plaintext = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, plaintext.count, &plaintext) == errSecSuccess else {
            throw LabError.message("Could not prepare Mac authentication.")
        }
        plaintext.replaceSubrange(0...user.count, with: user + [0])
        plaintext.replaceSubrange(64...(64 + pass.count), with: pass + [0])
        var encrypted = [UInt8](repeating: 0, count: 128)
        var written = 0
        guard CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                      key, 16, nil, plaintext, 128, &encrypted, 128, &written) == kCCSuccess,
              written == 128 else { throw LabError.message("Could not encrypt Mac credentials.") }
        try send(encrypted + publicKey)
    }

    func run(url: URL, password: String?, username: String? = nil, macLogin: Bool = false, allowUnauthenticated: Bool = true, frame: (CGImage) -> Void) throws {
        guard let host = url.host, let port = UInt16(exactly: url.port ?? 5900) else {
            throw LabError.message("Invalid guest display address.")
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var resolved: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &resolved) == 0, let resolved else {
                throw LabError.message("Could not resolve the display host.")
            }
            defer { freeaddrinfo(resolved) }
            addr.sin_addr = resolved.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
        }
        let connection = socket(AF_INET, SOCK_STREAM, 0)
        guard connection >= 0 else { throw LabError.message("Could not open guest display socket.") }
        LocalSocket.configure(connection, timeout: allowUnauthenticated ? 15 : 4)
        defer {
            writeLock.lock()
            lock.lock()
            fd = -1
            close(connection)
            lock.unlock()
            writeLock.unlock()
        }
        lock.lock()
        if stopped { lock.unlock(); return }
        fd = connection
        lock.unlock()
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(connection, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else {
            if !allowUnauthenticated && errno == ECONNREFUSED {
                throw LabError.message("This host refused the connection. Check that Screen Sharing is enabled.")
            }
            throw LabError.message(allowUnauthenticated ? "Could not connect to guest display."
                                   : "Screen Sharing is unreachable on this network.")
        }
        let version = String(bytes: try receive(12), encoding: .ascii) ?? ""
        guard version.hasPrefix("RFB "), let minor = Int(version.dropFirst(8).prefix(3)), minor >= 3 else {
            throw LabError.message("Unsupported guest display protocol.")
        }
        let negotiated = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3)
        try send(Array(String(format: "RFB 003.%03d\n", negotiated).utf8))
        let security: Int
        if negotiated == 3 { security = try number(4) }
        else {
            let types = try receive(number(1))
            security = macLogin ? (types.contains(30) ? 30 : 0) : (password != nil || !allowUnauthenticated) && types.contains(2) ? 2 : (types.contains(1) ? 1 : (types.contains(2) ? 2 : 0))
            guard security != 0 else { throw LabError.message(macLogin ? "This host did not offer Mac account sign-in." : "This host did not offer VNC password sign-in.") }
            guard allowUnauthenticated || security != 1 else {
                throw LabError.message("This host needs password-protected VNC access.")
            }
            try send([UInt8(security)])
        }
        guard macLogin ? security == 30 : ((allowUnauthenticated && security == 1) || security == 2) else { throw LabError.message("Unsupported VNC authentication.") }
        if security == 2 { try authenticate(password) }
        if security == 30 { try authenticateMac(username, password) }
        if security == 30 || security == 2 || negotiated >= 8 {
            guard try number(4) == 0 else { throw LabError.message("Guest display rejected authentication.") }
        }
        try send([1])
        try resize(number(2), number(2))
        _ = try receive(16)
        let length = try number(4)
        guard length <= 1_048_576 else { throw LabError.message("Invalid display name.") }
        _ = try receive(length)
        // 32-bit little endian pixels, RGB bits 16/8/0, unused high byte.
        try send([0,0,0,0,32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0])
        try send([2,0,0,2] + bytes32(0) + bytes32(UInt32(bitPattern: -223)))
        // An unchanged desktop can leave an incremental request pending indefinitely.
        var unlimited = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &unlimited, socklen_t(MemoryLayout<timeval>.size))
        var shortWrite = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &shortWrite, socklen_t(MemoryLayout<timeval>.size))
        var incremental = false
        var needsRequest = true
        var nextRequest = ProcessInfo.processInfo.systemUptime
        while true {
            if needsRequest {
                let delay = nextRequest - ProcessInfo.processInfo.systemUptime
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                nextRequest = ProcessInfo.processInfo.systemUptime + 1.0 / 120
                try send([3, incremental ? 1 : 0, 0,0,0,0] + bytes16(UInt16(width)) + bytes16(UInt16(height)))
                needsRequest = false
            }
            let message = try number(1)
            if message == 2 { continue }
            if message == 3 {
                _ = try receive(3)
                let count = try number(4)
                guard count <= 1_048_576 else { throw LabError.message("Guest clipboard message too large.") }
                _ = try receive(count)
                continue
            }
            guard message == 0 else { throw LabError.message("Unsupported display update.") }
            _ = try receive(1)
            let count = try number(2)
            var resized = false
            for _ in 0..<count {
                let x = try number(2), y = try number(2), w = try number(2), h = try number(2)
                let encoding = Int32(bitPattern: UInt32(try number(4)))
                if encoding == -223 { try resize(w, h); resized = true; continue }
                guard encoding == 0, x + w <= width, y + h <= height else {
                    throw LabError.message("Invalid guest framebuffer rectangle.")
                }
                if x == 0 && w == width {
                    try pixels.withUnsafeMutableBytes { destination in
                        try receive(into: destination.baseAddress!.advanced(by: y * width * 4), count: w * h * 4)
                    }
                } else {
                    var rectangle = Data(count: w * h * 4)
                    try rectangle.withUnsafeMutableBytes { try receive(into: $0.baseAddress!, count: $0.count) }
                    pixels.withUnsafeMutableBytes { destination in
                        rectangle.withUnsafeBytes { source in
                            for row in 0..<h {
                                memcpy(destination.baseAddress!.advanced(by: ((y + row) * width + x) * 4),
                                       source.baseAddress!.advanced(by: row * w * 4), w * 4)
                            }
                        }
                    }
                }
            }
            if count > 0, let provider = CGDataProvider(data: pixels as CFData),
               let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                frame(image)
            }
            needsRequest = true
            incremental = !resized
        }
    }
}
