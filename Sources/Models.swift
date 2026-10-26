import Foundation

struct TokenBreakdown: Sendable, Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0
    var total: Int { input + output + cacheRead + cacheWrite }
    static func + (l: Self, r: Self) -> Self {
        .init(input: l.input + r.input, output: l.output + r.output,
              cacheRead: l.cacheRead + r.cacheRead, cacheWrite: l.cacheWrite + r.cacheWrite)
    }
    static func += (l: inout Self, r: Self) { l = l + r }
}

enum Service: String, CaseIterable, Sendable, Identifiable {
    /// `grok` is the Grok Build CLI; its raw value stays clear of the older "grok" preference key,
    /// which belongs to the Grok Bot activity icon.
    case claude, codex, grok = "grokcli"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        }
    }
    var logoMono: String {
        switch self { case .claude: "LogoClaudeMono"; case .codex: "LogoCodexMono"; case .grok: "LogoGrokMono" }
    }
    var logoColor: String {
        switch self { case .claude: "LogoClaudeColor"; case .codex: "LogoCodexColor"; case .grok: "LogoGrokMono" }
    }
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "sparkle"
        }
    }
}

struct DailyUsage: Sendable, Identifiable {
    let date: Date
    let tokens: TokenBreakdown
    var id: Date { date }
}

struct ServiceSummary: Sendable, Identifiable {
    let service: Service
    var available: Bool
    var reason: String?
    var today = TokenBreakdown()
    var week = TokenBreakdown()
    var month = TokenBreakdown()
    var last7: [DailyUsage] = []
    var sourceNote: String = ""
    var fileCount = 0
    var rate: RateInfo?
    /// Subscription plan for display (e.g. "Team 進階席位", "Max 5x", "Plus"); nil when unknown.
    var plan: String?
    var periodTokens: Int?
    var periodStart: Date?
    var periodSource: String?
    var id: Service { service }
}

/// yyyymmdd in the local calendar
typealias DayKey = Int

extension Date {
    var dayKey: DayKey {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: self)
        return c.year! * 10000 + c.month! * 100 + c.day!
    }
}

func compactNumber(_ n: Int) -> String {
    let d = Double(n)
    switch n {
    case 1_000_000_000...: return String(format: "%.2fB", d / 1e9)
    case 1_000_000...: return String(format: "%.1fM", d / 1e6)
    case 1_000...: return String(format: "%.1fK", d / 1e3)
    default: return "\(n)"
    }
}

struct RateWindow: Sendable, Equatable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
}

struct RateInfo: Sendable, Equatable {
    var primary: RateWindow?      // 5h
    var secondary: RateWindow?    // weekly
    var isEstimate: Bool
    var source: String
    var updatedAt: Date?
}

enum LabelMode: String, CaseIterable, Sendable {
    case mixed, percent, tokens
}

enum ValueKind: String, Sendable { case percent = "百分比", period = "本週期", today = "今日", none = "無資料" }

extension ServiceSummary {
    /// Mixed mode: % of current window → tokens in current window → today's tokens.
    var mixedValue: (text: String, kind: ValueKind) {
        if rate?.primary != nil { return (percentText(rate), .percent) }
        if let p = periodTokens { return (compactNumber(p), .period) }
        if available { return (compactNumber(today.total), .today) }
        return ("—", .none)
    }
}

enum SettingsKey {
    static let labelMode = "menuBarLabelMode"
    static let claudeOAuth = "claudeUseOAuth"
    static let claude5hLimit = "claude5hTokenLimit"
    static let claudeCredentialConsent = "claudeCredentialReadConsentV1"
    static let claudeCLIConsent = "claudeBackgroundCLIConsentV1"
    static let claudeCLIRefresh = "claudeCLIRefreshOnExpiry"
    static let grokQuota = "grokQuotaFromCLILogin"
    static let grokCLIRefresh = "grokCLIRefreshOnExpiry"
}

func percentText(_ r: RateInfo?) -> String {
    guard let p = r?.primary?.usedPercent else { return "—" }
    return (r!.isEstimate ? "~" : "") + "\(Int(p.rounded()))%"
}

/// Display names for the subscription plan. The inputs are undocumented fields written by Claude Code /
/// Codex, so anything unrecognized degrades to a plain capitalized name, or nil, never an error.
enum PlanName {
    /// Claude Code's `~/.claude.json` → `oauthAccount`. Claude Code itself treats
    /// subscription "team" + rate-limit tier "default_claude_max_5x" as a Team premium seat
    /// (`isTeamPremiumSubscriber`); `seatTier` is not used for that.
    static func claude(organizationType: String?, rateLimitTier: String?) -> String? {
        let type = organizationType?.lowercased().replacingOccurrences(of: "claude_", with: "")
        let tier = rateLimitTier?.lowercased() ?? ""
        let maxTier = tier.contains("max_20x") ? "Max 20x" : tier.contains("max_5x") ? "Max 5x" : nil
        switch type {
        case "team"?:
            if rateLimitTier == nil { return "Team" }
            return tier == "default_claude_max_5x" ? "Team 進階席位" : "Team 標準席位"
        case "max"?: return maxTier ?? "Max"
        case "pro"?: return "Pro"
        case "enterprise"?: return "Enterprise"
        case "free"?: return "Free"
        case let t? where !t.isEmpty: return capitalized(t)
        default: return maxTier
        }
    }

    /// Codex `plan_type` (token_count rate_limits, or the id_token's `chatgpt_plan_type`).
    static func codex(_ planType: String?) -> String? {
        guard let p = planType?.lowercased(), !p.isEmpty else { return nil }
        return ["plus": "Plus", "pro": "Pro", "team": "Team", "business": "Business", "enterprise": "Enterprise",
                "edu": "Edu", "free": "Free", "go": "Go"][p] ?? capitalized(p)
    }

    /// Grok CLI `subscription_tier_display` / credits `subscriptionTier` (e.g. "SuperGrok Heavy").
    static func grok(_ tier: String?) -> String? {
        guard let t = tier?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let key = t.lowercased().replacingOccurrences(of: "_", with: " ")
        if key.contains("heavy") { return "SuperGrok Heavy" }
        if key.contains("supergrok") || key.contains("super grok") { return "SuperGrok" }
        return t.contains(" ") || t.contains(where: \.isUppercase) ? t : capitalized(t)
    }

    /// Settings row subtitle: "<email> · <plan>", either part omitted when unknown.
    static func accountLine(_ email: String?, _ plan: String?) -> String {
        let parts = [email, plan].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "本機已有使用記錄" : parts.joined(separator: " · ")
    }

    private static func capitalized(_ s: String) -> String {
        s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Menu bar meter segments: the 5-hour window has 10 (10% each), a weekly window 7 (about one day
/// each), so "filled segments vs. days elapsed" shows at a glance whether the week is overspent.
enum MeterScale {
    static func segments(windowMinutes: Int?, weeklyIfUnknown: Bool) -> Int {
        guard let m = windowMinutes else { return weeklyIfUnknown ? 7 : 10 }
        return m > 24 * 60 ? 7 : 10
    }

    /// Any usage lights at least one segment; 100% (or more) lights them all.
    static func filled(percent: Double, segments: Int) -> Int {
        guard percent > 0, segments > 0 else { return 0 }
        return min(segments, Int((percent / (100 / Double(segments))).rounded(.up)))
    }
}
