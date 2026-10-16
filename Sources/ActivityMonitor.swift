import Foundation
import Darwin

/// Cheap activity detection: recent log-file writes + CPU of the CLI processes.
/// Runs every ~2.5s; no shelling out, no network.
actor ActivityMonitor {
    private struct CPUSample { var ticks: UInt64; var at: UInt64 }
    private var samples: [pid_t: CPUSample] = [:]
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let fileWindow: TimeInterval = 20
    private let cpuThreshold = 3.0   // percent of one core
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t)
        return (UInt64(t.numer), UInt64(t.denom))
    }()
    private let forced: Set<Service> = {
        let raw = ProcessInfo.processInfo.environment["TOKENBAR_FORCE_ACTIVE"] ?? ""
        return Set(raw.split(separator: ",").compactMap { Service(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }()

    struct Reading: Sendable, Equatable { var active: Set<Service>; var detail: [Service: String] }

    private let disabled = ProcessInfo.processInfo.environment["TOKENBAR_NO_ACTIVITY"] == "1"   // debug: measure idle CPU

    func poll() -> Reading {
        if disabled { return Reading(active: [], detail: [:]) }
        var r = Reading(active: forced, detail: [:])
        for s in forced { r.detail[s] = "debug 強制" }
        let cpu = processCPU()
        let now = Date()
        let files: [Service: Date?] = [.claude: newestClaude(), .codex: newestCodex(), .gemini: newestGemini()]
        for s in Service.allCases {
            var why: [String] = []
            if let m = files[s] ?? nil, now.timeIntervalSince(m) < fileWindow { why.append("記錄檔 \(Int(now.timeIntervalSince(m)))s 前更新") }
            if let c = cpu[s], c > 0 { why.append(String(format: "CLI CPU %.0f%%", c)) }
            if !why.isEmpty { r.active.insert(s); r.detail[s] = why.joined(separator: "、") }
        }
        return r
    }

    // MARK: files

    private func mtime(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    private func newest(in dir: String, ext: Set<String>) -> Date? {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: Date?
        for n in items where ext.contains((n as NSString).pathExtension) {
            if let m = mtime(dir + "/" + n), m > (best ?? .distantPast) { best = m }
        }
        return best
    }

    private func newestClaude() -> Date? {
        let root = home.path + "/.claude/projects"
        var best: Date?
        for p in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + p
            // project dir mtime changes when a session file is created; only descend into recent ones cheaply
            if let m = newest(in: dir, ext: ["jsonl"]), m > (best ?? .distantPast) { best = m }
        }
        return best
    }

    private func newestCodex() -> Date? {
        let cal = Calendar.current
        var best: Date?
        for off in [0, -1] {
            let d = cal.date(byAdding: .day, value: off, to: Date())!
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = String(format: "%@/.codex/sessions/%04d/%02d/%02d", home.path, c.year!, c.month!, c.day!)
            if let m = newest(in: dir, ext: ["jsonl"]), m > (best ?? .distantPast) { best = m }
        }
        return best
    }

    private func newestGemini() -> Date? {
        let g = home.path + "/.gemini"
        var c: [Date?] = [newest(in: g + "/antigravity-cli/conversations", ext: ["db", "db-wal"])]
        for p in (try? fm.contentsOfDirectory(atPath: g + "/tmp")) ?? [] {
            c.append(newest(in: g + "/tmp/" + p + "/chats", ext: ["json"]))
        }
        c.append(geminiAppLastWork())
        return c.compactMap { $0 }.max()
    }

    private var geminiLogCache: (path: String, mtime: Date, last: Date?)?
    /// Gemini.app (com.google.GeminiMacOS) has no token data, but its diagnostic log records
    /// agent/stream work (RemyUpdateGoal, processStreamResponses, DesktopToolService, runSingleStream).
    private func geminiAppLastWork() -> Date? {
        let dir = home.path + "/Library/Caches/com.google.GeminiMacOS/Logs"
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        let logs = names.filter { $0.hasPrefix("diagnostic") && $0.hasSuffix(".log") }
            .compactMap { n -> (String, Date)? in mtime(dir + "/" + n).map { (dir + "/" + n, $0) } }
        guard let (path, m) = logs.max(by: { $0.1 < $1.1 }) else { return nil }
        if let c = geminiLogCache, c.path == path, c.mtime == m { return c.last }
        var last: Date?
        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            try? fh.seek(toOffset: size > 65536 ? size - 65536 : 0)
            let text = String(decoding: (try? fh.readToEnd()) ?? Data(), as: UTF8.self)
            let markers = ["RemyUpdateGoal", "processStreamResponses", "DesktopToolService", "runSingleStream"]
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss.SSS"; f.locale = Locale(identifier: "en_US_POSIX")
            for line in text.split(separator: "\n").reversed() where markers.contains(where: { line.contains($0) }) {
                if let d = f.date(from: String(line.prefix(19))) { last = d; break }
            }
        }
        geminiLogCache = (path, m, last)
        return last
    }

    // MARK: processes

    /// Returns the service and CPU threshold for a process, matching on name, executable path and args.
    private func classify(pid: pid_t, name: String) -> (Service, Double)? {
        switch name {
        case "claude": return (.claude, cpuThreshold)          // Claude Code CLI (desktop "Claude" ignored)
        case "codex": return (.codex, cpuThreshold)            // Codex CLI / app-server
        case "agy", "gemini", "antigravity", "language_server_macos_arm": return (.gemini, cpuThreshold)
        case "Gemini", "Antigravity":
            // Desktop apps idle at ~5-8% CPU; only treat sustained higher load as working.
            let path = execPath(pid)
            if path.contains("/Gemini.app/Contents/MacOS/") || path.contains("/Antigravity.app/Contents/MacOS/") {
                return (.gemini, 15)
            }
            return nil
        case "node", "bun":
            let a = args(pid)
            if a.contains("/gemini") || a.contains("@google/gemini-cli") { return (.gemini, cpuThreshold) }
            if a.contains("@anthropic-ai/claude-code") { return (.claude, cpuThreshold) }
            if a.contains("@openai/codex") { return (.codex, cpuThreshold) }
            return nil
        default: return nil
        }
    }

    private func execPath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private var argsCache: [pid_t: String] = [:]
    private func args(_ pid: pid_t) -> String {
        if let a = argsCache[pid] { return a }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        let a = String(decoding: buf.prefix(size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
        argsCache[pid] = a
        return a
    }

    private func processCPU() -> [Service: Double] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        let now = mach_absolute_time()
        var out: [Service: Double] = [:]
        var seen = Set<pid_t>()
        var nameBuf = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            guard proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 else { continue }
            let name = String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard let (svc, threshold) = classify(pid: pid, name: name) else { continue }
            var info = proc_taskinfo()
            let sz = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { continue }
            seen.insert(pid)
            let ticks = info.pti_total_user + info.pti_total_system
            if let prev = samples[pid], now > prev.at, ticks >= prev.ticks {
                let cpuNs = Double(ticks - prev.ticks) * Double(timebase.numer) / Double(timebase.denom)
                let wallNs = Double(now - prev.at) * Double(timebase.numer) / Double(timebase.denom)
                let pct = cpuNs / wallNs * 100
                if pct >= threshold { out[svc, default: 0] += pct }
            }
            samples[pid] = CPUSample(ticks: ticks, at: now)
        }
        samples = samples.filter { seen.contains($0.key) }
        argsCache = argsCache.filter { seen.contains($0.key) }
        return out
    }
}
