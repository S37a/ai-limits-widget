import Foundation
import SQLite3

// MARK: - Data models

struct ModelUsage {
    let modelID: String
    let providerID: String
    let messages: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheRead: Int
    let cost: Double
    let lastUsed: Date?
}

struct ProviderRow {
    let id: String
    let name: String
    let type: String
    let label: String
    let models: [ModelUsage]
    let limit: String
    let remaining: String
    let resetAt: String
    let resetProgress: Double
    let usageToday: String
    let usageWeek: String
    let usageMonth: String
}

// MARK: - State

final class Limits {
    private let authURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")
    private let dbURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/opencode.db")

    func fetch() -> [ProviderRow] {
        guard let auth = try? readAuth() else { return [] }
        var rows: [ProviderRow] = []
        for (providerID, entry) in auth {
            rows.append(buildRow(providerID: providerID, authEntry: entry))
        }
        let order = ["anthropic", "openai", "openrouter", "google", "ollama-cloud"]
        rows.sort { a, b in
            let ai = order.firstIndex(of: a.id) ?? Int.max
            let bi = order.firstIndex(of: b.id) ?? Int.max
            if ai != bi { return ai < bi }
            return a.id < b.id
        }
        return rows
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
        return try JSONDecoder().decode([String: AuthEntry].self, from: data)
    }

    // MARK: build row

    private func buildRow(providerID: String, authEntry: AuthEntry) -> ProviderRow {
        let models = (try? queryModelsFromDB(providerID: providerID)) ?? []
        let name = prettyName(providerID)

        if providerID == "openrouter", let key = authEntry.key {
            return openRouterRow(providerID: providerID, key: key, models: models, name: name, type: authEntry.type)
        }
        return localOnlyRow(providerID: providerID, type: authEntry.type, models: models, name: name)
    }

    private func localOnlyRow(providerID: String, type: String, models: [ModelUsage], name: String) -> ProviderRow {
        let (today, week, month) = aggregateWindows(models: models)
        // rolling 5h window like Claude Code / ChatGPT Plus
        let windowSec = 5.0 * 3600
        let windowStart = Date().addingTimeInterval(-windowSec)
        let windowTokens = queryWindowTokens(providerID: providerID, since: windowStart)
        let lastUsed = models.compactMap { $0.lastUsed }.max()

        let limit: String
        let remaining: String
        let resetAt: String
        let progress: Double

        if windowTokens > 0 {
            // active window: show how much of the 5h window is consumed
            let windowEnd = windowStart.addingTimeInterval(windowSec)
            let secsToReset = windowEnd.timeIntervalSinceNow
            let pctWindow = max(0, min(1, 1 - secsToReset / windowSec))
            limit = "5h window"
            remaining = "\(fmtTokens(windowTokens)) in window"
            resetAt = secsToReset > 0 ? "reset in \(humanDuration(secs: secsToReset))" : "window expired"
            // if window already expired, show 0 (will reset on next message)
            progress = secsToReset > 0 ? pctWindow : 0
        } else if let last = lastUsed {
            // idle: show how long ago last use was
            let ago = Date().timeIntervalSince(last)
            limit = "5h window"
            remaining = "idle"
            resetAt = ago < windowSec ? "window resets in \(humanDuration(secs: windowSec - ago))" : "no recent use"
            progress = 0
        } else {
            limit = "5h window"
            remaining = "no usage"
            resetAt = "—"
            progress = 0
        }
        return ProviderRow(
            id: providerID, name: name, type: type, label: "—",
            models: models,
            limit: limit, remaining: remaining, resetAt: resetAt, resetProgress: progress,
            usageToday: today, usageWeek: week, usageMonth: month
        )
    }

    // MARK: OpenRouter API (synchronous for console)

    private struct ORKeyResponse: Decodable { let data: ORKeyData }
    private struct ORKeyData: Decodable {
        let label: String?
        let usage: Double?
        let usageDaily: Double?
        let usageWeekly: Double?
        let usageMonthly: Double?
        let limit: Double?
        let limitRemaining: Double?
        let limitReset: Double?
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
    private struct ORCreditsResponse: Decodable { let data: ORCreditsData }
    private struct ORCreditsData: Decodable {
        let totalCredits: Double?
        let totalUsage: Double?
        enum CodingKeys: String, CodingKey {
            case totalCredits = "total_credits"
            case totalUsage = "total_usage"
        }
    }

    private func syncFetch(url: URL, headers: [String: String]) -> Data? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            result = data
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    private func openRouterRow(providerID: String, key: String, models: [ModelUsage], name: String, type: String) -> ProviderRow {
        var keyData: ORKeyData?
        var credits: ORCreditsData?

        if let url = URL(string: "https://openrouter.ai/api/v1/key") {
            if let data = syncFetch(url: url, headers: ["Authorization": "Bearer \(key)"]),
               let decoded = try? JSONDecoder().decode(ORKeyResponse.self, from: data) {
                keyData = decoded.data
            }
        }
        if let url = URL(string: "https://openrouter.ai/api/v1/credits") {
            if let data = syncFetch(url: url, headers: ["Authorization": "Bearer \(key)"]),
               let decoded = try? JSONDecoder().decode(ORCreditsResponse.self, from: data) {
                credits = decoded.data
            }
        }

        let (today, week, month) = aggregateWindows(models: models)
        var limit = "—", remaining = "—", resetAt = "—", progress: Double = 0

        if let kd = keyData, let lim = kd.limit, lim > 0 {
            let rem = kd.limitRemaining ?? (lim - (kd.usage ?? 0))
            limit = "$\(fmt(lim))"
            remaining = "$\(fmt(rem))"
            if let reset = kd.limitReset, reset > 0 {
                let secs = (reset / 1000) - Date().timeIntervalSince1970
                resetAt = secs > 0 ? humanDuration(secs: secs) : "—"
                progress = lim > 0 ? 1 - min(max(rem / lim, 0), 1) : 0
            } else {
                resetAt = "no reset"
                progress = lim > 0 ? 1 - min(max(rem / lim, 0), 1) : 0
            }
        } else if let c = credits, let total = c.totalCredits, total > 0 {
            let used = c.totalUsage ?? 0
            limit = "$\(fmt(total))"
            remaining = "$\(fmt(max(total - used, 0)))"
            resetAt = "credits"
            progress = min(used / total, 1)
        } else if let kd = keyData, (kd.isFreeTier ?? false) {
            limit = "free tier"
        }

        return ProviderRow(
            id: providerID, name: name, type: type, label: keyData?.label ?? "—",
            models: models,
            limit: limit, remaining: remaining, resetAt: resetAt, resetProgress: progress,
            usageToday: today, usageWeek: week, usageMonth: month
        )
    }

    // MARK: rolling window token count

    private func queryWindowTokens(providerID: String, since: Date) -> Int {
        let sinceMs = Int(since.timeIntervalSince1970 * 1000)
        let sql = """
        SELECT
            coalesce(sum(json_extract(data,'$.tokens.input')),0)
          + coalesce(sum(json_extract(data,'$.tokens.output')),0)
          + coalesce(sum(json_extract(data,'$.tokens.cache.read')),0) AS total
        FROM message
        WHERE json_extract(data,'$.role')='assistant'
          AND json_extract(data,'$.providerID')=?
          AND json_extract(data,'$.time.created') >= ?
        """
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(sinceMs))
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    // MARK: SQLite

    private func queryModelsFromDB(providerID: String) throws -> [ModelUsage] {
        let since = Int(Date().addingTimeInterval(-30*24*60*60).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT json_extract(model,'$.id'), json_extract(model,'$.providerID'),
               count(*), sum(tokens_input), sum(tokens_output),
               sum(tokens_cache_read), sum(cost), max(time_created)
        FROM session
        WHERE json_extract(model,'$.providerID') = ? AND time_created >= ?
        GROUP BY json_extract(model,'$.id')
        ORDER BY sum(tokens_input) DESC LIMIT 8
        """
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close_v2(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, providerID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(since))

        var rows: [ModelUsage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mid = String(cString: sqlite3_column_text(stmt, 0))
            let pid = String(cString: sqlite3_column_text(stmt, 1))
            let n = Int(sqlite3_column_int64(stmt, 2))
            let ti = Int(sqlite3_column_int64(stmt, 3))
            let to = Int(sqlite3_column_int64(stmt, 4))
            let cr = Int(sqlite3_column_int64(stmt, 5))
            let c = sqlite3_column_double(stmt, 6)
            let lastMs = sqlite3_column_int64(stmt, 7)
            let last = lastMs > 0 ? Date(timeIntervalSince1970: TimeInterval(lastMs)/1000) : nil
            rows.append(ModelUsage(modelID: mid, providerID: pid, messages: n,
                                   inputTokens: ti, outputTokens: to,
                                   cacheRead: cr, cost: c, lastUsed: last))
        }
        return rows
    }

    // MARK: helpers

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
        return (fmtTokens(sumSince(dayStart)), fmtTokens(sumSince(weekStart)), fmtTokens(sumSince(monthStart)))
    }

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
        v >= 1 ? String(format: "%.2f", v) : String(format: "%.4f", v)
    }
    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }
    private func humanDuration(secs: TimeInterval) -> String {
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - ANSI helpers

enum A {
    static let clear = "\u{1B}[2J\u{1B}[H"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let red = "\u{1B}[31m"
    static let cyan = "\u{1B}[36m"
    static let magenta = "\u{1B}[35m"
    static func cursor(_ row: Int, _ col: Int) -> String { "\u{1B}[\(row);\(col)H" }
}

// MARK: - Render

func bar(_ progress: Double, width: Int = 20) -> String {
    let filled = Int(progress * Double(width))
    let pct = Int(progress * 100)
    let color = progress > 0.8 ? A.red : (progress > 0.5 ? A.yellow : A.green)
    let blocks = String(repeating: "█", count: max(filled, 0))
    let empty = String(repeating: "░", count: max(width - filled, 0))
    return "\(color)\(blocks)\(empty)\(A.reset) \(pct)%"
}

func render(rows: [ProviderRow], updated: Date, refreshing: Bool) {
    var out = A.clear
    out += "\(A.bold)╔════════════════════════════════════════════════════════════╗\(A.reset)\n"
    out += "\(A.bold)║\(A.reset) \(A.cyan)\(A.bold)AI LIMITS\(A.reset)\(A.dim) — opencode providers\(A.reset)"
    let headerRight = refreshing ? "\(A.dim)refreshing…\(A.reset)" : "updated \(updated.formatted(date: .omitted, time: .shortened))"
    let pad = String(repeating: " ", count: max(0, 60 - 23 - headerRight.count))
    out += "\(pad)\(headerRight) \(A.bold)║\(A.reset)\n"
    out += "\(A.bold)╚════════════════════════════════════════════════════════════╝\(A.reset)\n\n"

    if rows.isEmpty {
        out += "\(A.dim)  No providers found. Configure opencode first: \(A.reset)\(A.cyan)opencode providers login\(A.reset)\n\n"
    }

    for row in rows {
        // header line
        let dot = row.resetProgress > 0.8 ? "\(A.red)●\(A.reset)" :
                  row.resetProgress > 0.5 ? "\(A.yellow)●\(A.reset)" :
                  "\(A.green)●\(A.reset)"
        out += "  \(dot) \(A.bold)\(row.name)\(A.reset) \(A.dim)[\(row.type)]\(A.reset)"
        if row.label != "—" { out += " \(A.dim)· \(row.label)\(A.reset)" }
        out += "\n"

        // limits line
        out += "      limit:      \(A.bold)\(row.limit)\(A.reset)"
        out += "    remaining: \(A.green)\(row.remaining)\(A.reset)"
        out += "    reset: \(A.magenta)\(row.resetAt)\(A.reset)\n"

        // progress bar
        if row.resetProgress > 0 {
            out += "      \(bar(row.resetProgress))\n"
        }

        // usage line
        out += "      usage 1d: \(A.cyan)\(row.usageToday)\(A.reset)"
        out += "  7d: \(A.cyan)\(row.usageWeek)\(A.reset)"
        out += "  30d: \(A.cyan)\(row.usageMonth)\(A.reset) tokens\n"

        // models
        if !row.models.isEmpty {
            out += "      \(A.dim)models: \(A.reset)\n"
            for m in row.models.prefix(5) {
                let last = m.lastUsed != nil ? " · \(m.lastUsed!.formatted(.relative(presentation: .named)))" : ""
                out += "        \(A.magenta)\(m.modelID)\(A.reset)\n"
                out += "          \(A.dim)\(fmtT(m.inputTokens)) in · \(fmtT(m.outputTokens)) out · \(fmtT(m.cacheRead)) cache · \(m.messages) msgs\(last)\(A.reset)\n"
            }
            if row.models.count > 5 {
                out += "        \(A.dim)+ \(row.models.count - 5) more\(A.reset)\n"
            }
        }
        out += "\n"
    }

    out += "\(A.dim)  ── q: quit · r: refresh · auto-refresh 60s ──\(A.reset)\n"
    FileHandle.standardOutput.write(Data(out.utf8))
}

func fmtT(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n)/1_000) }
    return "\(n)"
}

// MARK: - Main loop

var keepRunning = true
signal(SIGINT) { _ in keepRunning = false }
setbuf(stdout, nil)

let limits = Limits()
let lock = NSLock()
var lastRows: [ProviderRow] = []
var lastUpdated = Date()

func doFetch() {
    lock.lock()
    defer { lock.unlock() }
    lastRows = limits.fetch()
    lastUpdated = Date()
    render(rows: lastRows, updated: lastUpdated, refreshing: false)
}

// initial fetch
doFetch()

// background timer
let queue = DispatchQueue.global(qos: .utility)
let timer = DispatchSource.makeTimerSource(queue: queue)
timer.schedule(deadline: .now() + 60, repeating: 60)
timer.setEventHandler {
    lock.lock()
    let refreshing = true
    let rows = lastRows
    let updated = lastUpdated
    lock.unlock()
    render(rows: rows, updated: updated, refreshing: refreshing)
    doFetch()
}
timer.resume()

// input loop (q to quit, r to refresh)
DispatchQueue.global(qos: .userInteractive).async {
    while keepRunning {
        if let c = readByte() {
            if c == 113 || c == 81 { // q, Q
                keepRunning = false
                break
            } else if c == 114 || c == 82 { // r, R
                DispatchQueue.global().async { doFetch() }
            }
        }
    }
}

while keepRunning {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
}

timer.cancel()
print("\n\(A.dim)Bye.\(A.reset)")

// MARK: - readByte (poll stdin)

func readByte() -> UInt8? {
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&pfd, 1, 200) // 200ms timeout
    if ready > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        var buf: UInt8 = 0
        let n = read(STDIN_FILENO, &buf, 1)
        return n > 0 ? buf : nil
    }
    return nil
}