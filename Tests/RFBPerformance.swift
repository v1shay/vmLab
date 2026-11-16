import Foundation

@main enum RFBPerformance {
    static func main() throws {
        let display = RFB()
        var start: Double?
        var frames = 0
        var duration = 0.0
        do {
            try display.run(url: URL(string: CommandLine.arguments[1])!, password: nil) { _ in
                let now = ProcessInfo.processInfo.systemUptime
                if start == nil { start = now }
                frames += 1
                duration = now - start!
                if duration >= 1 { display.stop() }
            }
        } catch {
            guard duration >= 1 else { throw error }
        }
        let rate = Double(frames - 1) / duration
        precondition(rate > 75, "The old 15 FPS throttle must not return")
        print(String(format: "PASS: RFB stream delivered %.1f FPS over %.2f seconds", rate, duration))
    }
}
