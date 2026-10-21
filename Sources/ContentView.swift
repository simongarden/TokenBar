import SwiftUI

extension Service {
    var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: Color(.sRGB, red: 0x7A/255.0, green: 0x9D/255.0, blue: 1)   // Codex #7A9DFF
        case .grok: Color(white: 0.55)
        }
    }
}

struct ContentView: View {
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if isSnapshot {
                cards   // ImageRenderer can't draw Liquid Glass
            } else {
                GlassEffectContainer(spacing: 8) { cards }
            }
            footer
        }
        .padding(12)
        .frame(width: 380)
        .modifier(SKIRRTheme())
    }

    private func rateNote(for s: ServiceSummary) -> String {
        switch s.service {
        case .claude:
            return ClaudeConnectionPresentation(enabled: Prefs.claudeAPI, status: store.claudeStatus,
                                                needsLogin: store.claudeNeedsLogin).title
        case .codex: return "最近的 token_count 事件中沒有 rate_limits"
        case .grok:
            // The action row below already names the problem; avoid saying it twice.
            if store.grokStatus == .usageUnknown { return GrokUsageClient.Status.usageUnknown.message }
            return store.grokConnection.action == .none && !store.grokAwaitingLogin ? store.grokConnection.title : ""
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(store.summaries) { summary in
                ServiceCard(summary: summary, rateNote: rateNote(for: summary),
                    connection: summary.service == .claude ? ClaudeConnectionPresentation(
                        enabled: Prefs.claudeAPI, status: store.claudeStatus, needsLogin: store.claudeNeedsLogin) : nil,
                    isConnecting: store.isConnectingClaude,
                    grok: summary.service == .grok ? store.grokConnection : nil, grokBusy: store.grokAwaitingLogin,
                    grokAction: {
                        // Installing explains itself first in Settings; signing in starts right away.
                        if store.grokConnection.action == .install { WindowManager.shared.showSettings() }
                        else { store.connectGrok() }
                    })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("SKIRRMark").resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
            Text("OKM SKÍRR").font(.headline).fixedSize()
            Spacer(minLength: 0)
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(store.isRefreshing)
            .help("數據更新").accessibilityLabel("數據更新")
            if let t = store.lastUpdated {
                Text("更新於 \(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { WindowManager.shared.showSettings() } label: {
                Label("設定", systemImage: "gearshape")
            }
            .modifier(GlassButton())
            Spacer()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("結束", systemImage: "power")
            }
            .modifier(GlassButton())
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

struct ServiceCard: View {
    let summary: ServiceSummary
    let rateNote: String
    var connection: ClaudeConnectionPresentation? = nil
    var isConnecting = false
    var grok: GrokConnectionPresentation? = nil
    var grokBusy = false
    var grokAction: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(summary.service.logoColor)
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                Text(summary.service.displayName).font(.subheadline.weight(.semibold))
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let plan = summary.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            rateSection
            if let connection, connection.action != .none {
                HStack {
                    Text(isConnecting ? "正在處理連線…" : connection.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(connection.actionTitle) { WindowManager.shared.showSettings() }
                        .modifier(GlassButton()).controlSize(.small).disabled(isConnecting)
                }
            }
            if let grok, grok.action != .none || grokBusy {
                HStack {
                    Text(grokBusy ? "等待你完成 Grok 登入…" : grok.title).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !grokBusy {
                        Button(grok.actionTitle, action: grokAction)
                            .modifier(GlassButton()).controlSize(.small)
                    }
                }
            }
            if let p = summary.periodTokens {
                HStack(spacing: 4) {
                    Text("本週期").font(.caption2).foregroundStyle(.secondary)
                    Text(compactNumber(p)).font(.caption.monospacedDigit().weight(.semibold))
                    Text(summary.periodSource ?? "").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if summary.available {
                HStack(spacing: 0) {
                    stat("今日", summary.today.total)
                    stat("近 7 日", summary.week.total)
                    stat("本月", summary.month.total)
                }
                .padding(.top, 2)
                breakdown(summary.month)
                    .padding(.bottom, 11)
                DayCellsChart(days: summary.last7, colors: [])
                    .compositingGroup()   // keep explicit colors out of glass vibrancy
            } else if summary.service == .claude, connection?.connected == true {
                Text("已連接 Claude；尚無本機使用 Code 記錄")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summary.service == .grok {
                Text("尚無本機 Grok CLI 使用記錄。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summary.service == .codex {
                Text("尚無本機 Codex 使用記錄；目前僅支援 Codex 用量統計。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label(summary.reason ?? "無資料", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .modifier(CardBackground())
    }

    private var barStyle: AnyShapeStyle {
        switch summary.service {
        case .codex:
            let c = [0xB1A7FF, 0x7A9DFF, 0x3941FF].map { v in
                Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
            }
            return AnyShapeStyle(LinearGradient(colors: c, startPoint: .top, endPoint: .bottom))
        case .claude, .grok:
            return AnyShapeStyle(summary.service.tint.gradient)
        }
    }

    @ViewBuilder private var rateSection: some View {
        if let r = summary.rate {
            VStack(alignment: .leading, spacing: 3) {
                if let p = r.primary { windowRow(p, title: windowTitle(p.windowMinutes), est: r.isEstimate) }
                if let w = r.secondary { windowRow(w, title: "每週", est: r.isEstimate) }
            }
        } else if (summary.service != .codex || summary.available) && !rateNote.isEmpty {
            Label(connection?.detail ?? rateNote, systemImage: "gauge.with.dots.needle.0percent")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windowTitle(_ minutes: Int?) -> String {
        switch minutes ?? 300 {
        case ..<1440: "5 小時"
        case ..<(7 * 1440): "每日"
        case ..<(28 * 1440): "每週"
        default: "每月"
        }
    }

    private func windowRow(_ w: RateWindow, title: String, est: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            LimitBar(fraction: min(w.usedPercent, 100) / 100, fill: MeterStyle.fill(for: w.usedPercent))
            Text((est ? "~" : "") + "\(Int(w.usedPercent.rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold)).frame(width: 40, alignment: .trailing)
                .foregroundStyle(MeterStyle.textColor(for: w.usedPercent))
            if let r = w.resetsAt {
                Text("重置 " + r.formatted(Calendar.current.isDateInToday(r)
                                            ? .dateTime.hour().minute() : .dateTime.month(.defaultDigits).day().hour().minute()))
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            }
        }
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(compactNumber(n)).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ t: TokenBreakdown) -> some View {
        HStack(spacing: 10) {
            Text("本月").foregroundStyle(.secondary)
            item("arrow.down", "輸入", t.input)
            item("arrow.up", "輸出", t.output)
            item("memorychip", "快取讀", t.cacheRead)
            item("square.and.arrow.down", "快取寫", t.cacheWrite)
        }
        .font(.caption2)
    }

    private func item(_ sym: String, _ title: String, _ n: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: sym).foregroundStyle(.secondary)
            Text("\(title) \(compactNumber(n))").monospacedDigit()
        }
    }
}

/// 7 day columns × 10 rounded cells; busiest day = 10 lit, others proportional (≥1 if > 0).
struct DayCellsChart: View {
    let days: [DailyUsage]
    let colors: [Color]          // unused now (lit cells are neutral white/black)
    @Environment(\.colorScheme) private var scheme
    private let rows = 10

    private var maxValue: Int { days.map(\.tokens.total).max() ?? 0 }
    private func lit(_ v: Int) -> Int { DayCellsChart.litCount(v, max: maxValue, rows: rows) }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE"; return f
    }()
    static func weekday(_ d: Date) -> String { weekdayFormatter.string(from: d).uppercased() }   // SUN…SAT

    static func litCount(_ v: Int, max m: Int, rows: Int = 10) -> Int {
        guard v > 0, m > 0 else { return 0 }
        return Swift.max(1, Swift.min(rows, Int((Double(v) / Double(m) * Double(rows)).rounded())))
    }
    private var litColor: Color { MeterStyle.fill }
    private var unlitColor: Color { scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10) }
    /// Color for cell at row r (0 = top) by interpolating the stops.
    private func color(row r: Int) -> Color {
        guard colors.count > 1 else { return colors.first ?? .primary }
        let t = Double(r) / Double(rows - 1) * Double(colors.count - 1)
        let i = min(Int(t), colors.count - 2)
        let f = t - Double(i)
        let a = NSColor(colors[i]).usingColorSpace(.sRGB)!, b = NSColor(colors[i + 1]).usingColorSpace(.sRGB)!
        return Color(.sRGB, red: a.redComponent + (b.redComponent - a.redComponent) * f,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("近 7 日 · 最高 \(compactNumber(maxValue))")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days) { d in
                    let n = lit(d.tokens.total)
                    VStack(spacing: 3) {
                        VStack(spacing: 2) {
                            ForEach(0..<rows, id: \.self) { r in
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(rows - r <= n ? litColor : unlitColor)
                                    .frame(height: 4)
                            }
                        }
                        .help("\(d.date.formatted(.dateTime.month().day()))：\(compactNumber(d.tokens.total))")
                        let today = Calendar.current.isDateInToday(d.date)
                        Text(Self.weekday(d.date))
                            .font(.system(size: 9, weight: today ? .bold : .medium, design: .monospaced))
                            .foregroundStyle(today ? .primary : .secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

let isSnapshot = ProcessInfo.processInfo.environment["TOKENBAR_SNAPSHOT"] != nil

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        if isSnapshot {
            content.background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 14))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }
}

/// Shared fill so the limit bars and the 7-day cells are exactly the same gray.
enum MeterStyle {
    static let fill = Color(nsColor: .secondaryLabelColor)

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: NSColor.Name(name)) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
    static let warning = dynamic("TokenBarWarning", light: 0xB45309, dark: 0xF0A04B)   // >= 70%
    static let danger = dynamic("TokenBarDanger", light: 0xC0362C, dark: 0xF07A6E)     // >= 90%

    static func fill(for percent: Double) -> Color {
        percent >= 90 ? danger : percent >= 70 ? warning : fill
    }
    static func textColor(for percent: Double) -> Color {
        percent >= 90 ? danger : percent >= 70 ? warning : .primary
    }
}

/// Custom limit bar (system ProgressView ignores tint in the non-key popover and renders its own gray).
struct LimitBar: View {
    let fraction: Double
    var fill: Color = MeterStyle.fill
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
                Capsule().fill(fill).frame(width: max(0, g.size.width * fraction))
            }
        }
        .frame(height: 5)
        .compositingGroup()
    }
}
