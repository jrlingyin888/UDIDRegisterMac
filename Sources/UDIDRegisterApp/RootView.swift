import SwiftUI
import UDIDRegisterKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            Text("UDID 注册助手").font(.title2).bold()
            Text(model.accounts.isEmpty ? "还没有账号" : "账号数：\(model.accounts.count)")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520)
    }
}
