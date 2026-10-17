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
        get { UserDefaults.standard.object(forKey: SettingsKey.claudeOAuth) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.claudeOAuth) }
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
            ProviderInfo(id: "claude", name: "Claude Code", logo: "LogoClaudeColor", detected: cDetected,
                         status: cDetected ? (cEmail.map { "已偵測到 · \($0)" } ?? "已偵測到本機記錄") : "未偵測到",
                         help: cDetected ? nil : "請先安裝 Claude Code 並登入 Claude 帳號。",
                         link: URL(string: "https://docs.anthropic.com/en/docs/claude-code")),
            ProviderInfo(id: "codex", name: "ChatGPT / Codex", logo: "LogoCodexColor", detected: xDetected,
                         status: xDetected ? (xEmail.map { "已偵測到 · \($0)" } ?? "已偵測到本機記錄") : "未偵測到",
                         help: xDetected ? nil : "請先安裝 Codex（ChatGPT App 或 CLI）並登入。",
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
            case .notFound: "找不到憑證（請先在終端機執行 claude 並登入）"
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
    @MainActor static func authorizeClaudeKeychain() async -> KeychainAuth {
        NSApp.activate()
        try? await Task.sleep(for: .milliseconds(150))
        let st: OSStatus = await Task.detached { keychainStatus(allowUI: true) }.value
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
        onboarding = present(onboarding, title: "歡迎使用 AI Token Status", view: AnyView(view.environment(store)))
    }

    func showSettings() {
        NotificationCenter.default.post(name: .tokenBarClosePopover, object: nil)
        settings = present(settings, title: "AI Token Status 設定", view: AnyView(SettingsView()))
    }

    private func present(_ existing: NSWindow?, title: String, view: AnyView) -> NSWindow {
        let w = existing ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                                     styleMask: [.titled, .closable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.contentViewController = NSHostingController(rootView: view.frame(width: 520, height: 440))
        w.setContentSize(NSSize(width: 520, height: 440))
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
        Button { on.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(on ? Color.accentColor : .secondary)
                Image(info.logo).resizable().scaledToFit().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(info.status).font(.caption).foregroundStyle(info.detected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    if let h = info.help {
                        HStack(spacing: 4) {
                            Text(h).font(.caption2).foregroundStyle(.secondary)
                            if let l = info.link { Link("說明", destination: l).font(.caption2) }
                        }
                    }
                }
                Spacer()
            }
            .padding(10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .modifier(CardBackground())
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    var onFinish: () -> Void
    @Environment(UsageStore.self) private var store: UsageStore?
    @State private var step: Int
    @State private var sel: [String: Bool]
    @State private var authResult: ProviderDetector.KeychainAuth?
    @State private var authorizing = false
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
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 40, weight: .semibold)).foregroundStyle(.tint)
            Text("歡迎使用 AI Token Status").font(.largeTitle.weight(.bold))
            Text("在選單列即時掌握 Claude Code 與 ChatGPT / Codex 的用量、限額與重置時間。")
                .font(.title3).foregroundStyle(.secondary)
            Label("所有資料都只在這台 Mac 上讀取與計算。", systemImage: "lock.shield")
            Label("不收集、不上傳任何使用記錄或對話內容。", systemImage: "icloud.slash")
            Label("只讀取各工具留在本機的記錄檔，不會修改它們。", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("選擇要顯示的服務").font(.title2.weight(.bold))
            Text("已自動偵測本機安裝狀態；偵測到的服務已預先勾選。").font(.callout).foregroundStyle(.secondary)
            ForEach(providers) { p in
                ProviderRow(info: p, on: Binding(get: { sel[p.id] ?? false }, set: { sel[p.id] = $0 }))
            }
            if !sel.values.contains(true) {
                Text("請至少選擇一項服務。").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var authorize: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "key.viewfinder").font(.system(size: 36, weight: .semibold)).foregroundStyle(.tint)
            Text("Claude 用量授權").font(.title2.weight(.bold))
            Text("若要顯示 Claude 的 5 小時與每週限額百分比，AI Token Status 需要讀取鑰匙圈中 Claude Code 的登入憑證，並向 Anthropic 查詢你自己的用量（與 Claude Code 的 /usage 相同）。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("按下「授權」後，macOS 會跳出鑰匙圈存取視窗，請選擇「永遠允許」。憑證只保存在記憶體中，不會寫入任何檔案。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { runAuth() } label: {
                    Label(authResult == nil || authResult == .ok ? "授權" : "重試",
                          systemImage: authResult == nil || authResult == .ok ? "checkmark.shield" : "arrow.clockwise")
                }
                .modifier(GlassButton(prominent: true)).disabled(authorizing || authResult == .ok)
                if authorizing { ProgressView().controlSize(.small) }
                if let r = authResult {
                    Label(r == .ok ? "成功" : "\(r.message) — 將改用本機 token 統計",
                          systemImage: r == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(r == .ok ? .green : .orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runAuth() {
        authorizing = true
        Task { @MainActor in
            let r = await ProviderDetector.authorizeClaudeKeychain()
            authResult = r
            Prefs.claudeAPI = r == .ok
            authorizing = false
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 36, weight: .semibold)).foregroundStyle(.green)
            Text("設定完成").font(.title2.weight(.bold))
            Text("選單列將顯示：").foregroundStyle(.secondary)
            HStack {
                MenuBarLabelContent(summaries: (store?.summaries ?? []).filter { sel[$0.service.rawValue] == true },
                                    mode: .mixed, grok: sel["grok"] == true, mono: .white)
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
    @State private var sel: [String: Bool] = Dictionary(uniqueKeysWithValues: ["claude", "codex", "grok"].map { ($0, Prefs.isEnabled($0)) })
    @State private var claudeAPI = Prefs.claudeAPI
    @State private var authorizing = false
    @State private var authNote: String?
    private let providers = ProviderDetector.detect()

    private func apply(_ on: Bool) {
        Prefs.claudeAPI = on
        NotificationCenter.default.post(name: .tokenBarPrefsChanged, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("顯示的服務").font(.title3.weight(.bold))
            ForEach(providers) { p in
                ProviderRow(info: p, on: Binding(get: { sel[p.id] ?? false }, set: { v in
                    sel[p.id] = v
                    if sel.values.contains(true) { Prefs.setEnabled(p.id, v) } else { sel[p.id] = true }
                    NotificationCenter.default.post(name: .tokenBarPrefsChanged, object: nil)
                }))
            }
            HStack(spacing: 8) {
                Toggle("Claude 使用官方用量 API（需鑰匙圈授權）", isOn: $claudeAPI)
                    .toggleStyle(.switch).disabled(authorizing)
                if authorizing { ProgressView().controlSize(.small) }
            }
            .onChange(of: claudeAPI) { _, v in
                guard v else { apply(false); return }
                // Background refreshes never prompt, so turning it on is where the Keychain prompt happens.
                authorizing = true; authNote = nil
                Task { @MainActor in
                    let r = await ProviderDetector.authorizeClaudeKeychain()
                    authorizing = false
                    if r == .ok { apply(true) } else { authNote = "鑰匙圈授權失敗：\(r.message)"; claudeAPI = false }
                }
            }
            if let n = authNote {
                Text(n).font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Spacer()
                Button { WindowManager.shared.showOnboarding() } label: {
                    Label("重新執行安裝引導", systemImage: "arrow.counterclockwise")
                }
                .modifier(GlassButton()).controlSize(.large)
            }
        }
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

/// Liquid Glass buttons; plain bordered styles in snapshot mode (ImageRenderer can't draw glass).
struct GlassButton: ViewModifier {
    var prominent = false
    func body(content: Content) -> some View {
        if isSnapshot {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        } else {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        }
    }
}
