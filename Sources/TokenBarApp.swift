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
    var active: Set<Service> = []
    var activityDetail: [Service: String] = [:]
    private let activity = ActivityMonitor()
    @ObservationIgnored private var activityLoop: Task<Void, Never>?

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
        activityLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollActivity()
                try? await Task.sleep(for: .seconds(2.5))
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

    private func pollActivity() async {
        let r = await activity.poll()
        activityDetail = r.detail
        guard r.active != active else { return }
        let names = r.active.map(\.rawValue).sorted().joined(separator: ",")
        log.notice("activity changed: [\(names, privacy: .public)] \(r.detail.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: "; "), privacy: .public)")
        active = r.active
    }

    var todayTotal: Int { summaries.reduce(0) { $0 + $1.today.total } }
}

struct MenuBarLabelContent: View {
    let summaries: [ServiceSummary]
    let mode: LabelMode
    var active: Set<Service> = []
    var mono: Color = .black
    private func t(_ s: Service) -> Double {
        active.contains(s) ? 1 : 0   // active: full-color logo, idle: template mono
    }
    var body: some View {
        HStack(spacing: 11) {
            ForEach(summaries) { s in
                HStack(spacing: 2) {
                    ZStack {
                        Image(s.service.logoMono).renderingMode(.template).resizable().scaledToFit()
                            .foregroundStyle(mono).opacity(1 - t(s.service))
                        Image(s.service.logoColor).resizable().scaledToFit().opacity(t(s.service))
                    }
                    .frame(width: 14, height: 14)
                    Text(text(s)).lineLimit(1).fixedSize()
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
            }
        }
        .foregroundStyle(mono)
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
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusController(store: UsageStore())
    }
}

/// NSStatusItem + popover. The label is a cached NSImage, redrawn only when values/activity change.
@MainActor final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: UsageStore

    init(store: UsageStore) {
        self.store = store
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView(store: store))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        track()
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let b = item.button {
            NSApp.activate()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    private func track() {
        withObservationTracking {
            _ = store.summaries; _ = store.active
        } onChange: { [weak self] in
            Task { @MainActor in self?.stateChanged(); self?.track() }
        }
        stateChanged()
    }

    private func stateChanged() { redraw() }

    private func redraw() {
        let mode = LabelMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.labelMode) ?? "") ?? .mixed
        let dark = (item.button?.effectiveAppearance ?? NSApp.effectiveAppearance)
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let active = store.active
        let texts = store.summaries.map { "\($0.mixedValue.text)|\(percentText($0.rate))|\($0.today.total)" }.joined(separator: ";")
        let base = "\(texts)|\(mode.rawValue)|\(active.map(\.rawValue).sorted())|\(dark)"
        let img = LabelCache.shared.image(base: base, frame: 0) {
            let r = ImageRenderer(content: MenuBarLabelContent(summaries: store.summaries, mode: mode, active: active,
                                                               mono: active.isEmpty ? .black : (dark ? .white : .black)))
            r.scale = NSScreen.main?.backingScaleFactor ?? 2
            let img = r.nsImage ?? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)!
            img.isTemplate = active.isEmpty   // color frames can't be template; idle stays template
            return img
        }
        if item.button?.image !== img { item.button?.image = img }
    }
}

/// Caches rendered menu-bar frames so the animation is a cheap image swap.
@MainActor final class LabelCache {
    static let shared = LabelCache()
    private var base = ""
    private var frames: [Int: NSImage] = [:]
    func image(base: String, frame: Int, render: () -> NSImage) -> NSImage {
        if base != self.base { self.base = base; frames.removeAll() }
        if let img = frames[frame] { return img }
        let img = render()
        frames[frame] = img
        return img
    }
}
