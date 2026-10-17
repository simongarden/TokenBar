import Foundation
import Security
import os

private let clog = Logger(subsystem: "com.okmaster.TokenBar", category: "claude-api")

/// Reads Claude Code's OAuth credential (`claudeAiOauth.accessToken`) from the login Keychain and calls
/// the same endpoint `/usage` uses. Token stays in memory only; never logged.
/// Throttling: success → next call ≥ 5 min; 429 → Retry-After or 10→20→40→60 min backoff,
/// persisted in UserDefaults so relaunching does not reset it.
actor ClaudeUsageClient {
    enum Status: Error, Sendable, Equatable {
        case ok, noCredential, denied, expired, httpError(Int), failed
        case waiting(Date)   // backing off until date
    }

    private static let nextKey = "claudeAPINextAllowed"
    private static let backoffKey = "claudeAPIBackoffMinutes"
    private static let lastStatusKey = "claudeAPILastStatus"
    private let successInterval: TimeInterval = 5 * 60

    private var token: String?
    private var expiresAt: Date?
    private var cached: RateInfo?
    private var lastStatus: Status = .failed

    private var nextAllowed: Date {
        get { UserDefaults.standard.object(forKey: Self.nextKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Self.nextKey) }
    }
    private var backoffMinutes: Double {
        get { UserDefaults.standard.double(forKey: Self.backoffKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.backoffKey) }
    }

    /// Returns the last result without calling the API unless the throttle window has passed.
    func fetch() async -> (RateInfo?, Status) {
        let now = Date()
        if now < nextAllowed {
            if cached != nil { return (cached, .ok) }
            if case .ok = lastStatus { return (cached, .ok) }
            return (nil, .waiting(nextAllowed))
        }
        if token == nil || (expiresAt.map { $0 < now } ?? false) {
            switch readKeychain() {
            case .success(let t): token = t.0; expiresAt = t.1
            case .failure(let s):
                lastStatus = s; cached = nil
                nextAllowed = now.addingTimeInterval(successInterval)
                return (nil, s)
            }
        }
        if let e = expiresAt, e < now {
            // Claude Code refreshes the token when it runs; don't call with an expired token.
            token = nil; lastStatus = .expired; cached = nil
            nextAllowed = now.addingTimeInterval(successInterval)
            clog.notice("token expired at \(e.formatted(), privacy: .public); skipping call")
            return (nil, .expired)
        }
        guard let token else { return (nil, .failed) }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("claude-code/\(Self.claudeCodeVersion())", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            clog.notice("GET /api/oauth/usage -> \(code, privacy: .public)")
            if code == 429 {
                let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Self.parseRetryAfter)
                backoffMinutes = min(60, max(10, backoffMinutes == 0 ? 10 : backoffMinutes * 2))
                let wait = retry ?? backoffMinutes * 60
                nextAllowed = Date().addingTimeInterval(wait)
                clog.notice("429: next attempt at \(self.nextAllowed.formatted(date: .omitted, time: .standard), privacy: .public) (retry-after: \(retry.map { "\(Int($0))s" } ?? "none", privacy: .public))")
                lastStatus = .httpError(429); cached = nil
                return (nil, .waiting(nextAllowed))
            }
            guard code == 200 else {
                if code == 401 { self.token = nil }
                nextAllowed = Date().addingTimeInterval(successInterval)
                lastStatus = .httpError(code); cached = nil
                return (nil, lastStatus)
            }
            backoffMinutes = 0
            nextAllowed = Date().addingTimeInterval(successInterval)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lastStatus = .failed; return (nil, .failed)
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
            cached = RateInfo(primary: win("five_hour", 300), secondary: win("seven_day", 10080),
                              isEstimate: false, source: "Anthropic OAuth /api/oauth/usage", updatedAt: Date())
            lastStatus = .ok
            return (cached, .ok)
        } catch {
            nextAllowed = Date().addingTimeInterval(successInterval)
            lastStatus = .failed
            return (nil, .failed)
        }
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

    private func readKeychain() -> Result<(String, Date?), Status> {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "Claude Code-credentials",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return .failure(.noCredential) }
        guard st == errSecSuccess, let data = out as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let t = oauth["accessToken"] as? String else {
            return .failure(st == errSecSuccess ? .failed : .denied)
        }
        // expiresAt is epoch milliseconds
        let exp = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return .success((t, exp))
    }
}
