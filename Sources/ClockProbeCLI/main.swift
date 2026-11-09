import Foundation
import ClockCore

@main struct ClockProbeCLI {
    static func main() async {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let engine = ClockEngine()
        var success = false
        for host in ["time.apple.com", "time.cloudflare.com"] {
            do {
                let sample = try await SNTPClient.query(host: host)
                if let expected = engine.snapshot(continuous: sample.continuous).trueUTC {
                    print("Cross-source disagreement: \(sample.utc - expected) seconds")
                }
                engine.accept(sample)
                print(String(data: try encoder.encode(sample), encoding: .utf8)!)
                print(String(data: try encoder.encode(engine.snapshot()), encoding: .utf8)!)
                success = true
            } catch { print("\(host): \(error.localizedDescription)") }
        }
        if !success { exit(1) }
        if let index = CommandLine.arguments.firstIndex(of: "--record"), CommandLine.arguments.count > index + 1, let seconds = Int(CommandLine.arguments[index + 1]) {
            for _ in 0..<max(0, seconds) {
                try? await Task.sleep(for: .seconds(1))
                if let data = try? encoder.encode(engine.snapshot()) { print(String(decoding: data, as: UTF8.self)) }
                fflush(stdout)
            }
        }
    }
}
