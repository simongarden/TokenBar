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

    struct Reading: Sendable, Equatable { var active: Set<Service>; var detail: [Service: String]; var grok: String? = nil }

    private let disabled = ProcessInfo.processInfo.environment["TOKENBAR_NO_ACTIVITY"] == "1"   // debug: measure idle CPU

    func poll(enabled: Set<Service>, grok: Bool) -> Reading {
        if disabled { return Reading(active: [], detail: [:]) }
        var r = Reading(active: forced.intersection(enabled), detail: [:])
        for s in forced { r.detail[s] = "debug 強制" }
        let cpu = enabled.isEmpty ? [:] : processCPU()
        let now = Date()
        var files: [Service: Date?] = [:]
        if enabled.contains(.claude) { files[.claude] = newestClaude() }
        if enabled.contains(.codex) { files[.codex] = newestCodex() }
        for s in enabled {
            var why: [String] = []
            if let m = files[s] ?? nil, now.timeIntervalSince(m) < fileWindow { why.append("記錄檔 \(Int(now.timeIntervalSince(m)))s 前更新") }
            if let c = cpu[s], c > 0 { why.append(String(format: "CLI CPU %.0f%%", c)) }
            if !why.isEmpty { r.active.insert(s); r.detail[s] = why.joined(separator: "、") }
        }
        r.grok = grok ? grokBotBusy() : nil
        return r
    }

    // MARK: Grok Bot (same logic as ~/.local/bin/agent-caffeinate.sh)

    /// Grok Bot.app main process with a busy descendant: a shell that itself has children,
    /// or any non-shell descendant outside an .app bundle's Frameworks/MacOS (i.e. not an Electron helper).
    private func grokBotBusy() -> String? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        var kids: [pid_t: [pid_t]] = [:]
        var root: pid_t?
        let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(max(0, n))) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz) == sz else { continue }
            kids[pid_t(info.pbi_ppid), default: []].append(pid)
            if root == nil, info.pbi_ppid == 1 {
                let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if name == "Grok Bot", execPath(pid).hasSuffix("Grok Bot.app/Contents/MacOS/Grok Bot") { root = pid }
            }
        }
        guard let root else { return nil }
        let shells: Set<String> = ["zsh", "bash", "sh", "-zsh", "fish"]
        func busy(_ p: pid_t, depth: Int) -> String? {
            guard depth < 12 else { return nil }
            for k in kids[p] ?? [] {
                let path = execPath(k)
                let base = (path as NSString).lastPathComponent
                if shells.contains(base) {
                    if let c = kids[k], !c.isEmpty { return "shell \(k) 執行中（\(c.count) 個子程序）" }
                } else if !path.isEmpty, path.range(of: #"\.app/Contents/(Frameworks|MacOS)/"#, options: .regularExpression) == nil {
                    return "\(base) (\(k))"
                } else if let r = busy(k, depth: depth + 1) { return r }
            }
            return nil
        }
        return busy(root, depth: 0)
    }

    // MARK: files

    private func newest(in dir: String, ext: Set<String>) -> Date? {
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        var best: Date?
        for n in items where ext.contains((n as NSString).pathExtension) {
            if let m = fileMtime(dir + "/" + n), m > (best ?? .distantPast) { best = m }
        }
        return best
    }

    /// Claude Code writes one jsonl per session under ~/.claude/projects/<project>/; there can be
    /// thousands, so only hot files and project directories are stat'ed on each 2.5 s poll.
    private lazy var claudeWatcher = RecentFileWatcher(root: home.path + "/.claude/projects")

    private func newestClaude() -> Date? { claudeWatcher.newest() }

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

    // MARK: processes

    /// Returns the service and CPU threshold for a process, matching on name, executable path and args.
    private func classify(pid: pid_t, name: String) -> (Service, Double)? {
        switch name {
        case "claude": return (.claude, cpuThreshold)          // Claude Code CLI (desktop "Claude" ignored)
        case "codex": return (.codex, cpuThreshold)            // Codex CLI / app-server
        case "grok": return (.grok, cpuThreshold)              // Grok Build CLI (Grok Bot.app is separate)
        case "node", "bun":
            let a = args(pid)
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
