import Foundation
import Darwin
import LocalAuthentication
import Security
import os

private let clog = Logger(subsystem: "com.okmaster.TokenBar", category: "claude-api")

/// Old API/CLI preferences are not evidence of informed consent to these capabilities.
/// UserDefaults is a UX authorization boundary, not protection from malicious same-user code.
enum ClaudeAccessPolicy {
    static func canReadCredentials(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: SettingsKey.claudeCredentialConsent)
            && defaults.bool(forKey: SettingsKey.claudeOAuth)
    }

    /// Background `claude doctor` is on by default once Claude is connected; the user can turn it off.
    static func canRunCLI(in defaults: UserDefaults = .standard) -> Bool {
        canReadCredentials(in: defaults) && (defaults.object(forKey: SettingsKey.claudeCLIConsent) as? Bool ?? true)
    }

    static func grantCredentialRead(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: SettingsKey.claudeCredentialConsent)
        defaults.set(true, forKey: SettingsKey.claudeOAuth)
    }

    static func revoke(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: SettingsKey.claudeOAuth)
        defaults.set(false, forKey: SettingsKey.claudeCredentialConsent)
        defaults.removeObject(forKey: SettingsKey.claudeCLIConsent)   // a later reconnect starts from the default
        defaults.removeObject(forKey: ClaudeUsageClient.savedKey)
        ClaudeKeychain.setReadMode(.securityTool, defaults)
    }
}

/// Claude Code's login item: background reads require consent and may never prompt.
enum ClaudeKeychain {
    static let service = "Claude Code-credentials"
    // Resolve the legacy UI-fail constant without using a deprecated declaration. Some
    // Keychain paths need this in addition to LAContext.interactionNotAllowed.
    private static let noUIFailurePolicy: String? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail"),
              let value = symbol.assumingMemoryBound(to: CFString?.self).pointee else { return nil }
        return value as String
    }()

    /// `allowUI: false` asks the Keychain not to prompt. Verified 2026-10-21: securityd still shows the
    /// access dialog once Claude Code has rewritten the item, so background reads go through
    /// `SecurityTool` first and only use this path while the item is unchanged since an explicit allow.
    static func copyData(allowUI: Bool) -> (OSStatus, Data?) {
        guard allowUI || ClaudeAccessPolicy.canReadCredentials() else { return (errSecAuthFailed, nil) }
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        if !allowUI {
            let ctx = LAContext(); ctx.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = ctx
            guard let policy = noUIFailurePolicy else { return (errSecInteractionNotAllowed, nil) }
            q[kSecUseAuthenticationUI as String] = policy as CFString
        }
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        return (st, out as? Data)
    }

    /// Attributes only (no ACL check, never prompts): the item's modification date.
    static func modificationDate() -> Date? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? [String: Any])?[kSecAttrModificationDate as String] as? Date
    }

    /// `claudeAiOauth.accessToken` and its expiry (`expiresAt`, epoch milliseconds).
    static func parseToken(_ data: Data) -> (token: String, expiresAt: Date?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let t = oauth["accessToken"] as? String, !t.isEmpty else { return nil }
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

    /// How background reads reach the item. Claude Code stores it with `security add-generic-password -U`,
    /// which keeps `/usr/bin/security` trusted but drops any "Always Allow" given to OKM Skirr, so
    /// `.securityTool` is the normal path. `.keychain` is the fallback after the tool failed: reads stay
    /// silent only while the item is unchanged since the user's explicit allow.
    enum ReadMode: Equatable { case securityTool, keychain(allowedAt: Date?) }
    static let modeKey = "claudeKeychainReadMode"            // "keychain" = fallback; absent = security tool
    static let allowedAtKey = "claudeKeychainAllowedModified" // item modification date at the explicit allow

    static func readMode(_ d: UserDefaults = .standard) -> ReadMode {
        d.string(forKey: modeKey) == "keychain" ? .keychain(allowedAt: d.object(forKey: allowedAtKey) as? Date) : .securityTool
    }

    static func setReadMode(_ m: ReadMode, _ d: UserDefaults = .standard) {
        switch m {
        case .securityTool: d.removeObject(forKey: modeKey); d.removeObject(forKey: allowedAtKey)
        case .keychain(let at): d.set("keychain", forKey: modeKey); d.set(at, forKey: allowedAtKey)
        }
    }

    enum BackgroundStep: Equatable { case securityTool, keychain, askUser }

    /// The fallback never reads an item that changed since the explicit allow: that read would prompt.
    static func backgroundStep(_ mode: ReadMode, modified: Date?) -> BackgroundStep {
        switch mode {
        case .securityTool: .securityTool
        case .keychain(let at): at != nil && at == modified ? .keychain : .askUser
        }
    }

    /// Background read: never shows a prompt. A security-tool failure switches to the fallback and
    /// returns `.denied`, which offers the "允許連接" button instead of retrying every refresh.
    static func readToken() -> Result<(String, Date?), ClaudeUsageClient.Status> {
        guard ClaudeAccessPolicy.canReadCredentials() else { return .failure(.consentRequired) }
        switch backgroundStep(readMode(), modified: modificationDate()) {
        case .securityTool:
            switch SecurityTool.read(service: service) {
            case .success(let data):
                guard let t = parseToken(data) else { return .failure(.failed) }
                return .success((t.token, t.expiresAt))
            case .failure(.notFound): return .failure(.noCredential)
            case .failure(let e):
                clog.notice("security tool read failed: \(String(describing: e), privacy: .public); waiting for an explicit allow")
                setReadMode(.keychain(allowedAt: nil))
                return .failure(.denied)
            }
        case .keychain:
            let (st, data) = copyData(allowUI: false)
            if st != errSecSuccess {
                clog.notice("keychain read OSStatus=\(st, privacy: .public)")
                return .failure(status(for: st))
            }
            guard let data, let t = parseToken(data) else { return .failure(.failed) }
            return .success((t.token, t.expiresAt))
        case .askUser:
            clog.notice("credential item changed since the last allow; waiting for an explicit allow")
            return .failure(.denied)
        }
    }

    /// The explicit "連接／允許連接" action: the security tool first (no prompt), else the Keychain with
    /// the macOS prompt. Records which path worked for later background reads.
    static func authorize() -> OSStatus {
        if case .success(let data) = SecurityTool.read(service: service), parseToken(data) != nil {
            setReadMode(.securityTool)
            return errSecSuccess
        }
        let (st, data) = copyData(allowUI: true)
        guard st == errSecSuccess else { return st }
        guard let data, parseToken(data) != nil else { return errSecDecode }
        setReadMode(.keychain(allowedAt: modificationDate()))
        return errSecSuccess
    }
}

/// Reads a generic password through `/usr/bin/security`, the tool Claude Code itself uses, so the
/// item's own ACL applies instead of a per-app "Always Allow". The secret only passes through a pipe
/// into memory. A run that does not finish within `timeout` (e.g. waiting on a prompt) is killed.
enum SecurityTool {
    enum Failure: Error, Equatable { case notFound, exit(Int32), timedOut, launch }

    static func read(service: String, executable: URL = URL(fileURLWithPath: "/usr/bin/security"),
                     timeout: TimeInterval = 5) -> Result<Data, Failure> {
        let p = Process()
        p.executableURL = executable
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return .failure(.launch) }
        // The token is a few KB, well below the pipe buffer, so reading after exit cannot deadlock.
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return .failure(.timedOut)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        switch p.terminationStatus {
        case 0: return .success(decode(data))
        case 44: return .failure(.notFound)   // errSecItemNotFound
        case let c: return .failure(.exit(c))
        }
    }

    /// `-w` prints the secret plus a newline, or hex when the stored bytes are not printable text.
    static func decode(_ raw: Data) -> Data {
        var d = raw
        while let last = d.last, last == 0x0A || last == 0x0D { d.removeLast() }
        guard let text = String(data: d, encoding: .utf8), !text.isEmpty, text.count % 2 == 0,
              text.allSatisfy(\.isHexDigit), !text.hasPrefix("{") else { return d }
        var bytes = Data(capacity: text.count / 2)
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let b = UInt8(text[i..<j], radix: 16) else { return d }
            bytes.append(b); i = j
        }
        return bytes
    }
}

/// Reads Claude Code's OAuth credential (`claudeAiOauth.accessToken`) from the login Keychain and calls
/// the same endpoint `/usage` uses. Token stays in memory only; never logged.
/// Connection failures: retried once on a new connection (NetworkRetry); the first failure in a row
/// keeps the last good result and retries after 1 min, the second reports `.failed`.
/// Throttling: success → next call ≥ 5 min; 429 → Retry-After or 10→20→40→60 min backoff,
/// persisted in UserDefaults so relaunching does not reset it.
/// Expired credential: asks `refreshCredential` (runs `claude doctor`) at most once per 30 min,
/// then re-reads the Keychain; TokenBar never writes the credential itself.
actor ClaudeUsageClient {
    enum Status: Error, Sendable, Equatable {
        case ok, consentRequired, noCredential, denied, expired, httpError(Int), failed
        case waiting(Date)   // backing off until date
    }

    typealias TokenReader = @Sendable () -> Result<(String, Date?), Status>
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    /// Lets Claude Code refresh its own expired credential; returns false if it did not run
    /// (turned off, CLI not found). Success is judged by re-reading the Keychain afterwards.
    typealias CredentialRefresher = @Sendable () async -> Bool

    static let nextKey = "claudeAPINextAllowed"
    static let backoffKey = "claudeAPIBackoffMinutes"
    static let savedKey = "claudeAPILastResult"
    static let cliRefreshKey = "claudeCLIRefreshLastAttempt"
    private let successInterval: TimeInterval = 5 * 60
    static let cliRefreshInterval: TimeInterval = 30 * 60
    static let networkRetryDelay: TimeInterval = 60

    private let defaults: UserDefaults
    private let readToken: TokenReader
    private let transport: Transport
    private let retryTransport: Transport
    private let refreshCredential: CredentialRefresher?
    private let hasConsent: @Sendable () -> Bool
    /// Consecutive attempts that got no HTTP response at all.
    private var networkFailures = 0
    private var credentialGeneration = 0

    private var token: String?
    private var expiresAt: Date?
    private var cached: RateInfo?
    /// Result of the last attempt in this process; nil until the first one.
    private var lastStatus: Status?
    private var didLoadSaved = false

    /// `defaultsSuite` nil = standard defaults (tests pass a throwaway suite).
    init(defaultsSuite: String? = nil,
         readToken: @escaping TokenReader = { ClaudeKeychain.readToken() },
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
         retryTransport: @escaping Transport = NetworkRetry.freshConnection,
         refreshCredential: CredentialRefresher? = nil,
         hasConsent: @escaping @Sendable () -> Bool = { ClaudeAccessPolicy.canReadCredentials() }) {
        self.defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.readToken = readToken
        self.transport = transport
        self.retryTransport = retryTransport
        self.refreshCredential = refreshCredential
        self.hasConsent = hasConsent
    }

    private var nextAllowed: Date {
        get { defaults.object(forKey: Self.nextKey) as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: Self.nextKey) }
    }
    /// Persisted so relaunching does not re-run the CLI immediately.
    private var lastCLIRefresh: Date {
        get { defaults.object(forKey: Self.cliRefreshKey) as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: Self.cliRefreshKey) }
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
        credentialGeneration += 1
        token = nil; expiresAt = nil; cached = nil
        defaults.removeObject(forKey: Self.savedKey)
        switch lastStatus {
        case .consentRequired?, .denied?, .noCredential?, .expired?, .httpError(401)?: nextAllowed = .distantPast
        default: break
        }
    }

    /// Returns the last result without calling the API unless the throttle window has passed.
    /// While throttled the last attempt's status is kept (an error is not masked by the disk cache).
    func fetch(now: Date = Date(), allowAutomaticRefresh: Bool = true) async -> (RateInfo?, Status) {
        guard hasConsent() else { return denyConsent() }
        let generation = credentialGeneration
        if !didLoadSaved {
            // Launch only: show the last good result until the first real attempt.
            didLoadSaved = true
            if let saved = loadSaved(now: now) { cached = saved; lastStatus = .ok }
        }
        if now < nextAllowed {
            if var rate = cached {
                for key in [\RateInfo.primary, \RateInfo.secondary] {
                    if let reset = rate[keyPath: key]?.resetsAt, reset <= now {
                        rate[keyPath: key]?.usedPercent = 0
                        rate[keyPath: key]?.resetsAt = nil
                    }
                }
                cached = rate
            }
            return (cached, lastStatus ?? .waiting(nextAllowed))
        }
        if token == nil || (expiresAt.map { $0 < now } ?? false) {
            switch readToken() {
            case .success(let t): token = t.0; expiresAt = t.1
            case .failure(let s): return fail(s, now: now)
            }
        }
        if let e = expiresAt, e < now {
            // Never call with an expired token; let Claude Code refresh it, then re-read.
            token = nil
            let didRefresh = allowAutomaticRefresh ? await refreshViaCLI(now: now) : false
            guard hasConsent(), generation == credentialGeneration else { return (nil, .consentRequired) }
            guard didRefresh, case .success(let t) = readToken(), t.1.map({ $0 > now }) ?? true else {
                clog.notice("token expired at \(e.formatted(), privacy: .public); skipping call")
                return fail(.expired, now: now)
            }
            guard hasConsent(), generation == credentialGeneration else { return (nil, .consentRequired) }
            clog.notice("token refreshed by Claude Code CLI")
            token = t.0; expiresAt = t.1
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
            let (data, resp) = try await NetworkRetry.send(req, using: transport, retry: retryTransport,
                                                           log: clog, label: "GET /api/oauth/usage")
            networkFailures = 0
            guard hasConsent(), generation == credentialGeneration else { return (nil, .consentRequired) }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            clog.notice("GET /api/oauth/usage -> \(code, privacy: .public)")
            if code == 429 {
                let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Self.parseRetryAfter)
                backoffMinutes = min(60, max(10, backoffMinutes == 0 ? 10 : backoffMinutes * 2))
                let wait = retry ?? backoffMinutes * 60
                nextAllowed = now.addingTimeInterval(wait)
                clog.notice("429: next attempt at \(self.nextAllowed.formatted(date: .omitted, time: .standard), privacy: .public) (retry-after: \(retry.map { "\(Int($0))s" } ?? "none", privacy: .public))")
                defaults.removeObject(forKey: Self.savedKey)
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
            guard hasConsent(), generation == credentialGeneration else { return (nil, .consentRequired) }
            // No response even on a new connection: the first such failure in a row keeps the last good
            // result on screen and retries sooner; only a second one shows the connection problem.
            if NetworkRetry.isConnectionError(error) {
                networkFailures += 1
                if networkFailures == 1, let cached, lastStatus == .ok {
                    nextAllowed = now.addingTimeInterval(Self.networkRetryDelay)
                    clog.notice("keeping the last result after a connection failure; next attempt in \(Int(Self.networkRetryDelay))s")
                    return (cached, .ok)
                }
            }
            return fail(.failed, now: now)
        }
    }

    private func denyConsent() -> (RateInfo?, Status) {
        credentialGeneration += 1
        token = nil; expiresAt = nil; cached = nil
        defaults.removeObject(forKey: Self.savedKey)
        lastStatus = .consentRequired
        return (nil, .consentRequired)
    }

    /// Runs the refresher unless it ran within `cliRefreshInterval`; true if it ran.
    private func refreshViaCLI(now: Date) async -> Bool {
        guard let refreshCredential, now.timeIntervalSince(lastCLIRefresh) >= Self.cliRefreshInterval else { return false }
        lastCLIRefresh = now   // before awaiting: a failed or slow run must not repeat on the next poll
        return await refreshCredential()
    }

    /// Error: clear the shown result and retry after the normal interval.
    private func fail(_ s: Status, now: Date) -> (RateInfo?, Status) {
        nextAllowed = now.addingTimeInterval(successInterval)
        defaults.removeObject(forKey: Self.savedKey)
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
