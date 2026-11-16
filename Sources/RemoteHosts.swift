import AppKit
import SwiftUI

struct RemoteHost: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let os: String
    let online: Bool
    let addresses: [String]
    var lan = false
    var port = 5900

    init(id: String, name: String, hostname: String, port: Int) {
        self.id = id
        self.name = name
        os = "macOS"
        online = true
        addresses = [hostname]
        lan = true
        self.port = port
    }

    enum CodingKeys: String, CodingKey {
        case id = "ID", name = "HostName", os = "OS", online = "Online", addresses = "TailscaleIPs"
    }

    var address: String? { addresses.first { !$0.contains(":") } }

    var symbol: String {
        let model = name.lowercased()
        if model.contains("macbook") { return "laptopcomputer" }
        if model.contains("imac") { return "desktopcomputer" }
        if model.contains("mini") { return "macmini" }
        if model.contains("ipad") { return "ipad" }
        if os == "iOS" || os == "android" { return "iphone" }
        if os == "windows" || os == "linux" { return "desktopcomputer" }
        return "macstudio"
    }

    var url: URL? {
        guard let address else { return nil }
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = address
        components.port = port
        return components.url
    }
}

final class RemoteHosts: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var status = "Checking Tailscale…"
    @Published private(set) var networkReady = false
    @Published var selected: RemoteHost?
    @Published private var nearby: [String: RemoteHost] = [:]
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]

    var allHosts: [RemoteHost] {
        (Array(nearby.values) + hosts).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func reachable(_ host: RemoteHost) -> Bool { host.lan || (networkReady && host.online) }
    func canConnect(_ host: RemoteHost) -> Bool { host.lan || networkReady }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = service.name + service.domain
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let id = sender.name + sender.domain
        guard services[id] === sender, let hostname = sender.hostName, sender.port > 0 else { return }
        nearby[id] = RemoteHost(id: "lan:" + id, name: sender.name, hostname: hostname, port: sender.port)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = service.name + service.domain
        services.removeValue(forKey: id)?.stop()
        nearby.removeValue(forKey: id)
    }

    private struct Status: Decodable {
        let BackendState: String
        let Peer: [String: RemoteHost]?
    }

    @MainActor func monitor() async {
        if FrontendProbe.report != nil,
           let count = ProcessInfo.processInfo.environment["VMLAB_FRONTEND_ONLINE_HOSTS"].flatMap(Int.init) {
            nearby = Dictionary(uniqueKeysWithValues: (0..<min(max(count, 0), 500)).map { index in
                let host = RemoteHost(id: "fixture:\(index)", name: String(format: "Online Mac %03d", index),
                                      hostname: "127.0.0.1", port: 5900)
                return (host.id, host)
            })
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            return
        }
        browser.delegate = self
        browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.")
        defer {
            browser.stop()
            services.values.forEach { $0.stop() }
            services.removeAll()
            nearby.removeAll()
        }
        while !Task.isCancelled {
            let result = await Task.detached(priority: .utility) { Self.readStatus() }.value
            guard !Task.isCancelled else { return }
            if let result {
                let updated = (result.Peer ?? [:]).values.sorted {
                    if $0.online != $1.online { return $0.online }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                if hosts != updated { hosts = updated }
                networkReady = result.BackendState == "Running"
                status = networkReady ? (hosts.isEmpty ? "No Tailscale peers" : "") : "Tailscale disconnected"
            } else {
                networkReady = false
                status = "Tailscale unavailable"
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    nonisolated private static func readStatus() -> Status? {
        let executable = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "alarm 4; exec @ARGV", executable, "status", "--json"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try? JSONDecoder().decode(Status.self, from: data)
    }
}

struct HostAndVMList: View {
    @StateObject private var cluster = ClusterStatus()
    @ObservedObject var directory: RemoteHosts
    @ObservedObject var lab: Lab
    let wallpaper: CGImage?
    var columns = false
    let onLaunchError: (Error) -> Void

    var body: some View {
        Group {
            if columns {
                HStack(alignment: .top, spacing: 12) {
                    list { section("Active", online: true) }
                    list { recentJobs }
                    list {
                        section("Inactive", online: false)
                        taskHosts
                    }
                }
            } else {
                list {
                    section("Active", online: true)
                    recentJobs
                    section("Inactive", online: false)
                    taskHosts
                }
            }
        }
        .task { await cluster.monitor() }
    }

    private func list<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 6) { content() }
                .padding(.horizontal, columns ? 2 : 0)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: "vmLab machine list")
                .environment(\.wallpaperCropSpace, "vmLab machine list")
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var taskHosts: some View {
        if !cluster.snapshot.hosts.isEmpty {
            Text("Task hosts")
                .font(ViewerTypography.geist(size: 10))
                .foregroundStyle(.secondary)
            ForEach(cluster.snapshot.hosts.values.sorted { $0.name < $1.name }, id: \.id) { host in
                HStack {
                    MachineReveal(id: host.id, name: host.name, symbol: .system("terminal"))
                    Spacer()
                    Text(cluster.owner(host.id).map { "Reserved · " + $0 } ?? "SSH task host")
                        .font(ViewerTypography.geist(size: 10))
                        .foregroundStyle(.secondary)
                }
                .font(ViewerTypography.geist(size: 12))
            }
        }
    }

    @ViewBuilder private var recentJobs: some View {
        if columns || !cluster.tasks.isEmpty {
            Text("Recent Jobs")
                .font(ViewerTypography.geist(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            ForEach(cluster.tasks) { task in
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: task.resultDirectory))
                } label: {
                    HStack {
                        MachineReveal(id: "task:" + task.id, name: task.machine.name,
                                      symbol: .runtime(task.controlRuntime), online: task.active)
                            .help(task.controlRuntime == .process ? "Job results" : task.controlRuntime.title + " job")
                        Spacer(minLength: 4)
                        Text(task.status.replacingOccurrences(of: "_", with: " "))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassControlStyle(row: true, solid: true, wallpaper: nil))
                .help("Open job logs and results")
            }
        }
    }

    @ViewBuilder private func section(_ title: String, online: Bool) -> some View {
        let hosts = directory.allHosts.filter { directory.reachable($0) == online }
        let active = lab.visibleMachines.map(\.id)
        let names = online ? active : lab.recentNames.filter { !active.contains($0) }
        Group {
            WallpaperFilledTitle(name: title, image: online ? wallpaper : nil,
                                 color: online ? .mint : Color(white: 0.66),
                                 font: ViewerTypography.geist(size: 10))
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            ForEach(names, id: \.self) { name in
                Button {
                    if let machine = lab.visibleMachines.first(where: { $0.id == name }) {
                        lab.select(machine)
                    } else {
                        do { try lab.openRecent(name) }
                        catch { onLaunchError(error) }
                    }
                } label: {
                    HStack {
                        MachineReveal(id: "vm:" + name, name: name,
                                      symbol: cluster.runtime("vm:" + name).map { .runtime($0) }
                                          ?? .os(lab.visibleMachines.first { $0.id == name }?.os ?? lab.recentOS[name] ?? .unknown),
                                      online: online, order: names.firstIndex(of: name) ?? 0)
                        Spacer()
                        if let owner = cluster.owner("vm:" + name) {
                            Text("Reserved · " + owner)
                                .font(ViewerTypography.geist(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(online ? Color.white : Color(white: 0.66))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(GlassControlStyle(row: true, solid: !online, wallpaper: online ? wallpaper : nil))
                .accessibilityValue(online ? "Active VM" : "Inactive VM")
            }
            ForEach(hosts) { host in
                Button {
                    directory.selected = host
                } label: {
                    MachineReveal(id: host.id, name: host.name, symbol: .system(host.symbol),
                                  online: online, order: hosts.firstIndex(of: host) ?? 0)
                        .lineLimit(1)
                        .foregroundStyle(online ? Color.white : Color(white: 0.66))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(GlassControlStyle(row: true, solid: !online, wallpaper: online ? wallpaper : nil))
                .accessibilityValue("\(online ? "Active" : "Inactive"), \(host.lan ? "Local network" : "Tailscale")")
            }
        }
    }
}

struct RemoteDesktop: View {
    let host: RemoteHost
    let networkReady: Bool
    let wallpaper: CGImage?
    let onAspectChange: (CGFloat?) -> Void
    @StateObject private var machine = Machine("Remote display", displayPassword: nil)
    @State private var username = ""
    @State private var password = ""
    @State private var macLogin = true
    @State private var connecting = false
    @State private var detail: String?

    var body: some View {
        Group {
            if let frame = machine.frame {
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / CGFloat(frame.width),
                                    geometry.size.height / CGFloat(frame.height))
                    GuestSurface(machine: machine, frame: frame)
                        .frame(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(.black)
            } else {
                VStack(spacing: 12) {
                    Label(host.name, systemImage: host.symbol)
                        .font(ViewerTypography.font(.medium, size: 14))
                    if !networkReady {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Tailscale").font(ViewerTypography.geist(size: 12))
                        Button("Open Tailscale") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") {
                                NSWorkspace.shared.open(url)
                            } else {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app"))
                            }
                        }
                    } else {
                        if connecting { ProgressView().controlSize(.small) }
                        if let detail { Text(detail).font(ViewerTypography.geist(size: 12)) }
                        HStack(spacing: 6) {
                            signInButton("Mac Account", useMacAccount: true)
                            signInButton("VNC Password", useMacAccount: false)
                        }
                        if macLogin {
                            TextField("Mac account name", text: $username)
                                .modifier(GlassSignInField())
                        }
                        SecureField(macLogin ? "Mac account password" : "VNC password", text: $password)
                            .modifier(GlassSignInField())
                            .onSubmit(connect)
                        Button("Connect") { connect() }
                            .disabled(connecting || host.url == nil || password.isEmpty || (macLogin && username.isEmpty))
                    }
                }
                .buttonStyle(GlassControlStyle())
                .multilineTextAlignment(.center)
                .padding(18)
                .background {
                    BezierBox()
                        .fill(.ultraThinMaterial)
                        .overlay { BezierBox().strokeBorder(.white.opacity(0.25)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WallpaperSlice(image: wallpaper).overlay(.black.opacity(0.48)) }
            }
        }
        .onAppear { username = UserDefaults.standard.string(forKey: "RemoteAccount." + host.id) ?? "" }
        .onChange(of: networkReady) { _, ready in if !ready { disconnect() } }
        .onChange(of: machine.frame.map { CGFloat($0.width) / CGFloat($0.height) }) { _, aspect in
            onAspectChange(aspect)
        }
        .onDisappear(perform: disconnect)
    }

    private func signInButton(_ title: String, useMacAccount: Bool) -> some View {
        Button {
            if macLogin != useMacAccount {
                macLogin = useMacAccount
                password = ""
                detail = nil
            }
        } label: {
            Text(title)
                .foregroundStyle(macLogin == useMacAccount ? .white : .white.opacity(0.68))
        }
        .overlay {
            BezierBox()
                .strokeBorder(.white.opacity(macLogin == useMacAccount ? 0.48 : 0))
                .allowsHitTesting(false)
        }
        .accessibilityAddTraits(macLogin == useMacAccount ? .isSelected : [])
        .disabled(connecting)
    }

    private struct GlassSignInField: ViewModifier {
        func body(content: Content) -> some View {
            content.textFieldStyle(.plain)
                .font(ViewerTypography.font(.regular, size: 12))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .frame(width: 240, height: 29)
                .background(.black.opacity(0.22), in: BezierBox())
                .overlay {
                    BezierBox().strokeBorder(.white.opacity(0.24))
                        .allowsHitTesting(false)
                }
        }
    }

    private func disconnect() {
        machine.display.stop()
        machine.display = RFB()
        machine.frame = nil
        connecting = false
    }

    private func connect() {
        guard networkReady, !connecting, machine.frame == nil, !password.isEmpty,
              (!macLogin || !username.isEmpty), let url = host.url else { return }
        disconnect()
        connecting = true
        detail = nil
        let credential = password
        let account = username
        let useMacLogin = macLogin
        password = ""
        let display = machine.display
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let delivery = LatestFrameDelivery { frame in
                    guard machine.display === display else { return }
                    if machine.frame == nil && useMacLogin {
                        UserDefaults.standard.set(account, forKey: "RemoteAccount." + host.id)
                    }
                    if connecting { connecting = false }
                    machine.frame = frame
                }
                try display.run(url: url, password: credential, username: account, macLogin: useMacLogin,
                                allowUnauthenticated: false) { delivery.submit($0) }
            } catch {
                DispatchQueue.main.async {
                    guard machine.display === display else { return }
                    connecting = false
                    machine.frame = nil
                    detail = error.localizedDescription
                }
            }
        }
    }
}
