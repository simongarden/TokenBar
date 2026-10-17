import SwiftUI
import ServiceManagement

extension Service {
    var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: Color(.sRGB, red: 0x7A/255.0, green: 0x9D/255.0, blue: 1)   // Codex #7A9DFF
        }
    }
}

struct ContentView: View {
    let store: UsageStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
    }

    private func rateNote(for s: ServiceSummary) -> String {
        switch s.service {
        case .claude:
            let st: String = switch store.claudeStatus {
            case nil: "官方 API 已停用"
            case .ok?: ""
            case .noCredential?: "鑰匙圈找不到 Claude Code 憑證"
            case .denied?: "鑰匙圈存取被拒"
            case .httpError(let c)?: "API 錯誤 \(c)"
            case .failed?: "API 讀取失敗"
            case .expired?: "Claude Code 憑證已過期（開啟 Claude Code 後會自動更新）"
            case .waiting(let d)?: "API 限流中，\(d.formatted(date: .omitted, time: .shortened)) 後再試"
            }
            return s.rate == nil ? "\(st)" : st
        case .codex: return "最近的 token_count 事件中沒有 rate_limits"
        }
    }

    private var cards: some View {
        VStack(spacing: 8) {
            ForEach(store.summaries) { ServiceCard(summary: $0, rateNote: rateNote(for: $0)) }
        }
    }

    private var header: some View {
        HStack {
            Label("AI Token Status", systemImage: "chart.bar.xaxis")
                .font(.headline)
            Spacer()
            if let t = store.lastUpdated {
                Text("更新於 \(t.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Toggle("登入時啟動", isOn: $launchAtLogin)
                .toggleStyle(.switch).controlSize(.mini).font(.caption)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Label("立即更新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(store.isRefreshing)
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("結束", systemImage: "power")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

struct ServiceCard: View {
    let summary: ServiceSummary
    let rateNote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(summary.service.logoColor)
                    .resizable().scaledToFit()
                    .frame(width: 18, height: 18)
                Text(summary.service.displayName).font(.subheadline.weight(.semibold))
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let a = summary.account {
                    Text(a).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            rateSection
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
        case .claude:
            return AnyShapeStyle(summary.service.tint.gradient)
        }
    }

    @ViewBuilder private var rateSection: some View {
        if let r = summary.rate {
            VStack(alignment: .leading, spacing: 3) {
                if let p = r.primary { windowRow(p, title: p.windowMinutes == 1440 ? "每日" : "5 小時", est: r.isEstimate) }
                if let w = r.secondary { windowRow(w, title: "每週", est: r.isEstimate) }
            }
        } else {
            Label("用量百分比：— " + rateNote, systemImage: "gauge.with.dots.needle.0percent")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        Text(d.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2).foregroundStyle(Calendar.current.isDateInToday(d.date) ? .primary : .secondary)
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
