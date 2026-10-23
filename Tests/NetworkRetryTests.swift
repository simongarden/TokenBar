import Foundation
import os
import Testing

/// A scripted network: each call to `transport` takes the next outcome for its path
/// (default: 200 with `body`), and every call is counted.
private final class FakeNet: @unchecked Sendable {
    enum Outcome { case ok, fail(URLError.Code) }
    private let lock = NSLock()
    private var queue: [String: [Outcome]] = [:]
    private(set) var calls: [String: Int] = [:]
    let body: Data
    init(body: Any) { self.body = try! JSONSerialization.data(withJSONObject: body) }

    func script(_ path: String, _ outcomes: Outcome...) { lock.withLock { queue[path, default: []] += outcomes } }
    func count(_ path: String) -> Int { lock.withLock { calls[path] ?? 0 } }

    var transport: NetworkRetry.Transport {
        { req in
            let path = req.url!.path
            let next: Outcome = self.lock.withLock {
                self.calls[path, default: 0] += 1
                return self.queue[path]?.isEmpty == false ? self.queue[path]!.removeFirst() : .ok
            }
            switch next {
            case .ok: return (self.body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            case .fail(let code): throw URLError(code)
            }
        }
    }
}

private let log = Logger(subsystem: "com.okmaster.TokenBarTests", category: "net")
private let t0 = Date(timeIntervalSince1970: 1_900_000_000)
private func req(_ path: String) -> URLRequest { URLRequest(url: URL(string: "https://example.com\(path)")!) }

@Suite struct NetworkRetryTests {
    @Test func transientFailureIsRetriedOnTheFreshTransport() async throws {
        let primary = FakeNet(body: [:]), fresh = FakeNet(body: [:])
        primary.script("/x", .fail(.timedOut))
        let (_, resp) = try await NetworkRetry.send(req("/x"), using: primary.transport, retry: fresh.transport, log: log, label: "t")
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        #expect(primary.count("/x") == 1 && fresh.count("/x") == 1)
    }

    @Test func successAndNonTransientErrorsAreNotRetried() async {
        let primary = FakeNet(body: [:]), fresh = FakeNet(body: [:])
        _ = try? await NetworkRetry.send(req("/ok"), using: primary.transport, retry: fresh.transport, log: log, label: "t")
        primary.script("/cancel", .fail(.cancelled))
        await #expect(throws: URLError.self) {
            try await NetworkRetry.send(req("/cancel"), using: primary.transport, retry: fresh.transport, log: log, label: "t")
        }
        #expect(fresh.count("/ok") == 0 && fresh.count("/cancel") == 0)
    }

    @Test func failedRetryThrowsItsError() async {
        let primary = FakeNet(body: [:]), fresh = FakeNet(body: [:])
        primary.script("/x", .fail(.timedOut)); fresh.script("/x", .fail(.networkConnectionLost))
        do {
            _ = try await NetworkRetry.send(req("/x"), using: primary.transport, retry: fresh.transport, log: log, label: "t")
            Issue.record("expected an error")
        } catch let e as URLError {
            #expect(e.code == .networkConnectionLost)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func transientClassification() {
        for c: URLError.Code in [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet] {
            #expect(NetworkRetry.isTransient(URLError(c)))
        }
        for c: URLError.Code in [.cancelled, .badURL, .userAuthenticationRequired] { #expect(!NetworkRetry.isTransient(URLError(c))) }
        #expect(!NetworkRetry.isTransient(CocoaError(.fileNoSuchFile)))
        #expect(NetworkRetry.describe(URLError(.timedOut)).hasPrefix("URLError -1001"))
    }
}

@Suite struct GrokNetworkFailureTests {
    private let billing = "/v1/billing"
    private func client(_ primary: FakeNet, _ fresh: FakeNet) -> GrokUsageClient {
        GrokUsageClient(readCredential: { GrokCredential(token: "t", expiresAt: nil, email: nil) },
                        transport: primary.transport, retryTransport: fresh.transport)
    }
    private func net() -> FakeNet { FakeNet(body: ["config": ["creditUsagePercent": 12]]) }

    @Test func staleConnectionIsHealedByTheRetry() async {
        let primary = net(), fresh = net()
        let c = client(primary, fresh)
        #expect(await c.fetch(now: t0).status == .ok)
        primary.script(billing, .fail(.timedOut))   // the reused connection is dead
        let r = await c.fetch(now: t0.addingTimeInterval(5 * 60 + 1))
        #expect(r.status == .ok)
        #expect(fresh.count(billing) == 1)
    }

    @Test func oneFailureKeepsLastResultAndRetriesSooner() async {
        let primary = net(), fresh = net()
        let c = client(primary, fresh)
        let good = await c.fetch(now: t0)
        #expect(good.status == .ok)
        primary.script(billing, .fail(.timedOut)); fresh.script(billing, .fail(.timedOut))
        let t1 = t0.addingTimeInterval(5 * 60 + 1)
        #expect(await c.fetch(now: t1) == good)               // not "暫時連不上"
        #expect(await c.fetch(now: t1.addingTimeInterval(30)) == good)   // still throttled, no call
        #expect(primary.count(billing) == 2)
        // A second failure in a row (after the 1-min retry delay) is shown.
        primary.script(billing, .fail(.timedOut)); fresh.script(billing, .fail(.timedOut))
        #expect(await c.fetch(now: t1.addingTimeInterval(61)).status == .failed)
    }

    @Test func successResetsTheFailureCount() async {
        let primary = net(), fresh = net()
        let c = client(primary, fresh)
        _ = await c.fetch(now: t0)
        primary.script(billing, .fail(.timedOut)); fresh.script(billing, .fail(.timedOut))
        #expect(await c.fetch(now: t0.addingTimeInterval(301)).status == .ok)
        #expect(await c.fetch(now: t0.addingTimeInterval(362)).status == .ok)     // recovered
        primary.script(billing, .fail(.timedOut)); fresh.script(billing, .fail(.timedOut))
        #expect(await c.fetch(now: t0.addingTimeInterval(663)).status == .ok)     // first failure again
    }

    @Test func failureWithoutAGoodResultIsShownAtOnce() async {
        let primary = net(), fresh = net()
        primary.script(billing, .fail(.timedOut)); fresh.script(billing, .fail(.timedOut))
        #expect(await client(primary, fresh).fetch(now: t0).status == .failed)
    }
}

@Suite struct ClaudeNetworkFailureTests {
    private let usage = "/api/oauth/usage"
    private func suite() -> String {
        let name = "TokenBarNetTests-\(UUID().uuidString)"
        UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
        return name
    }
    private func client(_ primary: FakeNet, _ fresh: FakeNet) -> ClaudeUsageClient {
        ClaudeUsageClient(defaultsSuite: suite(), readToken: { .success(("tok", nil)) },
                          transport: primary.transport, retryTransport: fresh.transport, hasConsent: { true })
    }
    private func net() -> FakeNet { FakeNet(body: ["five_hour": ["utilization": 42], "seven_day": ["utilization": 7]]) }

    @Test func staleConnectionIsHealedByTheRetry() async {
        let primary = net(), fresh = net()
        let c = client(primary, fresh)
        #expect(await c.fetch(now: t0).1 == .ok)
        primary.script(usage, .fail(.timedOut))
        let (r, s) = await c.fetch(now: t0.addingTimeInterval(301))
        #expect(s == .ok && r?.primary?.usedPercent == 42)
        #expect(fresh.count(usage) == 1)
    }

    @Test func oneFailureKeepsLastResultThenSecondIsShown() async {
        let primary = net(), fresh = net()
        let c = client(primary, fresh)
        _ = await c.fetch(now: t0)
        primary.script(usage, .fail(.timedOut)); fresh.script(usage, .fail(.timedOut))
        let (r1, s1) = await c.fetch(now: t0.addingTimeInterval(301))
        #expect(s1 == .ok && r1?.primary?.usedPercent == 42)
        primary.script(usage, .fail(.timedOut)); fresh.script(usage, .fail(.timedOut))
        let (r2, s2) = await c.fetch(now: t0.addingTimeInterval(362))   // after the 1-min retry delay
        #expect(r2 == nil && s2 == .failed)
    }

    @Test func failureWithoutAGoodResultIsShownAtOnce() async {
        let primary = net(), fresh = net()
        primary.script(usage, .fail(.timedOut)); fresh.script(usage, .fail(.timedOut))
        #expect(await client(primary, fresh).fetch(now: t0).1 == .failed)
    }
}
