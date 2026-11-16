import Foundation

enum TartDiscovery {
    struct Guest: Decodable {
        let name: String
        let running: Bool
        var os: GuestOS = .unknown

        enum CodingKeys: String, CodingKey {
            case name = "Name"
            case running = "Running"
        }
    }

    struct Session {
        let pid: Int32
        let endpoint: URL?
    }

    struct DisplayTicket: Codable {
        let guest: String
        let url: URL

        private static func file(for pid: Int32) -> URL {
            URL(fileURLWithPath: LocalSocket.directory).appendingPathComponent("display-\(pid).json")
        }

        static func save(_ url: URL, guest: String, pid: Int32) {
            guard url.host == "127.0.0.1", let data = try? JSONEncoder().encode(Self(guest: guest, url: url))
            else { return }
            try? data.write(to: file(for: pid), options: .atomic)
        }

        static func recover(guest: String, pid: Int32, port: UInt16) -> URL? {
            guard let data = try? Data(contentsOf: file(for: pid)),
                  let ticket = try? JSONDecoder().decode(Self.self, from: data),
                  ticket.guest == guest, ticket.url.host == "127.0.0.1",
                  ticket.url.port == Int(port) else { return nil }
            return ticket.url
        }

        static func remove(pid: Int32) { try? FileManager.default.removeItem(at: file(for: pid)) }
    }

    static func snapshot() throws -> (guests: [Guest], sessions: [String: Session]) {
        let tart = try tartPath()
        let guests = try inventory(tart: tart)
        guard guests.contains(where: \.running) else { return (guests, [:]) }
        let processes = String(decoding: try run("/bin/ps", ["-U", String(getuid()), "-ww", "-o", "pid=,command="]), as: UTF8.self)
        var sessions: [String: Session] = [:]
        for line in processes.split(separator: "\n") {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]),
                  let run = fields[1].range(of: " run "),
                  URL(fileURLWithPath: String(fields[1][..<run.lowerBound])).lastPathComponent == "tart"
            else { continue }
            let arguments = fields[1][run.upperBound...].split(whereSeparator: \.isWhitespace)
            guard let name = arguments.last.map(String.init),
                  guests.contains(where: { $0.running && $0.name == name }) else { continue }
            var endpoint: URL?
            if arguments.contains("--vnc-experimental"),
               let listeners = try? Self.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]) {
                let ports = String(decoding: listeners, as: UTF8.self).split(separator: "\n").compactMap { row -> UInt16? in
                    guard row.hasPrefix("n"), let port = row.split(separator: ":").last else { return nil }
                    return UInt16(port)
                }
                if Set(ports).count == 1, let port = ports.first {
                    endpoint = DisplayTicket.recover(guest: name, pid: pid, port: port)
                        ?? URL(string: "vnc://127.0.0.1:\(port)")
                }
            }
            sessions[name] = Session(pid: pid, endpoint: endpoint)
        }
        return (guests, sessions)
    }

    static func inventory(tart: String) throws -> [Guest] {
        try JSONDecoder().decode([Guest].self, from: run(tart, ["list", "--format", "json"])).map { guest in
            var result = guest
            result.os = GuestOS.local(guest.name)
            return result
        }
    }

    static func stop(_ name: String, tart: String) throws {
        _ = try run(tart, ["stop", name])
    }

    private static func run(_ path: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LabError.message("Could not read Tart runtime state.") }
        return data
    }
}
