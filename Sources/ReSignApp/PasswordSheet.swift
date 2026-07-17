import SwiftUI

/// 通用密码输入小 sheet：确认回调带回明文密码，取消回调无参。
struct PasswordSheet: View {
    let title: String
    let confirmLabel: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 280)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button(confirmLabel) { onConfirm(password) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
    }
}
