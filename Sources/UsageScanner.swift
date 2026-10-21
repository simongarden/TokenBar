import Foundation

/// Scans local log files read-only. Never writes to source files.
actor UsageScanner {
    private struct ClaudeMessageKey: Hashable {
        let messageID: String
        let requestID: String
    }
    private struct ClaudeRecord {
        let date: Date
        let tokens: TokenBreakdown
        let sidechain: Bool
    }
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }
    private struct FileState {
        var offset: UInt64 = 0
        var mtime: Date?
        var size: UInt64 = 0
        var identity: FileIdentity?
        var claudeMessages: [ClaudeMessageKey: ClaudeRecord] = [:]
        var claudeUnkeyed: [ClaudeRecord] = []
        var grokTurns: [String: ClaudeRecord] = [:]   // _meta.eventId → completed turn
        var grokUnkeyed: [ClaudeRecord] = []
        var days: [DayKey: TokenBreakdown] = [:]
        var lastCodexTotal = -1
        var recent: [(Date, TokenBreakdown)] = []
        var latestRate: (Date, RateInfo)?
        var latestPlan: (Date, String)?
    }

    private var states: [Service: [String: FileState]] = [:]
    private let fm = FileManager.default
    private let home: URL
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()
    /// Grok Build CLI data home: `GROK_HOME` when set, else `~/.grok`.
    let grokHome: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.grokHome = Self.grokHome(home: home, environment: environment)
    }

    static func grokHome(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appending(path: ".grok")
    }

    func scanAll(claude5hLimit: Int, enabled: Set<Service>) -> [ServiceSummary] {
        // Disabled providers are not scanned at all.
        var c = enabled.contains(.claude) ? scanClaude() : ServiceSummary(service: .claude, available: false)
        var x = enabled.contains(.codex) ? scanCodex() : ServiceSummary(service: .codex, available: false)
        let g = enabled.contains(.grok) ? scanGrok() : ServiceSummary(service: .grok, available: false)
        if enabled.contains(.claude) {
            let f = planFields(.claude)
            c.plan = PlanName.claude(organizationType: f["type"], rateLimitTier: f["tier"])
        }
        if enabled.contains(.codex) {
            // The server reports plan_type with every token_count; the id_token copy can be stale.
            let live = (states[.codex] ?? [:]).values.compactMap(\.latestPlan).max { $0.0 < $1.0 }?.1
            x.plan = PlanName.codex(live ?? planFields(.codex)["type"])
        }
        prune()
        // Claude: Claude Code-style 5h block from local jsonl (may be overridden by API resets_at later)
        if let b = claudeBlock() {
            c.periodStart = b.start
            c.periodTokens = b.tokens.total
            c.periodSource = "Claude Code 式 5 小時區塊（本機 jsonl，\(b.start.formatted(date: .omitted, time: .shortened)) 起）"
            if claude5hLimit > 0 {
                let used = b.tokens.input + b.tokens.output + b.tokens.cacheWrite
                c.rate = RateInfo(primary: .init(usedPercent: Double(used) / Double(claude5hLimit) * 100, windowMinutes: 300,
                                                 resetsAt: b.start.addingTimeInterval(5 * 3600)),
                                  isEstimate: true, source: "本機 jsonl 估算：本區塊 \(compactNumber(used)) / \(compactNumber(claude5hLimit))（不含快取讀）")
            }
        }
        // Codex: newest rate_limits across all sessions
        x.rate = (states[.codex] ?? [:]).values.compactMap(\.latestRate).max { $0.0 < $1.0 }?.1
        let now = Date()
        for w in [\RateInfo.primary, \RateInfo.secondary] {
            if let r = x.rate?[keyPath: w]?.resetsAt, r < now { x.rate![keyPath: w]!.usedPercent = 0 } // window already reset
        }
        if let p = x.rate?.primary, let r = p.resetsAt, let m = p.windowMinutes, r > now {
            let start = r.addingTimeInterval(-Double(m) * 60)
            x.periodStart = start
            x.periodTokens = windowTokens(.codex, since: start).total
            x.periodSource = "限額視窗（\(start.formatted(date: .omitted, time: .shortened)) 起）"
        }
        return [c, x, g].filter { enabled.contains($0.service) }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for svc in Service.allCases {
            for k in (states[svc] ?? [:]).keys { states[svc]![k]!.recent.removeAll { $0.0 < cutoff } }
        }
    }

    func windowTokens(_ svc: Service, since start: Date) -> TokenBreakdown {
        var t = TokenBreakdown()
        for st in (states[svc] ?? [:]).values { for (d, b) in st.recent where d >= start { t += b } }
        return t
    }

    /// Active 5h block like Claude Code / ccusage: starts at the hour floor of the first message
    /// after a 5h gap or after the previous block ended.
    private func claudeBlock() -> (start: Date, tokens: TokenBreakdown)? {
        let entries = (states[.claude] ?? [:]).values.flatMap(\.recent).sorted { $0.0 < $1.0 }
        var start: Date?, last: Date?
        let cal = Calendar.current
        for (d, _) in entries {
            if start == nil || d >= start!.addingTimeInterval(5 * 3600) || d.timeIntervalSince(last!) >= 5 * 3600 {
                start = cal.dateInterval(of: .hour, for: d)!.start
            }
            last = d
        }
        guard let start, Date() < start.addingTimeInterval(5 * 3600) else { return nil }
        return (start, windowTokens(.claude, since: start))
    }

    // MARK: - Subscription plan (read-only; only plan fields are extracted, tokens never stored or logged)

    private var planCache: [Service: (Date?, [String: String])] = [:]

    /// Claude: `~/.claude.json` oauthAccount organizationType / userRateLimitTier.
    /// Codex: `chatgpt_plan_type` from the `~/.codex/auth.json` id_token (fallback only).
    private func planFields(_ svc: Service) -> [String: String] {
        let path = home.path + (svc == .claude ? "/.claude.json" : "/.codex/auth.json")
        let m = attrs(path).mtime
        if let c = planCache[svc], c.0 == m { return c.1 }
        var fields: [String: String] = [:]
        if let data = fm.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch svc {
            case .claude:
                let oa = obj["oauthAccount"] as? [String: Any]
                fields["type"] = oa?["organizationType"] as? String
                fields["tier"] = oa?["userRateLimitTier"] as? String
            case .codex:
                if let jwt = (obj["tokens"] as? [String: Any])?["id_token"] as? String {
                    let parts = jwt.split(separator: ".")
                    if parts.count > 1 {
                        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
                        if let pd = Data(base64Encoded: b),
                           let payload = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] {
                            fields["type"] = (payload["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
                        }
                    }
                }
            case .grok: break   // plan comes from GrokUsageClient (/v1/settings)
            }
        }
        planCache[svc] = (m, fields)
        return fields
    }

    private func codexWindow(_ any: Any?) -> RateWindow? {
        guard let d = any as? [String: Any], let p = d["used_percent"] as? NSNumber else { return nil }
        let r = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateWindow(usedPercent: p.doubleValue, windowMinutes: (d["window_minutes"] as? NSNumber)?.intValue, resetsAt: r)
    }

    // MARK: - Helpers

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    private func files(under dir: URL, ext: String) -> [URL] {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where u.pathExtension == ext { out.append(u) }
        return out
    }

    private func attrs(_ path: String) -> (size: UInt64, mtime: Date?) {
        let a = try? fm.attributesOfItem(atPath: path)
        return ((a?[.size] as? NSNumber)?.uint64Value ?? 0, a?[.modificationDate] as? Date)
    }

    /// Returns only complete new lines since the cached offset.
    private func newLines(_ path: String, _ st: inout FileState) -> [Data] {
        guard let a = try? fm.attributesOfItem(atPath: path),
              let size = (a[.size] as? NSNumber)?.uint64Value,
              let inode = (a[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (a[.systemNumber] as? NSNumber)?.uint64Value else { return [] }
        let mtime = a[.modificationDate] as? Date
        let identity = FileIdentity(device: device, inode: inode)
        // Replacements and in-place rewrites must rebuild both rows and aggregates.
        if let old = st.identity,
           old != identity || size < st.size || (size == st.size && mtime != st.mtime) {
            st = FileState()
        }
        st.identity = identity; st.size = size; st.mtime = mtime
        guard size > st.offset, let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: st.offset)
            guard let data = try fh.readToEnd(), let nl = data.lastIndex(of: 0x0A) else { return [] }
            st.offset += UInt64(nl - data.startIndex + 1)
            return data[data.startIndex..<nl].split(separator: 0x0A).map { Data($0) }
        } catch { return [] }
    }

    private func summarize(_ service: Service, note: String, missing: String?) -> ServiceSummary {
        var s = ServiceSummary(service: service, available: false, sourceNote: note)
        if let missing { s.reason = missing; return s }
        let fileStates = states[service] ?? [:]
        s.fileCount = fileStates.count
        var days: [DayKey: TokenBreakdown] = [:]
        for st in fileStates.values { for (k, v) in st.days { days[k, default: .init()] += v } }
        guard !days.isEmpty else {
            s.reason = "已找到 \(fileStates.count) 個檔案，但其中沒有 token 用量記錄"
            return s
        }
        s.available = true
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        for i in (0..<7).reversed() {
            let d = cal.date(byAdding: .day, value: -i, to: todayStart)!
            let t = days[d.dayKey] ?? .init()
            s.last7.append(.init(date: d, tokens: t))
            s.week += t
        }
        s.today = days[now.dayKey] ?? .init()
        let monthPrefix = now.dayKey / 100
        for (k, v) in days where k / 100 == monthPrefix { s.month += v }
        return s
    }

    private func int(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }

    // MARK: - Claude Code: ~/.claude/projects/**/*.jsonl  (message.usage)

    private func scanClaude() -> ServiceSummary {
        let dir = home.appending(path: ".claude/projects")
        let note = "~/.claude/projects/**/*.jsonl"
        guard fm.fileExists(atPath: dir.path) else {
            states[.claude] = [:]
            return summarize(.claude, note: note, missing: "找不到 ~/.claude/projects")
        }
        let urls = files(under: dir, ext: "jsonl").sorted { $0.path < $1.path }
        let paths = Set(urls.map(\.path))
        let oldMap = states[.claude] ?? [:]
        var map = oldMap.filter { paths.contains($0.key) }
        var changed = map.count != oldMap.count
        let needle = Data("\"usage\"".utf8)
        for url in urls {
            let previous = map[url.path]
            var st = previous ?? FileState()
            let lines = newLines(url.path, &st)
            changed = changed || previous == nil || previous?.mtime != st.mtime || previous?.size != st.size
                || previous?.identity != st.identity || !lines.isEmpty
            for line in lines where line.range(of: needle) != nil {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] == nil || obj["type"] as? String == "assistant",
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let date = parseDate(obj["timestamp"] as? String) else { continue }
                let t = TokenBreakdown(input: max(0, int(usage["input_tokens"])),
                                       output: max(0, int(usage["output_tokens"])),
                                       cacheRead: max(0, int(usage["cache_read_input_tokens"])),
                                       cacheWrite: max(0, int(usage["cache_creation_input_tokens"])))
                let record = ClaudeRecord(date: date, tokens: t,
                                          sidechain: (obj["isSidechain"] as? Bool == true) || url.path.contains("/subagents/"))
                if let mid = msg["id"] as? String, !mid.isEmpty {
                    let key = ClaudeMessageKey(messageID: mid, requestID: (obj["requestId"] as? String) ?? "")
                    // Usage is cumulative within a message. Last complete snapshot wins, even
                    // when a later snapshot corrects counters downward.
                    st.claudeMessages[key] = record
                } else {
                    st.claudeUnkeyed.append(record)
                }
            }
            map[url.path] = st
        }
        if changed { rebuildClaudeAggregates(&map) }
        states[.claude] = map
        return summarize(.claude, note: note, missing: nil)
    }

    /// Reconcile cross-file transcript copies deterministically, then build all visible totals
    /// from the same winners. Deleting/truncating a file can promote another surviving copy.
    private func rebuildClaudeAggregates(_ map: inout [String: FileState]) {
        var winners: [ClaudeMessageKey: (path: String, record: ClaudeRecord)] = [:]
        for path in map.keys.sorted() {
            guard let st = map[path] else { continue }
            for (key, record) in st.claudeMessages {
                if let old = winners[key] {
                    if old.record.sidechain != record.sidechain {
                        if record.sidechain { continue }
                    } else if record.date <= old.record.date { continue }
                }
                winners[key] = (path, record)
            }
        }
        for path in Array(map.keys) {
            map[path]?.days = [:]; map[path]?.recent = []
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        func add(_ record: ClaudeRecord, path: String) {
            map[path]!.days[record.date.dayKey, default: .init()] += record.tokens
            if record.date > cutoff { map[path]!.recent.append((record.date, record.tokens)) }
        }
        for (path, record) in winners.values { add(record, path: path) }
        for path in map.keys.sorted() {
            for record in map[path]!.claudeUnkeyed { add(record, path: path) }
        }
    }

    // MARK: - Codex: ~/.codex/sessions/**/*.jsonl  (event_msg / token_count)

    private func scanCodex() -> ServiceSummary {
        let dir = home.appending(path: ".codex/sessions")
        let note = "~/.codex/sessions/**/*.jsonl（token_count 事件）"
        guard fm.fileExists(atPath: dir.path) else {
            states[.codex] = [:]
            return summarize(.codex, note: note, missing: "找不到 ~/.codex/sessions")
        }
        let urls = files(under: dir, ext: "jsonl")
        let paths = Set(urls.map(\.path))
        var map = (states[.codex] ?? [:]).filter { paths.contains($0.key) }
        let needle = Data("\"token_count\"".utf8)
        for url in urls {
            var st = map[url.path] ?? FileState()
            for line in newLines(url.path, &st) where line.range(of: needle) != nil {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let date0 = parseDate(obj["timestamp"] as? String) else { continue }
                if let plan = (payload["rate_limits"] as? [String: Any])?["plan_type"] as? String, !plan.isEmpty,
                   st.latestPlan == nil || st.latestPlan!.0 <= date0 {
                    st.latestPlan = (date0, plan)
                }
                if let rl = payload["rate_limits"] as? [String: Any], let p = codexWindow(rl["primary"]),
                   st.latestRate == nil || st.latestRate!.0 <= date0 {
                    st.latestRate = (date0, RateInfo(primary: p, secondary: codexWindow(rl["secondary"]), isEstimate: false,
                                                     source: "Codex token_count.rate_limits", updatedAt: date0))
                }
                guard let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let date = parseDate(obj["timestamp"] as? String) else { continue }
                // Codex re-emits token_count with unchanged totals; count only when cumulative total moves.
                let total = int((info["total_token_usage"] as? [String: Any])?["total_tokens"])
                if total == st.lastCodexTotal { continue }
                st.lastCodexTotal = total
                let cached = int(last["cached_input_tokens"])
                let t = TokenBreakdown(input: max(0, int(last["input_tokens"]) - cached),
                                       output: int(last["output_tokens"]),
                                       cacheRead: cached,
                                       cacheWrite: int(last["cache_write_input_tokens"]))
                st.days[date.dayKey, default: .init()] += t
                if date > Date().addingTimeInterval(-24 * 3600) { st.recent.append((date, t)) }
            }
            map[url.path] = st
        }
        states[.codex] = map
        return summarize(.codex, note: note, missing: nil)
    }

    // MARK: - Grok Build CLI: $GROK_HOME/sessions/<encoded-cwd>/<session>/updates.jsonl  (turn_completed)

    private func scanGrok() -> ServiceSummary {
        let dir = grokHome.appending(path: "sessions")
        let note = "~/.grok/sessions/**/updates.jsonl（turn_completed 事件）"
        guard fm.fileExists(atPath: dir.path) else {
            states[.grok] = [:]
            return summarize(.grok, note: note, missing: "找不到 ~/.grok/sessions（尚未使用 Grok CLI）")
        }
        let urls = files(under: dir, ext: "jsonl").filter { $0.lastPathComponent == "updates.jsonl" }
        let paths = Set(urls.map(\.path))
        let oldMap = states[.grok] ?? [:]
        var map = oldMap.filter { paths.contains($0.key) }
        var changed = map.count != oldMap.count
        let needle = Data("\"turn_completed\"".utf8)
        for url in urls {
            let previous = map[url.path]
            var st = previous ?? FileState()
            let lines = newLines(url.path, &st)
            changed = changed || previous == nil || previous?.identity != st.identity || !lines.isEmpty
            for line in lines where line.range(of: needle) != nil {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let params = obj["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "turn_completed",
                      let usage = update["usage"] as? [String: Any],
                      let t = grokTokens(usage), t.total > 0 else { continue }
                let meta = params["_meta"] as? [String: Any]
                guard let date = grokDate(meta?["agentTimestampMs"], obj["timestamp"]) else { continue }
                let record = ClaudeRecord(date: date, tokens: t, sidechain: false)
                if let id = meta?["eventId"] as? String, !id.isEmpty { st.grokTurns[id] = record }
                else { st.grokUnkeyed.append(record) }
            }
            map[url.path] = st
        }
        if changed { rebuildGrokAggregates(&map) }
        states[.grok] = map
        return summarize(.grok, note: note, missing: nil)
    }

    /// Grok records OpenAI-style usage: `inputTokens` includes cache reads and writes, and
    /// `reasoningTokens` is already inside `outputTokens`. Top-level totals, else the per-model sum.
    private func grokTokens(_ usage: [String: Any]) -> TokenBreakdown? {
        func split(_ u: [String: Any]) -> TokenBreakdown {
            let input = max(0, int(u["inputTokens"]))
            let read = min(max(0, int(u["cachedReadTokens"])), input)
            let write = min(max(0, int(u["cacheCreationTokens"])), input - read)
            return TokenBreakdown(input: input - read - write, output: max(0, int(u["outputTokens"])),
                                  cacheRead: read, cacheWrite: write)
        }
        let top = split(usage)
        if top.total > 0 { return top }
        guard let models = usage["modelUsage"] as? [String: Any] else { return nil }
        return models.values.compactMap { $0 as? [String: Any] }.map(split).reduce(TokenBreakdown(), +)
    }

    /// `_meta.agentTimestampMs` (epoch ms), else the envelope `timestamp` (epoch seconds, or ISO 8601).
    private func grokDate(_ ms: Any?, _ envelope: Any?) -> Date? {
        if let ms = (ms as? NSNumber)?.doubleValue, ms > 0 { return Date(timeIntervalSince1970: ms / 1000) }
        if let s = (envelope as? NSNumber)?.doubleValue, s > 0 { return Date(timeIntervalSince1970: s) }
        return parseDate(envelope as? String)
    }

    /// Forked and resumed sessions copy earlier events into their own `updates.jsonl`; each eventId
    /// counts once, attributed to the first path in sorted order.
    private func rebuildGrokAggregates(_ map: inout [String: FileState]) {
        var seen = Set<String>()
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for path in map.keys.sorted() {
            guard var st = map[path] else { continue }
            st.days = [:]; st.recent = []
            let fresh = st.grokTurns.filter { seen.insert($0.key).inserted }.values
            for record in Array(fresh) + st.grokUnkeyed {
                st.days[record.date.dayKey, default: .init()] += record.tokens
                if record.date > cutoff { st.recent.append((record.date, record.tokens)) }
            }
            map[path] = st
        }
    }
}
