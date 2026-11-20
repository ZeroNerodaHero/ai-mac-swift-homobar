import Foundation

enum RunState: String {
    case creating = "CREATING", running = "RUNNING", waiting = "WAITING_FOR_BACKGROUND_WORK"
    case finished = "FINISHED", error = "ERROR", cancelled = "CANCELLED", expired = "EXPIRED"
    case unknown = "UNKNOWN", idle = "IDLE"

    var isActive: Bool { self == .creating || self == .running || self == .waiting }

    var icon: String {
        switch self {
        case .running: return "🟢"
        case .creating, .waiting: return "🟡"
        case .finished: return "✅"
        case .error: return "❌"
        case .cancelled, .expired: return "⚪️"
        case .unknown: return "⚠️"
        case .idle: return "▫️"
        }
    }

    var label: String {
        switch self {
        case .waiting: return "WAITING"
        case .unknown: return "UNKNOWN (lookup failed)"
        case .idle: return "IDLE (older)"
        default: return rawValue
        }
    }
}

struct AgentRow: Identifiable {
    let id: String
    let name: String
    let url: URL
    let agentStatus: String
    let createdAt: Date?
    let updatedAt: Date?
    var runState: RunState
    var durationMs: Double?
    var runUpdatedAt: Date?
    var prURLs: [URL]

    /// "Running" includes an ACTIVE agent whose run lookup failed.
    var isRunning: Bool { runState.isActive || (runState == .unknown && agentStatus == "ACTIVE") }
    var endedAt: Date? { runUpdatedAt ?? updatedAt ?? createdAt }
}

struct PullRequest: Identifiable, Decodable {
    let number: Int
    let title: String
    let url: String
    let createdAt: String
    let isDraft: Bool?
    let headRefName: String?
    var id: Int { number }
    var created: Date? { Fmt.parse(createdAt) }
}

enum Fmt {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    static func age(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "?" }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m" }
        return "\(s / 86400)d"
    }

    static func duration(ms: Double?) -> String? {
        guard let ms else { return nil }
        let s = Int(ms / 1000)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m\(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h\(String(format: "%02d", (s % 3600) / 60))m"
    }
}
