import Foundation
import Testing

private final class UsageLogs {
    let home: URL
    let root: URL
    let date = Date()
    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "TokenBarLogs-\(UUID().uuidString)")
        root = home.appending(path: ".claude/projects/project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func row(_ id: String?, output: Int, request: String = "request", date: Date? = nil, sidechain: Bool = false) throws -> Data {
        var message: [String: Any] = ["usage": ["input_tokens": 100, "output_tokens": output,
                                                "cache_read_input_tokens": 20, "cache_creation_input_tokens": 10]]
        message["id"] = id
        let object: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date ?? self.date),
                                     "requestId": request, "isSidechain": sidechain, "message": message]
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
    @discardableResult func write(_ data: Data, name: String = "session.jsonl", atomic: Bool = false) throws -> URL {
        let url = root.appending(path: name)
        try data.write(to: url, options: atomic ? .atomic : [])
        return url
    }
    func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}

@Suite struct UsageScannerTests {
    @Test func streamingUsesLastSnapshotAcrossRefreshes() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let url = try logs.write(logs.row("message", output: 1))
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 131)
        try logs.append(logs.row("message", output: 50), to: url)
        let summary = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0]
        #expect(summary.today == TokenBreakdown(input: 100, output: 50, cacheRead: 20, cacheWrite: 10))
        #expect(summary.week.total == 180 && summary.month.total == 180)
        #expect(await scanner.windowTokens(.claude, since: logs.date.addingTimeInterval(-1)).total == 180)
        let restarted = UsageScanner(home: logs.home)
        #expect(await restarted.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today == summary.today)
    }

    @Test func cumulativeCorrectionsCanDecreaseCounters() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let url = try logs.write(logs.row("message", output: 50))
        _ = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])
        try logs.append(logs.row("message", output: 2), to: url)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 132)
    }

    @Test func duplicateRowsDoNotIncreaseTotals() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let row = try logs.row("message", output: 5)
        try logs.write(row + row)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 135)
    }

    @Test func distinctRequestsAndUnkeyedRowsCountSeparately() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        try logs.write(logs.row("message", output: 5, request: "one")
            + logs.row("message", output: 5, request: "two") + logs.row(nil, output: 5))
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 405)
    }

    @Test func truncatedFileRebuildsMessageIdentity() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        try logs.write(logs.row("message", output: 5) + logs.row("removed", output: 100))
        _ = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])
        try logs.write(logs.row("message", output: 5))
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 135)
    }

    @Test func sameSizeAtomicReplacementIsRescanned() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        try logs.write(logs.row("message", output: 5))
        _ = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])
        try logs.write(logs.row("message", output: 9), atomic: true)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 139)
    }

    @Test func deletedFilesAndRootsDoNotLeaveCachedUsage() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let url = try logs.write(logs.row("message", output: 5))
        _ = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])
        try FileManager.default.removeItem(at: url)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 0)
        try logs.write(logs.row("message", output: 5))
        _ = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])
        try FileManager.default.removeItem(at: logs.home.appending(path: ".claude/projects"))
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 0)
        #expect(await scanner.windowTokens(.claude, since: .distantPast).total == 0)
    }

    @Test func crossFileCopiesPreferParentAndPromoteSurvivor() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let parent = try logs.write(logs.row("message", output: 5), name: "z-parent.jsonl")
        try logs.write(logs.row("message", output: 99, sidechain: true), name: "a-copy.jsonl")
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 135)
        try FileManager.default.removeItem(at: parent)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 229)
    }

    @Test func incompleteLinesAreRetriedWithoutDoubleCounting() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let row = try logs.row("message", output: 5)
        let url = try logs.write(Data(row.dropLast(8)))
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 0)
        try logs.append(Data(row.suffix(8)), to: url)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 135)
        #expect(await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0].today.total == 135)
    }

    @Test func changingSnapshotDateMovesAllAggregates() async throws {
        let logs = try UsageLogs(); let scanner = UsageScanner(home: logs.home)
        let old = Calendar.current.date(byAdding: .day, value: -1, to: logs.date)!
        let url = try logs.write(logs.row("message", output: 1, date: old))
        _ = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])
        try logs.append(logs.row("message", output: 5), to: url)
        let summary = await scanner.scanAll(claude5hLimit: 0, enabled: [.claude])[0]
        #expect(summary.today.total == 135)
        #expect(summary.week.total == 135)
    }
}
