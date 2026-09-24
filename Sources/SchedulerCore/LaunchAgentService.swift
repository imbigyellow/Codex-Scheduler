import Foundation
import Darwin

public enum AgentError: LocalizedError {
    case commandFailed(String)
    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        }
    }
}

public final class LaunchAgentService {
    public static let schedulerLabel = "com.codexscheduler.scheduler"
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)) {
        self.directory = directory
    }

    public var schedulerPlistURL: URL {
        directory.appendingPathComponent("\(Self.schedulerLabel).plist")
    }

    // Agents created by earlier versions are removed as their tasks finish.
    public func plistURL(for task: ScheduledTask) -> URL {
        directory.appendingPathComponent("\(task.label).plist")
    }

    public func schedulerPlist(helperPath: String) -> [String: Any] {
        [
            "Label": Self.schedulerLabel,
            "ProgramArguments": [helperPath, "--daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": TaskStore().directory.appendingPathComponent("helper.out.log").path,
            "StandardErrorPath": TaskStore().directory.appendingPathComponent("helper.err.log").path
        ]
    }

    public func ensureInstalled(helperPath: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: TaskStore().directory, withIntermediateDirectories: true)
        let lockURL = TaskStore().directory.appendingPathComponent("scheduler-agent.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw AgentError.commandFailed("无法锁定调度服务") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw AgentError.commandFailed("无法锁定调度服务") }
        defer { flock(lockFD, LOCK_UN) }
        let data = try PropertyListSerialization.data(fromPropertyList: schedulerPlist(helperPath: helperPath), format: .xml, options: 0)
        let url = schedulerPlistURL
        let service = "gui/\(getuid())/\(Self.schedulerLabel)"
        let current = try? Data(contentsOf: url)
        if current != data {
            if current != nil { try? runLaunchctl(["bootout", service]) }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if !isLoaded(service) {
            try runLaunchctl(["bootstrap", "gui/\(getuid())", url.path])
        }
    }

    public func remove(_ task: ScheduledTask) {
        guard task.label.hasPrefix("com.codexscheduler.task.") else { return }
        let url = plistURL(for: task)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
        try? runLaunchctl(["bootout", "gui/\(getuid())/\(task.label)"])
    }

    private func isLoaded(_ service: String) -> Bool {
        (try? runLaunchctl(["print", service])) != nil
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "launchctl 失败"
            throw AgentError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
