import Foundation
import SchedulerCore

if CommandLine.arguments.contains("--permission-probe") {
    guard let helperIndex = CommandLine.arguments.firstIndex(of: "--helper"),
          CommandLine.arguments.indices.contains(helperIndex + 1) else { fatalError("--helper path required") }
    print("LaunchAgent helper accessibility: \(PermissionProbeService().isLaunchAgentHelperTrusted(helperPath: CommandLine.arguments[helperIndex + 1]))")
    exit(0)
}

if CommandLine.arguments.contains("--agent-registration") {
    guard let helperIndex = CommandLine.arguments.firstIndex(of: "--helper"),
          CommandLine.arguments.indices.contains(helperIndex + 1) else { fatalError("--helper path required") }
    let helper = CommandLine.arguments[helperIndex + 1]
    let store = TaskStore()
    let agents = LaunchAgentService()
    let tasks = [1.0, 2.0].map { hours in
        ScheduledTask(prompt: "Registration-only check", target: .codex,
                      targetDate: Date().addingTimeInterval(hours * 3600))
    }
    do {
        for task in tasks {
            try store.add(task)
            try agents.ensureInstalled(helperPath: helper)
        }
        try check(FileManager.default.fileExists(atPath: agents.schedulerPlistURL.path), "scheduler exists")
        try check(tasks.allSatisfy { !FileManager.default.fileExists(atPath: agents.plistURL(for: $0).path) },
                  "no per-task agents")
        print("Registration check: two tasks, one fixed LaunchAgent")
    } catch {
        fputs("Registration check failed: \(error)\n", stderr)
        for task in tasks { try? store.delete(id: task.id) }
        exit(1)
    }
    for task in tasks { try? store.delete(id: task.id) }
    exit(0)
}

if CommandLine.arguments.contains("--agent-integration") {
    guard let helperIndex = CommandLine.arguments.firstIndex(of: "--helper"),
          CommandLine.arguments.indices.contains(helperIndex + 1) else { fatalError("--helper path required") }
    let helper = CommandLine.arguments[helperIndex + 1]
    let store = TaskStore()
    let agents = LaunchAgentService()
    let task = ScheduledTask(prompt: "Codex Scheduler 自动验收测试，请忽略此消息。",
                             target: .codex, targetDate: Date().addingTimeInterval(4), isTest: true)
    do {
        try store.add(task)
        try agents.ensureInstalled(helperPath: helper)
        let installedData = try Data(contentsOf: agents.schedulerPlistURL)
        let installed = try PropertyListSerialization.propertyList(from: installedData, format: nil) as! [String: Any]
        try check(installed["Label"] as? String == LaunchAgentService.schedulerLabel, "installed agent label")
        try check((installed["ProgramArguments"] as? [String])?.first == helper, "installed helper path")
        print("Integration agent: \(agents.schedulerPlistURL.path)")
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 1)
            if let current = try store.all().first(where: { $0.id == task.id }),
               current.status != .waiting && current.status != .running {
                print("Integration result: \(current.status.rawValue); \(current.error ?? "none")")
                agents.remove(task)
                try store.delete(id: task.id)
                exit(0)
            }
        }
        agents.remove(task)
        try store.delete(id: task.id)
        fputs("Integration agent did not finish in 25 seconds\n", stderr)
        exit(1)
    } catch {
        agents.remove(task)
        try? store.delete(id: task.id)
        fputs("Integration failed: \(error)\n", stderr)
        exit(1)
    }
}

func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let target = Date(timeIntervalSince1970: 1_800_000_000)
    try check(SchedulePolicy.decision(target: target, now: target.addingTimeInterval(-1)) == .early, "early")
    try check(SchedulePolicy.decision(target: target, now: target) == .execute, "due")
    try check(SchedulePolicy.decision(target: target, now: target.addingTimeInterval(600)) == .execute, "grace")
    try check(SchedulePolicy.decision(target: target, now: target.addingTimeInterval(601)) == .missed, "missed")
    try check(SchedulePolicy.decision(target: target, now: target.addingTimeInterval(365 * 86400)) == .missed, "next year")

    let first = ScheduledTask(prompt: "中文\nemoji 😀\n$(echo hello)", target: .codex,
                              targetDate: Date().addingTimeInterval(3600))
    let second = ScheduledTask(prompt: "second", target: .chatGPT,
                               targetDate: Date().addingTimeInterval(7200))
    try check(first.label != second.label, "unique legacy task labels")
    let agent = LaunchAgentService()
    let data = try PropertyListSerialization.data(fromPropertyList: agent.schedulerPlist(helperPath: "/tmp/SchedulerHelper"), format: .xml, options: 0)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    try check(plist["Label"] as? String == LaunchAgentService.schedulerLabel, "fixed scheduler label")
    try check((plist["ProgramArguments"] as? [String])?.last == "--daemon", "daemon arguments")
    try check(plist["KeepAlive"] as? Bool == true, "login restart")
    try check(plist["StartCalendarInterval"] == nil && plist["StartInterval"] == nil, "no polling")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = TaskStore(directory: folder)
    let task = ScheduledTask(prompt: "你好 😀\n`echo test`", target: .codex,
                             targetDate: Date().addingTimeInterval(-5))
    try store.add(task)
    try check(try store.all().first?.prompt == task.prompt, "unicode persistence")
    try check(try store.claimIfDue(id: task.id) == .execute, "claim")
    try check(try store.claimIfDue(id: task.id) == nil, "single claim")

    let waiting = ScheduledTask(prompt: "Keep me", target: .chatGPT,
                                targetDate: Date().addingTimeInterval(3600))
    let sent = ScheduledTask(prompt: "Old sent prompt", target: .codex,
                             targetDate: Date().addingTimeInterval(-60), status: .sent)
    let failed = ScheduledTask(prompt: "Old failed prompt", target: .codex,
                               targetDate: Date().addingTimeInterval(-60), status: .failed)
    let cancelled = ScheduledTask(prompt: "Old cancelled prompt", target: .codex,
                                  targetDate: Date().addingTimeInterval(-60), status: .cancelled)
    let missed = ScheduledTask(prompt: "Old missed prompt", target: .codex,
                               targetDate: Date().addingTimeInterval(-60), status: .missed)
    for item in [waiting, sent, failed, cancelled, missed] { try store.add(item) }
    let logRecord = try JSONSerialization.data(withJSONObject: ["id": sent.id.uuidString, "result": "sent"])
    try store.appendExecutionLog(logRecord, taskID: sent.id)
    let logURL = folder.appendingPathComponent("executions.jsonl")
    try check(try Data(contentsOf: logURL).count > 0, "log exists before clear")
    let removed = try store.clearHistory()
    try check(removed.count == 4, "only terminal tasks removed")
    let remaining = try store.all()
    try check(remaining.count == 2, "waiting and running remain")
    try check(remaining.contains(where: { $0.id == waiting.id }), "waiting preserved")
    try check(remaining.contains(where: { $0.id == task.id && $0.status == .running }), "running preserved")
    try check(try Data(contentsOf: logURL).isEmpty, "execution log cleared")
    try store.appendExecutionLog(logRecord, taskID: sent.id)
    try check(try Data(contentsOf: logURL).isEmpty, "cleared task cannot recreate log")
    print("SchedulerSelfTest: 20 checks passed")
} catch {
    fputs("SchedulerSelfTest failed: \(error)\n", stderr)
    exit(1)
}
