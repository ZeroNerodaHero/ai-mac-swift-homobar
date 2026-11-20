import SwiftUI
import AppKit

enum Filter: String, CaseIterable, Identifiable {
    case all = "All", running = "Running", failed = "Failed", done = "Done", prs = "PRs"
    var id: String { rawValue }
}

struct ContentView: View {
    @ObservedObject var store: JobStore
    @State private var filter: Filter = .all
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in Text(title(f)).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextField("Search jobs and PRs", text: $query).textFieldStyle(.roundedBorder)
            if !store.unseenFailures.isEmpty { failureBanner }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) { sections }
                    .padding(.trailing, 6)
            }
            .frame(height: 400)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 460)
    }

    // MARK: pieces
    private var header: some View {
        HStack {
            Text("Jobs").font(.headline)
            if let t = store.lastUpdated {
                Text("updated \(Fmt.age(t, now: store.now)) ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.loading { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh now").keyboardShortcut("r")
        }
    }

    private var failureBanner: some View {
        HStack {
            Text("✗ \(store.unseenFailures.count) new failure\(store.unseenFailures.count == 1 ? "" : "s") in the last 24h")
                .foregroundStyle(.red).font(.callout.weight(.semibold))
            Spacer()
            Button("Mark seen") { store.markFailuresSeen() }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
    }

    @ViewBuilder private var sections: some View {
        if let err = store.agentError, filter != .prs {
            VStack(alignment: .leading, spacing: 4) {
                Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                if store.needsKey {
                    Link("Create a key at cursor.com/dashboard → API Keys", destination: URL(string: "https://cursor.com/dashboard")!)
                    Text("security add-generic-password -a $USER -s cursor-api-key -w").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(.vertical, 4)
        }
        switch filter {
        case .all:
            agentSection("Running", store.running, empty: "Nothing running 🎉")
            agentSection("Failed in last 24h", store.failed, empty: "No failures 👍")
            agentSection("Done", store.done, empty: "Nothing here")
            prSection
        case .running: agentSection("Running", store.running, empty: "Nothing running 🎉")
        case .failed: agentSection("Failed in last 24h", store.failed, empty: "No failures 👍")
        case .done: agentSection("Done", store.done, empty: "Nothing here")
        case .prs: prSection
        }
    }

    private func matches(_ s: String) -> Bool { query.isEmpty || s.localizedCaseInsensitiveContains(query) }

    @ViewBuilder private func agentSection(_ title: String, _ rows: [AgentRow], empty: String) -> some View {
        if store.agentError == nil {
            let shown = rows.filter { matches($0.name) }
            Section {
                if shown.isEmpty {
                    Text(query.isEmpty ? empty : "No matches").foregroundStyle(.secondary).font(.callout).padding(.vertical, 4)
                }
                ForEach(shown) { a in
                    AgentRowView(agent: a, isNew: store.unseenFailures.contains { $0.id == a.id }, now: store.now)
                }
            } header: { SectionHeader(title: title, count: shown.count) }
        }
    }

    @ViewBuilder private var prSection: some View {
        let shown = store.prs.filter { matches($0.title) || matches("#\($0.number)") || matches($0.headRefName ?? "") }
        Section {
            if let e = store.prError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
            } else if shown.isEmpty {
                Text(query.isEmpty ? "No open PRs" : "No matches").foregroundStyle(.secondary).font(.callout).padding(.vertical, 4)
            }
            ForEach(shown) { p in PRRowView(pr: p, now: store.now) }
        } header: { SectionHeader(title: "Open PRs · slop-stream-architecture", count: shown.count) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Mark failures seen") { store.markFailuresSeen() }.disabled(store.failed.isEmpty)
            Link("cursor.com/agents", destination: URL(string: "https://cursor.com/agents")!)
            Link("PRs", destination: URL(string: "https://github.com/\(ghRepo)/pulls")!)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.borderless).font(.callout)
    }

    private func title(_ f: Filter) -> String {
        switch f {
        case .all: return "All"
        case .running: return "Running \(store.running.count)"
        case .failed: return "Failed \(store.failed.count)"
        case .done: return "Done"
        case .prs: return "PRs \(store.prs.count)"
        }
    }
}

struct SectionHeader: View {
    let title: String; let count: Int
    var body: some View {
        HStack {
            Text("\(title) (\(count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 4).padding(.top, 4)
        .background(.regularMaterial)
    }
}

struct AgentRowView: View {
    let agent: AgentRow
    let isNew: Bool
    let now: Date
    @State private var hover = false

    private var detail: String {
        var parts = [agent.runState.label]
        if agent.isRunning {
            parts.append("started \(Fmt.age(agent.createdAt, now: now)) ago")
        } else {
            if let d = Fmt.duration(ms: agent.durationMs) { parts.append(agent.runState == .error ? "failed after \(d)" : "took \(d)") }
            parts.append("\(Fmt.age(agent.endedAt, now: now)) ago")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(agent.runState.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(isNew ? Color.red : Color.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(Array(agent.prURLs.enumerated()), id: \.offset) { i, u in
                Button(agent.prURLs.count > 1 ? "PR \(i + 1)" : "PR") { NSWorkspace.shared.open(u) }
                    .controlSize(.small).help(u.absoluteString)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.open(agent.url) }
        .help("Open on cursor.com")
    }
}

struct PRRowView: View {
    let pr: PullRequest
    let now: Date
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("⎇").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(pr.number) \(pr.title)").lineLimit(1)
                Text([pr.isDraft == true ? "draft" : nil, pr.headRefName, "\(Fmt.age(pr.created, now: now)) old"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } }
    }
}
