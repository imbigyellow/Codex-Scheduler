import Foundation

public enum CodexThreadReference {
    public static func id(from input: String) -> UUID? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed) { return id }
        guard let url = URLComponents(string: trimmed), url.scheme == "codex",
              url.host == "threads", url.path.split(separator: "/").count == 1,
              let last = url.path.split(separator: "/").last else { return nil }
        return UUID(uuidString: String(last))
    }
}
