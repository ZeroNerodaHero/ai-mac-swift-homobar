import Foundation
import UserNotifications
import AppKit

@MainActor
final class JobStore: ObservableObject {
    @Published var agents: [AgentRow] = []
    @Published var prs: [PullRequest] = []
    @Published var agentError: String?
    @Published var prError: String?
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var seenAt: Date = SharedState.seenAt
    @Published var now = Date()

    private var key: String?
    private var prevRunning: Set<String>?
    private var knownFailures: Set<String>? = UserDefaults.standard.array(forKey: "knownFailures").map { Set($0 as? [String] ?? []) }

    init() {
        Task { await loop() }
    }

    private func loop() async {
        while true {
            await refresh()
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
        }
    }

    // MARK: derived
    var running: [AgentRow] { agents.filter(\.isRunning) }
    var failed: [AgentRow] {
        agents.filter { $0.runState == .error && ($0.endedAt.map { now.timeIntervalSince($0) < CursorAPI.failWindow } ?? false) }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }
    var unseenFailures: [AgentRow] { failed.filter { ($0.endedAt ?? .distantPast) > seenAt } }
    var done: [AgentRow] {
        agents.filter { !$0.isRunning && !failed.map(\.id).contains($0.id) }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }
    var needsKey: Bool { agentError == "needs API key" }

    var labelText: String {
        let pr = prs.isEmpty ? "" : " · PR \(prs.count)"
        let fail = unseenFailures.isEmpty ? "" : " ✗ \(unseenFailures.count)"
        if needsKey { return "⚙ ? · PR \(prs.count)" }
        if agentError != nil { return "⚙ !\(pr)" }
        if !running.isEmpty { return "⚙ \(running.count)\(pr)\(fail)" }
        return "✓\(pr)\(fail)"
    }
    var labelIsRed: Bool { !unseenFailures.isEmpty || (agentError != nil && !needsKey) }

    // MARK: actions
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false; now = Date(); lastUpdated = now; seenAt = SharedState.seenAt }

        async let prsTask: Result<[PullRequest], Error> = { do { return .success(try await GitHub.openPRs()) } catch { return .failure(error) } }()

        if key == nil { key = await Task.detached { KeyStore.load() }.value }
        if let key {
            do {
                agents = try await CursorAPI(key: key).fetchAgents()
                agentError = nil
            } catch {
                agentError = (error as? LocalizedError)?.errorDescription ?? "Cursor API error: \(type(of: error))"
                if case APIError.http(let c)? = error as? APIError, c == 401 || c == 403 { self.key = nil }
            }
        } else {
            agentError = "needs API key"
        }

        switch await prsTask {
        case .success(let p): prs = p; prError = nil
        case .failure(let e): prError = "gh error: \(e.localizedDescription)"
        }

        if agentError == nil { notifyTransitions() }
    }

    func markFailuresSeen() {
        SharedState.markSeen()
        seenAt = SharedState.seenAt
    }

    private func notifyTransitions() {
        now = Date()
        let runIDs = Set(running.map(\.id))
        if let prev = prevRunning, !prev.isEmpty, runIDs.isEmpty {
            Notifier.post(title: "Jobbar", body: "All jobs finished (\(prev.count) done)")
        }
        prevRunning = runIDs

        let failIDs = Set(failed.map(\.id))
        if let known = knownFailures {
            let new = failed.filter { !known.contains($0.id) }
            if new.count == 1, let f = new.first {
                let how = Fmt.duration(ms: f.durationMs).map { " after \($0)" } ?? ""
                Notifier.post(title: "Job failed", body: "\(f.name) failed\(how)")
            } else if new.count > 1 {
                Notifier.post(title: "Jobbar", body: "\(new.count) new failed jobs")
            }
        }
        knownFailures = failIDs   // first run seeds silently
        UserDefaults.standard.set(Array(failIDs), forKey: "knownFailures")
    }
}

enum Notifier {
    /// UNUserNotificationCenter needs a real bundle; fall back to osascript when run as a bare binary.
    static var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuth() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        if hasBundle {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        } else {
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""]
            try? p.run()
        }
    }
}
