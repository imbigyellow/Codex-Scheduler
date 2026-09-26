import Foundation

public enum TargetApp: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case chatGPT = "ChatGPT"
    public var id: String { rawValue }

    public var knownBundleIDs: [String] {
        switch self {
        case .codex: return ["com.openai.codex"]
        case .chatGPT: return ["com.openai.chat", "com.openai.codex"]
        }
    }
}

public enum TaskStatus: String, Codable, Sendable {
    case waiting, running, sent, cancelled, failed, missed
}

public struct ScheduledTask: Codable, Identifiable, Sendable {
    public var id: UUID
    public var prompt: String
    public var target: TargetApp
    public var targetDate: Date
    public var scheduledAt: Date
    public var timeZoneID: String
    public var isTest: Bool
    public var status: TaskStatus
    public var actualExecutionDate: Date?
    public var error: String?
    /// When set, continue this Codex conversation without using the desktop UI.
    public var codexThreadID: UUID?
    public var codexWorkingDirectory: String?
    public var preventIdleSleep: Bool?

    public init(id: UUID = UUID(), prompt: String, target: TargetApp, targetDate: Date,
                scheduledAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier,
                isTest: Bool = false, status: TaskStatus = .waiting,
                codexThreadID: UUID? = nil, codexWorkingDirectory: String? = nil,
                preventIdleSleep: Bool? = nil) {
        self.id = id
        self.prompt = prompt
        self.target = target
        self.targetDate = targetDate
        self.scheduledAt = scheduledAt
        self.timeZoneID = timeZoneID
        self.isTest = isTest
        self.status = status
        self.codexThreadID = codexThreadID
        self.codexWorkingDirectory = codexWorkingDirectory
        self.preventIdleSleep = preventIdleSleep
    }

    public var label: String { "com.codexscheduler.task.\(id.uuidString.lowercased())" }
}

public enum DueDecision: Equatable {
    case early, execute, missed
}

public enum SchedulePolicy {
    public static let gracePeriod: TimeInterval = 10 * 60
    // Allow only ordinary scheduler latency; never send a prompt long after wake.
    public static let backgroundGracePeriod: TimeInterval = 30
    public static func decision(target: Date, now: Date, background: Bool = false) -> DueDecision {
        let elapsed = now.timeIntervalSince(target)
        if elapsed < 0 { return .early }
        if elapsed > (background ? backgroundGracePeriod : gracePeriod) { return .missed }
        return .execute
    }
}
