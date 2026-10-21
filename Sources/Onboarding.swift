import OSLog
import SwiftUI
import AppKit
import Security
import ServiceManagement

// MARK: - Preferences

enum Prefs {
    static let onboardingDoneKey = "onboardingDone"
    static func key(_ id: String) -> String { "enabled.\(id)" }
    static func isEnabled(_ id: String) -> Bool { UserDefaults.standard.object(forKey: key(id)) as? Bool ?? true }
    static func setEnabled(_ id: String, _ on: Bool) { UserDefaults.standard.set(on, forKey: key(id)) }
    static func isEnabled(_ s: Service) -> Bool { isEnabled(s.rawValue) }
    static var grokEnabled: Bool { isEnabled("grok") }
    static var enabledServices: Set<Service> { Set(Service.allCases.filter { isEnabled($0) }) }
    static var claudeAPI: Bool {
        get { ClaudeAccessPolicy.canReadCredentials() }
        set {
            if !newValue {
                ClaudeAccessPolicy.revoke()
                NotificationCenter.default.post(name: .tokenBarCredentialsChanged, object: nil)
            } else if UserDefaults.standard.bool(forKey: SettingsKey.claudeCredentialConsent) {
                UserDefaults.standard.set(true, forKey: SettingsKey.claudeOAuth)
            }
        }
    }
    /// A separate, explicit opt-in. Legacy default-on preferences never grant CLI execution.
    static var claudeCLIRefresh: Bool {
        get { ClaudeAccessPolicy.canRunCLI() }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.claudeCLIConsent) }
    }

    /// Existing installs (have prior TokenBar data) skip onboarding with everything enabled.
    static func migrateIfNeeded() {
        let d = UserDefaults.standard
        if ProcessInfo.processInfo.environment["TOKENBAR_RESET_ONBOARDING"] == "1" {
            d.removeObject(forKey: onboardingDoneKey); return
        }
        guard d.object(forKey: onboardingDoneKey) == nil else { return }
        if d.object(forKey: ClaudeUsageClient.savedKey) != nil || d.object(forKey: ClaudeUsageClient.nextKey) != nil {
            for id in ["claude", "codex", "grok"] { setEnabled(id, true) }
            d.set(true, forKey: onboardingDoneKey)
        }
    }
    static var onboardingDone: Bool { UserDefaults.standard.bool(forKey: onboardingDoneKey) }
}

extension Notification.Name {
    static let tokenBarClosePopover = Notification.Name("TokenBarClosePopover")
    static let tokenBarPrefsChanged = Notification.Name("TokenBarPrefsChanged")
    static let tokenBarCredentialsChanged = Notification.Name("TokenBarCredentialsChanged")
}

// MARK: - Detection

struct ProviderInfo: Sendable, Identifiable {
    let id: String          // claude / codex / grok
    let name: String
    let logo: String
    let detected: Bool
    let status: String
    let help: String?
    let link: URL?
}

enum ProviderDetector {
    static func detect() -> [ProviderInfo] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // Claude Code
        var cEmail: String?
        if let d = fm.contents(atPath: home + "/.claude.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            cEmail = (o["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
        }
        let cDetected = cEmail != nil || fm.fileExists(atPath: home + "/.claude/projects")
        // Codex
        var xEmail: String?
        if let d = fm.contents(atPath: home + "/.codex/auth.json"),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let jwt = (o["tokens"] as? [String: Any])?["id_token"] as? String {
            let parts = jwt.split(separator: ".")
            if parts.count > 1 {
                var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                b += String(repeating: "=", count: (4 - b.count % 4) % 4)
                if let pd = Data(base64Encoded: b), let p = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] {
                    xEmail = p["email"] as? String
                }
            }
        }
        let xDetected = xEmail != nil || fm.fileExists(atPath: home + "/.codex/sessions")
        let gDetected = fm.fileExists(atPath: "/Applications/Grok Bot.app")
        return [
            ProviderInfo(id: "claude", name: "Claude", logo: "LogoClaudeColor", detected: cDetected,
                         status: cDetected ? (cEmail.map { "已偵測到 · \($0)" } ?? "已偵測到本機記錄") : "未偵測到",
                         help: cDetected ? nil : "請先安裝 Claude Code 並登入 Claude 帳號。",
                         link: URL(string: "https://docs.anthropic.com/en/docs/claude-code")),
            ProviderInfo(id: "codex", name: "Codex", logo: "LogoCodexColor", detected: xDetected,
                         status: xDetected ? (xEmail.map { "已偵測到 · \($0)" } ?? "已偵測到本機記錄") : "未偵測到",
                         help: xDetected ? nil : "請先安裝 Codex App 或 CLI 並登入。",
                         link: URL(string: "https://developers.openai.com/codex")),
            ProviderInfo(id: "grok", name: "Grok Bot", logo: "LogoGrokMono", detected: gDetected,
                         status: (gDetected ? "已偵測到 · " : "未偵測到 · ") + "僅顯示背景運作狀態，無用量數字",
                         help: nil, link: nil),
        ]
    }

    /// Keychain access result for the onboarding/settings UI.
    enum KeychainAuth: Equatable, Sendable {
        case ok, notFound, denied, error(Int32)
        var message: String {
            switch self {
            case .ok: "成功"
            case .notFound: "尚未登入 Claude"
            case .denied: "已拒絕"
            case .error(let c): "錯誤碼 \(c)"
            }
        }
    }

    static func classify(_ st: OSStatus) -> KeychainAuth {
        switch st {
        case errSecSuccess: .ok
        case errSecItemNotFound: .notFound
        case errSecUserCanceled, errSecAuthFailed: .denied   // -128 / -25293
        default: .error(st)
        }
    }

    /// Triggers the Keychain read so macOS shows its access prompt. The app is
    /// activated first: an LSUIElement app that isn't frontmost can get
    /// errSecInteractionNotAllowed (-25308) instead of a prompt.
    @MainActor static func authorizeClaudeKeychain(notify: Bool = true) async -> KeychainAuth {
        NSApp.activate()
        try? await Task.sleep(for: .milliseconds(150))
        let st: OSStatus = await Task.detached {
            let (status, data) = ClaudeKeychain.copyData(allowUI: true)
            guard status == errSecSuccess else { return status }
            guard let data, ClaudeKeychain.parseToken(data) != nil else { return errSecDecode }
            return errSecSuccess
        }.value
        if st == errSecSuccess {
            ClaudeAccessPolicy.grantCredentialRead()
            if notify { NotificationCenter.default.post(name: .tokenBarCredentialsChanged, object: nil) }
        }
        klog.notice("keychain authorize OSStatus=\(st, privacy: .public)")
        return classify(st)
    }

    /// Reads the item (data discarded immediately, never logged); returns only the status.
    nonisolated static func keychainStatus(allowUI: Bool) -> OSStatus {
        ClaudeKeychain.copyData(allowUI: allowUI).0
    }

    /// Existence check that never needs ACL approval (attributes only).
    nonisolated static func keychainItemExists() -> OSStatus {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: ClaudeKeychain.service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out)
    }
}

private let klog = Logger(subsystem: "com.okmaster.TokenBar", category: "keychain")

// MARK: - Window manager

@MainActor final class WindowManager {
    static let shared = WindowManager()
    weak var store: UsageStore?
    private var onboarding: NSWindow?
    private var settings: NSWindow?

    func showOnboarding() {
        NotificationCenter.default.post(name: .tokenBarClosePopover, object: nil)
        settings?.close()
        let view = OnboardingView { [weak self] in
            UserDefaults.standard.set(true, forKey: Prefs.onboardingDoneKey)
            self?.onboarding?.close()
            NotificationCenter.default.post(name: .tokenBarPrefsChanged, object: nil)
        }
        onboarding = present(onboarding, title: "歡迎使用 OKM Skirr", view: AnyView(view.environment(store)))
    }

    func showSettings() {
        NotificationCenter.default.post(name: .tokenBarClosePopover, object: nil)
        if let settings, settings.isVisible {
            NSApp.activate(); settings.makeKeyAndOrderFront(nil); return
        }
        settings = present(settings, title: "設定", view: AnyView(SettingsView(store: store)),
                           size: NSSize(width: 620, height: 820), extendsUnderTitlebar: false)
        settings?.styleMask.insert(.resizable)
        settings?.contentMinSize = NSSize(width: 560, height: 560)
    }

    private func present(_ existing: NSWindow?, title: String, view: AnyView, size: NSSize = NSSize(width: 520, height: 440), extendsUnderTitlebar: Bool = true) -> NSWindow {
        let w = existing ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                                     styleMask: [.titled, .closable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        if extendsUnderTitlebar { w.styleMask.insert(.fullSizeContentView) }
        else { w.styleMask.remove(.fullSizeContentView) }
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .visible
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.contentViewController = NSHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        w.setContentSize(size)
        let mouse = NSEvent.mouseLocation   // center on the screen under the pointer
        if let scr = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = scr.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()   // LSUIElement apps may not be granted activation; still bring the window forward
        return w
    }
}

// MARK: - Shared pieces

struct ProviderRow: View {
    let info: ProviderInfo
    @Binding var on: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(info.logo).resizable().scaledToFit().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name).font(.body.weight(.semibold))
                Text(info.status).font(.caption).foregroundStyle(.secondary)
                if let help = info.help {
                    HStack(spacing: 4) {
                        Text(help).font(.caption2).foregroundStyle(.secondary)
                        if let link = info.link { Link("說明", destination: link).font(.caption2) }
                    }
                }
            }
            Spacer(minLength: 12)
            Toggle(info.name, isOn: $on)
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("啟用 \(info.name)")
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 16))
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var onFinish: () -> Void
    @Environment(UsageStore.self) private var store: UsageStore?
    @State private var step: Int
    @State private var sel: [String: Bool]
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let providers: [ProviderInfo]

    init(initialStep: Int = 1, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let p = ProviderDetector.detect()
        providers = p
        _step = State(initialValue: initialStep)
        _sel = State(initialValue: Dictionary(uniqueKeysWithValues: p.map { ($0.id, $0.detected) }))
    }

    private var steps: [Int] { sel["claude"] == true ? [1, 2, 3, 4] : [1, 2, 4] }
    private var canContinue: Bool { step != 2 || sel.values.contains(true) }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 1: welcome
                case 2: choose
                case 3: authorize
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28).padding(.top, 36)
            footer.padding(20)
        }
        .background(.regularMaterial)
        .modifier(SKIRRTheme())
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 40, weight: .semibold)).foregroundStyle(.tint)
            Text("歡迎使用 OKM SKÍRR").font(.largeTitle.weight(.bold))
            Text("在選單列即時掌握 Claude 與 Codex 的用量、限額與重置時間。")
                .font(.title3).foregroundStyle(.secondary)
            Label("所有資料都只在這台 Mac 上讀取與計算。", systemImage: "lock.shield")
            Label("不收集、不上傳任何使用記錄或對話內容。", systemImage: "icloud.slash")
            Label("只讀取各工具留在本機的記錄檔，不會修改它們。", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("選擇要顯示的服務").font(.title2.weight(.bold))
            Text("已自動偵測本機安裝狀態；偵測到的服務已預先啟用。").font(.callout).foregroundStyle(.secondary)
            ForEach(providers) { p in
                ProviderRow(info: p, on: Binding(get: { sel[p.id] ?? false }, set: { sel[p.id] = $0 }))
            }
            if !sel.values.contains(true) {
                Text("請至少選擇一項服務。").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var authorize: some View {
        let connection = ClaudeConnectionPresentation(enabled: Prefs.claudeAPI, status: store?.claudeStatus,
                                                       needsLogin: store?.claudeNeedsLogin == true)
        return VStack(alignment: .leading, spacing: 14) {
            Text("連接 Claude").font(.title2.weight(.bold))
            Text("連接後就能看到用量與重置時間。你也可以稍後再設定，先查看本機用量。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ClaudeConnectionPanel(presentation: connection, busy: store?.isConnectingClaude == true,
                                  note: store?.claudeConnectionNote, action: {
                if connection.action == .connect {
                    Task { await store?.connectClaude() }
                } else { WindowManager.shared.showSettings() }
            })
            Text("macOS 可能要求你允許存取 Claude 登入資料。你可隨時到設定中斷連接。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(.green)
            Text("設定完成").font(.title2.weight(.bold))
            Text("選單列將顯示：").foregroundStyle(.secondary)
            HStack {
                MenuBarLabelContent(summaries: (store?.summaries ?? []).filter { sel[$0.service.rawValue] == true },
                                    mode: .mixed, grok: sel["grok"] == true, palette: .dark)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.75), in: .capsule)
                Spacer()
            }
            Text("點選單列圖示可查看詳細用量；之後可在下拉選單的齒輪按鈕中修改設定。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("登入時啟動", isOn: $launchAtLogin)
                .toggleStyle(.switch)
                .onChange(of: launchAtLogin) { _, on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                }
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(steps, id: \.self) { s in
                    Circle().fill(s == step ? Color.primary : Color.primary.opacity(0.2)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step != 1 {
                Button("上一步") { move(-1) }.modifier(GlassButton())
            }
            if step == 3 {
                Button("略過") { Prefs.claudeAPI = false; move(1) }.modifier(GlassButton())
            }
            Button(step == 4 ? "開始使用" : "繼續") {
                if step == 2 { for (k, v) in sel { Prefs.setEnabled(k, v) } }
                if step == 4 { onFinish() } else { move(1) }
            }
            .modifier(GlassButton(prominent: true)).keyboardShortcut(.defaultAction).disabled(!canContinue)
        }
        .controlSize(.large)
    }

    private func move(_ d: Int) {
        guard let i = steps.firstIndex(of: step) else { step = 1; return }
        let n = min(max(0, i + d), steps.count - 1)
        step = steps[n]
    }
}

// MARK: - Settings

struct SettingsView: View {
    var store: UsageStore? = nil
    @State private var sel: [String: Bool] = Dictionary(uniqueKeysWithValues: ["claude", "codex", "grok"].map { ($0, Prefs.isEnabled($0)) })
    @State private var connected = Prefs.claudeAPI
    @State private var autoRepair = Prefs.claudeCLIRefresh
    @State private var awaitingLogin = false
    @State private var loginNote: String?
    @State private var confirmRepair = false
    @State private var autoUpdate = Updater.shared.automaticallyChecks
    private let providers: [ProviderInfo]
    init(store: UsageStore? = nil, providers: [ProviderInfo]? = nil) {
        self.store = store
        self.providers = providers ?? ProviderDetector.detect()
    }
    @AppStorage("skirr.appearance") private var appearance = "system"
    @AppStorage("skirr.animateSettingsLogo") private var animateLogo = true
    private static let version: String = {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }()
    private var busy: Bool { store?.isConnectingClaude == true }
    private var connection: ClaudeConnectionPresentation {
        ClaudeConnectionPresentation(enabled: connected, status: store?.claudeStatus, needsLogin: store?.claudeNeedsLogin == true)
    }

    private func connect(repair: Bool = false) {
        guard let store else { return }
        awaitingLogin = false; loginNote = nil
        Task { @MainActor in
            await store.connectClaude(repair: repair)
            connected = Prefs.claudeAPI
            sel["claude"] = Prefs.isEnabled(.claude)
        }
    }

    private func login() {
        guard let cli = ClaudeCLI.locate() else {
            loginNote = "尚未安裝 Claude Code。請先按下方的「安裝 Claude Code」，完成後再回來連接。"
            return
        }
        do {
            let command = try cli.loginCommandFile()
            guard NSWorkspace.shared.open(command) else {
                try? FileManager.default.removeItem(at: command.deletingLastPathComponent())
                loginNote = "無法開啟登入視窗，請稍後再試。"; return
            }
            awaitingLogin = true
            loginNote = "登入視窗已開啟。依畫面操作，完成後按下方按鈕確認。"
        } catch { loginNote = "登入視窗無法準備完成，請稍後再試。" }
    }

    private func performAction() {
        switch connection.action {
        case .connect: connect()
        case .repair: confirmRepair = true
        case .login: login()
        case .none: break
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("外觀").font(.headline)
                VStack(spacing: 14) {
                    HStack {
                        Text("配色主題")
                        Spacer()
                        Picker("配色主題", selection: $appearance) {
                            Text("跟隨系統").tag("system")
                            Text("淺色模式").tag("light")
                            Text("深色模式").tag("dark")
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 280)
                    }
                    Divider()
                    Toggle(isOn: $animateLogo) { Text("開啟設定時播放標誌動畫").frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(.switch)
                }.padding(16).background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 18))
            }
            Text("Claude 連線").font(.headline)
            ClaudeConnectionPanel(presentation: connection, busy: busy,
                note: loginNote ?? store?.claudeConnectionNote, awaitingLogin: awaitingLogin,
                action: performAction, confirmLogin: { connect() })
            if connected {
                Toggle(isOn: $autoRepair) { Text("自動保持 Claude 連線").frame(maxWidth: .infinity, alignment: .leading) }
                    .toggleStyle(.switch).disabled(busy)
                    .onChange(of: autoRepair) { _, value in
                        Prefs.claudeCLIRefresh = value
                        NotificationCenter.default.post(name: .tokenBarPrefsChanged, object: nil)
                    }
                Text("允許在登入需要更新時啟動 Claude Code，可能出現系統授權視窗。預設關閉，也可只在需要時手動修復。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("中斷 Claude 連接", role: .destructive) {
                    Prefs.claudeAPI = false; connected = false; autoRepair = false
                    awaitingLogin = false; loginNote = nil
                    store?.claudeNeedsLogin = false
                }.disabled(busy)
            }
            if connection.action == .login {
                Link("安裝 Claude Code", destination: URL(string: "https://code.claude.com/docs/en/quickstart")!)
                    .font(.caption)
            }
            Divider()
            Text("顯示的服務").font(.headline)
            ForEach(providers) { p in
                ProviderRow(info: p, on: Binding(get: { sel[p.id] ?? false }, set: { value in
                    sel[p.id] = value
                    if sel.values.contains(true) { Prefs.setEnabled(p.id, value) } else { sel[p.id] = true }
                    NotificationCenter.default.post(name: .tokenBarPrefsChanged, object: nil)
                })).disabled(busy && p.id == "claude")
            }
            Text("至少需啟用一項服務。").font(.caption).foregroundStyle(.secondary)
            Text("軟體更新").font(.headline)
            VStack(spacing: 14) {
            Toggle(isOn: $autoUpdate) { Text("自動檢查更新").frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(.switch)
                .onChange(of: autoUpdate) { _, value in Updater.shared.automaticallyChecks = value }
            HStack {
                Text("版本 \(Self.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("檢查更新…") { Updater.shared.checkForUpdates() }.modifier(GlassButton())
            }
            }.padding(16).background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 18))
            HStack {
                Text("需要重新選擇服務或設定連線？").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重新設定…") { WindowManager.shared.showOnboarding() }.modifier(GlassButton())
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 28)
    }

    var body: some View {
        VStack(spacing: 0) {
            SKIRRHeader(animate: animateLogo, version: Self.version)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 14)
            Divider().padding(.horizontal, 28)
            ScrollView { settingsContent }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(SKIRRBrand.accent)
        .accentColor(SKIRRBrand.accent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .confirmationDialog("修復 Claude 連線？", isPresented: $confirmRepair, titleVisibility: .visible) {
            Button("修復連線") { connect(repair: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會啟動已安裝的 Claude Code 更新登入，可能顯示系統授權視窗。不會傳送對話或執行 AI 工作，也不會開啟背景自動修復。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .tokenBarCredentialsChanged)) { _ in
            connected = Prefs.claudeAPI; autoRepair = Prefs.claudeCLIRefresh
        }
    }
}

/// Liquid Glass buttons; plain bordered styles in snapshot mode (ImageRenderer can't draw glass).
struct GlassButton: ViewModifier {
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if isSnapshot || reduceTransparency {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        } else {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        }
    }
}
