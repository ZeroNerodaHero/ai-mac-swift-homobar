import Foundation
import Security

let ghRepo = "ZeroNerodaHero/slop-stream-architecture"
let ghPath = "/opt/homebrew/bin/gh"

/// Reads the Cursor API key. Never logs or displays it.
enum KeyStore {
    static func load() -> String? {
        // 1) Security framework, non-interactive (no keychain prompt).
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cursor-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let s = String(data: data, encoding: .utf8)?.trimmed, !s.isEmpty {
            return s
        }
        // 2) /usr/bin/security is usually on the item's ACL (it created it), so no prompt.
        if let s = run("/usr/bin/security", ["find-generic-password", "-s", "cursor-api-key", "-w"])?.trimmed, !s.isEmpty {
            return s
        }
        // 3) File fallback.
        let path = NSString(string: "~/.config/job-menubar/key").expandingTildeInPath
        if let s = try? String(contentsOfFile: path, encoding: .utf8).trimmed, !s.isEmpty { return s }
        return nil
    }

    private static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

enum APIError: LocalizedError {
    case http(Int), badJSON
    var errorDescription: String? {
        switch self {
        case .http(let c) where c == 401 || c == 403: return "API key rejected (\(c))"
        case .http(let c): return "Cursor API HTTP \(c)"
        case .badJSON: return "Cursor API returned bad JSON"
        }
    }
}

struct CursorAPI {
    let key: String
    static let failWindow: TimeInterval = 24 * 3600

    func get(_ path: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.cursor.com/v1" + path)!)
        req.timeoutInterval = 15
        req.setValue("Basic " + Data((key + ":").utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw APIError.http(h.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.badJSON }
        return obj
    }

    /// Lists up to ~100 agents (2 pages), then fetches the latest run for active ones and ones updated in the last 24h.
    func fetchAgents() async throws -> [AgentRow] {
        var raw: [[String: Any]] = []
        var cursor: String? = nil
        repeat {
            var path = "/agents?limit=50&includeArchived=false"
            if let c = cursor, let enc = c.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "&cursor=" + enc }
            let page = try await get(path)
            raw += (page["items"] as? [[String: Any]]) ?? []
            cursor = page["nextCursor"] as? String
        } while cursor != nil && raw.count < 100

        let now = Date()
        var rows: [AgentRow] = raw.compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            let status = a["status"] as? String ?? "IDLE"
            return AgentRow(
                id: id,
                name: (a["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "untitled",
                url: URL(string: a["url"] as? String ?? "") ?? URL(string: "https://cursor.com/agents/\(id)")!,
                agentStatus: status,
                createdAt: Fmt.parse(a["createdAt"] as? String),
                updatedAt: Fmt.parse(a["updatedAt"] as? String),
                runState: status == "ACTIVE" ? .running : .idle,
                durationMs: nil, runUpdatedAt: nil, prURLs: [])
        }
        let runIDs: [String: String] = Dictionary(uniqueKeysWithValues: raw.compactMap { a in
            guard let id = a["id"] as? String, let r = a["latestRunId"] as? String else { return nil }
            return (id, r)
        })
        let wanted = rows.indices.filter { i in
            rows[i].agentStatus == "ACTIVE" || (rows[i].updatedAt.map { now.timeIntervalSince($0) < Self.failWindow } ?? false)
        }

        // Fetch runs, 8 at a time.
        for chunk in stride(from: 0, to: wanted.count, by: 8).map({ Array(wanted[$0..<min($0 + 8, wanted.count)]) }) {
            await withTaskGroup(of: (Int, [String: Any]?).self) { group in
                for i in chunk {
                    let agentID = rows[i].id
                    guard let runID = runIDs[agentID] else { continue }
                    group.addTask { (i, try? await self.get("/agents/\(agentID)/runs/\(runID)")) }
                }
                for await (i, run) in group {
                    guard let run else { rows[i].runState = .unknown; continue }   // lookup failed: don't assume FINISHED
                    rows[i].runState = RunState(rawValue: run["status"] as? String ?? "") ?? .unknown
                    rows[i].durationMs = (run["durationMs"] as? NSNumber)?.doubleValue
                    rows[i].runUpdatedAt = Fmt.parse(run["updatedAt"] as? String)
                    let branches = ((run["git"] as? [String: Any])?["branches"] as? [[String: Any]]) ?? []
                    rows[i].prURLs = branches.compactMap { ($0["prUrl"] as? String).flatMap(URL.init(string:)) }
                }
            }
        }
        // Agents with no run at all: ACTIVE stays running, recent IDLE counts as finished.
        for i in wanted where runIDs[rows[i].id] == nil && rows[i].agentStatus != "ACTIVE" { rows[i].runState = .finished }
        return rows
    }
}

enum GitHub {
    static func openPRs() async throws -> [PullRequest] {
        try await Task.detached(priority: .utility) { () throws -> [PullRequest] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ghPath)
            p.arguments = ["pr", "list", "-R", ghRepo, "--state", "open", "--limit", "30",
                           "--json", "number,title,url,createdAt,isDraft,headRefName"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin"
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out; p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let edata = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(data: edata, encoding: .utf8)?.trimmed.components(separatedBy: "\n").last ?? "gh failed"
                throw NSError(domain: "gh", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
            }
            return try JSONDecoder().decode([PullRequest].self, from: data)
        }.value
    }
}

/// Seen marker shared with the SwiftBar plugin (~/.config/job-menubar/state.json, key failures_seen_at).
enum SharedState {
    static let path = NSString(string: "~/.config/job-menubar/state.json").expandingTildeInPath

    static func read() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static var seenAt: Date {
        Date(timeIntervalSince1970: (read()["failures_seen_at"] as? NSNumber)?.doubleValue ?? 0)
    }

    static func markSeen(_ date: Date = Date()) {
        var o = read()
        o["failures_seen_at"] = date.timeIntervalSince1970
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}
