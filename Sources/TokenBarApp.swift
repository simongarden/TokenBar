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
    var grokActive = false
    var activityDetail: [Service: String] = [:]
    private let activity = ActivityMonitor()
    @ObservationIgnored private var activityLoop: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [SettingsKey.labelMode: LabelMode.mixed.rawValue,
                                                  SettingsKey.claudeOAuth: true,
                                                  SettingsKey.claude5hLimit: 0])
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        NotificationCenter.default.addObserver(forName: .tokenBarPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.claudeClient.credentialsChanged()
                    await self.refresh(); await self.pollActivity()
                }
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
        var s = await scanner.scanAll(claude5hLimit: d.integer(forKey: SettingsKey.claude5hLimit), enabled: Prefs.enabledServices)
        if Prefs.claudeAPI && Prefs.isEnabled(.claude) {
            let (rate, st) = await claudeClient.fetch()
            claudeStatus = st
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
        let r = await activity.poll(enabled: Prefs.enabledServices, grok: Prefs.grokEnabled)
        activityDetail = r.detail
        if (r.grok != nil) != grokActive {
            grokActive = r.grok != nil
            log.notice("grok bot \(self.grokActive ? "ACTIVE" : "IDLE", privacy: .public) \(r.grok ?? "", privacy: .public)")
        }
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
    var grok = false
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
                    if let r = meterRate(s), let p = r.primary {
                        if let w = r.secondary {
                            VStack(alignment: .leading, spacing: 2) {
                                meterRow(p, height: 6, text: countdown(p.resetsAt, weekly: false), size: 8, svc: s.service)
                                meterRow(w, height: 6, text: countdown(w.resetsAt, weekly: true), size: 8, svc: s.service)
                            }
                        } else {
                            meterRow(p, height: 12, text: countdown(p.resetsAt, weekly: (p.windowMinutes ?? 0) > 1440), size: 10, svc: s.service)
                        }
                    } else {
                        Text(text(s)).lineLimit(1).fixedSize()
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(textStyle(s.service))
                    }
                }
            }
            if grok {   // Grok Bot: shown only while working, icon only
                Image("LogoGrokMono").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(mono).frame(width: 14, height: 14)
            }
        }
        .foregroundStyle(mono)
        .padding(.horizontal, 1)
        .fixedSize()
    }

    private func meterRow(_ w: RateWindow, height: CGFloat, text: String?, size: CGFloat, svc: Service) -> some View {
        HStack(spacing: 3) {
            SegmentMeter(percent: w.usedPercent, color: mono, height: height, fills: fills(svc))
            if let text {
                Text(text).font(.system(size: size, weight: .semibold).monospacedDigit())
                    .foregroundStyle(textStyle(svc)).lineLimit(1).fixedSize()
                    .frame(height: height, alignment: .center)
            }
        }
    }

    /// Brand colors for filled segments while active (nil = monochrome).
    private func fills(_ svc: Service) -> [Color]? {
        active.contains(svc) ? svc.segmentColors : nil
    }

    private func textStyle(_ svc: Service) -> AnyShapeStyle {
        guard active.contains(svc) else { return AnyShapeStyle(mono) }
        let c = svc.segmentColors
        return c.count > 1 && c.first != c.last
            ? AnyShapeStyle(LinearGradient(colors: c, startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(c[0])
    }

    /// Percentage tier → draw meters instead of text (estimates included).
    private func meterRate(_ s: ServiceSummary) -> RateInfo? {
        switch mode {
        case .mixed, .percent: return s.rate?.primary != nil ? s.rate : nil
        case .tokens: return nil
        }
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
        if ProcessInfo.processInfo.environment["TOKENBAR_KEYCHAIN_PROBE"] == "1" {
            // Debug: status codes only, no UI, no secret output.
            print("exists(attrs)=\(ProviderDetector.keychainItemExists()) read(noUI)=\(ProviderDetector.keychainStatus(allowUI: false))")
            exit(0)
        }
        if let path = ProcessInfo.processInfo.environment["TOKENBAR_SNAPSHOT"] {
            // Debug: render the popover content to PNG and exit (no status item).
            let store = UsageStore()
            Task { @MainActor in
                while store.lastUpdated == nil { try? await Task.sleep(for: .milliseconds(200)) }
                for sm in store.summaries {
                    let m = sm.last7.map(\.tokens.total).max() ?? 0
                    let row = sm.last7.map { "\($0.date.formatted(.dateTime.month(.defaultDigits).day())) \(compactNumber($0.tokens.total))=\(DayCellsChart.litCount($0.tokens.total, max: m))" }
                    print("\(sm.service.rawValue): " + row.joined(separator: ", "))
                }
                let name = ProcessInfo.processInfo.environment["TOKENBAR_SNAPSHOT_VIEW"] ?? "popover"
                let view: AnyView
                if name.hasPrefix("onboard"), let n = Int(name.dropFirst(7)) {
                    view = AnyView(OnboardingView(initialStep: n) {}.environment(store).frame(width: 520, height: 440))
                } else if name == "settings" {
                    view = AnyView(SettingsView().frame(width: 520, height: 440))
                } else {
                    view = AnyView(ContentView(store: store))
                }
                let wrapped = view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: wrapped)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
            return
        }
        Prefs.migrateIfNeeded()
        Updater.shared.start()
        let store = UsageStore()
        WindowManager.shared.store = store
        controller = StatusController(store: store)
        if !Prefs.onboardingDone { WindowManager.shared.showOnboarding() }
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
        NotificationCenter.default.addObserver(forName: .tokenBarClosePopover, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        track()
        // Countdown text: redraw once a minute; cached image is reused unless the strings changed.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.redraw() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
    }

    private var outsideMonitor: Any?
    private var lastClose = Date.distantPast

    @objc private func toggle() {
        // A transient popover closes itself on mouse-down on the status item; don't immediately reopen.
        if Date().timeIntervalSince(lastClose) < 0.3 { return }
        if popover.isShown { closePopover() }
        else if let b = item.button {
            NSApp.activate()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            // Clicks in other apps / desktop close the popover.
            outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.closePopover() }
            }
        }
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        lastClose = Date()
    }

    private func track() {
        withObservationTracking {
            _ = store.summaries; _ = store.active; _ = store.grokActive
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
        let texts = store.summaries.map {
            "\($0.mixedValue.text)|\(percentText($0.rate))|\($0.today.total)|" +
            "\(countdown($0.rate?.primary?.resetsAt, weekly: false) ?? "")|\(countdown($0.rate?.secondary?.resetsAt, weekly: true) ?? "")"
        }.joined(separator: ";")
        let base = "\(texts)|\(mode.rawValue)|\(active.map(\.rawValue).sorted())|\(dark)|g\(store.grokActive)"
        let img = LabelCache.shared.image(base: base, frame: 0) {
            let r = ImageRenderer(content: MenuBarLabelContent(summaries: store.summaries, mode: mode, active: active, grok: store.grokActive,
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

/// 5 rounded vertical segments, each = 20%; filled = ceil(percent / 20).
struct SegmentMeter: View {
    let percent: Double
    let color: Color
    let height: CGFloat
    var fills: [Color]? = nil
    var filled: Int { percent <= 0 ? 0 : min(5, Int((percent / 20).rounded(.up))) }
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < filled ? (fills?[i] ?? color) : color.opacity(0.25))
                    .frame(width: 3, height: height)
            }
        }
    }
}

extension Service {
    /// Per-segment brand colors (left → right).
    var segmentColors: [Color] {
        func hex(_ v: UInt32) -> Color {
            Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
        }
        switch self {
        case .claude: return Array(repeating: hex(0xD97757), count: 5)   // claude-color.svg
        case .codex: return [0xB1A7FF, 0x96A2FF, 0x7A9DFF, 0x5A6FFF, 0x3941FF].map(hex)   // Codex gradient
        }
    }
}

/// Time until reset: 5h window → "3h20m"/"45m"; weekly → "2d6h"/"5h". nil if unknown or passed.
func countdown(_ date: Date?, weekly: Bool, now: Date = Date()) -> String? {
    guard let date, date > now else { return nil }
    let mins = Int((date.timeIntervalSince(now) / 60).rounded(.up))
    if weekly {
        let h = Int((Double(mins) / 60).rounded(.up))
        return h >= 24 ? "\(h / 24)d\(h % 24)h" : "\(h)h"
    }
    return mins >= 60 ? "\(mins / 60)h\(mins % 60)m" : "\(mins)m"
}
