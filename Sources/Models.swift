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
    case claude, codex, gemini
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini / Antigravity"
        }
    }
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .gemini: "sparkle"
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
    var primary: RateWindow?      // 5h (or daily for Gemini estimate)
    var secondary: RateWindow?    // weekly
    var isEstimate: Bool
    var source: String
    var updatedAt: Date?
}

enum LabelMode: String, CaseIterable, Sendable {
    case percent, tokens
}

enum SettingsKey {
    static let labelMode = "labelMode"
    static let claudeOAuth = "claudeUseOAuth"
    static let claude5hLimit = "claude5hTokenLimit"
    static let geminiDailyLimit = "geminiDailyTokenLimit"
}

func percentText(_ r: RateInfo?) -> String {
    guard let p = r?.primary?.usedPercent else { return "—" }
    return (r!.isEstimate ? "~" : "") + "\(Int(p.rounded()))%"
}
