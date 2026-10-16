import Foundation
import SQLite3

/// Scans local log files read-only. Never writes to source files.
actor UsageScanner {
    private struct FileState {
        var offset: UInt64 = 0
        var mtime: Date?
        var days: [DayKey: TokenBreakdown] = [:]
        var lastCodexTotal = -1
        var recent: [(Date, Int)] = []
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

    func scanAll(claude5hLimit: Int, geminiDailyLimit: Int) -> [ServiceSummary] {
        var c = scanClaude(), x = scanCodex(), g = scanGemini()
        // Claude: local rolling-5h estimate (input+output+cache write) vs configured limit
        let cutoff = Date().addingTimeInterval(-5 * 3600)
        var used = 0
        for k in (states[.claude] ?? [:]).keys {
            states[.claude]![k]!.recent.removeAll { $0.0 < cutoff }
            used += states[.claude]![k]!.recent.reduce(0) { $0 + $1.1 }
        }
        if claude5hLimit > 0 {
            c.rate = RateInfo(primary: .init(usedPercent: Double(used) / Double(claude5hLimit) * 100, windowMinutes: 300),
                              isEstimate: true, source: "本機 jsonl 估算：近 5 小時 \(compactNumber(used)) / \(compactNumber(claude5hLimit))")
        }
        // Codex: newest rate_limits across all sessions
        x.rate = (states[.codex] ?? [:]).values.compactMap(\.latestRate).max { $0.0 < $1.0 }?.1
        let now = Date()
        for w in [\RateInfo.primary, \RateInfo.secondary] {
            if let r = x.rate?[keyPath: w]?.resetsAt, r < now { x.rate![keyPath: w]!.usedPercent = 0 } // window already reset
        }
        // Gemini: no local quota data; optional daily estimate
        if geminiDailyLimit > 0 {
            g.rate = RateInfo(primary: .init(usedPercent: Double(g.today.total) / Double(geminiDailyLimit) * 100, windowMinutes: 1440),
                              isEstimate: true, source: "估算：今日 \(compactNumber(g.today.total)) / \(compactNumber(geminiDailyLimit))")
        }
        return [c, x, g]
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
                if date > Date().addingTimeInterval(-5 * 3600) {
                    st.recent.append((date, t.input + t.output + t.cacheWrite))
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
            }
            map[url.path] = st
        }
        states[.codex] = map
        return summarize(.codex, note: note, missing: nil)
    }

    // MARK: - Gemini CLI chats + Antigravity CLI (agy) conversation DBs

    private func scanGemini() -> ServiceSummary {
        let gem = home.appending(path: ".gemini")
        let note = "~/.gemini/antigravity-cli/conversations/*.db（gen_metadata）、~/.gemini/tmp/*/chats/*.json"
        guard fm.fileExists(atPath: gem.path) else {
            return summarize(.gemini, note: note, missing: "找不到 ~/.gemini")
        }
        var map = states[.gemini] ?? [:]
        // Gemini CLI session files
        let tmp = gem.appending(path: "tmp")
        for proj in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            let chats = proj.appending(path: "chats")
            for url in (try? fm.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == "json" {
                let m = attrs(url.path).mtime
                if map[url.path]?.mtime == m, m != nil { continue }
                var st = FileState(); st.mtime = m
                if let data = try? Data(contentsOf: url),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msgs = obj["messages"] as? [[String: Any]] {
                    for msg in msgs {
                        guard let tk = msg["tokens"] as? [String: Any],
                              let date = parseDate(msg["timestamp"] as? String) else { continue }
                        let cached = int(tk["cached"])
                        let t = TokenBreakdown(input: max(0, int(tk["input"]) - cached),
                                               output: int(tk["output"]) + int(tk["thoughts"]),
                                               cacheRead: cached)
                        st.days[date.dayKey, default: .init()] += t
                    }
                }
                map[url.path] = st
            }
        }
        // Antigravity CLI conversations (SQLite + protobuf)
        let convDir = gem.appending(path: "antigravity-cli/conversations")
        for url in (try? fm.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "db" {
            let walPath = url.path + "-wal"
            let m = max(attrs(url.path).mtime ?? .distantPast, attrs(walPath).mtime ?? .distantPast)
            if map[url.path]?.mtime == m { continue }
            var st = FileState(); st.mtime = m
            st.days = AgyReader.read(dbURL: url, fallbackDate: m)
            map[url.path] = st
        }
        states[.gemini] = map
        var s = summarize(.gemini, note: note, missing: nil)
        if !s.available {
            s.reason = (s.reason ?? "") + "（Gemini CLI chats 為空；agy 對話未含用量）"
        }
        return s
    }
}

// MARK: - Antigravity reader

enum AgyReader {
    /// Copies the DB (+WAL) to a temp dir, then reads it, so the original is never opened for writing.
    static func read(dbURL: URL, fallbackDate: Date) -> [DayKey: TokenBreakdown] {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appending(path: "TokenBarAgy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpDir) }
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let copy = tmpDir.appending(path: "c.db")
            try fm.copyItem(at: dbURL, to: copy)
            let wal = URL(fileURLWithPath: dbURL.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_close(db) }
            var date = fallbackDate
            for blob in query(db, "SELECT data FROM trajectory_metadata_blob LIMIT 1") {
                if case .bytes(let ts)? = Proto.first(blob, 2), case .varint(let sec)? = Proto.first(ts, 1), sec > 0 {
                    date = Date(timeIntervalSince1970: TimeInterval(sec))
                }
            }
            var result: [DayKey: TokenBreakdown] = [:]
            for blob in query(db, "SELECT data FROM gen_metadata") {
                guard case .bytes(let f1)? = Proto.first(blob, 1),
                      case .bytes(let usage)? = Proto.first(f1, 4) else { continue }
                // Observed: 2 = prompt tokens, 3 = output tokens (incl. thinking, 9 = thinking subset)
                let input = Proto.varint(usage, 2), output = Proto.varint(usage, 3)
                if input == 0 && output == 0 { continue }
                result[date.dayKey, default: .init()] += TokenBreakdown(input: input, output: output)
            }
            return result
        } catch { return [:] }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String) -> [Data] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Data] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(stmt, 0))
            if let p = sqlite3_column_blob(stmt, 0), n > 0 { out.append(Data(bytes: p, count: n)) }
        }
        return out
    }
}

/// Minimal protobuf wire-format reader.
enum Proto {
    enum Value { case varint(UInt64), bytes(Data) }

    static func fields(_ data: Data) -> [(Int, Value)] {
        let b = [UInt8](data)
        var i = 0
        var out: [(Int, Value)] = []
        func readVarint() -> UInt64? {
            var r: UInt64 = 0, s: UInt64 = 0
            while i < b.count, s < 64 {
                let c = b[i]; i += 1
                r |= UInt64(c & 0x7F) << s; s += 7
                if c < 0x80 { return r }
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { break }
            let f = Int(key >> 3)
            switch key & 7 {
            case 0: guard let v = readVarint() else { return out }; out.append((f, .varint(v)))
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let l = readVarint(), i + Int(l) <= b.count else { return out }
                out.append((f, .bytes(Data(b[i..<i + Int(l)])))); i += Int(l)
            default: return out
            }
        }
        return out
    }

    static func first(_ data: Data, _ field: Int) -> Value? { fields(data).first { $0.0 == field }?.1 }
    static func varint(_ data: Data, _ field: Int) -> Int {
        if case .varint(let v)? = first(data, field) { return Int(clamping: v) }
        return 0
    }
}
