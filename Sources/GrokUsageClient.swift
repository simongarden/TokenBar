import Foundation
import os

private let glog = Logger(subsystem: "com.okmaster.TokenBar", category: "grok-api")

/// Grok Build CLI login (`grok login`) cached in `$GROK_HOME/auth.json`. Read-only: OKM Skirr never
/// refreshes or rewrites it, and the token stays in memory only (never logged or persisted).
struct GrokCredential: Sendable, Equatable {
    var token: String
    var expiresAt: Date?
    var email: String?

    /// SuperGrok OIDC scope written by `grok login`; the legacy session scope is the fallback.
    static let oidcScopePrefix = "https://auth.x.ai::"

    static func authFile(grokHome: URL = UsageScanner.grokHome()) -> URL { grokHome.appending(path: "auth.json") }

    /// `auth.json` is a map keyed by scope URL; only entries carrying a non-empty `key` count.
    static func parse(_ data: Data) -> GrokCredential? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var oidc: [String: Any]?, legacy: [String: Any]?
        for (scope, value) in root.sorted(by: { $0.key < $1.key }) {
            guard let e = value as? [String: Any], let k = e["key"] as? String, !k.isEmpty else { continue }
            if scope.hasPrefix(oidcScopePrefix) { oidc = oidc ?? e }
            else if scope.contains("/sign-in") { legacy = legacy ?? e }
        }
        guard let e = oidc ?? legacy, let token = e["key"] as? String else { return nil }
        func text(_ k: String) -> String? { (e[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expires = text("expires_at").flatMap { f.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return GrokCredential(token: token, expiresAt: expires, email: text("email"))
    }

    static func read(grokHome: URL = UsageScanner.grokHome()) -> GrokCredential? {
        FileManager.default.contents(atPath: authFile(grokHome: grokHome).path).flatMap(parse)
    }
}

/// Weekly credit pool from the endpoint the Grok CLI itself calls
/// (`cli-chat-proxy.grok.com/v1/billing?format=credits`) plus the plan from `/v1/settings`.
/// Throttling: any attempt → next call ≥ 5 min; 429 → Retry-After or 10→20→40→60 min backoff.
actor GrokUsageClient {
    enum Status: Sendable, Equatable {
        case ok
        case usageUnknown       // period known, percent not published yet (e.g. start of the week)
        case noCredential, expired
        case teamAccount        // 412 "No personal team": team logins have no personal pool
        case httpError(Int), failed
        case waiting(Date)

        var message: String {
            switch self {
            case .ok: "Grok 每週額度"
            case .usageUnknown: "本週額度百分比尚未提供"
            case .noCredential: "尚未登入 Grok"
            case .expired, .httpError(401), .httpError(403): "Grok 需要重新登入"
            case .teamAccount: "團隊帳號沒有個人額度，只顯示本機用量"
            case .httpError(let c): "Grok 額度查詢失敗（HTTP \(c)）"
            case .failed: "Grok 額度查詢失敗"
            case .waiting(let d): "查詢過於頻繁，\(d.formatted(date: .omitted, time: .shortened)) 後重試"
            }
        }
    }

    struct Result: Sendable, Equatable {
        var rate: RateInfo?
        var plan: String?
        var status: Status
    }

    typealias CredentialReader = @Sendable () -> GrokCredential?
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private let interval: TimeInterval = 5 * 60

    private let readCredential: CredentialReader
    private let transport: Transport
    private var nextAllowed = Date.distantPast
    private var backoffMinutes: Double = 0
    private var last: Result?

    init(readCredential: @escaping CredentialReader = { GrokCredential.read() },
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.readCredential = readCredential
        self.transport = transport
    }

    /// A new login or re-enabled quota lookup: forget the last result and allow an immediate call.
    func reset() { nextAllowed = .distantPast; last = nil }

    /// Returns the last result without a network call until the throttle window has passed, except
    /// that a missing/expired login is re-checked locally so a fresh `grok login` shows up right away.
    /// A window whose reset time has passed is shown as 0% until the next fetch.
    func fetch(now: Date = Date()) async -> Result {
        if let s = last?.status, s == .noCredential || s == .expired,
           let e = readCredential().map({ $0.expiresAt ?? .distantFuture }), e > now {
            nextAllowed = .distantPast
        }
        if now < nextAllowed, var r = last {
            if let reset = r.rate?.primary?.resetsAt, reset <= now {
                r.rate?.primary?.usedPercent = 0; r.rate?.primary?.resetsAt = nil
                last = r
            }
            return r
        }
        nextAllowed = now.addingTimeInterval(interval)
        guard let cred = readCredential() else { return remember(.init(status: .noCredential)) }
        // Never send an expired token; the CLI refreshes it on its next run.
        if let e = cred.expiresAt, e <= now { return remember(.init(status: .expired)) }

        let billing: (Data, HTTPURLResponse)
        do { billing = try await get(Self.billingURL, token: cred.token, timeout: 15) }
        catch { return remember(.init(status: .failed)) }
        let code = billing.1.statusCode
        glog.notice("GET /v1/billing -> \(code, privacy: .public)")
        if code == 429 {
            let retry = billing.1.value(forHTTPHeaderField: "Retry-After").flatMap(ClaudeUsageClient.parseRetryAfter)
            backoffMinutes = min(60, max(10, backoffMinutes == 0 ? 10 : backoffMinutes * 2))
            nextAllowed = now.addingTimeInterval(retry ?? backoffMinutes * 60)
            return remember(.init(rate: nil, plan: last?.plan, status: .waiting(nextAllowed)))
        }
        backoffMinutes = 0
        let plan = await fetchPlan(token: cred.token)
        switch code {
        case 200: break
        case 412: return remember(.init(plan: plan, status: .teamAccount))
        default: return remember(.init(plan: plan, status: .httpError(code)))
        }
        guard let credits = Self.parseCredits(billing.0, now: now) else { return remember(.init(plan: plan, status: .failed)) }
        let rate = credits.window.map {
            RateInfo(primary: $0, secondary: nil, isEstimate: false, source: "Grok CLI 每週額度（cli-chat-proxy /v1/billing）", updatedAt: now)
        }
        return remember(.init(rate: rate, plan: plan ?? credits.tier, status: rate == nil ? .usageUnknown : .ok))
    }

    private func remember(_ r: Result) -> Result { last = r; return r }

    /// Optional enrichment: any failure just leaves the plan unknown.
    private func fetchPlan(token: String) async -> String? {
        guard let (data, resp) = try? await get(Self.settingsURL, token: token, timeout: 5), resp.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return PlanName.grok(obj["subscription_tier_display"] as? String)
    }

    private func get(_ url: URL, token: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout
        let (data, resp) = try await transport(req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// `config.creditUsagePercent` (0–100), else `onDemandUsed.val / onDemandCap.val`; reset from
    /// `config.currentPeriod.end`, else `billingPeriodEnd`. A missing percent is unknown, never 0%.
    /// nil when the payload has neither a percent nor a period.
    static func parseCredits(_ data: Data, now: Date = Date()) -> (window: RateWindow?, tier: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = obj["config"] as? [String: Any] else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ v: Any?) -> Date? { (v as? String).flatMap { f.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } }
        func val(_ v: Any?) -> Double? { ((v as? [String: Any])?["val"] as? NSNumber)?.doubleValue }
        let period = config["currentPeriod"] as? [String: Any]
        let currentEnd = date(period?["end"])
        let end = currentEnd ?? date(config["billingPeriodEnd"])
        let start = currentEnd != nil ? date(period?["start"]) : date(config["billingPeriodStart"])
        var percent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue
        if percent == nil, let cap = val(config["onDemandCap"]), cap > 0, let used = val(config["onDemandUsed"]) {
            percent = used / cap * 100
        }
        guard percent != nil || end != nil else { return nil }
        let tier = PlanName.grok((config["subscriptionTier"] ?? obj["subscriptionTier"]) as? String)
        guard let p = percent, p.isFinite else { return (nil, tier) }
        var minutes = 7 * 24 * 60   // the unified-billing pool is weekly
        if let start, let end, end > start, start <= now { minutes = Int(end.timeIntervalSince(start) / 60) }
        return (RateWindow(usedPercent: min(100, max(0, p)), windowMinutes: minutes, resetsAt: end.flatMap { $0 > now ? $0 : nil }), tier)
    }
}
