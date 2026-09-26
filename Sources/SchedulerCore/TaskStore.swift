import Foundation
import Darwin

public enum StoreError: Error { case lockFailed, missingTask, runningTask }

public final class TaskStore {
    public let directory: URL
    private let fileManager = FileManager.default
    private var fileURL: URL { directory.appendingPathComponent("tasks.json") }
    private var lockURL: URL { directory.appendingPathComponent("tasks.lock") }
    private var executionLogURL: URL { directory.appendingPathComponent("executions.jsonl") }
    private var sleepStartURL: URL { directory.appendingPathComponent("sleep-start.json") }

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexScheduler", isDirectory: true)) {
        self.directory = directory
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw StoreError.lockFailed }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.lockFailed }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func readUnlocked() throws -> [ScheduledTask] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ScheduledTask].self, from: Data(contentsOf: fileURL))
    }

    private func writeUnlocked(_ tasks: [ScheduledTask]) throws {
        let data = try JSONEncoder().encode(tasks)
        let temporary = directory.appendingPathComponent("tasks-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if rename(temporary.path, fileURL.path) != 0 {
            try? fileManager.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    public func all() throws -> [ScheduledTask] { try withLock { try readUnlocked() } }

    public func add(_ task: ScheduledTask) throws {
        try withLock {
            var tasks = try readUnlocked()
            tasks.append(task)
            try writeUnlocked(tasks)
        }
    }

    @discardableResult
    public func update(id: UUID, _ change: (inout ScheduledTask) -> Void) throws -> ScheduledTask {
        try withLock {
            var tasks = try readUnlocked()
            guard let index = tasks.firstIndex(where: { $0.id == id }) else { throw StoreError.missingTask }
            change(&tasks[index])
            try writeUnlocked(tasks)
            return tasks[index]
        }
    }

    public func claimIfDue(id: UUID, now: Date = Date()) throws -> DueDecision? {
        try withLock {
            var tasks = try readUnlocked()
            guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].status == .waiting else { return nil }
            let background = tasks[index].target == .codex && tasks[index].codexThreadID != nil
            let sleptThroughDeadline: Bool
            if fileManager.fileExists(atPath: sleepStartURL.path) {
                let start = try JSONDecoder().decode(Date.self, from: Data(contentsOf: sleepStartURL))
                sleptThroughDeadline = tasks[index].targetDate >= start && tasks[index].targetDate <= now
            } else {
                sleptThroughDeadline = false
            }
            let decision = sleptThroughDeadline ? DueDecision.missed :
                SchedulePolicy.decision(target: tasks[index].targetDate, now: now, background: background)
            switch decision {
            case .early: break
            case .execute:
                tasks[index].status = .running
                tasks[index].actualExecutionDate = now
                try writeUnlocked(tasks)
            case .missed:
                tasks[index].status = .missed
                tasks[index].actualExecutionDate = now
                tasks[index].error = sleptThroughDeadline ? "预定时间电脑处于睡眠" :
                    (background ? "未能按时执行（可能睡眠或关机）" : "超过 10 分钟宽限期")
                try writeUnlocked(tasks)
            }
            return decision
        }
    }

    public func recordSleepStart(at date: Date = Date()) throws {
        try withLock {
            try JSONEncoder().encode(date).write(to: sleepStartURL, options: .atomic)
        }
    }

    public func hasPendingSleep() throws -> Bool {
        try withLock { fileManager.fileExists(atPath: sleepStartURL.path) }
    }

    @discardableResult
    public func finishSleep(at now: Date = Date()) throws -> [ScheduledTask] {
        try withLock {
            guard fileManager.fileExists(atPath: sleepStartURL.path) else { return [] }
            let start = try JSONDecoder().decode(Date.self, from: Data(contentsOf: sleepStartURL))
            var tasks = try readUnlocked()
            var missed: [ScheduledTask] = []
            for index in tasks.indices where tasks[index].status == .waiting &&
                tasks[index].targetDate >= start && tasks[index].targetDate <= now {
                tasks[index].status = .missed
                tasks[index].actualExecutionDate = now
                tasks[index].error = "预定时间电脑处于睡眠"
                missed.append(tasks[index])
            }
            if !missed.isEmpty { try writeUnlocked(tasks) }
            try fileManager.removeItem(at: sleepStartURL)
            return missed
        }
    }

    public func delete(id: UUID) throws {
        try withLock {
            var tasks = try readUnlocked()
            if tasks.contains(where: { $0.id == id && $0.status == .running }) { throw StoreError.runningTask }
            tasks.removeAll { $0.id == id }
            try writeUnlocked(tasks)
        }
    }

    @discardableResult
    public func clearHistory() throws -> [ScheduledTask] {
        try withLock {
            let tasks = try readUnlocked()
            let history = tasks.filter { $0.status != .waiting && $0.status != .running }
            guard !history.isEmpty else { return [] }
            try writeUnlocked(tasks.filter { $0.status == .waiting || $0.status == .running })
            if fileManager.fileExists(atPath: executionLogURL.path) {
                let fd = open(executionLogURL.path, O_WRONLY | O_TRUNC)
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                close(fd)
            }
            return history
        }
    }

    public func appendExecutionLog(_ record: Data, taskID: UUID) throws {
        try withLock {
            guard try readUnlocked().contains(where: { $0.id == taskID }) else { return }
            let fd = open(executionLogURL.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(fd) }
            let line = record + Data([10])
            try line.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                    guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    written += count
                }
            }
        }
    }
}
