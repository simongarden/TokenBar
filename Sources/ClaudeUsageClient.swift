import Foundation
import Security

/// Reads Claude Code's own OAuth credential from the login Keychain (macOS shows an
/// authorization prompt the first time) and calls the same usage endpoint `/usage` uses.
/// The token is kept in memory only and never logged.
actor ClaudeUsageClient {
    enum Status: Error, Sendable, Equatable { case ok, noCredential, denied, httpError(Int), failed }

    private var token: String?
    private var cached: RateInfo?
    private var lastFetch: Date?
    private(set) var status: Status = .failed

    func fetch() async -> (RateInfo?, Status) {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 120 { return (cached, status) }
        lastFetch = Date()
        if token == nil {
            switch readKeychain() {
            case .success(let t): token = t
            case .failure(let s): status = s; cached = nil; return (nil, s)
            }
        }
        guard let token else { return (nil, .failed) }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                if code == 401 { self.token = nil }
                if code == 429 { lastFetch = Date().addingTimeInterval(8 * 60) }   // back off ~10 min when throttled   // Claude Code refreshes it; re-read next time
                status = .httpError(code); cached = nil
                return (nil, status)
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status = .failed; return (nil, status)
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
            status = .ok
            return (cached, status)
        } catch {
            status = .failed; return (nil, status)
        }
    }

    private func readKeychain() -> Result<String, Status> {
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
        return .success(t)
    }
}
