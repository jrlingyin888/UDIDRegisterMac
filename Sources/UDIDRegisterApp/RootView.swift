import SwiftUI
import UDIDRegisterKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showAccounts = false
    @State private var showDevices = false

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
                if !model.quotaText.isEmpty {
                    Button { showDevices = true } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .help("查看已登记设备")
                    .popover(isPresented: $showDevices, arrowEdge: .bottom) {
                        DeviceListView().environment(model)
                    }
                    Text(model.quotaText).font(.caption).foregroundStyle(.secondary)
                }
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
        .task { model.restoreSelection(); await model.refreshQuota() }
        .onChange(of: model.selectedID) { _, _ in
            model.persistSelection()
            model.results = []          // 切换/删除账号时，上一账号的注册结果不再适用
            Task { await model.refreshQuota() }
        }
    }
}
