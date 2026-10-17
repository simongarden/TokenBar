import Foundation
import Security
import Synchronization
import Testing

/// Counts API calls and returns a fixed response.
private final class FakeAPI: Sendable {
    let calls = Mutex(0)
    let code: Int
    let headers: [String: String]
    let body: Data
    init(code: Int, headers: [String: String] = [:], body: String = "{}") {
        self.code = code; self.headers = headers; self.body = Data(body.utf8)
    }
    var transport: ClaudeUsageClient.Transport {
        { req in
            self.calls.withLock { $0 += 1 }
            return (self.body, HTTPURLResponse(url: req.url!, statusCode: self.code, httpVersion: nil, headerFields: self.headers)!)
        }
    }
    var count: Int { calls.withLock { $0 } }
}

private let okBody = #"{"five_hour":{"utilization":42,"resets_at":"2031-01-01T05:00:00Z"},"seven_day":{"utilization":7}}"#
private let goodToken: ClaudeUsageClient.TokenReader = { .success(("tok", nil)) }

/// A throwaway UserDefaults suite name.
private func freshDefaults() -> String {
    let name = "TokenBarTests-\(UUID().uuidString)"
    UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
    return name
}

@Suite struct ClaudeUsageClientTests {
    let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    @Test func successIsCachedWhileThrottled() async {
        let api = FakeAPI(code: 200, body: okBody)
        let c = ClaudeUsageClient(defaultsSuite: freshDefaults(), readToken: goodToken, transport: api.transport)
        let (r1, s1) = await c.fetch(now: t0)
        #expect(s1 == .ok)
        #expect(r1?.primary?.usedPercent == 42)
        #expect(r1?.secondary?.usedPercent == 7)
        let (r2, s2) = await c.fetch(now: t0.addingTimeInterval(30))
        #expect(s2 == .ok && r2?.primary?.usedPercent == 42)
        #expect(api.count == 1)
        _ = await c.fetch(now: t0.addingTimeInterval(5 * 60 + 1))
        #expect(api.count == 2)
    }

    /// Regression: an error used to be replaced by the disk cache (.ok) on the next 30 s refresh.
    @Test func httpErrorIsNotMaskedBySavedResult() async {
        let d = freshDefaults()
        let warm = ClaudeUsageClient(defaultsSuite: d, readToken: goodToken, transport: FakeAPI(code: 200, body: okBody).transport)
        _ = await warm.fetch(now: t0)

        // Relaunch after the throttle passed; the API now fails.
        let api = FakeAPI(code: 500)
        let c = ClaudeUsageClient(defaultsSuite: d, readToken: goodToken, transport: api.transport)
        let later = t0.addingTimeInterval(10 * 60)
        let (r1, s1) = await c.fetch(now: later)
        #expect(r1 == nil && s1 == .httpError(500))
        let (r2, s2) = await c.fetch(now: later.addingTimeInterval(30))
        #expect(r2 == nil)
        #expect(s2 == .httpError(500))
        #expect(api.count == 1)
    }

    @Test func rateLimitedStaysWaiting() async {
        let api = FakeAPI(code: 429, headers: ["Retry-After": "120"])
        let c = ClaudeUsageClient(defaultsSuite: freshDefaults(), readToken: goodToken, transport: api.transport)
        let (_, s1) = await c.fetch(now: t0)
        #expect(s1 == .waiting(t0.addingTimeInterval(120)))
        let (r2, s2) = await c.fetch(now: t0.addingTimeInterval(30))
        #expect(r2 == nil && s2 == .waiting(t0.addingTimeInterval(120)))
        #expect(api.count == 1)
    }

    @Test func launchShowsSavedResultWithoutCalling() async {
        let d = freshDefaults()
        let warm = ClaudeUsageClient(defaultsSuite: d, readToken: goodToken, transport: FakeAPI(code: 200, body: okBody).transport)
        _ = await warm.fetch(now: t0)
        let api = FakeAPI(code: 200, body: okBody)
        let c = ClaudeUsageClient(defaultsSuite: d, readToken: goodToken, transport: api.transport)
        let (r, s) = await c.fetch(now: t0.addingTimeInterval(60))
        #expect(s == .ok && r?.primary?.usedPercent == 42)
        #expect(api.count == 0)
    }

    @Test func launchDuringBackoffWithoutSavedResultIsWaiting() async {
        let d = freshDefaults()
        let until = t0.addingTimeInterval(600)
        UserDefaults(suiteName: d)!.set(until, forKey: ClaudeUsageClient.nextKey)
        let c = ClaudeUsageClient(defaultsSuite: d, readToken: goodToken, transport: FakeAPI(code: 200).transport)
        let (r, s) = await c.fetch(now: t0)
        #expect(r == nil && s == .waiting(until))
    }

    /// Keychain denial is retried only after the interval, and (via `credentialsChanged`) right after re-authorizing.
    @Test func deniedKeychainIsThrottledUntilCredentialsChange() async {
        let reads = Mutex(0)
        let granted = Mutex(false)
        let reader: ClaudeUsageClient.TokenReader = {
            reads.withLock { $0 += 1 }
            return granted.withLock { $0 } ? .success(("tok", nil)) : .failure(.denied)
        }
        let api = FakeAPI(code: 200, body: okBody)
        let c = ClaudeUsageClient(defaultsSuite: freshDefaults(), readToken: reader, transport: api.transport)
        #expect(await c.fetch(now: t0).1 == .denied)
        #expect(await c.fetch(now: t0.addingTimeInterval(30)).1 == .denied)
        #expect(reads.withLock { $0 } == 1)

        granted.withLock { $0 = true }
        await c.credentialsChanged()
        #expect(await c.fetch(now: t0.addingTimeInterval(60)).1 == .ok)
        #expect(api.count == 1)
    }

    @Test func expiredTokenSkipsCall() async {
        let api = FakeAPI(code: 200, body: okBody)
        let c = ClaudeUsageClient(defaultsSuite: freshDefaults(), readToken: { .success(("tok", Date(timeIntervalSince1970: 1))) },
                                  transport: api.transport)
        #expect(await c.fetch(now: t0).1 == .expired)
        #expect(api.count == 0)
    }
}

@Suite struct ClaudeKeychainTests {
    @Test func backgroundReadFailuresMapToDenied() {
        #expect(ClaudeKeychain.status(for: errSecInteractionNotAllowed) == .denied)
        #expect(ClaudeKeychain.status(for: errSecUserCanceled) == .denied)
        #expect(ClaudeKeychain.status(for: errSecItemNotFound) == .noCredential)
        #expect(ClaudeKeychain.status(for: errSecSuccess) == .ok)
    }

    @Test func parsesTokenAndMillisecondExpiry() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"abc","expiresAt":1900000000000}}"#.utf8)
        let t = try #require(ClaudeKeychain.parseToken(data))
        #expect(t.token == "abc")
        #expect(t.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(ClaudeKeychain.parseToken(Data("{}".utf8)) == nil)
    }
}
