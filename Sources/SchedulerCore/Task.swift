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

    public init(id: UUID = UUID(), prompt: String, target: TargetApp, targetDate: Date,
                scheduledAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier,
                isTest: Bool = false, status: TaskStatus = .waiting) {
        self.id = id
        self.prompt = prompt
        self.target = target
        self.targetDate = targetDate
        self.scheduledAt = scheduledAt
        self.timeZoneID = timeZoneID
        self.isTest = isTest
        self.status = status
    }

    public var label: String { "com.codexscheduler.task.\(id.uuidString.lowercased())" }
}

public enum DueDecision: Equatable {
    case early, execute, missed
}

public enum SchedulePolicy {
    public static let gracePeriod: TimeInterval = 10 * 60
    public static func decision(target: Date, now: Date) -> DueDecision {
        let elapsed = now.timeIntervalSince(target)
        if elapsed < 0 { return .early }
        if elapsed > gracePeriod { return .missed }
        return .execute
    }
}
