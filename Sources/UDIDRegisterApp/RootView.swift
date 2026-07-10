import SwiftUI
import UDIDRegisterKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showAccounts = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账号").font(.subheadline)
                Picker("账号", selection: $model.selectedID) {
                    ForEach(model.accounts) { a in Text(a.displayName).tag(Optional(a.id)) }
                }
                .labelsHidden().frame(maxWidth: 220)
                Button("管理账号…") { showAccounts = true }
                Spacer()
            }
            if model.selected == nil {
                Text("请先添加一个苹果账号").foregroundStyle(.secondary)
            }
            if model.selected != nil {
                Divider()
                RegisterView().environment(model)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520)
        .sheet(isPresented: $showAccounts) { AccountManagerView().environment(model) }
    }
}
