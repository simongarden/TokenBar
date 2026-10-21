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
    var isConnectingClaude = false
    var claudeNeedsLogin = false
    var claudeConnectionNote: String?
    var grokStatus: GrokUsageClient.Status?
    var grokInstalled = GrokCLI.locate() != nil
    var grokAccount: String?
    /// A setup/login Terminal window is open; the store watches `auth.json` and connects by itself.
    var grokAwaitingLogin = false
    var grokNote: String?
    @ObservationIgnored private var grokWatch: Task<Void, Never>?
    private let scanner = UsageScanner()
    private let grokClient = GrokUsageClient()
    private let claudeClient = ClaudeUsageClient(refreshCredential: ClaudeCLI.refreshIfEnabled)
    @ObservationIgnored private var loop: Task<Void, Never>?
    var active: Set<Service> = []
    var grokActive = false
    var activityDetail: [Service: String] = [:]
    private let activity = ActivityMonitor()
    @ObservationIgnored private var activityLoop: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [SettingsKey.labelMode: LabelMode.mixed.rawValue,
                                                  SettingsKey.claudeOAuth: false,
                                                  SettingsKey.grokQuota: true,
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
                    await self.refresh(); await self.pollActivity()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .tokenBarCredentialsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    await self.claudeClient.credentialsChanged()
                    await self.refresh()
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

    func refresh(allowConnectionAction: Bool = false) async {
        guard !isRefreshing, !isConnectingClaude || allowConnectionAction else { return }
        isRefreshing = true
        let d = UserDefaults.standard
        var s = await scanner.scanAll(claude5hLimit: d.integer(forKey: SettingsKey.claude5hLimit), enabled: Prefs.enabledServices)
        if Prefs.claudeAPI && Prefs.isEnabled(.claude) {
            let (rate, st) = await claudeClient.fetch(allowAutomaticRefresh: !isConnectingClaude)
            claudeStatus = Prefs.claudeAPI ? st : nil
            if st == .ok { claudeNeedsLogin = false; claudeConnectionNote = nil }
            if Prefs.claudeAPI, let rate, let i = s.firstIndex(where: { $0.service == .claude }) {
                s[i].rate = rate
                if let r = rate.primary?.resetsAt, r > .now {
                    let start = r.addingTimeInterval(-5 * 3600)
                    s[i].periodStart = start
                    s[i].periodTokens = await scanner.windowTokens(.claude, since: start).total
                    s[i].periodSource = "官方 5 小時視窗（\(start.formatted(date: .omitted, time: .shortened)) 起，本機 jsonl 統計）"
                }
            }
        } else { claudeStatus = nil }
        grokInstalled = GrokCLI.locate() != nil
        grokAccount = GrokCredential.read()?.email
        if Prefs.grokQuota && Prefs.isEnabled(.grok), let i = s.firstIndex(where: { $0.service == .grok }) {
            let r = await grokClient.fetch()
            grokStatus = r.status
            s[i].rate = r.rate
            s[i].plan = r.plan
        } else { grokStatus = nil }
        summaries = s.filter { Prefs.isEnabled($0.service) }
        lastUpdated = .now
        isRefreshing = false
    }

    /// Called only by an explicit Connect/Repair action. Repair is a one-shot authorization;
    /// it never enables unattended CLI execution for later refreshes.
    func connectClaude(repair: Bool = false) async {
        guard !isConnectingClaude else { return }
        isConnectingClaude = true
        claudeConnectionNote = nil
        defer { isConnectingClaude = false }
        // Serialize with any earlier refresh; new scheduled refreshes wait while this action runs.
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        let authorization = await ProviderDetector.authorizeClaudeKeychain(notify: false)
        guard authorization == .ok else {
            switch authorization {
            case .notFound: claudeStatus = .noCredential; claudeNeedsLogin = true
            case .denied: claudeStatus = .denied
            default: claudeStatus = .failed
            }
            return
        }
        Prefs.setEnabled("claude", true)
        if repair {
            guard let cli = ClaudeCLI.locate() else {
                claudeNeedsLogin = true
                claudeConnectionNote = "尚未找到 Claude Code。請先安裝，再按登入。"
                return
            }
            _ = await cli.runDoctor()
        }
        await claudeClient.credentialsChanged()
        await refresh(allowConnectionAction: true)
        if repair, claudeStatus == .expired || claudeStatus == .httpError(401) {
            claudeNeedsLogin = true
            claudeConnectionNote = "這次需要重新登入。請按「登入 Claude」，完成後再回到這裡。"
        }
    }

    var grokConnection: GrokConnectionPresentation {
        GrokConnectionPresentation(installed: grokInstalled, quotaOn: Prefs.grokQuota, status: grokStatus, account: grokAccount)
    }

    /// The single Grok button: install + sign in, sign in again, or turn the quota lookup back on.
    /// Installing and signing in run only in a Terminal window opened here; nothing runs in the background.
    func connectGrok() {
        Prefs.setEnabled(Service.grok.rawValue, true)
        grokNote = nil
        if grokConnection.action == .enableQuota {
            Prefs.grokQuota = true
            Task { await grokClient.reset(); await refresh() }
            return
        }
        let before = authStamp()
        do {
            let command = try GrokCLI.setupCommandFile(cli: GrokCLI.locate())
            guard NSWorkspace.shared.open(command) else {
                try? FileManager.default.removeItem(at: command.deletingLastPathComponent())
                grokNote = "無法開啟視窗，請稍後再試。"; return
            }
        } catch { grokNote = "視窗無法準備完成，請稍後再試。"; return }
        Prefs.grokQuota = true
        grokAwaitingLogin = true
        NotificationCenter.default.post(name: .tokenBarPrefsChanged, object: nil)
        grokWatch?.cancel()
        grokWatch = Task { [weak self] in
            // Up to 15 minutes: installing can take a while, and the browser login waits on the user.
            for _ in 0..<450 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let stamp = self.authStamp()
                if stamp != before, let c = GrokCredential.read(), (c.expiresAt ?? .distantFuture) > .now {
                    await self.grokClient.reset()
                    self.grokAwaitingLogin = false
                    await self.refresh()
                    return
                }
            }
            self?.grokAwaitingLogin = false
            self?.grokNote = "還沒有偵測到登入。完成登入後，這裡會在下次更新時自動連接。"
        }
    }

    /// `auth.json` modification time; `grok login` rewrites the file.
    private func authStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: GrokCredential.authFile().path))?[.modificationDate] as? Date
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

/// Menu bar label colors. Countdown text, meter tracks and the Grok icon use `text`; the service logo,
/// filled meter segments and value text use `idle`, or `active` while that CLI is working.
struct MenuBarPalette {
    var text: Color, idle: Color, active: Color
    static let gray = Color(white: 0.5)
    /// Dark bar: white when idle (drawn as a template image), black while working.
    static let dark = MenuBarPalette(text: .white, idle: .white, active: .black)
    /// Light bar: gray when idle, black while working.
    static let light = MenuBarPalette(text: .black, idle: gray, active: .black)
}

struct MenuBarLabelContent: View {
    let summaries: [ServiceSummary]
    let mode: LabelMode
    var active: Set<Service> = []
    var grok = false
    var palette: MenuBarPalette = .light
    private var mono: Color { palette.text }
    private func ink(_ s: Service) -> Color { active.contains(s) ? palette.active : palette.idle }
    var body: some View {
        HStack(spacing: 11) {
            ForEach(summaries) { s in
                HStack(spacing: 2) {
                    Image(s.service.logoMono).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(ink(s.service))
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
                            .foregroundStyle(ink(s.service))
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
            SegmentMeter(percent: w.usedPercent, color: mono, height: height, fill: ink(svc),
                         // gray fill: fainter track so filled segments still stand out
                         trackOpacity: ink(svc) == MenuBarPalette.gray ? 0.1 : 0.25)
            if let text {
                Text(text).font(.system(size: size, weight: .semibold).monospacedDigit())
                    .foregroundStyle(mono).lineLimit(1).fixedSize()   // countdown: same color idle or active
                    .frame(height: height, alignment: .center)
            }
        }
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
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SKIRR_SETTINGS_PREVIEW"] {
            let scheme: ColorScheme = ProcessInfo.processInfo.environment["SKIRR_PREVIEW_LIGHT"] == "1" ? .light : .dark
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let providers = [
                ProviderInfo(id: "claude", name: "Claude", logo: "LogoClaudeColor", detected: true,
                             status: "user@example.com · Team 進階席位", help: nil, link: nil),
                ProviderInfo(id: "codex", name: "Codex", logo: "LogoCodexColor", detected: true,
                             status: "user@example.com · Team", help: nil, link: nil),
                ProviderInfo(id: "grok", name: "Grok Bot", logo: "LogoGrokMono", detected: true,
                             status: "僅顯示背景運作狀態，無用量數字", help: nil, link: nil)
            ]
            let root = SettingsView(providers: providers).environment(\.colorScheme, scheme)
                .environment(\.controlActiveState, .key)
                .frame(width: 620, height: 1260)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 620, height: 1260),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                hosting.layoutSubtreeIfNeeded()
                if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
                window.orderOut(nil)
                exit(0)
            }
            return
        }
        #endif
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
                    view = AnyView(SettingsView(store: store).frame(width: 620))
                } else if name == "menubar" {
                    // Menu bar label: dark / light bar × idle / all services active.
                    let all = Set(Service.allCases)
                    let rows: [(String, Color, MenuBarPalette, Set<Service>)] = [
                        ("dark idle", Color(white: 0.16), .dark, []), ("dark active", Color(white: 0.16), .dark, all),
                        ("light idle", Color(white: 0.92), .light, []), ("light active", Color(white: 0.92), .light, all)]
                    view = AnyView(VStack(alignment: .leading, spacing: 6) {
                        ForEach(rows, id: \.0) { r in
                            HStack {
                                Text(r.0).font(.caption.monospaced()).foregroundStyle(.gray).frame(width: 90, alignment: .leading)
                                MenuBarLabelContent(summaries: store.summaries, mode: .mixed, active: r.3, grok: true, palette: r.2)
                                    .padding(.horizontal, 8).padding(.vertical, 4).background(r.1)
                            }
                        }
                    }.padding(10))
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
        // Status items can move between displays without any usage data changing.
        for name in [NSWindow.didChangeBackingPropertiesNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window,
                          window === self.item.button?.window else { return }
                    self.redraw()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
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
        let scale = item.button?.window?.backingScaleFactor
            ?? NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let base = "\(texts)|\(mode.rawValue)|\(active.map(\.rawValue).sorted())|\(dark)|g\(store.grokActive)|scale\(scale)"
        let img = LabelCache.shared.image(base: base, frame: 0) {
            let content = MenuBarLabelContent(summaries: store.summaries, mode: mode, active: active,
                                             grok: store.grokActive, palette: dark ? .dark : .light)
            let img = StatusImageRenderer.image(content, preferredScale: scale)
                ?? NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)!
            // Only the dark idle frame is single-color (white) and can be a template; the light idle frame
            // is gray + black and every active frame is two-tone, so they carry explicit colors.
            img.isTemplate = active.isEmpty && dark
            return img
        }
        if item.button?.image !== img { item.button?.image = img }
    }
}

/// 5 rounded vertical segments, each = 20%; filled = ceil(percent / 20).
struct SegmentMeter: View {
    let percent: Double
    let color: Color
    let height: CGFloat
    /// Filled segments; unfilled ones are `color` at `trackOpacity`.
    var fill: Color? = nil
    var trackOpacity: Double = 0.25
    var filled: Int { percent <= 0 ? 0 : min(5, Int((percent / 20).rounded(.up))) }
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < filled ? (fill ?? color) : color.opacity(trackOpacity))
                    .frame(width: 3, height: height)
            }
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

extension ClaudeCLI {
    /// Expired Claude credential: let Claude Code refresh it with `claude doctor` (setting on, CLI found).
    /// True if the CLI ran; the client re-reads the Keychain to see whether it helped.
    @Sendable static func refreshIfEnabled() async -> Bool {
        guard ClaudeAccessPolicy.canRunCLI() else { return false }
        guard let cli = ClaudeCLI.locate() else {
            log.notice("claude doctor refresh: CLI not found")
            return false
        }
        let code = await cli.runDoctor()
        log.notice("claude doctor refresh: \(cli.executable.path, privacy: .public) exit \(code.map(String.init) ?? "none", privacy: .public)")
        return true
    }
}
