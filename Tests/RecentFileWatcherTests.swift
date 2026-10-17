import Foundation
import Testing

@Suite struct RecentFileWatcherTests {
    let root: URL
    let now = Date()
    private let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "RecentFileWatcherTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ rel: String, mtime: Date) throws {
        let u = root.appending(path: rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: u.path) { try Data("{}\n".utf8).write(to: u) }
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: u.path)
    }

    private func touchDir(_ rel: String, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: root.appending(path: rel).path)
    }

    @Test func findsNewestRecentFile() throws {
        try write("a/old.jsonl", mtime: now.addingTimeInterval(-3600))
        try write("a/new.jsonl", mtime: now.addingTimeInterval(-5))
        try write("b/mid.jsonl", mtime: now.addingTimeInterval(-60))
        try write("b/ignore.txt", mtime: now)
        var w = RecentFileWatcher(root: root.path)
        let r = w.newest(now: now)
        let n = try #require(r)
        #expect(abs(n.timeIntervalSince(now.addingTimeInterval(-5))) < 0.01)
    }

    @Test func nilWhenNothingRecent() throws {
        try write("a/old.jsonl", mtime: now.addingTimeInterval(-3600))
        var w = RecentFileWatcher(root: root.path)
        #expect(w.newest(now: now) == nil)
    }

    /// Between full scans only root, project dirs and hot files are stat'ed, not every file.
    @Test func pollsBetweenFullScansDoNotStatColdFiles() throws {
        for i in 0..<200 { try write("p\(i % 4)/s\(i).jsonl", mtime: now.addingTimeInterval(-7200)) }
        try write("p0/hot.jsonl", mtime: now.addingTimeInterval(-1))
        var w = RecentFileWatcher(root: root.path)
        _ = w.newest(now: now)
        let full = w.lastCost
        _ = w.newest(now: now.addingTimeInterval(2.5))
        #expect(full > 200)
        #expect(w.lastCost <= 1 + 4 + 1)   // root + 4 project dirs + 1 hot file
    }

    @Test func seesAppendToHotFile() throws {
        try write("p/s.jsonl", mtime: now.addingTimeInterval(-100))
        var w = RecentFileWatcher(root: root.path)
        _ = w.newest(now: now)
        try write("p/s.jsonl", mtime: now.addingTimeInterval(2))
        let r = w.newest(now: now.addingTimeInterval(2.5))
        let n = try #require(r)
        #expect(abs(n.timeIntervalSince(now.addingTimeInterval(2))) < 0.01)
    }

    @Test func seesNewFileInExistingProjectBeforeFullScan() throws {
        try write("p/cold.jsonl", mtime: now.addingTimeInterval(-7200))
        try touchDir("p", now.addingTimeInterval(-7200))
        var w = RecentFileWatcher(root: root.path)
        #expect(w.newest(now: now) == nil)
        try write("p/new.jsonl", mtime: now.addingTimeInterval(1))
        try touchDir("p", now.addingTimeInterval(1))
        #expect(w.newest(now: now.addingTimeInterval(2.5)) != nil)
    }

    @Test func seesNewProjectDirectory() throws {
        try write("p/cold.jsonl", mtime: now.addingTimeInterval(-7200))
        try touchDir("", now.addingTimeInterval(-7200))
        var w = RecentFileWatcher(root: root.path)
        #expect(w.newest(now: now) == nil)
        try write("q/new.jsonl", mtime: now.addingTimeInterval(1))
        try touchDir("", now.addingTimeInterval(1))
        #expect(w.newest(now: now.addingTimeInterval(2.5)) != nil)
    }

    /// An old file that is appended to again (e.g. a resumed session) is found by the next full scan.
    @Test func reawakenedColdFileFoundByFullScan() throws {
        try write("p/s.jsonl", mtime: now.addingTimeInterval(-7200))
        var w = RecentFileWatcher(root: root.path, fullInterval: 30)
        #expect(w.newest(now: now) == nil)
        try write("p/s.jsonl", mtime: now.addingTimeInterval(1))
        #expect(w.newest(now: now.addingTimeInterval(31)) != nil)
    }
}
