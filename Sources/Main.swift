import AppKit
import SwiftUI
import Darwin

struct Request: Codable {
    let args: [String]
    var displayPassword: String? = nil
    var reservation: String? = nil
    var guestOS: String? = nil
}
struct Reply: Codable {
    var output: String? = nil
    var png: Data? = nil
    var error: String? = nil
}

func tartPath() throws -> String {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    let candidates = [ProcessInfo.processInfo.environment["VMLAB_TART"],
                      "/opt/homebrew/bin/tart", "/usr/local/bin/tart",
                      home + "/Applications/Tart.app/Contents/MacOS/tart",
                      "/Applications/Tart.app/Contents/MacOS/tart"].compactMap { $0 }
    guard let path = candidates.first(where: fm.isExecutableFile(atPath:)) else {
        throw LabError.message("Tart is missing. Install it with: brew install openai/tools/tart")
    }
    return path
}

final class Machine: ObservableObject, Identifiable {
    let id: String
    @Published var os: GuestOS
    let process = Process()
    let lifecycle = DispatchQueue(label: "vmlab.guest-lifecycle", qos: .userInitiated)
    let output = Pipe()
    var display = RFB()
    var external = false
    var externalPID: Int32?
    var endpoint: URL?
    let frames = GuestFrames()
    let input = GuestInput()
    private var currentFrame: CGImage?
    var frame: CGImage? {
        get { currentFrame }
        set {
            if currentFrame?.width != newValue?.width || currentFrame?.height != newValue?.height {
                objectWillChange.send()
            }
            currentFrame = newValue
            frames.present(newValue)
        }
    }
    @Published var failed = false
    var state = "starting"
    var detail: String?
    var pending = Data()
    var connected = false
    var guestFailed = false
    var displayPassword: String?
    @Published var toolsStatus = "Unchecked"
    var checkingTools = false
    @Published var previewOnly = false
    var capturingPreview = false

    init(_ name: String, displayPassword: String?, os: GuestOS = .unknown) {
        id = name
        self.os = os
        self.displayPassword = displayPassword
    }
}

final class Lab: ObservableObject {
    @Published var machines: [Machine] = []
    var visibleMachines: [Machine] { machines.filter { $0.external || $0.process.isRunning || $0.state == "starting" || $0.state == "stopping" } }
    var hasOwnedGuests: Bool { machines.contains { !$0.external && ($0.process.isRunning || $0.state == "starting") } }
    @Published private(set) var shuttingDown = false
    @Published var launchFailure: String?
    var onQuit: ((@escaping (Reply) -> Void) -> Void)?
    var onOwnedGuestExit: (() -> Void)?
    private var discovery: Timer?
    private var discoveryInFlight = false
    @Published private(set) var recentNames: [String] = []
    @Published private(set) var recentOS: [String: GuestOS] = [:]
    private var recentsInFlight = false
    @Published private(set) var displayAspect: CGFloat?
    @Published private(set) var selectedID: String?

    var selectedMachine: Machine? { visibleMachines.first { $0.id == selectedID } }

    func select(_ machine: Machine?) {
        selectedID = machine?.id
        updateDisplayAspect()
        if let machine {
            checkTools(machine)
            refreshPreview(machine)
        }
    }

    private func refreshPreview(_ machine: Machine) {
        guard machine.external, machine.failed, !machine.capturingPreview,
              (machine.frame == nil || selectedID == machine.id),
              let tart = try? tartPath() else { return }
        machine.capturingPreview = true
        let name = machine.id
        let pid = machine.externalPID
        DispatchQueue.global(qos: .utility).async { [weak self, weak machine] in
            let frame = GuestPreview.capture(tart: tart, guest: name)
            DispatchQueue.main.async { [weak self, weak machine] in
                guard let self, let machine else { return }
                machine.capturingPreview = false
                guard self.machines.contains(where: { $0 === machine }),
                      machine.externalPID == pid, machine.failed, let frame else { return }
                machine.previewOnly = true
                machine.frame = frame
                machine.toolsStatus = "Connected"
                self.updateDisplayAspect()
            }
        }
    }

    func reconnect(_ machine: Machine, password: String? = nil) {
        guard let endpoint = machine.endpoint else { discover(); return }
        if let password { machine.displayPassword = password }
        machine.display.stop()
        machine.display = RFB()
        machine.frame = nil
        machine.previewOnly = false
        updateDisplayAspect()
        connect(machine, to: endpoint)
        checkTools(machine)
    }

    private func checkTools(_ machine: Machine) {
        guard !machine.checkingTools, let tart = try? tartPath(),
              ProcessInfo.processInfo.environment["VMLAB_TART"] == nil else { return }
        machine.checkingTools = true
        machine.toolsStatus = "Checking…"
        let name = machine.id
        DispatchQueue.global(qos: .utility).async { [weak machine] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = ["-e", "alarm 5; exec @ARGV", tart, "exec", name, "/usr/bin/true"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let ready: Bool
            do {
                try process.run()
                process.waitUntilExit()
                ready = process.terminationStatus == 0
            } catch { ready = false }
            DispatchQueue.main.async { [weak machine] in
                machine?.checkingTools = false
                machine?.toolsStatus = ready ? "Connected" : "Unavailable"
            }
        }
    }
    private var socket: DispatchSourceRead?
    private var lease: Int32 = -1

    func stop(_ name: String, reservation: String? = nil, completion: @escaping (Reply) -> Void) {
        guard !shuttingDown else { completion(Reply(error: "vmLab is shutting down.")); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try ClusterControl.check(name, token: reservation)
                DispatchQueue.main.async { self?.stopChecked(name, completion: completion) }
            } catch {
                DispatchQueue.main.async { completion(Reply(error: error.localizedDescription)) }
            }
        }
    }

    private func stopChecked(_ name: String, completion: @escaping (Reply) -> Void) {
        let machine = machines.first { $0.id == name }
        if machine?.state == "stopping" {
            completion(Reply(output: "Shutdown already requested for \(name)."))
            return
        }
        if let machine, !machine.external, machine.process.isRunning || machine.state == "starting" {
            machine.state = "stopping"
            objectWillChange.send()
            machine.lifecycle.async { if machine.process.isRunning { machine.process.interrupt() } }
            completion(Reply(output: "Shutdown requested for \(name)."))
            return
        }
        guard let tart = try? tartPath() else { completion(Reply(error: "Tart is unavailable.")); return }
        DispatchQueue.global(qos: .utility).async {
            let reply: Reply
            do {
                try TartDiscovery.stop(name, tart: tart)
                reply = Reply(output: "Stopped \(name).")
            } catch { reply = Reply(error: "Tart could not stop \(name).") }
            DispatchQueue.main.async { [weak self] in
                self?.discover()
                completion(reply)
            }
        }
    }

    func stopAll(completion: @escaping (String?) -> Void) {
        guard !shuttingDown else { completion("Shutdown is already in progress."); return }
        shuttingDown = true
        let ownedMachines = machines.filter { !$0.external }
        let owned = ownedMachines.map(\.process)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let failure: String?
            do {
                try ClusterControl.check()
                for machine in ownedMachines { machine.lifecycle.sync {} }
                let tart = try tartPath()
                let running = Set(try TartDiscovery.inventory(tart: tart).filter(\.running).map(\.name))
                DispatchQueue.concurrentPerform(iterations: owned.count) { index in
                    let process = owned[index]
                    if process.isRunning { process.interrupt(); process.waitUntilExit() }
                }
                let remaining = try TartDiscovery.inventory(tart: tart).filter(\.running)
                DispatchQueue.concurrentPerform(iterations: remaining.count) { index in
                    try? TartDiscovery.stop(remaining[index].name, tart: tart)
                }
                let stillRunning = try TartDiscovery.inventory(tart: tart).filter(\.running).map(\.name)
                failure = stillRunning.isEmpty ? nil : "Still running: \(stillRunning.sorted().joined(separator: ", "))."
                if let files = try? FileManager.default.contentsOfDirectory(atPath: LocalSocket.directory),
                   !running.isEmpty, stillRunning.isEmpty {
                    for file in files where file.hasPrefix("display-") && file.hasSuffix(".json") {
                        try? FileManager.default.removeItem(atPath: LocalSocket.directory + "/" + file)
                    }
                }
            } catch { failure = "Could not verify shutdown with Tart: \(error.localizedDescription)" }
            DispatchQueue.main.async { [weak self] in
                self?.shuttingDown = false
                completion(failure)
            }
        }
    }

    func startDiscovery() {
        guard discovery == nil, ProcessInfo.processInfo.environment["VMLAB_TART"] == nil else { return }
        discover()
        discovery = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.discover()
        }
    }

    private func discover() {
        guard !discoveryInFlight else { return }
        discoveryInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = try? TartDiscovery.snapshot()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.discoveryInFlight = false
                self.refreshRecents()
                guard let snapshot else { return }
                self.reconcile(snapshot.guests.filter(\.running), sessions: snapshot.sessions)
            }
        }
    }

    private func reconcile(_ guests: [TartDiscovery.Guest], sessions: [String: TartDiscovery.Session]) {
        let running = Set(guests.map(\.name))
        let removed = machines.filter { $0.external && !running.contains($0.id) }
        removed.forEach {
            $0.display.stop()
            if let pid = $0.externalPID { TartDiscovery.DisplayTicket.remove(pid: pid) }
        }
        if !removed.isEmpty { machines.removeAll { $0.external && !running.contains($0.id) } }

        for guest in guests {
            if let owned = machines.first(where: { $0.id == guest.name && !$0.external && $0.process.isRunning }) {
                if owned.os != guest.os { owned.os = guest.os }
                continue
            }
            let machine: Machine
            if let existing = machines.first(where: { $0.id == guest.name && $0.external }) {
                machine = existing
            } else {
                machine = Machine(guest.name, displayPassword: nil, os: guest.os)
                machine.external = true
                machine.state = "running"
                machines.removeAll { $0.id == guest.name }
                machines.append(machine)
            }
            let session = sessions[guest.name]
            if machine.externalPID != session?.pid || machine.endpoint != session?.endpoint {
                machine.display.stop()
                machine.display = RFB()
                machine.frame = nil
                machine.previewOnly = false
                machine.connected = false
                machine.failed = false
                machine.externalPID = session?.pid
                machine.endpoint = session?.endpoint
            }
            if let endpoint = machine.endpoint {
                if !machine.connected && !machine.failed { connect(machine, to: endpoint) }
            } else if machine.detail == nil || !machine.failed {
                machine.detail = "No compatible VNC display is available."
                machine.failed = true
            }
        }
        for machine in visibleMachines { refreshPreview(machine) }
        if selectedMachine == nil && (selectedID != nil || visibleMachines.count == 1) {
            select(visibleMachines.count == 1 ? visibleMachines.first : nil)
        }
        updateDisplayAspect()
    }

    func refreshRecents() {
        guard !recentsInFlight else { return }
        recentsInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let environment = ProcessInfo.processInfo.environment
            let home = environment["TART_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart")
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: home.appendingPathComponent("vms"), includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])) ?? []
            let local = entries.compactMap { url -> (String, Date)? in
                guard let metadata = try? url.resourceValues(forKeys: keys), metadata.isDirectory == true,
                      FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
                else { return nil }
                return (url.lastPathComponent, metadata.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }.map { $0.0 }
            let history = UserDefaults.standard.stringArray(forKey: "recentVMNames") ?? []
            var seen = Set<String>()
            let names = (history.filter { local.contains($0) } + local).filter { seen.insert($0).inserted }
            let operatingSystems = Dictionary(uniqueKeysWithValues: names.map { ($0, GuestOS.local($0)) })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.recentsInFlight = false
                if self.recentNames != names { self.recentNames = names }
                if self.recentOS != operatingSystems { self.recentOS = operatingSystems }
            }
        }
    }

    func openRecent(_ name: String) throws {
        try start(name, sharing: false, displayPassword: nil)
    }

    private func updateDisplayAspect() {
        let aspect = selectedMachine?.frame.map { CGFloat($0.width) / CGFloat($0.height) }
        if aspect != displayAspect { displayAspect = aspect }
    }

    func listen() throws {
        try LocalSocket.prepare()
        lease = open(LocalSocket.directory + "/owner.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { close(lease); lease = -1 }
            throw LabError.message("vmLab is already running.")
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LabError.message("Could not create control socket.") }
        LocalSocket.configure(fd)
        unlink(LocalSocket.path)
        guard LocalSocket.address({ bind(fd, $0, $1) }) == 0, chmod(LocalSocket.path, 0o600) == 0,
              Darwin.listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            throw LabError.message("Could not listen on the control socket.")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "vmlab.accept"))
        source.setEventHandler { [weak self] in
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return }
            guard fcntl(peer, F_SETFL, 0) == 0, LocalSocket.peerAllowed(peer) else { close(peer); return }
            LocalSocket.configure(peer)
            DispatchQueue.global(qos: .utility).async {
                do {
                    let data = try LocalSocket.read(peer, limit: 65_536)
                    var request = try JSONDecoder().decode(Request.self, from: data)
                    if request.args.first == "start", request.args.count > 1 {
                        request.guestOS = GuestOS.local(request.args[1]).rawValue
                    }
                    DispatchQueue.main.async {
                        let respond: (Reply) -> Void = { reply in
                            DispatchQueue.global(qos: .utility).async {
                                defer { close(peer) }
                                if let bytes = try? JSONEncoder().encode(reply) { try? LocalSocket.write(bytes, to: peer) }
                            }
                        }
                        guard let self else { respond(Reply(error: "vmLab is closing.")); return }
                        if request.args == ["quit"], let onQuit = self.onQuit {
                            onQuit(respond)
                        } else if request.args.count == 2,
                                  ["stop", "shutdown"].contains(request.args[0]) {
                            self.stop(request.args[1], reservation: request.reservation, completion: respond)
                        } else if request.args.count >= 2,
                                  ["screenshot", "key", "click", "drag"].contains(request.args[0]) {
                            guard let machine = self.machines.first(where: { $0.id == request.args[1] }) else {
                                respond(Reply(error: "Unknown vmLab VM.")); return
                            }
                            let display = machine.display
                            let frame = machine.frame
                            let operation = { respond(Self.handleDisplay(request.args, display: display, frame: frame)) }
                            if request.args[0] == "screenshot" {
                                DispatchQueue.global(qos: .userInitiated).async(execute: operation)
                            } else { machine.input.operation(operation) }
                        } else {
                            respond(self.handle(request))
                        }
                    }
                } catch {
                    if let data = try? JSONEncoder().encode(Reply(error: error.localizedDescription)) {
                        try? LocalSocket.write(data, to: peer)
                    }
                    close(peer)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        socket = source
        source.resume()
    }

    func closeLab() {
        discovery?.invalidate()
        discovery = nil
        for machine in machines {
            machine.display.stop()
            if !machine.external { machine.lifecycle.async { if machine.process.isRunning { machine.process.interrupt() } } }
        }
        socket?.cancel()
        if lease >= 0 { unlink(LocalSocket.path); close(lease); lease = -1 }
    }

    private func start(_ name: String, sharing: Bool, displayPassword: String?, os: GuestOS? = nil) throws {
        guard !shuttingDown else { throw LabError.message("vmLab is shutting down.") }
        guard !name.isEmpty, name.count <= 100, !name.hasPrefix("-"),
              !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              !name.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw LabError.message("Use a local Tart VM name.")
        }
        if machines.contains(where: { $0.id == name && ($0.external || $0.process.isRunning || $0.state == "starting" || $0.state == "stopping") }) {
            throw LabError.message("This VM is already running in vmLab.")
        }
        machines.removeAll { !$0.external && ($0.id == name || (!$0.process.isRunning && $0.state != "starting" && $0.state != "stopping")) }
        let machine = Machine(name, displayPassword: sharing ? displayPassword : nil, os: os ?? recentOS[name] ?? .unknown)
        let p = machine.process
        p.executableURL = URL(fileURLWithPath: try tartPath())
        p.arguments = ["run", "--no-graphics", "--no-clipboard", sharing ? "--vnc" : "--vnc-experimental", name]
        p.standardOutput = machine.output
        p.standardError = machine.output
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self, weak machine] p in
            let status = p.terminationStatus
            TartDiscovery.DisplayTicket.remove(pid: p.processIdentifier)
            DispatchQueue.main.async {
                guard let machine else { return }
                machine.display.stop()
                machine.frame = nil
                let failed = machine.state != "stopping" && (status != 0 || machine.guestFailed)
                machine.state = failed ? "failed" : "stopped"
                machine.failed = machine.state == "failed"
                if machine.failed && machine.detail == nil { machine.detail = "Tart exited with status \(status)." }
                if self?.selectedID == machine.id {
                    self?.select(self?.visibleMachines.count == 1 ? self?.visibleMachines.first : nil)
                }
                self?.updateDisplayAspect()
                self?.refreshRecents()
                self?.objectWillChange.send()
                self?.onOwnedGuestExit?()
            }
        }
        machine.output.fileHandleForReading.readabilityHandler = { [weak self, weak machine] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async {
                guard let self, let machine else { return }
                self.consume(data, from: machine)
            }
        }
        machines.append(machine)
        select(machine)
        machine.lifecycle.async { [weak self, weak machine] in
            do { try p.run() }
            catch {
                machine?.output.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    machine?.state = "failed"
                    machine?.failed = true
                    machine?.detail = error.localizedDescription
                    self?.launchFailure = error.localizedDescription
                    self?.objectWillChange.send()
                }
            }
        }
    }

    private func consume(_ data: Data, from machine: Machine) {
        machine.pending.append(data)
        if machine.pending.count > 65_536 { machine.pending.removeAll(); return }
        while let newline = machine.pending.firstIndex(of: 10) {
            let line = String(decoding: machine.pending[..<newline], as: UTF8.self)
            machine.pending.removeSubrange(...newline)
            if let range = line.range(of: "vnc://"),
               let token = line[range.lowerBound...].split(whereSeparator: \.isWhitespace).first,
               let url = URL(string: String(token)), !machine.connected {
                if machine.process.isRunning {
                    TartDiscovery.DisplayTicket.save(url, guest: machine.id, pid: machine.process.processIdentifier)
                    machine.endpoint = url
                    connect(machine, to: url)
                }
            } else if line.contains("stopped the virtual machine due to error") {
                machine.guestFailed = true
                machine.detail = String(line.prefix(400))
                if machine.state == "stopped" {
                    machine.state = "failed"
                    machine.failed = true
                    objectWillChange.send()
                }
            } else if !line.contains("vnc://") && !line.isEmpty && !machine.connected {
                machine.detail = String(line.prefix(400))
            }
        }
    }

    private func connect(_ machine: Machine, to url: URL) {
        machine.connected = true
        machine.failed = false
        machine.detail = nil
        let display = machine.display
        let password = machine.displayPassword ?? url.password
        let delivery = LatestFrameDelivery { [weak self, weak machine] frame in
            guard let self, let machine, machine.display === display,
                  machine.external || (machine.process.isRunning && machine.state != "stopping") else { return }
            let previous = machine.frame
            if machine.previewOnly { machine.previewOnly = false }
            machine.frame = frame
            machine.state = "running"
            if previous?.width != frame.width || previous?.height != frame.height { self.updateDisplayAspect() }
            if previous == nil && !machine.external {
                DispatchQueue.global(qos: .utility).async {
                    let defaults = UserDefaults.standard
                    var history = defaults.stringArray(forKey: "recentVMNames") ?? []
                    history.removeAll { $0 == machine.id }
                    history.insert(machine.id, at: 0)
                    defaults.set(Array(history.prefix(30)), forKey: "recentVMNames")
                    DispatchQueue.main.async { self.refreshRecents() }
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak machine] in
            do {
                try display.run(url: url, password: password) { delivery.submit($0) }
            } catch {
                DispatchQueue.main.async { [weak self, weak machine] in
                    guard let self, let machine, machine.display === display,
                          machine.external || (machine.process.isRunning && machine.state != "stopping")
                    else { return }
                    machine.frame = nil
                    machine.failed = true
                    machine.detail = error.localizedDescription
                    if machine.external {
                        machine.display = RFB()
                        machine.connected = false
                        self.refreshPreview(machine)
                    } else {
                        machine.state = "display-error"
                    }
                    self.updateDisplayAspect()
                }
            }
        }
    }

    private func handle(_ request: Request) -> Reply {
        let args = request.args
        do {
            if args == ["list"] {
                let entries = machines.map { machine -> [String: Any] in
                    var row: [String: Any] = ["name": machine.id, "os": machine.os.rawValue, "state": machine.state, "pid": machine.externalPID ?? machine.process.processIdentifier]
                    if let image = machine.frame { row["width"] = image.width; row["height"] = image.height; row["display"] = machine.previewOnly ? "guest-preview" : "vnc" }
                    if let detail = machine.detail, machine.frame == nil { row["detail"] = detail }
                    return row
                }
                let json = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
                return Reply(output: String(decoding: json, as: UTF8.self))
            }
            guard args.count >= 2 else { throw LabError.message("Run vmlab help.") }
            let command = args[0], name = args[1]
            if command == "start" && (args.count == 2 || (args.count == 3 && args[2] == "--sharing")) {
                if let running = visibleMachines.first(where: { $0.id == name }) {
                    select(running)
                    if running.frame == nil { reconnect(running, password: request.displayPassword) }
                    return Reply(output: "Selected running VM \(name).")
                }
                try start(name, sharing: args.count == 3, displayPassword: request.displayPassword, os: request.guestOS.flatMap(GuestOS.init(rawValue:)))
                return Reply(output: "Started \(name). Use list to check display readiness.")
            }
            throw LabError.message("Run vmlab help.")
        } catch { return Reply(error: error.localizedDescription) }
    }

    private static func handleDisplay(_ args: [String], display: RFB, frame: CGImage?) -> Reply {
        do {
            switch args[0] {
            case "screenshot" where args.count == 2:
                guard let frame = frame, let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
                    throw LabError.message("No guest frame yet.")
                }
                return Reply(png: png)
            case "key" where args.count == 3:
                let keys = args[2].split(separator: "+", omittingEmptySubsequences: false)
                let values = keys.compactMap { key -> UInt32? in
                    if key.hasPrefix("0x") { return UInt32(key.dropFirst(2), radix: 16) }
                    if key.unicodeScalars.count == 1, let value = key.unicodeScalars.first?.value {
                        return value < 256 ? value : 0x01000000 | value
                    }
                    return nil
                }
                guard frame != nil, keys.count == values.count, (1...8).contains(keys.count) else {
                    throw LabError.message("Expected a ready display and a chord such as 0xffeb+q.")
                }
                var pressed: [UInt32] = []
                defer { for key in pressed.reversed() { try? display.key(key, down: false) } }
                for key in values { try display.key(key, down: true); pressed.append(key) }
                return Reply(output: "Sent.")
            case "click" where args.count == 4:
                guard let frame = frame, let x = UInt16(args[2]), let y = UInt16(args[3]),
                      Int(x) < frame.width, Int(y) < frame.height else { throw LabError.message("Point is outside the guest display.") }
                try display.pointer(x: x, y: y, buttons: 1)
                try display.pointer(x: x, y: y, buttons: 0)
                return Reply(output: "Sent.")
            case "drag" where args.count == 6:
                let points = args.dropFirst(2).compactMap { UInt16($0) }
                guard let frame = frame, points.count == 4,
                      Int(points[0]) < frame.width, Int(points[2]) < frame.width,
                      Int(points[1]) < frame.height, Int(points[3]) < frame.height else {
                    throw LabError.message("Drag endpoints must be inside the guest display.")
                }
                let (x, y) = (Int(points[0]), Int(points[1]))
                let (dx, dy) = (Int(points[2]) - x, Int(points[3]) - y)
                defer { try? display.pointer(x: points[2], y: points[3], buttons: 0) }
                for step in 0...12 {
                    try display.pointer(x: UInt16(x + dx * step / 12), y: UInt16(y + dy * step / 12), buttons: 1)
                }
                return Reply(output: "Sent.")
            default: throw LabError.message("Run vmlab help.")
            }
        } catch { return Reply(error: error.localizedDescription) }
    }
}

struct GuestBootAnimation: View {
    let os: GuestOS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        VStack(spacing: 16) {
            GuestOSIcon(os: os, size: 36)
                .opacity(pulsing ? 1 : 0.55)
                .scaleEffect(pulsing ? 1.06 : 1)
                .accessibilityHidden(true)
            Text("Starting \(os.title)…")
                .font(ViewerTypography.geistHeading)
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

struct Pane: View {
    @ObservedObject var machine: Machine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let lab: Lab
    @State private var promptForPassword = false
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            if let frame = machine.frame {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / CGFloat(frame.width),
                                    geometry.size.height / CGFloat(frame.height))
                    Group {
                        if machine.previewOnly {
                            Image(decorative: frame, scale: 1).resizable()
                                .accessibilityLabel("Read-only guest display preview")
                        } else {
                            GuestSurface(machine: machine, frame: frame)
                        }
                    }
                    .frame(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(.black)
                .transition(.opacity)
            } else if machine.state == "starting" && !machine.failed {
                GuestBootAnimation(os: machine.os)
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Label { Text(machine.id) } icon: { GuestOSIcon(os: machine.os) }
                        .font(ViewerTypography.font(.medium, size: 13))
                    Text("VM \(machine.state == "starting" ? "Starting" : "Running") · Display \(machine.connected ? "Connecting" : "Disconnected") · Guest tools \(machine.toolsStatus)")
                        .font(ViewerTypography.geist(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Reconnect display") {
                        if machine.endpoint != nil && machine.detail?.localizedCaseInsensitiveContains("password") == true {
                            promptForPassword = true
                        } else {
                            lab.reconnect(machine)
                        }
                    }
                    .font(ViewerTypography.font(.medium, size: 11))
                    .buttonStyle(GlassControlStyle())
                    .help(machine.detail ?? "Reconnect to the guest display")
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: machine.frame != nil)
        .alert("VNC Password", isPresented: $promptForPassword) {
            SecureField("Password", text: $password)
            Button(role: .cancel) { password = "" } label: {
                Text("Cancel").font(ViewerTypography.font(.medium, size: 11))
            }
            Button {
                lab.reconnect(machine, password: password)
                password = ""
            } label: {
                Text("Connect").font(ViewerTypography.font(.medium, size: 11))
            }
        }
    }
}

struct GuestToolbar: View {
    @ObservedObject var machine: Machine

    @State private var showConnection = false

    var body: some View {
        if machine.frame != nil {
            Button("Copy screenshot") {
                guard let latest = machine.frame else { return }
                let image = NSImage(cgImage: latest, size: .zero)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            .font(ViewerTypography.font(.medium, size: 11))
            .help("Copy the guest display. Esc releases guest input.")
            Button {
                showConnection.toggle()
            } label: {
                Label("Connection", systemImage: "chevron.down")
                    .font(ViewerTypography.font(.medium, size: 11))
            }
            .popover(isPresented: $showConnection, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("VM running", systemImage: "checkmark.circle")
                    Label(machine.previewOnly ? "Read-only preview" : "Display connected",
                          systemImage: "display")
                    Label("Guest tools: \(machine.toolsStatus)", systemImage: "terminal")
                        .foregroundStyle(.secondary)
                }
                .font(ViewerTypography.geist(size: 12))
                .padding(14)
            }
        }
    }
}

struct Wallpaper: Identifiable {
    let id: String
    let name: String
    var title: String { "\(name) (\(id))" }

    static let versions: [Wallpaper] = [
        .init(id: "27", name: "Golden Gate"),
        .init(id: "26", name: "Tahoe"),
        .init(id: "15", name: "Sequoia"),
        .init(id: "14", name: "Sonoma"),
        .init(id: "13", name: "Ventura"),
        .init(id: "12", name: "Monterey"),
        .init(id: "11", name: "Big Sur"),
        .init(id: "10.15", name: "Catalina"),
        .init(id: "10.14", name: "Mojave"),
        .init(id: "10.13", name: "High Sierra"),
        .init(id: "10.12", name: "Sierra"),
        .init(id: "10.11", name: "El Capitan"),
        .init(id: "10.10", name: "Yosemite"),
        .init(id: "10.9", name: "Mavericks"),
        .init(id: "10.8", name: "Mountain Lion"),
        .init(id: "10.7", name: "Lion"),
        .init(id: "10.6", name: "Snow Leopard"),
        .init(id: "10.5", name: "Leopard"),
        .init(id: "10.4", name: "Tiger"),
        .init(id: "10.3", name: "Panther"),
        .init(id: "10.2", name: "Jaguar"),
        .init(id: "10.1", name: "Cheetah / Puma"),
    ]

    static let cycle = Array(versions.reversed())
}

struct Viewer: View {
    static let barHeight: CGFloat = 30
    @ObservedObject var lab: Lab
    let fitDisplay: (CGFloat?) -> Void
    @State private var remoteAspect: CGFloat?
    @StateObject private var remotes = RemoteHosts()
    @State private var launchError: String?
    @StateObject private var wallpaper = WallpaperStore()
    @AppStorage("wallpaperDither") private var wallpaperDither = false
    @AppStorage("machineListColumns") private var machineColumns = false
    var body: some View {
        GeometryReader { canvas in
            VStack(spacing: 0) {
                HStack {
                    WallpaperPicker(state: wallpaper.picker, next: wallpaper.next)
                    Button {
                        wallpaperDither.toggle()
                        WallpaperPresentation.dither(wallpaperDither)
                    } label: {
                        Circle()
                            .fill(wallpaperDither ? Color.white : Color.white.opacity(0.32))
                            .frame(width: 4, height: 4)
                            .frame(width: 17, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Wallpaper dithering")
                    .accessibilityValue(wallpaperDither ? "On" : "Off")
                    .help(wallpaperDither ? "Turn dithering off" : "Dither wallpaper")
                    Spacer(minLength: 0)
                    if remotes.selected != nil {
                        Button("Disconnect") {
                            remoteAspect = nil
                            remotes.selected = nil
                        }
                    } else if let machine = lab.selectedMachine {
                        Button("Hosts & VMs") { lab.select(nil) }
                        GuestToolbar(machine: machine)
                        Button("Shut Down") {
                            lab.stop(machine.id) { reply in
                                launchError = reply.error
                            }
                        }
                        .font(ViewerTypography.font(.medium, size: 11))
                        .disabled(lab.shuttingDown)
                        if lab.visibleMachines.count > 1 {
                            Button("Active VMs") { lab.select(nil) }
                                .font(ViewerTypography.font(.medium, size: 11))
                        }
                    }
                }
                .buttonStyle(GlassControlStyle())
                .padding(.leading, 80)
                .padding(.trailing, 13)
                .frame(height: Self.barHeight)
                .background {
                    WallpaperSlice(image: wallpaper.image, primary: true)
                        .overlay(.black.opacity(0.48))
                        .ignoresSafeArea(edges: .top)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
                if let remote = remotes.selected {
                    RemoteDesktop(host: remote, networkReady: remotes.canConnect(remote), wallpaper: wallpaper.image) {
                        remoteAspect = $0
                    }
                    .id(remote.id)
                } else if let selected = lab.selectedMachine {
                    Pane(machine: selected, lab: lab).id(selected.id)
                } else {
                    HostAndVMList(directory: remotes, lab: lab, wallpaper: wallpaper.image, columns: machineColumns) { error in
                        launchError = error.localizedDescription
                    }
                    .padding(min(32, max(15, canvas.size.width * 0.035)))
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            machineColumns.toggle()
                        } label: {
                            Image(systemName: machineColumns ? "list.bullet" : "rectangle.split.3x1")
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(.white.opacity(0.75))
                                .background(.ultraThinMaterial, in: BezierBox())
                        }
                        .buttonStyle(.plain)
                        .help(machineColumns ? "Use vertical list" : "Use three columns")
                        .accessibilityLabel("Machine layout")
                        .accessibilityValue(machineColumns ? "Three columns" : "Vertical list")
                        .padding(8)
                    }
                }
            }
            .environment(\.wallpaperCanvasSize, canvas.size)
            .coordinateSpace(name: WallpaperSlice.coordinateSpace)
            .environment(\.viewerControlScale, min(1.2, max(0.85, 1 + (canvas.size.width - 660) / 1800)))
            .environment(\.wallpaperDithering, wallpaperDither)
        }
        .ignoresSafeArea(edges: .top)
        .alert("Couldn’t Start VM", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {} message: {
            Text(launchError ?? "")
        }
        .background { ViewerGlass().ignoresSafeArea() }
        .overlay { ViewerEdgeLight().ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .onChange(of: remotes.selected == nil ? lab.displayAspect : remoteAspect, initial: true) { _, aspect in
            fitDisplay(aspect)
        }
        .onChange(of: lab.launchFailure) { _, failure in
            if let failure { launchError = failure; lab.launchFailure = nil }
        }
        .task { await remotes.monitor() }
        .task { await wallpaper.runProbe() }
    }


}

final class ViewerHostingView: NSHostingView<Viewer> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let lab = Lab()
    var window: NSWindow?
    private var terminationApproved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try lab.listen() } catch {
            fputs("vmLab: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        lab.refreshRecents()
        lab.startDiscovery()
        let w = ViewerWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 410),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "vmLab"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.minSize = NSSize(width: 200, height: 110)
        w.contentView = ViewerHostingView(rootView: Viewer(lab: lab) { [weak w] aspect in w?.fitDisplay(aspect) })
        w.isReleasedWhenClosed = false
        w.restoreHomeFrame()
        w.makeKeyAndOrderFront(nil)
        FrontendProbe.windowVisible()
        window = w
        lab.onQuit = { [weak self] respond in
            guard let self else { respond(Reply(error: "vmLab is closing.")); return }
            self.lab.stopAll { failure in
                respond(Reply(output: failure == nil ? "Shut down Tart VMs and quit vmLab." : nil, error: failure))
                if failure == nil {
                    self.terminationApproved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }
        }
        lab.onOwnedGuestExit = { [weak self] in self?.terminateIfIdle() }
        w.onClose = { [weak self] in self?.terminateIfIdle() }
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyCLIPath), keyEquivalent: "")
        copyPath.target = self
        app.submenu?.addItem(copyPath)
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit vmLab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyCLIPath() {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vmlab").path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        lab.refreshRecents()
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func terminateIfIdle() {
        guard !lab.hasOwnedGuests, window?.isVisible != true || NSApp.isHidden else { return }
        guard !lab.shuttingDown else { return }
        terminationApproved = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        if lab.shuttingDown { return .terminateCancel }
        lab.stopAll { failure in
            sender.reply(toApplicationShouldTerminate: failure == nil)
            if let failure {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Shut Down Tart VMs"
                alert.informativeText = failure
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) { lab.closeLab() }
}

let help = """
vmLab — macOS and Linux Tart viewer
  pool                                  Available local VMs and configured SSH hosts
  host add NAME --ssh USER@HOST          Enroll an existing SSH connection for tasks
  host list | host remove NAME           Manage task hosts
  reserve [--os linux|macos] [--owner ID] Reserve an available machine
  renew TOKEN [--ttl SECONDS]            Extend a reservation
  release TOKEN                         Release a reservation
  task run [OPTIONS] -- COMMAND ...     Pick a machine, run, collect, and release
  task submit [OPTIONS] -- COMMAND ...  Run in the background and return a task ID
  task list | show ID | wait ID         Inspect tasks and collected result paths
  task cancel ID                        Cancel a task and collect its logs
  list                                  JSON state, OS, dimensions, and diagnostics
  start NAME [--sharing]                Start an existing local Tart VM with a display
  stop NAME, shutdown NAME              Shut down a local Tart VM
  quit                                  Shut down all running local Tart VMs and quit vmLab
  screenshot NAME --out FILE            Save the current guest frame as PNG
  screenshot NAME --clipboard           Copy the current guest frame to the clipboard
  click NAME X Y                        Click guest pixel coordinates
  drag NAME X1 Y1 X2 Y2                 Drag between guest pixel coordinates
  key NAME KEYS                         Send a keysym or chord, e.g. 0xffeb+q
  tart list|clone|pull|create|set ...     Prepare Tart images and VMs
  exec [-i] NAME -- COMMAND [ARGS...]   Run a guest command, optionally piping stdin

Prepare an image with vmlab tart clone, then start its local name. macOS and Linux share the same commands. Guest exec requires Tart Guest Agent.
Run list until the display reports running. Closing the viewer window keeps VMs running.
"""

func runCLI() throws -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.isEmpty || ["help", "--help", "-h"].contains(args[0]) { print(help); return 0 }
    if ["pool", "host", "reserve", "renew", "release", "task"].contains(args[0]) {
        return try ClusterControl.run(args)
    }
    if ["start", "stop", "shutdown", "quit", "exec", "tart"].contains(args[0]) {
        let guardStatus = try ClusterControl.run(["_guard"] + args)
        if guardStatus != 0 { return guardStatus }
    }
    if args[0] == "tart" || args[0] == "exec" {
        if args[0] == "tart" {
            guard args.count >= 2, ["list", "clone", "pull", "create", "set", "get", "ip"].contains(args[1]) else {
                throw LabError.message("Use a documented Tart preparation command.")
            }
            args.removeFirst()
        }
        if args[0] == "exec" {
            let nameIndex = args.count > 1 && args[1] == "-i" ? 2 : 1
            let separator = nameIndex + 1
            guard args.count > separator + 1, !args[nameIndex].hasPrefix("-"), args[separator] == "--" else {
                throw LabError.message("Usage: vmlab exec [-i] NAME -- COMMAND [ARGS...]")
            }
            args.remove(at: separator)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try tartPath())
        p.arguments = args
        p.standardInput = FileHandle.standardInput
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        try p.run(); p.waitUntilExit(); return p.terminationStatus
    }
    var output: String?
    var clipboard = false
    if args.first == "screenshot" {
        if args.count == 4 && args[2] == "--out" {
            output = args.removeLast()
            args.removeLast()
        } else if args.count == 3 && args[2] == "--clipboard" {
            clipboard = true
            args.removeLast()
        } else {
            throw LabError.message("Usage: vmlab screenshot NAME (--out FILE | --clipboard)")
        }
    }
    var peer = try? LocalSocket.connect()
    if peer == nil {
        let bundle = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launch.arguments = ["-g", bundle.path]
        try launch.run()
        launch.waitUntilExit()
        for _ in 0..<50 {
            peer = try? LocalSocket.connect()
            if peer != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    guard let peer else { throw LabError.message("Could not reach vmLab. Open the app and retry.") }
    defer { close(peer) }
    if ["quit", "stop", "shutdown"].contains(args[0]) { LocalSocket.configure(peer, timeout: 120) }
    let password = args.first == "start" && args.last == "--sharing" ? ProcessInfo.processInfo.environment["VMLAB_VNC_PASSWORD"] : nil
    try LocalSocket.write(JSONEncoder().encode(Request(args: args, displayPassword: password, reservation: ProcessInfo.processInfo.environment["VMLAB_RESERVATION"])), to: peer)
    shutdown(peer, SHUT_WR)
    let reply = try JSONDecoder().decode(Reply.self, from: LocalSocket.read(peer, limit: 128 * 1024 * 1024))
    if let error = reply.error { throw LabError.message(error) }
    if let png = reply.png, let output { try png.write(to: URL(fileURLWithPath: output), options: .atomic); print(output) }
    if clipboard {
        guard let png = reply.png else { throw LabError.message("No guest frame received.") }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(png, forType: .png) else {
            throw LabError.message("Could not write to the clipboard.")
        }
        print("Screenshot copied to clipboard.")
    }
    if let text = reply.output { print(text) }
    return 0
}

@main enum Main {
    static func main() {
        FrontendProbe.start()
        if URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent.lowercased() == "vmlab" &&
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().lastPathComponent != "MacOS" {
            do { exit(try runCLI()) }
            catch { fputs("vmLab: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        WallpaperAppearance.bootstrap()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
