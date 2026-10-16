import SwiftUI
import Charts
import ServiceManagement

extension Service {
    var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: .teal
        case .gemini: .blue
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
                    ForEach(store.summaries) { ServiceCard(summary: $0) }
                }
            }
            footer
        }
        .padding(12)
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Label("AI Token 用量", systemImage: "chart.bar.xaxis")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: summary.service.symbol)
                    .foregroundStyle(summary.service.tint)
                    .frame(width: 18)
                Text(summary.service.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                if summary.available {
                    Text("今日 \(compactNumber(summary.today.total))")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(summary.service.tint)
                }
            }
            if summary.available {
                HStack(spacing: 0) {
                    stat("今日", summary.today.total)
                    stat("近 7 日", summary.week.total)
                    stat("本月", summary.month.total)
                }
                breakdown(summary.month)
                Chart(summary.last7) { d in
                    BarMark(x: .value("日期", d.date, unit: .day),
                            y: .value("Token", d.tokens.total))
                        .foregroundStyle(summary.service.tint.gradient)
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
            Text(summary.sourceNote)
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
