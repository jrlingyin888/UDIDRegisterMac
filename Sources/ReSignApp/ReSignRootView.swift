import SwiftUI
import ReSignAppCore
import UDIDRegisterKit

struct ReSignRootView: View {
    @Environment(ReSignModel.self) private var model
    @State private var showAccounts = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("账号").font(.subheadline)
                Picker("账号", selection: $model.selectedID) {
                    ForEach(model.accounts) { a in Text(a.displayName).tag(Optional(a.id)) }
                }
                .labelsHidden().frame(maxWidth: 240)
                Button("管理账号…") { showAccounts = true }
                Spacer()
            }
            if model.selected == nil {
                Text("请先在「管理账号…」里导入一个账号配置文件").foregroundStyle(.secondary)
            }
            if let banner = model.banner {
                Text(banner).font(.callout).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520, alignment: .topLeading)
        .sheet(isPresented: $showAccounts) { AccountsSheet().environment(model) }
    }
}

// TEMPORARY placeholder — Task 6 will replace this with the real AccountsSheet
// implementation in its own file. Delete this struct when Task 6 lands.
struct AccountsSheet: View {
    var body: some View { Text("账号管理（Task 6 补全）").padding() }
}
