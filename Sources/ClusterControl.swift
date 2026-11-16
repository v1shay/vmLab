import AppKit
import SwiftUI

/// The viewer reads the same atomic snapshots used by the agent CLI.
enum ClusterControl {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["VMLAB_CLUSTER_DIR"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vmLab/Cluster")
    }

    struct MachineRecord: Decodable, Equatable {
        let id: String
        let name: String
    }
    struct Reservation: Decodable, Equatable {
        let token: String
        let machine: MachineRecord
        let owner: String
        let expires: Double
    }
    struct TaskRecord: Decodable, Identifiable, Equatable {
        let id: String
        let machine: MachineRecord
        let status: String
        let created: Double
        let resultDirectory: String
        let runtime: String?
        let command: [String]?
        var controlRuntime: TaskRuntime {
            runtime.flatMap(TaskRuntime.init(rawValue:)) ?? TaskRuntime.detect(command ?? [])
        }
        var active: Bool { ["preparing", "running", "collecting"].contains(status) }
    }
    struct Snapshot: Decodable, Equatable {
        var leases: [String: Reservation] = [:]
        var tasks: [String: TaskRecord] = [:]
        var hosts: [String: MachineRecord] = [:]
    }

    static func read() -> Snapshot {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let value = try? JSONDecoder().decode(Snapshot.self, from: bytes) else { return Snapshot() }
        return value
    }

    static func check(_ name: String? = nil, token: String? = nil) throws {
        let reservations = read().leases.values.filter { $0.expires > Date().timeIntervalSince1970 && $0.machine.id.hasPrefix("vm:") }
        if let reserved = reservations.first(where: { name == nil || $0.machine.id == "vm:" + name! }),
           reserved.token != token {
            throw LabError.message("\(reserved.machine.name) is reserved by \(reserved.owner). Release its reservation before stopping it.")
        }
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let script = contents.appendingPathComponent("Resources/cluster.py")
        let helper = contents.appendingPathComponent("Helpers/vmlab")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["VMLAB_CLI"] = helper.path
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

@MainActor final class ClusterStatus: ObservableObject {
    @Published private(set) var snapshot = ClusterControl.Snapshot()

    func owner(_ machine: String) -> String? {
        snapshot.leases.values.first {
            $0.machine.id == machine && $0.expires > Date().timeIntervalSince1970
        }?.owner
    }

    func runtime(_ machine: String) -> TaskRuntime? {
        snapshot.tasks.values.first { $0.machine.id == machine && $0.active && $0.controlRuntime != .process }?.controlRuntime
    }

    var tasks: [ClusterControl.TaskRecord] {
        Array(snapshot.tasks.values.sorted { $0.created > $1.created }.prefix(5))
    }

    func monitor() async {
        while !Task.isCancelled {
            let updated = await Task.detached(priority: .utility) { ClusterControl.read() }.value
            guard !Task.isCancelled else { return }
            if updated != snapshot { snapshot = updated }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
