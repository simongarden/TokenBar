import SwiftUI
import Observation

@MainActor @Observable
final class UsageStore {
    var summaries: [ServiceSummary] = Service.allCases.map {
        ServiceSummary(service: $0, available: false, reason: "掃描中…")
    }
    var lastUpdated: Date?
    var isRefreshing = false
    private let scanner = UsageScanner()
    @ObservationIgnored private var loop: Task<Void, Never>?

    init() {
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
        summaries = await scanner.scanAll()
        lastUpdated = .now
        isRefreshing = false
    }

    var todayTotal: Int { summaries.reduce(0) { $0 + $1.today.total } }
}

@main
struct TokenBarApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chart.bar.xaxis")
                Text(store.lastUpdated == nil ? "—" : compactNumber(store.todayTotal))
                    .monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
