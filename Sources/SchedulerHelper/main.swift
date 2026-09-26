import AppKit
import ApplicationServices
import SchedulerCore
import Darwin

private enum SendError: LocalizedError {
    case noAccessibility, appNotFound, activationFailed, wrongFrontmost, eventFailed
    case codexMissing, invalidDirectory, codexFailed(String)
    var errorDescription: String? {
        switch self {
        case .noAccessibility: return "SchedulerHelper 没有辅助功能权限"
        case .appNotFound: return "未找到目标 App"
        case .activationFailed: return "无法激活目标 App"
        case .wrongFrontmost: return "目标 App 未成为前台应用"
        case .eventFailed: return "无法生成键盘事件"
        case .codexMissing: return "未找到 Codex CLI；请安装或更新 Codex 桌面应用"
        case .invalidDirectory: return "Codex 项目目录不存在"
        case .codexFailed(let message): return "Codex 后台续聊失败：\(message)"
        }
    }
}

private func codexExecutable() -> URL? {
    let paths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex"
    ]
    return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
}

private func continueCodexThread(_ task: ScheduledTask) throws {
    guard let threadID = task.codexThreadID else { return }
    guard let executable = codexExecutable() else { throw SendError.codexMissing }
    guard let directory = task.codexWorkingDirectory,
          FileManager.default.fileExists(atPath: directory) else { throw SendError.invalidDirectory }
    let process = Process()
    process.executableURL = executable
    process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
    process.arguments = ["exec", "resume", "--skip-git-repo-check", "-c", "approval_policy=never",
                         "-c", "sandbox_mode=\"workspace-write\"",
                         threadID.uuidString.lowercased(), "-"]
    let input = Pipe()
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("codex-scheduler-\(task.id.uuidString).log")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    input.fileHandleForWriting.write(Data(task.prompt.utf8))
    try? input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "退出码 \(process.terminationStatus)"
        throw SendError.codexFailed(String(message.suffix(800)))
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]
    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        }
    }
    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        _ = pasteboard.writeObjects(restored)
    }
}

private func findTarget(_ target: TargetApp) -> NSRunningApplication? {
    let workspace = NSWorkspace.shared
    let running = workspace.runningApplications.filter { $0.activationPolicy == .regular }
    // Current Codex builds can carry the ChatGPT display name while retaining this bundle ID.
    if target == .codex,
       let codex = running.first(where: { $0.bundleIdentifier == "com.openai.codex" }) { return codex }
    if let named = running.first(where: { $0.localizedName?.caseInsensitiveCompare(target.rawValue) == .orderedSame }) { return named }
    return running.first {
        target.knownBundleIDs.contains($0.bundleIdentifier ?? "") &&
        $0.bundleURL?.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(target.rawValue) == .orderedSame
    }
}

private func key(_ code: CGKeyCode, command: Bool = false) throws {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
        throw SendError.eventFailed
    }
    if command { down.flags = .maskCommand; up.flags = .maskCommand }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

private func send(_ task: ScheduledTask) throws {
    if task.target == .codex && task.codexThreadID != nil {
        try continueCodexThread(task)
        return
    }
    guard AXIsProcessTrusted() else { throw SendError.noAccessibility }
    var app = findTarget(task.target)
    if app == nil {
        for bundleID in task.target.knownBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                let isCodexBundle = task.target == .codex && bundleID == "com.openai.codex"
                guard isCodexBundle || name.caseInsensitiveCompare(task.target.rawValue) == .orderedSame else { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", url.path]
                try? process.run()
                process.waitUntilExit()
                for _ in 0..<40 {
                    app = findTarget(task.target)
                    if app != nil { break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                if app != nil { break }
            }
        }
    }
    guard let app else { throw SendError.appNotFound }
    var frontmost = false
    for _ in 0..<3 {
        guard app.activate(options: [.activateIgnoringOtherApps]) else { throw SendError.activationFailed }
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.15)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                frontmost = true
                break
            }
        }
        if frontmost { break }
    }
    guard frontmost else { throw SendError.wrongFrontmost }

    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(task.prompt, forType: .string) else {
        snapshot.restore(pasteboard)
        throw SendError.eventFailed
    }
    defer { snapshot.restore(pasteboard) }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.wrongFrontmost }
    try key(9, command: true) // V
    Thread.sleep(forTimeInterval: 0.8)
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { throw SendError.wrongFrontmost }
    try key(36) // Return
    Thread.sleep(forTimeInterval: 0.5)
}

private func appendLog(_ task: ScheduledTask, result: String, error: String? = nil) {
    let record: [String: Any] = [
        "id": task.id.uuidString, "scheduledAt": ISO8601DateFormatter().string(from: task.scheduledAt),
        "targetDate": ISO8601DateFormatter().string(from: task.targetDate),
        "actualExecutionDate": ISO8601DateFormatter().string(from: Date()),
        "targetApp": task.target.rawValue, "result": result, "error": error ?? ""
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
    try? TaskStore().appendExecutionLog(data, taskID: task.id)
}

private func runTask(id: UUID) {
    let store = TaskStore()
    guard let task = try? store.all().first(where: { $0.id == id }) else { return }
    guard let decision = try? store.claimIfDue(id: id) else { return }
    switch decision {
    case .early: return
    case .missed:
        let reason = (try? store.all().first(where: { $0.id == id })?.error) ?? "未能按时执行"
        appendLog(task, result: "missed", error: reason)
        LaunchAgentService().remove(task)
    case .execute:
        do {
            try send(task)
            try store.update(id: id) { $0.status = .sent; $0.error = nil }
            appendLog(task, result: "sent")
        } catch {
            let message = error.localizedDescription
            _ = try? store.update(id: id) { $0.status = .failed; $0.error = message }
            appendLog(task, result: "failed", error: message)
        }
        LaunchAgentService().remove(task)
    }
}

private final class SchedulerDaemon {
    private let store = TaskStore()
    private let timer = DispatchSource.makeTimerSource(queue: .main)
    private var observer: DispatchSourceFileSystemObject?
    private var caffeine: Process?
    private var inFlight = Set<UUID>()
    private var inFlightBackground = Set<UUID>()
    private let codexQueue = DispatchQueue(label: "CodexScheduler.codex")
    private var sleepObservers: [NSObjectProtocol] = []

    private func finishSleep() {
        do {
            for task in try store.finishSleep() {
                appendLog(task, result: "missed", error: "预定时间电脑处于睡眠")
            }
        } catch { fputs("Unable to record missed tasks after sleep: \(error)\n", stderr) }
        refreshSchedule()
    }

    private func updateSleepPrevention(_ needed: Bool) {
        if needed {
            guard caffeine?.isRunning != true else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = ["-i", "-w", String(getpid())]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run(); caffeine = process }
            catch { fputs("Unable to prevent idle sleep: \(error)\n", stderr) }
        } else if let caffeine {
            if caffeine.isRunning { caffeine.terminate() }
            self.caffeine = nil
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let fd = open(store.directory.path, O_EVTONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refreshSchedule() }
        source.setCancelHandler { close(fd) }
        observer = source
        timer.setEventHandler { [weak self] in self?.refreshSchedule() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        source.resume()
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            do { try self?.store.recordSleepStart() }
            catch { fputs("Unable to record sleep start: \(error)\n", stderr) }
        })
        sleepObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                  object: nil, queue: .main) { [weak self] _ in
            self?.finishSleep()
        })
        // A restarted agent may have missed the wake notification.
        if try store.hasPendingSleep() { finishSleep() }
        refreshSchedule()
    }

    private func refreshSchedule() {
        // The will-sleep notification can cause a file event before the machine sleeps.
        guard (try? store.hasPendingSleep()) == false else { return }
        guard let tasks = try? store.all() else { return }
        let now = Date()
        let waiting = tasks.filter { $0.status == .waiting }
        updateSleepPrevention(!inFlightBackground.isEmpty || waiting.contains {
            $0.target == .codex && $0.codexThreadID != nil && $0.preventIdleSleep == true
        })
        for task in waiting where task.targetDate <= now && !inFlight.contains(task.id) {
            inFlight.insert(task.id)
            if task.codexThreadID != nil && task.preventIdleSleep == true { inFlightBackground.insert(task.id) }
            let queue = task.codexThreadID == nil ? DispatchQueue.global(qos: .utility) : codexQueue
            queue.async { [weak self] in
                runTask(id: task.id)
                DispatchQueue.main.async {
                    self?.inFlight.remove(task.id)
                    self?.inFlightBackground.remove(task.id)
                    self?.refreshSchedule()
                }
            }
        }
        let remaining = (try? store.all().filter { $0.status == .waiting }) ?? []
        updateSleepPrevention(!inFlightBackground.isEmpty || remaining.contains {
            $0.target == .codex && $0.codexThreadID != nil && $0.preventIdleSleep == true
        })
        guard let next = remaining.filter({ $0.targetDate > now }).map(\.targetDate).min() else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        timer.schedule(wallDeadline: .now() + max(0.01, next.timeIntervalSinceNow), leeway: .milliseconds(100))
    }
}

if CommandLine.arguments.contains("--check-accessibility") { exit(AXIsProcessTrusted() ? 0 : 1) }
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe-accessibility" {
    let status = AXIsProcessTrusted() ? "authorized" : "denied"
    try? status.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
    exit(0)
}
if CommandLine.arguments.contains("--request-accessibility") {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    exit(0)
}
if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--daemon" {
    let daemon = SchedulerDaemon()
    do { try daemon.start() } catch {
        fputs("Scheduler daemon failed to start: \(error)\n", stderr)
        exit(1)
    }
    dispatchMain()
}
guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--run",
      let id = UUID(uuidString: CommandLine.arguments[2]) else { exit(2) }
runTask(id: id)
