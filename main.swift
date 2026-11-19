// GH Actions Bar — a macOS menu bar dropdown showing GitHub Actions status
// across every repo you own, collaborate on, or can see through your orgs.
// Auth comes from the `gh` CLI (`gh auth login`), so no tokens live here.
//
// Settings (optional):
//   defaults write com.drfarr.ghactionsbar days 14      # only repos pushed in the last N days
//   defaults write com.drfarr.ghactionsbar maxRepos 40  # cap on repos polled

import Cocoa

// MARK: - Model

struct Run: Decodable {
    let id: Int
    let name: String?
    let display_title: String?
    let head_branch: String?
    let event: String?
    let status: String          // queued, in_progress, completed, waiting, requested, pending
    let conclusion: String?     // success, failure, cancelled, skipped, timed_out, action_required, neutral
    let html_url: String
    let updated_at: String

    var isActive: Bool { status != "completed" }
    var updated: Date { ISO8601DateFormatter().date(from: updated_at) ?? .distantPast }

    var state: State {
        if isActive { return status == "in_progress" ? .running : .queued }
        switch conclusion {
        case "success": return .success
        case "failure", "timed_out", "startup_failure": return .failure
        case "action_required": return .attention
        default: return .neutral
        }
    }
}

struct RunsResponse: Decodable { let workflow_runs: [Run] }

enum State: Int, Comparable {
    case neutral, success, queued, running, attention, failure
    static func < (a: State, b: State) -> Bool { a.rawValue < b.rawValue }
    var dot: String {
        switch self {
        case .success: "🟢"
        case .failure: "🔴"
        case .running: "🟡"
        case .queued: "⏳"
        case .attention: "🟠"
        case .neutral: "⚪️"
        }
    }
}

struct RepoStatus {
    let name: String
    let runs: [Run]   // newest first, one per (workflow, branch)

    var latest: Date { runs.first?.updated ?? .distantPast }
    var running: Int { runs.filter(\.isActive).count }
    /// Running beats everything; otherwise the newest finished run decides.
    var state: State {
        if runs.contains(where: { $0.isActive }) { return .running }
        return runs.first?.state ?? .neutral
    }
}

// MARK: - GitHub via gh CLI

struct GHError: Error { let message: String }

enum GH {
    static let path: String = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"

    static func api(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = (path == "/usr/bin/env" ? ["gh"] : []) + ["api"] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw GHError(message: String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Repos you own, collaborate on, or reach through org membership, most recently pushed first.
    static func activeRepos(days: Int, max: Int) throws -> [String] {
        let data = try api([
            "--paginate",
            "/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member",
            "--jq", ".[] | select(.archived | not) | [.full_name, .pushed_at] | @tsv",
        ])
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let iso = ISO8601DateFormatter()
        var seen = Set<String>()
        let rows: [(String, Date)] = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count == 2, let d = iso.date(from: parts[1]), d >= cutoff,
                      seen.insert(parts[0]).inserted else { return nil }
                return (parts[0], d)
            }
        return rows.sorted { $0.1 > $1.1 }.prefix(max).map(\.0)
    }

    static func status(of repo: String) -> RepoStatus? {
        guard let data = try? api(["/repos/\(repo)/actions/runs?per_page=30"]),
              let resp = try? JSONDecoder().decode(RunsResponse.self, from: data),
              !resp.workflow_runs.isEmpty else { return nil }
        var seen = Set<String>()
        let runs = resp.workflow_runs
            .sorted { $0.updated > $1.updated }
            .filter { seen.insert("\($0.name ?? "")|\($0.head_branch ?? "")").inserted }
        return RepoStatus(name: repo, runs: Array(runs.prefix(10)))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var repos: [RepoStatus] = []
    private var repoNames: [String] = []
    private var repoNamesFetched = Date.distantPast
    private var lastError: String?
    private var lastUpdated: Date?
    private var loading = false

    private let defaults = UserDefaults.standard
    private var days: Int { let v = defaults.integer(forKey: "days"); return v > 0 ? v : 14 }
    private var maxRepos: Int { let v = defaults.integer(forKey: "maxRepos"); return v > 0 ? v : 40 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.neutral, running: 0)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
    }

    // Rebuild each time it opens so relative times stay fresh.
    func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }

    @objc func refresh() {
        guard !loading else { return }
        loading = true
        let needRepoList = Date().timeIntervalSince(repoNamesFetched) > 600 || repoNames.isEmpty
        let cachedNames = repoNames
        let days = self.days, maxRepos = self.maxRepos

        DispatchQueue.global(qos: .utility).async {
            do {
                let names = needRepoList ? try GH.activeRepos(days: days, max: maxRepos) : cachedNames
                var results = [RepoStatus?](repeating: nil, count: names.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: names.count) { i in
                    let s = GH.status(of: names[i])
                    lock.lock(); results[i] = s; lock.unlock()
                }
                let statuses = results.compactMap { $0 }.sorted { $0.latest > $1.latest }
                DispatchQueue.main.async {
                    if needRepoList { self.repoNames = names; self.repoNamesFetched = Date() }
                    self.finish(statuses, error: nil)
                }
            } catch {
                let msg = (error as? GHError)?.message ?? error.localizedDescription
                DispatchQueue.main.async { self.finish(self.repos, error: msg) }
            }
        }
    }

    private func finish(_ statuses: [RepoStatus], error: String?) {
        loading = false
        repos = statuses
        lastError = error
        if error == nil { lastUpdated = Date() }

        let running = repos.reduce(0) { $0 + $1.running }
        let worst = error != nil ? .attention : (repos.map(\.state).max() ?? .neutral)
        setIcon(running > 0 ? .running : worst, running: running)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: running > 0 ? 15 : 60, repeats: false) { [weak self] _ in
            self?.refresh()
        }
    }

    private func setIcon(_ state: State, running: Int) {
        let color: NSColor = switch state {
        case .success: .systemGreen
        case .failure: .systemRed
        case .running, .queued: .systemYellow
        case .attention: .systemOrange
        case .neutral: .secondaryLabelColor
        }
        let title = NSMutableAttributedString(string: "●", attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 13),
        ])
        if running > 0 {
            title.append(NSAttributedString(string: " \(running)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ]))
        }
        item.button?.attributedTitle = title
        item.button?.toolTip = "GitHub Actions"
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated

        if let err = lastError {
            let e = NSMenuItem(title: "⚠️ \(err.prefix(80))", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
            menu.addItem(.separator())
        }

        if repos.isEmpty {
            let empty = NSMenuItem(title: loading ? "Loading…" : "No workflow runs in the last \(days) days",
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        // Anything needing attention floats to the top.
        let ordered = repos.filter { $0.state >= .running } + repos.filter { $0.state < .running }
        for repo in ordered {
            let when = rel.localizedString(for: repo.latest, relativeTo: Date())
            let top = NSMenuItem(title: "\(repo.state.dot)  \(repo.name)  ·  \(when)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(link("Open Actions ↗", "https://github.com/\(repo.name)/actions"))
            sub.addItem(.separator())
            for run in repo.runs {
                let ago = rel.localizedString(for: run.updated, relativeTo: Date())
                let branch = run.head_branch.map { " · \($0)" } ?? ""
                let title = "\(run.state.dot)  \(run.name ?? "workflow")\(branch)  ·  \(ago)"
                let mi = link(title, run.html_url)
                mi.toolTip = run.display_title
                sub.addItem(mi)
            }
            top.submenu = sub
            menu.addItem(top)
        }

        menu.addItem(.separator())
        let updated = lastUpdated.map { "Updated \(rel.localizedString(for: $0, relativeTo: Date()))" } ?? "Not updated yet"
        let info = NSMenuItem(title: loading ? "Refreshing…" : updated, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        let r = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func refreshNow() {
        repoNamesFetched = .distantPast   // also pick up newly active repos
        refresh()
    }

    private func link(_ title: String, _ url: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = url
        return mi
    }

    @objc private func open(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
