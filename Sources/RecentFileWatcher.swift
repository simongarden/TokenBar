import Foundation
import Darwin

/// mtime with nanosecond precision (nil if the path doesn't exist).
func fileMtime(_ path: String) -> Date? {
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
}

/// Newest recent `*.<ext>` mtime in `root/<subdir>/`, without stat-ing every file on every poll.
///
/// A full listing runs at most every `fullInterval` (or when `root` itself changes). In between only
/// the subdirectories (a new file bumps its directory's mtime) and the "hot" files written within
/// `hotWindow` are stat'ed. An old file that starts being appended to again is picked up by the next
/// full listing. Returns nil when nothing was written within `hotWindow`.
struct RecentFileWatcher {
    let root: String
    var ext = "jsonl"
    var fullInterval: TimeInterval = 30
    var hotWindow: TimeInterval = 10 * 60

    private var lastFull = Date.distantPast
    private var dirMtimes: [String: Date] = [:]   // root and its subdirectories
    private var hot: [String: Date] = [:]         // file path → last seen mtime
    /// stat/list calls made by the last `newest` call (for tests).
    private(set) var lastCost = 0

    init(root: String, ext: String = "jsonl", fullInterval: TimeInterval = 30, hotWindow: TimeInterval = 10 * 60) {
        self.root = root; self.ext = ext; self.fullInterval = fullInterval; self.hotWindow = hotWindow
    }

    mutating func newest(now: Date = Date()) -> Date? {
        lastCost = 0
        if now.timeIntervalSince(lastFull) >= fullInterval || changed(root) {
            fullScan(now: now)
        } else {
            for dir in dirMtimes.keys where dir != root && changed(dir) { scan(dir: dir, now: now) }
            for path in hot.keys { lastCost += 1; hot[path] = fileMtime(path) }
        }
        hot = hot.filter { now.timeIntervalSince($0.value) < hotWindow }
        return hot.values.max()
    }

    /// Records the new mtime; true if it differs from the last one seen.
    private mutating func changed(_ dir: String) -> Bool {
        lastCost += 1
        guard let m = fileMtime(dir) else { return false }   // vanished: left to the next full scan
        defer { dirMtimes[dir] = m }
        return dirMtimes[dir] != m
    }

    private mutating func fullScan(now: Date) {
        lastFull = now
        dirMtimes = [:]; hot = [:]
        lastCost += 1
        guard let m = fileMtime(root) else { return }
        dirMtimes[root] = m
        lastCost += 1
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
            let dir = root + "/" + name
            lastCost += 1
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  let dm = fileMtime(dir) else { continue }
            dirMtimes[dir] = dm
            scan(dir: dir, now: now)
        }
    }

    /// Adds the directory's recently written files to the hot set.
    private mutating func scan(dir: String, now: Date) {
        lastCost += 1
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        where (name as NSString).pathExtension == ext {
            let path = dir + "/" + name
            lastCost += 1
            if let m = fileMtime(path), now.timeIntervalSince(m) < hotWindow { hot[path] = m }
        }
    }
}
