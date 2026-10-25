import SwiftUI

/// The plain-language fields a connection panel shows; one primary button at most.
protocol ConnectionPresenting {
    var title: String { get }
    var detail: String { get }
    var connected: Bool { get }
    var actionTitle: String { get }
    var hasAction: Bool { get }
}

extension ClaudeConnectionPresentation: ConnectionPresenting { var hasAction: Bool { action != .none } }
extension GrokConnectionPresentation: ConnectionPresenting { var hasAction: Bool { action != .none } }

struct ConnectionPanel<P: ConnectionPresenting>: View {
    let presentation: P
    var service = "Claude"
    var busy = false
    var note: String?
    var awaitingLogin = false
    let action: () -> Void
    var confirmLogin: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(busy ? "正在處理 \(service) 連線…" : (awaitingLogin ? "等待你完成 \(service) 登入" : presentation.title),
                  systemImage: presentation.connected ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.headline)
                .foregroundStyle(presentation.connected ? SKIRRBrand.success : .primary)
            Text(awaitingLogin ? (confirmLogin == nil ? "請依剛開啟的視窗完成操作，完成後這裡會自動更新。"
                                                      : "請在剛開啟的登入視窗完成操作，再回到這裡確認。")
                               : presentation.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if busy || (awaitingLogin && confirmLogin == nil) { ProgressView().controlSize(.small) }
                if awaitingLogin {
                    if let confirmLogin {
                        Button("完成登入，重新連接", action: confirmLogin)
                            .modifier(GlassButton(prominent: true)).disabled(busy)
                    } else {
                        Button("重新開啟視窗", action: action).modifier(GlassButton()).disabled(busy)
                    }
                } else if presentation.hasAction {
                    Button(presentation.actionTitle, action: action)
                        .modifier(GlassButton(prominent: true)).disabled(busy)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
