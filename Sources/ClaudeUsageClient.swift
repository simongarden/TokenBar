import Foundation
import LocalAuthentication
import Security
import os

private let clog = Logger(subsystem: "com.okmaster.TokenBar", category: "claude-api")

/// Claude Code's login Keychain item. Shared by the API client (background, never prompts)
/// and onboarding/settings (explicit "authorize" button, may prompt).
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"

    /// `allowUI: false` never shows the macOS access prompt: an item the app isn't
    /// "Always Allow"-ed for returns errSecInteractionNotAllowed instead.
    static func copyData(allowUI: Bool) -> (OSStatus, Data?) {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowUI {
            let ctx = LAContext(); ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = ctx
        }
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, out as? Data)
    }

    /// `claudeAiOauth.accessToken` and its expiry (`expiresAt`, epoch milliseconds).
    static func parseToken(_ data: Data) -> (token: String, expiresAt: Date?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let t = oauth["accessToken"] as? String else { return nil }
        let exp = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (t, exp)
    }

    static func status(for st: OSStatus) -> ClaudeUsageClient.Status {
        switch st {
        case errSecSuccess: .ok
        case errSecItemNotFound: .noCredential
        default: .denied   // incl. errSecInteractionNotAllowed: needs the explicit authorize button
        }
    }

    /// Background read: never prompts.
    static func readToken() -> Result<(String, Date?), ClaudeUsageClient.Status> {
        let (st, data) = copyData(allowUI: false)
        if st != errSecSuccess {
            clog.notice("keychain read OSStatus=\(st, privacy: .public)")
            return .failure(status(for: st))
        }
        guard let data, let t = parseToken(data) else { return .failure(.failed) }
        return .success((t.token, t.expiresAt))
    }
}

/// Reads Claude Code's OAuth credential (`claudeAiOauth.accessToken`) from the login Keychain and calls
/// the same endpoint `/usage` uses. Token stays in memory only; never logged.
/// Throttling: success → next call ≥ 5 min; 429 → Retry-After or 10→20→40→60 min backoff,
/// persisted in UserDefaults so relaunching does not reset it.
actor ClaudeUsageClient {
    enum Status: Error, Sendable, Equatable {
        case ok, noCredential, denied, expired, httpError(Int), failed
        case waiting(Date)   // backing off until date
    }

    typealias TokenReader = @Sendable () -> Result<(String, Date?), Status>
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let nextKey = "claudeAPINextAllowed"
    static let backoffKey = "claudeAPIBackoffMinutes"
    static let savedKey = "claudeAPILastResult"
    private let successInterval: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let readToken: TokenReader
    private let transport: Transport

    private var token: String?
    private var expiresAt: Date?
    private var cached: RateInfo?
    /// Result of the last attempt in this process; nil until the first one.
    private var lastStatus: Status?
    private var didLoadSaved = false

    /// `defaultsSuite` nil = standard defaults (tests pass a throwaway suite).
    init(defaultsSuite: String? = nil,
         readToken: @escaping TokenReader = { ClaudeKeychain.readToken() },
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.readToken = readToken
        self.transport = transport
    }

    private var nextAllowed: Date {
        get { defaults.object(forKey: Self.nextKey) as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: Self.nextKey) }
    }
    private var backoffMinutes: Double {
        get { defaults.double(forKey: Self.backoffKey) }
        set { defaults.set(newValue, forKey: Self.backoffKey) }
    }

    private func save(_ r: RateInfo, now: Date) {
        var d: [String: Any] = ["fetched": r.updatedAt ?? now]
        if let p = r.primary { d["p"] = p.usedPercent; d["pr"] = p.resetsAt }
        if let w = r.secondary { d["w"] = w.usedPercent; d["wr"] = w.resetsAt }
        defaults.set(d.compactMapValues { $0 }, forKey: Self.savedKey)
    }

    /// Last successful result from disk; a window whose reset time has passed counts as 0%.
    private func loadSaved(now: Date) -> RateInfo? {
        guard let d = defaults.dictionary(forKey: Self.savedKey) else { return nil }
        func win(_ k: String, _ rk: String, _ mins: Int) -> RateWindow? {
            guard let u = d[k] as? Double else { return nil }
            let r = d[rk] as? Date
            if let r, r < now { return RateWindow(usedPercent: 0, windowMinutes: mins, resetsAt: nil) }
            return RateWindow(usedPercent: u, windowMinutes: mins, resetsAt: r)
        }
        let fetched = d["fetched"] as? Date
        return RateInfo(primary: win("p", "pr", 300), secondary: win("w", "wr", 10080), isEstimate: false,
                        source: "Anthropic OAuth /api/oauth/usage（快取 \(fetched?.formatted(date: .omitted, time: .shortened) ?? "")）",
                        updatedAt: fetched)
    }

    /// Credentials may have changed (re-authorized / toggled): drop the in-memory token and
    /// allow an immediate retry if the last attempt failed on credentials.
    func credentialsChanged() {
        token = nil; expiresAt = nil
        switch lastStatus {
        case .denied?, .noCredential?, .expired?: nextAllowed = .distantPast
        default: break
        }
    }

    /// Returns the last result without calling the API unless the throttle window has passed.
    /// While throttled the last attempt's status is kept (an error is not masked by the disk cache).
    func fetch(now: Date = Date()) async -> (RateInfo?, Status) {
        if !didLoadSaved {
            // Launch only: show the last good result until the first real attempt.
            didLoadSaved = true
            if let saved = loadSaved(now: now) { cached = saved; lastStatus = .ok }
        }
        if now < nextAllowed {
            return (cached, lastStatus ?? .waiting(nextAllowed))
        }
        if token == nil || (expiresAt.map { $0 < now } ?? false) {
            switch readToken() {
            case .success(let t): token = t.0; expiresAt = t.1
            case .failure(let s): return fail(s, now: now)
            }
        }
        if let e = expiresAt, e < now {
            // Claude Code refreshes the token when it runs; don't call with an expired token.
            token = nil
            clog.notice("token expired at \(e.formatted(), privacy: .public); skipping call")
            return fail(.expired, now: now)
        }
        guard let token else { return fail(.failed, now: now) }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-code/\(Self.claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await transport(req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            clog.notice("GET /api/oauth/usage -> \(code, privacy: .public)")
            if code == 429 {
                let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Self.parseRetryAfter)
                backoffMinutes = min(60, max(10, backoffMinutes == 0 ? 10 : backoffMinutes * 2))
                let wait = retry ?? backoffMinutes * 60
                nextAllowed = now.addingTimeInterval(wait)
                clog.notice("429: next attempt at \(self.nextAllowed.formatted(date: .omitted, time: .standard), privacy: .public) (retry-after: \(retry.map { "\(Int($0))s" } ?? "none", privacy: .public))")
                cached = nil; lastStatus = .waiting(nextAllowed)
                return (nil, .waiting(nextAllowed))
            }
            guard code == 200 else {
                if code == 401 { self.token = nil }
                return fail(.httpError(code), now: now)
            }
            backoffMinutes = 0
            nextAllowed = now.addingTimeInterval(successInterval)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return fail(.failed, now: now)
            }
            func win(_ k: String, _ mins: Int) -> RateWindow? {
                guard let d = obj[k] as? [String: Any], let u = d["utilization"] as? NSNumber else { return nil }
                var r: Date?
                if let s = d["resets_at"] as? String {
                    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    r = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
                }
                return RateWindow(usedPercent: u.doubleValue, windowMinutes: mins, resetsAt: r)
            }
            let info = RateInfo(primary: win("five_hour", 300), secondary: win("seven_day", 10080),
                                isEstimate: false, source: "Anthropic OAuth /api/oauth/usage", updatedAt: now)
            cached = info; lastStatus = .ok
            save(info, now: now)
            return (info, .ok)
        } catch {
            return fail(.failed, now: now)
        }
    }

    /// Error: clear the shown result and retry after the normal interval.
    private func fail(_ s: Status, now: Date) -> (RateInfo?, Status) {
        nextAllowed = now.addingTimeInterval(successInterval)
        cached = nil; lastStatus = s
        return (nil, s)
    }

    static func parseRetryAfter(_ v: String) -> TimeInterval? {
        if let s = Double(v.trimmingCharacters(in: .whitespaces)) { return max(60, s) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: v).map { max(60, $0.timeIntervalSinceNow) }
    }

    /// Newest installed Claude Code version (desktop-bundled), e.g. "2.1.299".
    static func claudeCodeVersion() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Claude/claude-code").path
        let vs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.first?.isNumber == true }
        return vs.max { $0.compare($1, options: .numeric) == .orderedAscending } ?? "2.1.299"
    }
}
