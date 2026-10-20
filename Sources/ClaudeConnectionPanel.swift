import SwiftUI

struct ClaudeConnectionPanel: View {
    let presentation: ClaudeConnectionPresentation
    var busy = false
    var note: String?
    var awaitingLogin = false
    let action: () -> Void
    var confirmLogin: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(busy ? "正在處理 Claude 連線…" : (awaitingLogin ? "等待你完成 Claude 登入" : presentation.title),
                  systemImage: presentation.connected ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.headline)
                .foregroundStyle(presentation.connected ? Color.green : .primary)
            Text(awaitingLogin ? "請在剛開啟的登入視窗完成操作，再回到這裡確認。" : presentation.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small) }
                if awaitingLogin {
                    Button("完成登入，重新連接", action: confirmLogin)
                        .modifier(GlassButton(prominent: true)).disabled(busy)
                } else if presentation.action != .none {
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
