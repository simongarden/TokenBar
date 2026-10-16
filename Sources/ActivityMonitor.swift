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
            if let c = cpu[s], c >= cpuThreshold { why.append(String(format: "CLI CPU %.0f%%", c)) }
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
        return c.compactMap { $0 }.max()
    }

    // MARK: processes

    private func service(forProcess name: String) -> Service? {
        switch name {
        case "claude": .claude                 // Claude Code CLI (desktop app is "Claude", ignored)
        case "codex": .codex                   // Codex CLI / app-server
        case "agy", "gemini", "antigravity": .gemini
        default: nil
        }
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
            guard let svc = service(forProcess: name) else { continue }
            var info = proc_taskinfo()
            let sz = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, sz) == sz else { continue }
            seen.insert(pid)
            let ticks = info.pti_total_user + info.pti_total_system
            if let prev = samples[pid], now > prev.at, ticks >= prev.ticks {
                let cpuNs = Double(ticks - prev.ticks) * Double(timebase.numer) / Double(timebase.denom)
                let wallNs = Double(now - prev.at) * Double(timebase.numer) / Double(timebase.denom)
                out[svc, default: 0] += cpuNs / wallNs * 100
            }
            samples[pid] = CPUSample(ticks: ticks, at: now)
        }
        samples = samples.filter { seen.contains($0.key) }
        return out
    }
}
