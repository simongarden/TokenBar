import SwiftUI
import Observation
import os

private let log = Logger(subsystem: "com.okmaster.TokenBar", category: "usage")

@MainActor @Observable
final class UsageStore {
    var summaries: [ServiceSummary] = Service.allCases.map {
        ServiceSummary(service: $0, available: false, reason: "掃描中…")
    }
    var lastUpdated: Date?
    var isRefreshing = false
    var claudeStatus: ClaudeUsageClient.Status?
    private let scanner = UsageScanner()
    private let claudeClient = ClaudeUsageClient()
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [SettingsKey.labelMode: LabelMode.mixed.rawValue,
                                                  SettingsKey.claudeOAuth: true,
                                                  SettingsKey.claude5hLimit: 0,
                                                  SettingsKey.geminiDailyLimit: 0])
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let d = UserDefaults.standard
        var s = await scanner.scanAll(claude5hLimit: d.integer(forKey: SettingsKey.claude5hLimit),
                                      geminiDailyLimit: d.integer(forKey: SettingsKey.geminiDailyLimit))
        if d.bool(forKey: SettingsKey.claudeOAuth) {
            let (rate, st) = await claudeClient.fetch()
            claudeStatus = st
            log.notice("Claude usage API status: \(String(describing: st), privacy: .public)")
            if let rate, let i = s.firstIndex(where: { $0.service == .claude }) {
                s[i].rate = rate
                if let r = rate.primary?.resetsAt, r > .now {
                    let start = r.addingTimeInterval(-5 * 3600)
                    s[i].periodStart = start
                    s[i].periodTokens = await scanner.windowTokens(.claude, since: start).total
                    s[i].periodSource = "官方 5 小時視窗（\(start.formatted(date: .omitted, time: .shortened)) 起，本機 jsonl 統計）"
                }
            }
        } else { claudeStatus = nil }
        summaries = s
        lastUpdated = .now
        isRefreshing = false
    }

    var todayTotal: Int { summaries.reduce(0) { $0 + $1.today.total } }
}

struct MenuBarLabelContent: View {
    let summaries: [ServiceSummary]
    let mode: LabelMode
    var body: some View {
        HStack(spacing: 5) {
            ForEach(summaries) { s in
                HStack(spacing: 2) {
                    Image(systemName: s.service.symbol).font(.system(size: 11, weight: .semibold))
                    Text(text(s)).lineLimit(1).fixedSize()
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 1)
        .fixedSize()
    }

    private func text(_ s: ServiceSummary) -> String {
        switch mode {
        case .mixed: s.mixedValue.text
        case .percent: percentText(s.rate)
        case .tokens: s.available ? compactNumber(s.today.total) : "—"
        }
    }
}

@main
struct TokenBarApp: App {
    @State private var store = UsageStore()
    @AppStorage(SettingsKey.labelMode) private var modeRaw = LabelMode.mixed.rawValue

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            Image(nsImage: labelImage())
        }
        .menuBarExtraStyle(.window)
    }

    /// Render as a single monochrome template image so it adapts to light/dark menu bars.
    @MainActor private func labelImage() -> NSImage {
        let r = ImageRenderer(content: MenuBarLabelContent(summaries: store.summaries,
                                                           mode: LabelMode(rawValue: modeRaw) ?? .percent))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        let img = r.nsImage ?? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)!
        img.isTemplate = true
        return img
    }
}
