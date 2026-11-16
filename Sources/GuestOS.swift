import AppKit
import SwiftUI

/// Read Tart's OS metadata rather than inferring the OS from a VM's name.
enum GuestOS: String {
    case macOS = "darwin"
    case linux = "linux"
    case unknown

    var title: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        case .unknown: return "VM"
        }
    }

    static func local(_ name: String) -> GuestOS {
        guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return .unknown }
        let home = ProcessInfo.processInfo.environment["TART_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tart")
        let config = home.appendingPathComponent("vms").appendingPathComponent(name).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: config),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let os = json["os"] as? String else { return .unknown }
        return GuestOS(rawValue: os) ?? .unknown
    }
}

struct GuestOSIcon: View {
    let os: GuestOS
    var size: CGFloat = 16
    private static let penguin: NSImage? = Bundle.main.url(forResource: "Linux", withExtension: "gif")
        .flatMap { NSImage(contentsOf: $0) }

    var body: some View {
        Group {
            if os == .linux, let image = Self.penguin {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: os == .macOS ? "apple.logo" : "desktopcomputer")
                    .resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(os.title)
    }
}
