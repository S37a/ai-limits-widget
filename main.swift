import Cocoa
import SwiftUI
import Foundation
import WebKit
import SQLite3

// MARK: - Data models

struct ProviderRow: Identifiable {
    let id: String
    let name: String
    let type: String          // "oauth" | "api" | "wellknown" | "env"
    let label: String         // account label from OpenRouter, or "—"
    let models: [ModelUsage]
    let limit: String         // "—" if unknown
    let remaining: String
    let usageToday: String
    let usageWeek: String
    let usageMonth: String
    let resetAt: String       // human readable "—" or "3h 12m"
    let resetProgress: Double // 0.0..1.0 for the bar
}

struct ModelUsage: Identifiable {
    let id: String            // "provider/model"
    let modelID: String
    let providerID: String
    let messages: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cost: Double
    let lastUsed: Date?
}

// MARK: - AppState

final class AppState: ObservableObject {
    @Published var rows: [ProviderRow] = []
    @Published var lastUpdated: Date = Date()
    @Published var lastError: String?
    @Published var isRefreshing: Bool = false

    private let authURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")
    private let dbURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/opencode.db")

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        await MainActor.run {
            self.isRefreshing = true
            self.lastError = nil
        }
        do {
            let auth = try readAuth()
            var rows: [ProviderRow] = []
            for (providerID, authEntry) in auth {
                let row = try await buildRow(providerID: providerID, authEntry: authEntry)
                rows.append(row)
            }
            // stable order: anthropic, openai, openrouter, google, ollama-cloud, then rest
            let order = ["anthropic", "openai", "openrouter", "google", "ollama-cloud"]
            rows.sort { a, b in
                let ai = order.firstIndex(of: a.id) ?? Int.max
                let bi = order.firstIndex(of: b.id) ?? Int.max
                if ai != bi { return ai < bi }
                return a.id < b.id
            }
            await MainActor.run {
                self.rows = rows
                self.lastUpdated = Date()
                self.isRefreshing = false
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isRefreshing = false
            }
        }
    }

    // MARK: auth.json

    private struct AuthEntry: Decodable {
        let type: String
        let key: String?
        let refresh: String?
        let access: String?
        let expires: Double?
    }

    private func readAuth() throws -> [String: AuthEntry] {
        let data = try Data(contentsOf: authURL)
        let decoded = try JSONDecoder().decode([String: AuthEntry].self, from: data)
        return decoded
    }

    // MARK: build one row per provider

    private func buildRow(providerID: String, authEntry: AuthEntry) async throws -> ProviderRow {
        let models = try queryModelsFromDB(providerID: providerID)
        let displayName = prettyName(providerID)

        // OpenRouter: hit the real API
        if providerID == "openrouter", let key = authEntry.key {
            return try await openRouterRow(providerID: providerID, key: key, models: models, displayName: displayName)
        }
        // Google: no public quota API for AI Studio keys; show local usage only
        // Ollama Cloud: no public quota API; show local usage only
        // Anthropic / OpenAI: oauth, no quota API; show local usage only
        return localOnlyRow(providerID: providerID, type: authEntry.type, models: models, displayName: displayName)
    }

    private func localOnlyRow(providerID: String, type: String, models: [ModelUsage], displayName: String) -> ProviderRow {
        let (today, week, month) = aggregateWindows(models: models)
        return ProviderRow(
            id: providerID,
            name: displayName,
            type: type,
            label: "—",
            models: models,
            limit: "—",
            remaining: "—",
            usageToday: today,
            usageWeek: week,
            usageMonth: month,
            resetAt: "no public limit",
            resetProgress: 0
        )
    }

    // MARK: OpenRouter API

    private struct ORKeyResponse: Decodable {
        let data: ORKeyData
    }
    private struct ORKeyData: Decodable {
        let label: String?
        let usage: Double?
        let usageDaily: Double?
        let usageWeekly: Double?
        let usageMonthly: Double?
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: Double? // ms epoch
        let isFreeTier: Bool?
        enum CodingKeys: String, CodingKey {
            case label, usage, limit
            case usageDaily = "usage_daily"
            case usageWeekly = "usage_weekly"
            case usageMonthly = "usage_monthly"
            case limitRemaining = "limit_remaining"
            case limitReset = "limit_reset"
            case isFreeTier = "is_free_tier"
        }
    }
    private struct ORCreditsResponse: Decodable {
        let data: ORCreditsData
    }
    private struct ORCreditsData: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?
        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }
    }

    private func openRouterRow(providerID: String, key: String, models: [ModelUsage], displayName: String) async throws -> ProviderRow {
        var keyData: ORKeyData?
        var credits: ORCreditsData?
        do {
            keyData = try await getJSON(url: "https://openrouter.ai/api/v1/key", headers: ["Authorization": "Bearer \(key)"])
        } catch {
            // fall through — we still show local usage
        }
        do {
            credits = try await getJSON(url: "https://openrouter.ai/api/v1/credits", headers: ["Authorization": "Bearer \(key)"])
        } catch {
            // ignore
        }

        let (today, week, month) = aggregateWindows(models: models)
        let limit: String
        let remaining: String
        let resetAt: String
        let resetProgress: Double

        if let kd = keyData, let lim = kd.limit, lim > 0 {
            let rem = kd.limitRemaining ?? (lim - (kd.usage ?? 0))
            limit = "$\(fmt(lim))"
            remaining = "$\(fmt(rem))"
            if let reset = kd.limitReset, reset > 0 {
                let secs = (reset / 1000) - Date().timeIntervalSince1970
                resetAt = secs > 0 ? humanDuration(secs: secs) : "—"
                resetProgress = 1 - min(max(rem / lim, 0), 1)
            } else {
                resetAt = "no reset"
                resetProgress = lim > 0 ? 1 - min(max(rem / lim, 0), 1) : 0
            }
        } else if let c = credits, let total = c.totalCredits, total > 0 {
            let used = c.totalUsage ?? 0
            limit = "$\(fmt(total))"
            remaining = "$\(fmt(max(total - used, 0)))"
            resetAt = "credits"
            resetProgress = total > 0 ? min(used / total, 1) : 0
        } else if let kd = keyData, (kd.isFreeTier ?? false) {
            limit = "free tier"
            remaining = "—"
            resetAt = "—"
            resetProgress = 0
        } else {
            limit = "—"
            remaining = "—"
            resetAt = "—"
            resetProgress = 0
        }

        return ProviderRow(
            id: providerID,
            name: displayName,
            type: "api",
            label: keyData?.label ?? "—",
            models: models,
            limit: limit,
            remaining: remaining,
            usageToday: today,
            usageWeek: week,
            usageMonth: month,
            resetAt: resetAt,
            resetProgress: resetProgress
        )
    }

    private func getJSON<T: Decodable>(url: String, headers: [String: String]) async throws -> T {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.timeoutInterval = 12
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: opencode SQLite

    private func queryModelsFromDB(providerID: String) throws -> [ModelUsage] {
        // model column is JSON like {"id":"glm-5.2","providerID":"ollama-cloud","variant":"max"}
        // session table has aggregated columns tokens_input/output/cache_read and cost
        let since = Int(Date().addingTimeInterval(-30*24*60*60).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT
            json_extract(model,'$.id') AS mid,
            json_extract(model,'$.providerID') AS pid,
            count(*) AS n,
            sum(tokens_input) AS ti,
            sum(tokens_output) AS to,
            sum(tokens_cache_read) AS cr,
            sum(cost) AS c,
            max(time_created) AS last
        FROM session
        WHERE json_extract(model,'$.providerID') = ?
          AND time_created >= ?
        GROUP BY mid
        ORDER BY ti DESC
        LIMIT 8
        """
        var stmt: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &stmt, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open db"])
        }
        defer { sqlite3_close_v2(stmt) }

        var s: OpaquePointer?
        guard sqlite3_prepare_v2(stmt, sql, -1, &s, nil) == SQLITE_OK else {
            throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot prepare: \(String(cString: sqlite3_errmsg(stmt)))"])
        }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_text(s, 1, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(s, 2, Int64(since))

        var rows: [ModelUsage] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let mid = String(cString: sqlite3_column_text(s, 0))
            let pid = String(cString: sqlite3_column_text(s, 1))
            let n = Int(sqlite3_column_int64(s, 2))
            let ti = Int(sqlite3_column_int64(s, 3))
            let to = Int(sqlite3_column_int64(s, 4))
            let cr = Int(sqlite3_column_int64(s, 5))
            let c = sqlite3_column_double(s, 6)
            let lastMs = sqlite3_column_int64(s, 7)
            let last = lastMs > 0 ? Date(timeIntervalSince1970: TimeInterval(lastMs)/1000) : nil
            rows.append(ModelUsage(
                id: "\(pid)/\(mid)",
                modelID: mid,
                providerID: pid,
                messages: n,
                inputTokens: ti,
                outputTokens: to,
                cacheRead: cr,
                cost: c,
                lastUsed: last
            ))
        }
        return rows
    }

    // MARK: aggregation helpers

    private func aggregateWindows(models: [ModelUsage]) -> (String, String, String) {
        let now = Date()
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now).timeIntervalSince1970 * 1000
        let weekStart = (now.addingTimeInterval(-7*24*60*60)).timeIntervalSince1970 * 1000
        let monthStart = (now.addingTimeInterval(-30*24*60*60)).timeIntervalSince1970 * 1000

        func sumSince(_ sinceMs: Double) -> Int {
            models.reduce(0) { acc, m in
                guard let last = m.lastUsed else { return acc }
                if last.timeIntervalSince1970 * 1000 >= sinceMs {
                    return acc + m.inputTokens + m.outputTokens + m.cacheRead
                }
                return acc
            }
        }
        let today = sumSince(dayStart)
        let week = sumSince(weekStart)
        let month = sumSince(monthStart)
        return (fmtTokens(today), fmtTokens(week), fmtTokens(month))
    }

    // MARK: pretty

    private func prettyName(_ id: String) -> String {
        switch id {
        case "anthropic":   return "Anthropic"
        case "openai":       return "OpenAI"
        case "openrouter":   return "OpenRouter"
        case "google":       return "Google"
        case "ollama-cloud": return "Ollama Cloud"
        default:             return id.capitalized
        }
    }
    private func fmt(_ v: Double) -> String {
        if v >= 1 { return String(format: "%.2f", v) }
        return String(format: "%.4f", v)
    }
    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }
    private func humanDuration(secs: TimeInterval) -> String {
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - SwiftUI popover content

struct PopoverRoot: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.secondary.opacity(0.3))
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(state.rows) { row in
                        ProviderCard(row: row)
                    }
                    if let err = state.lastError {
                        Text(err).font(.caption).foregroundStyle(.red).padding(8)
                    }
                }
                .padding(10)
            }
            footer
        }
        .frame(width: 420, height: 540)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Limits").font(.headline)
                Text("Updated \(state.lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await state.refresh() }
            } label: {
                Image(systemName: state.isRefreshing ? "arrow.clockwise.circle" : "arrow.clockwise")
                    .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                    .animation(state.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: state.isRefreshing)
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text("\(state.rows.count) providers")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption).buttonStyle(.borderless)
        }
        .padding(8)
        .background(.regularMaterial)
    }
}

struct ProviderCard: View {
    let row: ProviderRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.system(size: 13, weight: .semibold))
                    Text("\(row.type) · \(row.label)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("limit: \(row.limit)").font(.caption2).foregroundStyle(.secondary)
                    Text("remaining: \(row.remaining)").font(.caption2).foregroundStyle(row.remaining.contains("$") ? .green : .secondary)
                }
            }

            if row.resetProgress > 0 {
                ProgressView(value: row.resetProgress)
                    .tint(row.resetProgress > 0.8 ? .red : .accentColor)
                    .scaleEffect(y: 0.6)
                HStack {
                    Text("used \(Int(row.resetProgress*100))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("reset: \(row.resetAt)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label("\(row.usageToday)", systemImage: "calendar")
                    .labelStyle(.titleAndIcon).font(.caption2)
                Label("\(row.usageWeek)", systemImage: "clock")
                    .labelStyle(.titleAndIcon).font(.caption2)
                Label("\(row.usageMonth)", systemImage: "chart.bar")
                    .labelStyle(.titleAndIcon).font(.caption2)
                Spacer()
                Text("tokens 1d/7d/30d").font(.system(size: 9)).foregroundStyle(.secondary)
            }

            if !row.models.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(row.models.prefix(4)) { m in
                        HStack {
                            Text(m.modelID)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(fmtT(m.inputTokens)) in · \(fmtT(m.outputTokens)) out · \(fmtT(m.cacheRead)) cache")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let last = m.lastUsed {
                            Text("last: \(last.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if row.models.count > 4 {
                        Text("+ \(row.models.count - 4) more")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func fmtT(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()
    private var popover: NSPopover!
    private var refreshTimer: Timer?
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "AI limits")
            button.image?.size = NSSize(width: 16, height: 16)
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverRoot(state: state))
        popover.contentSize = NSSize(width: 420, height: 540)

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.state.refresh() }
        }

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.popover.isShown { self.popover.performClose(nil) }
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                Task { await state.refresh() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()