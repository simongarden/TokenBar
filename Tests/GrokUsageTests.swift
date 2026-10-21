import Foundation
import Testing

private final class GrokLogs {
    let home: URL
    let sessions: URL
    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "TokenBarGrok-\(UUID().uuidString)")
        sessions = home.appending(path: ".grok/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func turn(_ event: String?, input: Int = 100, cached: Int = 40, output: Int = 20,
              ms: Double? = Date().timeIntervalSince1970 * 1000, seconds: Double? = nil, kind: String = "turn_completed") throws -> Data {
        var params: [String: Any] = ["sessionId": "s", "update": ["sessionUpdate": kind, "usage": [
            "inputTokens": input, "cachedReadTokens": cached, "outputTokens": output, "reasoningTokens": 5]]]
        var meta: [String: Any] = [:]
        meta["eventId"] = event
        meta["agentTimestampMs"] = ms
        params["_meta"] = meta
        var obj: [String: Any] = ["method": "_x.ai/session/update", "params": params]
        obj["timestamp"] = seconds
        var d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]); d.append(0x0A)
        return d
    }
    @discardableResult func write(_ data: Data, session: String = "a", cwd: String = "%2FUsers%2Fme%2Fproj") throws -> URL {
        let dir = sessions.appending(path: "\(cwd)/\(session)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "updates.jsonl")
        try data.write(to: url)
        return url
    }
    var scanner: UsageScanner { UsageScanner(home: home, environment: [:]) }
}

private func grok(_ s: UsageScanner) async -> ServiceSummary { await s.scanAll(claude5hLimit: 0, enabled: [.grok])[0] }

@Suite struct GrokScannerTests {
    @Test func completedTurnsSplitCachedInput() async throws {
        let logs = try GrokLogs()
        try logs.write(logs.turn("e1") + logs.turn("e2", kind: "agent_message_chunk"))
        let s = await grok(logs.scanner)
        #expect(s.service == .grok && s.available)
        // inputTokens includes the cache; reasoningTokens is already inside outputTokens.
        #expect(s.today == TokenBreakdown(input: 60, output: 20, cacheRead: 40, cacheWrite: 0))
    }

    @Test func forkedSessionCopiesCountOnce() async throws {
        let logs = try GrokLogs(); let scanner = logs.scanner
        try logs.write(logs.turn("e1"), session: "a")
        try logs.write(logs.turn("e1") + logs.turn("e2", output: 30), session: "b")
        #expect(await grok(scanner).today.total == 120 + 130)
        // Deleting the original promotes the surviving copy.
        try FileManager.default.removeItem(at: logs.sessions.appending(path: "%2FUsers%2Fme%2Fproj/a"))
        #expect(await grok(scanner).today.total == 250)
    }

    @Test func appendedTurnsAreRead() async throws {
        let logs = try GrokLogs(); let scanner = logs.scanner
        let url = try logs.write(logs.turn("e1"))
        _ = await grok(scanner)
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: logs.turn("e2")); try h.close()
        #expect(await grok(scanner).today.total == 240)
    }

    @Test func envelopeSecondsAreTheTimestampFallback() async throws {
        let logs = try GrokLogs()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        try logs.write(logs.turn("e1", ms: nil, seconds: yesterday.timeIntervalSince1970))
        let s = await grok(logs.scanner)
        #expect(s.today.total == 0 && s.week.total == 120)
    }

    @Test func missingDirectoryAndGrokHome() async throws {
        let logs = try GrokLogs()
        try FileManager.default.removeItem(at: logs.sessions)
        #expect(await grok(logs.scanner).available == false)
        let custom = logs.home.appending(path: "custom")
        try FileManager.default.createDirectory(at: custom.appending(path: "sessions/p/s"), withIntermediateDirectories: true)
        try logs.turn("e1").write(to: custom.appending(path: "sessions/p/s/updates.jsonl"))
        let s = await grok(UsageScanner(home: logs.home, environment: ["GROK_HOME": custom.path]))
        #expect(s.today.total == 120)
    }
}

private func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

@Suite struct GrokCreditsTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!

    @Test func weeklyPercentAndReset() throws {
        let c = try #require(GrokUsageClient.parseCredits(json(["config": [
            "creditUsagePercent": 37.5, "subscriptionTier": "SUPERGROK_HEAVY",
            "currentPeriod": ["start": "2026-10-19T00:00:00Z", "end": "2026-10-26T00:00:00Z"]]]), now: now))
        #expect(c.window?.usedPercent == 37.5 && c.window?.windowMinutes == 7 * 1440)
        #expect(c.window?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-26T00:00:00Z"))
        #expect(c.tier == "SuperGrok Heavy")
    }

    @Test func onDemandRatioAndBillingPeriodFallback() throws {
        let c = try #require(GrokUsageClient.parseCredits(json(["config": [
            "onDemandUsed": ["val": 250], "onDemandCap": ["val": 1000],
            "billingPeriodStart": "2026-10-01T00:00:00Z", "billingPeriodEnd": "2026-11-01T00:00:00.000Z"]]), now: now))
        #expect(c.window?.usedPercent == 25 && c.window?.windowMinutes == 31 * 1440)
    }

    @Test func missingPercentIsUnknownNotZero() throws {
        let c = try #require(GrokUsageClient.parseCredits(json(["config": [
            "currentPeriod": ["start": "2026-10-19T00:00:00Z", "end": "2026-10-26T00:00:00Z"]]]), now: now))
        #expect(c.window == nil)
        #expect(GrokUsageClient.parseCredits(json(["config": [:]]), now: now) == nil)
        #expect(GrokUsageClient.parseCredits(Data("nope".utf8), now: now) == nil)
    }

    @Test func credentialPrefersOIDCScope() throws {
        let c = try #require(GrokCredential.parse(json([
            "https://accounts.x.ai/sign-in": ["key": "legacy"],
            "https://auth.x.ai::client": ["key": "oidc", "email": "a@b.c", "expires_at": "2026-10-28T00:00:00Z"],
            "https://auth.x.ai::empty": ["key": ""]])))
        #expect(c.token == "oidc" && c.email == "a@b.c" && c.expiresAt != nil)
        #expect(GrokCredential.parse(json(["https://accounts.x.ai/sign-in": ["key": "legacy"]]))?.token == "legacy")
        #expect(GrokCredential.parse(json(["other": ["key": "x"]])) == nil)
    }

    @Test func planNames() {
        #expect(PlanName.grok("SuperGrok") == "SuperGrok")
        #expect(PlanName.grok("supergrok_heavy") == "SuperGrok Heavy")
        #expect(PlanName.grok("X Premium+") == "X Premium+")
        #expect(PlanName.grok("") == nil)
    }
}

private actor Calls {
    var urls: [String] = []
    func add(_ u: String) { urls.append(u) }
}

@Suite struct GrokUsageClientTests {
    let now = ISO8601DateFormatter().date(from: "2026-10-21T12:00:00Z")!
    let valid = GrokCredential(token: "t", expiresAt: ISO8601DateFormatter().date(from: "2026-10-28T00:00:00Z"), email: nil)

    private func client(_ cred: GrokCredential?, calls: Calls, billing: Int = 200, body: Any? = nil) -> GrokUsageClient {
        let payload = json(body ?? ["config": ["creditUsagePercent": 12,
            "currentPeriod": ["start": "2026-10-19T00:00:00Z", "end": "2026-10-26T00:00:00Z"]]])
        return GrokUsageClient(readCredential: { cred }, transport: { req in
            let url = req.url!.absoluteString
            await calls.add(url)
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            #expect(req.value(forHTTPHeaderField: "x-xai-token-auth") == "xai-grok-cli")
            if url.contains("settings") {
                return (json(["subscription_tier_display": "SuperGrok"]), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (payload, HTTPURLResponse(url: req.url!, statusCode: billing, httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        })
    }

    @Test func successIsThrottled() async {
        let calls = Calls(); let c = client(valid, calls: calls)
        let r = await c.fetch(now: now)
        #expect(r.status == .ok && r.plan == "SuperGrok" && r.rate?.primary?.usedPercent == 12)
        _ = await c.fetch(now: now.addingTimeInterval(60))
        #expect(await calls.urls.count == 2)   // billing + settings once
        _ = await c.fetch(now: now.addingTimeInterval(301))
        #expect(await calls.urls.count == 4)
    }

    @Test func expiredOrMissingLoginNeverCallsNetwork() async {
        let calls = Calls()
        var old = valid; old.expiresAt = now.addingTimeInterval(-1)
        #expect(await client(old, calls: calls).fetch(now: now).status == .expired)
        #expect(await client(nil, calls: calls).fetch(now: now).status == .noCredential)
        #expect(await calls.urls.isEmpty)
    }

    @Test func teamAccountKeepsPlan() async {
        let r = await client(valid, calls: Calls(), billing: 412).fetch(now: now)
        #expect(r.status == .teamAccount && r.rate == nil && r.plan == "SuperGrok")
    }

    @Test func rateLimitedWaitsForRetryAfter() async {
        let calls = Calls(); let c = client(valid, calls: calls, billing: 429)
        let r = await c.fetch(now: now)
        #expect(r.status == .waiting(now.addingTimeInterval(120)))
        _ = await c.fetch(now: now.addingTimeInterval(119))
        #expect(await calls.urls.count == 1)
    }

    @Test func unknownPercent() async {
        let r = await client(valid, calls: Calls(), body: ["config": ["currentPeriod": ["end": "2026-10-26T00:00:00Z"]]]).fetch(now: now)
        #expect(r.status == .usageUnknown && r.rate == nil)
    }
}

@Suite struct GrokConnectionTests {
    @Test func oneButtonPerState() {
        typealias P = GrokConnectionPresentation
        #expect(P(installed: false, quotaOn: true, status: .noCredential).action == .install)
        #expect(P(installed: true, quotaOn: true, status: .noCredential).action == .login)
        #expect(P(installed: true, quotaOn: true, status: .expired).action == .login)
        #expect(P(installed: true, quotaOn: true, status: .httpError(401)).action == .login)
        #expect(P(installed: true, quotaOn: false, status: nil).action == .enableQuota)
        let ok = P(installed: true, quotaOn: true, status: .ok, account: "a@b.c")
        #expect(ok.connected && ok.action == .none && ok.detail.hasPrefix("a@b.c"))
        // A login that works without the CLI on a known path still counts as connected.
        #expect(P(installed: false, quotaOn: true, status: .usageUnknown).connected)
        for s: GrokUsageClient.Status in [.teamAccount, .failed, .httpError(500), .waiting(.now)] {
            #expect(P(installed: true, quotaOn: true, status: s).action == .none)
        }
    }

    @Test func noTerminalJargonInUserText() {
        let states: [GrokUsageClient.Status?] = [nil, .ok, .usageUnknown, .noCredential, .expired, .teamAccount, .failed, .httpError(403)]
        for installed in [true, false] { for on in [true, false] { for s in states {
            let p = GrokConnectionPresentation(installed: installed, quotaOn: on, status: s)
            for t in [p.title, p.detail, p.actionTitle] {
                #expect(!t.contains("grok login") && !t.contains("~/") && !t.contains("CLI 指令"))
            }
        } } }
    }

    @Test func locateFindsInstallerDefault() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "TokenBarGrokCLI-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let grokHome = home.appending(path: ".grok")
        #expect(GrokCLI.locate(home: home, grokHome: grokHome, systemPaths: []) == nil)
        let bin = grokHome.appending(path: "bin/grok")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        #expect(GrokCLI.locate(home: home, grokHome: grokHome, systemPaths: [])?.executable.path == bin.path)
    }

    @Test func setupScriptInstallsOnlyWhenMissing() throws {
        let grokHome = URL(fileURLWithPath: "/tmp/g h")
        let env = ["HOME": "/Users/x", "PATH": "/usr/bin:relative", "NODE_OPTIONS": "--require x", "GROK_HOME": "/tmp/g h"]
        let fresh = try GrokCLI.setupCommandFile(cli: nil, grokHome: grokHome, environment: env)
        defer { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
        let script = try String(contentsOf: fresh, encoding: .utf8)
        #expect(script.contains("https://x.ai/cli/install.sh"))
        #expect(script.contains("'/tmp/g h/bin/grok' login"))
        #expect(script.contains("'GROK_HOME=/tmp/g h'") && !script.contains("NODE_OPTIONS") && !script.contains("relative"))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/zsh"); check.arguments = ["-n", fresh.path]
        try check.run(); check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: fresh.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let installed = try GrokCLI.setupCommandFile(cli: GrokCLI(executable: URL(fileURLWithPath: "/opt/grok")), environment: env)
        defer { try? FileManager.default.removeItem(at: installed.deletingLastPathComponent()) }
        let s2 = try String(contentsOf: installed, encoding: .utf8)
        #expect(!s2.contains("install.sh") && s2.contains("'/opt/grok' login"))
    }
}
