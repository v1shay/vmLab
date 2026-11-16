import Foundation
import ImageIO

enum GuestPreview {
    static func capture(tart: String, guest: String) -> CGImage? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "alarm 8; exec @ARGV", tart, "exec", guest, "/bin/sh", "-c", """
            dir=$(/usr/bin/mktemp -d) || exit 1
            trap '/bin/rm -rf "$dir"' EXIT
            /usr/sbin/screencapture -x -t png "$dir/frame.png" && /bin/cat "$dir/frame.png"
            """]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
