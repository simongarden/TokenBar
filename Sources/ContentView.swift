import SwiftUI
import Charts
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
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(store.summaries) { ServiceCard(summary: $0, rateNote: rateNote(for: $0)) }
                }
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
                Spacer()
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
                breakdown(summary.month)
                    .padding(.bottom, 11)
                Chart(summary.last7) { d in
                    BarMark(x: .value("日期", d.date, unit: .day),
                            y: .value("Token", d.tokens.total))
                        .foregroundStyle(barStyle)
                        .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                        AxisGridLine()
                        AxisValueLabel { if let n = v.as(Int.self) { Text(compactNumber(n)) } }
                    }
                }
                .font(.caption2)
                .frame(height: 56)
            } else {
                Label(summary.reason ?? "無資料", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
            ProgressView(value: min(w.usedPercent, 100), total: 100)
                .tint(w.usedPercent >= 90 ? .red : w.usedPercent >= 70 ? .orange : summary.service.tint)
            Text((est ? "~" : "") + "\(Int(w.usedPercent.rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold)).frame(width: 40, alignment: .trailing)
            if let r = w.resetsAt {
                Text("重置 " + r.formatted(Calendar.current.isDateInToday(r)
                                            ? .dateTime.hour().minute() : .dateTime.month(.defaultDigits).day().hour().minute()))
                    .font(.caption2).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            }
        }
    }

    private func stat(_ title: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(compactNumber(n)).font(.callout.monospacedDigit().weight(.medium))
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
