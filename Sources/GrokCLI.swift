import Foundation

/// xAI's Grok Build CLI. OKM Skirr never runs it in the background: installing and signing in happen
/// only in a Terminal window the user opened with one button, and the CLI writes its own `auth.json`.
struct GrokCLI: Sendable {
    let executable: URL

    /// Official installer (https://github.com/xai-org/grok-build#installing-the-released-binary).
    static let installScript = "https://x.ai/cli/install.sh"

    /// The installer's default `~/.grok/bin` first, then the symlinks it adds to directories on PATH.
    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       grokHome: URL = UsageScanner.grokHome(),
                       systemPaths: [String] = ["/opt/homebrew/bin/grok", "/usr/local/bin/grok"]) -> GrokCLI? {
        let candidates = [grokHome.appending(path: "bin/grok").path, home.appending(path: ".grok/bin/grok").path,
                          home.appending(path: ".local/bin/grok").path] + systemPaths
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { GrokCLI(executable: URL(fileURLWithPath: $0)) }
    }

    /// A Terminal script that installs the CLI when `cli` is nil, then runs `grok login`, which opens
    /// the browser. OKM Skirr never sees the login URL, code or token.
    static func setupCommandFile(cli: GrokCLI?, grokHome: URL = UsageScanner.grokHome(),
                                 environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let q = ClaudeCLI.shellQuote
        let directory = try ClaudeCLI.neutralDirectory()
        let command = directory.appending(path: "Grok-Login.command")
        var clean = ClaudeCLI.environment(from: environment)
        if let custom = environment["GROK_HOME"], !custom.isEmpty { clean["GROK_HOME"] = custom }
        let env = (["/usr/bin/env", "-i"] + clean.keys.sorted().map { q("\($0)=\(clean[$0]!)") }).joined(separator: " ")
        let grok = q((cli?.executable ?? grokHome.appending(path: "bin/grok")).path)
        let install = cli != nil ? "" : """
        printf '%s\\n\\n' '第 1 步：從 x.ai 官方網站下載並安裝 Grok CLI…'
        if ! /bin/bash -c \(q("/usr/bin/curl -fsSL \(installScript) | " + env + " /bin/bash")); then
          printf '\\n%s\\n' '安裝沒有完成，請確認網路連線後，回到 OKM Skirr 再按一次。'
          exit 1
        fi
        printf '\\n%s\\n\\n' '第 2 步：登入 Grok 帳號。'
        """
        let script = """
        #!/bin/zsh
        trap \(q("/bin/rm -f -- " + q(command.path) + "; /bin/rmdir -- " + q(directory.path))) EXIT
        cd \(q(directory.path)) || exit 1
        \(install)
        printf '%s\\n\\n' '瀏覽器會開啟 Grok 登入頁面，請在瀏覽器中登入並允許存取。'
        \(env) \(grok) login
        login_result=$?
        if [[ $login_result -eq 0 ]]; then
          printf '\\n%s\\n' '完成！OKM Skirr 會自動連接，你可以關閉這個視窗。'
        else
          printf '\\n%s\\n' '登入尚未完成。你可以關閉這個視窗，回到 OKM Skirr 再試一次。'
        fi
        exit "$login_result"
        """
        do {
            try Data(script.utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            return command
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// What the Grok connection panel says and which single button it offers, in plain words.
struct GrokConnectionPresentation: Equatable {
    enum Action: Equatable { case none, install, login, enableQuota }
    let title: String
    let detail: String
    let action: Action
    let actionTitle: String
    let connected: Bool

    init(installed: Bool, quotaOn: Bool, status: GrokUsageClient.Status?, account: String? = nil) {
        connected = quotaOn && (status == .ok || status == .usageUnknown)
        func set(_ t: String, _ d: String, _ a: Action = .none, _ at: String = "") -> (String, String, Action, String) { (t, d, a, at) }
        let v: (String, String, Action, String)
        if !installed && status != .ok && status != .usageUnknown {
            v = set("連接 Grok，查看用量",
                    "按一下就會自動安裝 xAI 官方的 Grok CLI，並開啟瀏覽器讓你登入 Grok 帳號。不需要輸入任何指令。",
                    .install, "安裝並連接 Grok")
        } else if !quotaOn {
            v = set("Grok 每週額度未開啟", "目前只統計這台 Mac 上的 Grok 使用記錄。開啟後可看到每週額度與重置時間。",
                    .enableQuota, "開啟每週額度")
        } else {
            switch status {
            case .ok?, .usageUnknown?:
                v = set("Grok 已連接", (account.map { $0 + "。" } ?? "") + "每週額度與重置時間會自動更新。")
            case .noCredential?:
                v = set("請登入 Grok", "按下登入後，在瀏覽器中登入 Grok 帳號即可，完成後會自動連接。", .login, "登入 Grok")
            case .expired?, .httpError(401)?, .httpError(403)?:
                v = set("Grok 需要重新登入", "登入已過期。按下登入，在瀏覽器中再登入一次即可。本機用量仍可查看。", .login, "重新登入 Grok")
            case .teamAccount?:
                v = set("團隊帳號沒有個人額度", "Grok 目前只提供個人方案的每週額度。這台 Mac 上的使用記錄仍會照常統計。")
            case .waiting(let until)?:
                v = set("Grok 暫時限制查詢", "\(until.formatted(date: .omitted, time: .shortened)) 後會自動重試，不需要做任何事。")
            case .failed?, .httpError?:
                v = set("暫時連不上 Grok", "請確認網路連線；App 稍後會自動重試。你仍可查看本機用量。")
            case nil:
                v = set("正在確認 Grok 連線", "取得額度後就會顯示。")
            }
        }
        (title, detail, action, actionTitle) = v
    }
}
