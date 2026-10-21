import Foundation
import Testing

@Suite struct PlanNameTests {
    @Test func claudeTeamSeats() {
        // Claude Code's isTeamPremiumSubscriber: team + default_claude_max_5x.
        #expect(PlanName.claude(organizationType: "claude_team", rateLimitTier: "default_claude_max_5x") == "Team 進階席位")
        #expect(PlanName.claude(organizationType: "claude_team", rateLimitTier: "default_claude_ai") == "Team 標準席位")
        #expect(PlanName.claude(organizationType: "claude_team", rateLimitTier: nil) == "Team")
    }

    @Test func claudeIndividualPlans() {
        #expect(PlanName.claude(organizationType: "claude_max", rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(PlanName.claude(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
        #expect(PlanName.claude(organizationType: "claude_max", rateLimitTier: nil) == "Max")
        #expect(PlanName.claude(organizationType: "claude_pro", rateLimitTier: "default_claude_ai") == "Pro")
        #expect(PlanName.claude(organizationType: "claude_enterprise", rateLimitTier: nil) == "Enterprise")
    }

    @Test func claudeUnknownValuesDegrade() {
        #expect(PlanName.claude(organizationType: "claude_new_plan", rateLimitTier: nil) == "New Plan")
        #expect(PlanName.claude(organizationType: nil, rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(PlanName.claude(organizationType: nil, rateLimitTier: nil) == nil)
        #expect(PlanName.claude(organizationType: "", rateLimitTier: "default_claude_ai") == nil)
    }

    @Test func settingsAccountLine() {
        #expect(PlanName.accountLine("a@b.com", "Team 進階席位") == "a@b.com · Team 進階席位")
        #expect(PlanName.accountLine("a@b.com", nil) == "a@b.com")
        #expect(PlanName.accountLine(nil, "Plus") == "Plus")
        #expect(PlanName.accountLine(nil, nil) == "本機已有使用記錄")
        #expect(!PlanName.accountLine("a@b.com", "Team").contains("已偵測到"))
    }

    @Test func codexPlans() {
        #expect(PlanName.codex("team") == "Team")
        #expect(PlanName.codex("PLUS") == "Plus")
        #expect(PlanName.codex("business") == "Business")
        #expect(PlanName.codex("self_serve_business") == "Self Serve Business")
        #expect(PlanName.codex("") == nil)
        #expect(PlanName.codex(nil) == nil)
    }
}

/// Plan read from the files Claude Code / Codex leave in a (fake) home directory.
@Suite struct ScannerPlanTests {
    let home: URL
    private let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "TokenBarPlan-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".claude/projects/p"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".codex/sessions/2026/10/21"), withIntermediateDirectories: true)
    }

    private func json(_ obj: Any, _ rel: String) throws {
        try JSONSerialization.data(withJSONObject: obj).write(to: home.appending(path: rel))
    }

    private func idToken(plan: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_plan_type": plan]])
        let b64 = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(b64).sig"
    }

    private func tokenCount(plan: String, at date: String) throws -> String {
        let row: [String: Any] = ["timestamp": date, "type": "event_msg",
                                  "payload": ["type": "token_count",
                                              "rate_limits": ["plan_type": plan,
                                                              "primary": ["used_percent": 10, "window_minutes": 300]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self)
    }

    @Test func claudePlanFromClaudeJSONNotEmail() async throws {
        try json(["oauthAccount": ["emailAddress": "someone@example.com", "organizationType": "claude_team",
                                   "userRateLimitTier": "default_claude_max_5x", "seatTier": "team_tier_1"]], ".claude.json")
        let s = await UsageScanner(home: home).scanAll(claude5hLimit: 0, enabled: [.claude])[0]
        #expect(s.plan == "Team 進階席位")
    }

    @Test func codexPrefersNewestTokenCountOverIDToken() async throws {
        try json(["tokens": ["id_token": idToken(plan: "plus")]], ".codex/auth.json")
        let lines = [try tokenCount(plan: "plus", at: "2026-10-20T01:00:00Z"),
                     try tokenCount(plan: "team", at: "2026-10-21T01:00:00Z")].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: home.appending(path: ".codex/sessions/2026/10/21/a.jsonl"))
        let s = await UsageScanner(home: home).scanAll(claude5hLimit: 0, enabled: [.codex])[0]
        #expect(s.plan == "Team")
    }

    @Test func codexFallsBackToIDToken() async throws {
        try json(["tokens": ["id_token": idToken(plan: "pro")]], ".codex/auth.json")
        let s = await UsageScanner(home: home).scanAll(claude5hLimit: 0, enabled: [.codex])[0]
        #expect(s.plan == "Pro")
    }

    @Test func noPlanWhenFilesMissing() async throws {
        let s = await UsageScanner(home: home).scanAll(claude5hLimit: 0, enabled: [.claude, .codex])
        #expect(s.allSatisfy { $0.plan == nil })
    }
}
