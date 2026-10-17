import Foundation

/// Scans local log files read-only. Never writes to source files.
actor UsageScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var mtime: Date?
        var days: [DayKey: TokenBreakdown] = [:]
        var lastCodexTotal = -1
        var recent: [(Date, TokenBreakdown)] = []
        var latestRate: (Date, RateInfo)?
    }

    private var states: [Service: [String: FileState]] = [:]
    private var claudeSeen = Set<String>()
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    func scanAll(claude5hLimit: Int) -> [ServiceSummary] {
        var c = scanClaude(), x = scanCodex()
        c.account = account(.claude); x.account = account(.codex)
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
        return [c, x]
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        for svc in [Service.claude, .codex] {
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

    // MARK: - Logged-in account (read-only; only the email is extracted, tokens never stored or logged)

    private var accountCache: [Service: (Date?, String?)] = [:]

    private func account(_ svc: Service) -> String? {
        let path = home.path + (svc == .claude ? "/.claude.json" : "/.codex/auth.json")
        let m = attrs(path).mtime
        if let c = accountCache[svc], c.0 == m { return c.1 }
        var email: String?
        if let data = fm.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch svc {
            case .claude:
                email = (obj["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
            case .codex:
                if let jwt = (obj["tokens"] as? [String: Any])?["id_token"] as? String {
                    let parts = jwt.split(separator: ".")
                    if parts.count > 1 {
                        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
                        if let pd = Data(base64Encoded: b),
                           let payload = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] {
                            email = payload["email"] as? String
                        }
                    }
                }
            }
        }
        accountCache[svc] = (m, email)
        return email
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
        let (size, _) = attrs(path)
        if size < st.offset { st = FileState() }
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
            return summarize(.claude, note: note, missing: "找不到 ~/.claude/projects")
        }
        var map = states[.claude] ?? [:]
        let needle = Data("\"usage\"".utf8)
        for url in files(under: dir, ext: "jsonl") {
            var st = map[url.path] ?? FileState()
            for line in newLines(url.path, &st) where line.range(of: needle) != nil {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let date = parseDate(obj["timestamp"] as? String) else { continue }
                // Streaming writes the same message several times; dedupe by message id + request id.
                if let mid = msg["id"] as? String {
                    let key = mid + ":" + ((obj["requestId"] as? String) ?? "")
                    if !claudeSeen.insert(key).inserted { continue }
                }
                let t = TokenBreakdown(input: int(usage["input_tokens"]),
                                       output: int(usage["output_tokens"]),
                                       cacheRead: int(usage["cache_read_input_tokens"]),
                                       cacheWrite: int(usage["cache_creation_input_tokens"]))
                st.days[date.dayKey, default: .init()] += t
                if date > Date().addingTimeInterval(-24 * 3600) {
                    st.recent.append((date, t))
                }
            }
            map[url.path] = st
        }
        states[.claude] = map
        return summarize(.claude, note: note, missing: nil)
    }

    // MARK: - Codex: ~/.codex/sessions/**/*.jsonl  (event_msg / token_count)

    private func scanCodex() -> ServiceSummary {
        let dir = home.appending(path: ".codex/sessions")
        let note = "~/.codex/sessions/**/*.jsonl（token_count 事件）"
        guard fm.fileExists(atPath: dir.path) else {
            return summarize(.codex, note: note, missing: "找不到 ~/.codex/sessions")
        }
        var map = states[.codex] ?? [:]
        let needle = Data("\"token_count\"".utf8)
        for url in files(under: dir, ext: "jsonl") {
            var st = map[url.path] ?? FileState()
            for line in newLines(url.path, &st) where line.range(of: needle) != nil {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let date0 = parseDate(obj["timestamp"] as? String) else { continue }
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
}

