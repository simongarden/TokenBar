import Foundation
import Synchronization
import Testing

private final class ConsentDefaults {
    let name = "TokenBarConsentTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { defaults.removePersistentDomain(forName: name) }
}

@Suite struct ClaudeAccessPolicyTests {
    @Test func legacyPreferencesDoNotGrantEitherCapability() {
        let fixture = ConsentDefaults(); let defaults = fixture.defaults
        defaults.set(true, forKey: SettingsKey.claudeOAuth)
        defaults.set(true, forKey: SettingsKey.claudeCLIRefresh)
        #expect(!ClaudeAccessPolicy.canReadCredentials(in: defaults))
        #expect(!ClaudeAccessPolicy.canRunCLI(in: defaults))
        ClaudeAccessPolicy.grantCredentialRead(in: defaults)
        #expect(ClaudeAccessPolicy.canReadCredentials(in: defaults))
        #expect(ClaudeAccessPolicy.canRunCLI(in: defaults))   // on by default once connected
        defaults.set(false, forKey: SettingsKey.claudeCLIConsent)
        #expect(!ClaudeAccessPolicy.canRunCLI(in: defaults))
        defaults.set(true, forKey: SettingsKey.claudeCLIConsent)
        #expect(ClaudeAccessPolicy.canRunCLI(in: defaults))
        defaults.set(["p": 42], forKey: ClaudeUsageClient.savedKey)
        ClaudeAccessPolicy.revoke(in: defaults)
        #expect(!ClaudeAccessPolicy.canReadCredentials(in: defaults))
        #expect(!ClaudeAccessPolicy.canRunCLI(in: defaults))
        #expect(defaults.object(forKey: ClaudeUsageClient.savedKey) == nil)
        ClaudeAccessPolicy.grantCredentialRead(in: defaults)
        #expect(ClaudeAccessPolicy.canRunCLI(in: defaults))
    }

    @Test func missingConsentDoesNotReadCredentialCallAPIOrRunCLI() async {
        let fixture = ConsentDefaults(); let calls = Mutex(0)
        let client = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { calls.withLock { $0 += 1 }; return .success(("fixture", .distantPast)) },
            transport: { _ in calls.withLock { $0 += 1 }; throw CancellationError() },
            refreshCredential: { calls.withLock { $0 += 1 }; return true }, hasConsent: { false })
        let (rate, status) = await client.fetch()
        #expect(rate == nil && status == .consentRequired)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func revocationDiscardsInFlightResponseAndPersistentCache() async {
        let fixture = ConsentDefaults(); let granted = Mutex(true)
        let client = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { .success(("fixture", nil)) },
            transport: { request in
                granted.withLock { $0 = false }
                return (Data(#"{"five_hour":{"utilization":42}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, hasConsent: { granted.withLock { $0 } })
        let (rate, status) = await client.fetch()
        #expect(rate == nil && status == .consentRequired)
        #expect(fixture.defaults.object(forKey: ClaudeUsageClient.savedKey) == nil)
        #expect(await client.fetch().1 == .consentRequired)
    }

    @Test func credentialsChangedDiscardsResponseForOldCredential() async {
        let fixture = ConsentDefaults()
        // A test transport holds its request until consent/credential generation changes.
        let gate = ResponseGate()
        let client = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { .success(("fixture", nil)) },
            transport: { request in
                await gate.wait()
                return (Data(#"{"five_hour":{"utilization":42}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, hasConsent: { true })
        let request = Task { await client.fetch() }
        await gate.waitUntilStarted()
        await client.credentialsChanged()
        await gate.release()
        #expect(await request.value.0 == nil)
        #expect(fixture.defaults.object(forKey: ClaudeUsageClient.savedKey) == nil)
    }

    @Test func resetBoundaryInvalidatesMemoryCacheWithoutExtraRequest() async {
        let fixture = ConsentDefaults(); let calls = Mutex(0); let now = Date()
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let body = Data("{\"five_hour\":{\"utilization\":42,\"resets_at\":\"\(reset)\"}}".utf8)
        let client = ClaudeUsageClient(defaultsSuite: fixture.name, readToken: { .success(("fixture", nil)) },
            transport: { request in
                calls.withLock { $0 += 1 }
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, hasConsent: { true })
        _ = await client.fetch(now: now)
        #expect(await client.fetch(now: now.addingTimeInterval(90)).0?.primary?.usedPercent == 0)
        #expect(calls.withLock { $0 } == 1)
    }
}

private actor ResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite struct ClaudeConsentBoundaryTests {
    @Test func revokedConsentDuringCLIRefreshPreventsSecondCredentialRead() async {
        let fixture = ConsentDefaults(); let consent = Mutex(true); let reads = Mutex(0)
        let client = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { reads.withLock { $0 += 1 }; return .success(("fixture", .distantPast)) },
            transport: { _ in Issue.record("Revoked consent must prevent HTTP"); throw CancellationError() },
            refreshCredential: { consent.withLock { $0 = false }; return true },
            hasConsent: { consent.withLock { $0 } })
        #expect(await client.fetch().1 == .consentRequired)
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func reauthorizationAfterDenialCanRetryImmediately() async {
        let fixture = ConsentDefaults(); let consent = Mutex(false); let now = Date()
        let client = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { .success(("fixture", nil)) },
            transport: { request in
                (Data(#"{"five_hour":{"utilization":12}}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, hasConsent: { consent.withLock { $0 } })
        #expect(await client.fetch(now: now).1 == .consentRequired)
        consent.withLock { $0 = true }
        await client.credentialsChanged()
        #expect(await client.fetch(now: now.addingTimeInterval(1)).0?.primary?.usedPercent == 12)
    }

    @Test func rateLimitedRelaunchDoesNotResurrectSavedSuccess() async {
        let fixture = ConsentDefaults(); let now = Date()
        fixture.defaults.set(["p": 42.0, "fetched": now], forKey: ClaudeUsageClient.savedKey)
        let transport: ClaudeUsageClient.Transport = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                    headerFields: ["Retry-After": "600"])!)
        }
        let first = ClaudeUsageClient(defaultsSuite: fixture.name, readToken: { .success(("fixture", nil)) },
                                      transport: transport, hasConsent: { true })
        #expect(await first.fetch(now: now).1 == .waiting(now.addingTimeInterval(600)))
        let second = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { Issue.record("Backoff must not read credentials"); return .failure(.failed) },
            transport: transport, hasConsent: { true })
        let (rate, status) = await second.fetch(now: now.addingTimeInterval(30))
        #expect(rate == nil && status == .waiting(now.addingTimeInterval(600)))
    }
}

@Suite struct ClaudeManualRecoveryTests {
    @Test func manualCheckDoesNotLaunchAnotherBackgroundRepair() async {
        let fixture = ConsentDefaults(); let calls = Mutex(0)
        let client = ClaudeUsageClient(defaultsSuite: fixture.name,
            readToken: { .success(("fixture", .distantPast)) },
            transport: { _ in Issue.record("Expired token must not be sent"); throw CancellationError() },
            refreshCredential: { calls.withLock { $0 += 1 }; return true }, hasConsent: { true })
        #expect(await client.fetch(allowAutomaticRefresh: false).1 == .expired)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func userReconnectionRetries401WithoutWaitingFiveMinutes() async {
        let fixture = ConsentDefaults(); let code = Mutex(401); let now = Date()
        let client = ClaudeUsageClient(defaultsSuite: fixture.name, readToken: { .success(("fixture", nil)) },
            transport: { request in
                let status = code.withLock { $0 }
                return (Data(#"{"five_hour":{"utilization":12}}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, hasConsent: { true })
        #expect(await client.fetch(now: now).1 == .httpError(401))
        code.withLock { $0 = 200 }
        await client.credentialsChanged()
        #expect(await client.fetch(now: now.addingTimeInterval(1)).1 == .ok)
    }
}
