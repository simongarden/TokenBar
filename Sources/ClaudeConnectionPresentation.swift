import Foundation

/// User-facing recovery actions depend on the failure, not on the technical error code.
struct ClaudeConnectionPresentation {
    enum Action: Equatable { case none, connect, repair, login }
    let title: String
    let detail: String
    let action: Action
    let actionTitle: String
    let connected: Bool

    init(enabled: Bool, status: ClaudeUsageClient.Status?, needsLogin: Bool = false) {
        connected = enabled && status == .ok && !needsLogin
        if needsLogin || status == .noCredential {
            title = "請登入 Claude"
            detail = "按下登入後，依視窗指示完成登入，再回到這裡確認。不需要輸入指令。"
            action = .login; actionTitle = "登入 Claude"
        } else if status == .denied {
            title = "需要你的允許"
            detail = "macOS 尚未允許讀取 Claude 登入資料。請再試一次，並在系統視窗中允許。"
            action = .connect; actionTitle = "允許連接"
        } else if !enabled || status == .consentRequired {
            title = "連接 Claude，查看用量"
            detail = "使用這台 Mac 已有的 Claude 登入資料，向 Claude 查詢用量。macOS 可能要求你允許存取；可隨時中斷。"
            action = .connect; actionTitle = "連接 Claude"
        } else {
            switch status {
            case .ok?:
                title = "Claude 已連接"
                detail = "用量與重置時間會自動更新。"
                action = .none; actionTitle = ""
            case .expired?, .httpError(401)?:
                title = "Claude 連線需要更新"
                detail = "先按「修復連線」，讓 App 嘗試恢復登入；若需要重新登入，會顯示下一步。本機用量仍可查看。"
                action = .repair; actionTitle = "修復連線"
            case .waiting(let until)?:
                title = "Claude 暫時限制查詢"
                detail = "\(until.formatted(date: .omitted, time: .shortened)) 後會自動重試，不需要重新登入。"
                action = .none; actionTitle = ""
            case .failed?, .httpError?:
                title = "暫時連不上 Claude"
                detail = "請確認網路連線；App 稍後會自動重試。你仍可查看本機用量。"
                action = .none; actionTitle = ""
            default:
                title = "正在確認 Claude 連線"
                detail = "取得用量後就會顯示用量。"
                action = .none; actionTitle = ""
            }
        }
    }
}
