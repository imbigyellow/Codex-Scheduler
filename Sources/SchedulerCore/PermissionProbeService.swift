import Foundation
import Darwin

public final class PermissionProbeService {
    public init() {}

    public func isLaunchAgentHelperTrusted(helperPath: String) -> Bool {
        let label = "com.codexscheduler.permission"
        let service = "gui/\(getuid())/\(label)"
        let agentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = agentsDirectory.appendingPathComponent("\(label).plist")
        let statusURL = TaskStore().directory.appendingPathComponent("permission-status.txt")

        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: TaskStore().directory, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [helperPath, "--probe-accessibility", statusURL.path],
                "RunAtLoad": true
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let existing = try? Data(contentsOf: plistURL)
            if existing != data {
                _ = runLaunchctl(["bootout", service])
                try data.write(to: plistURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: statusURL)
            if !runLaunchctl(["kickstart", "-k", service]) {
                guard runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) else { return false }
            }
            for _ in 0..<30 {
                if let value = try? String(contentsOf: statusURL, encoding: .utf8) {
                    return value == "authorized"
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } catch { return false }
        return false
    }

    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
