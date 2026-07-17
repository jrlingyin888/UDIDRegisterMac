import SwiftUI
import AppKit
import ReSignAppCore
import UDIDRegisterKit

/// 账号管理：导入配置文件 / 列表 / 删除。复用 ReSignModel 的 importAccountConfig / deleteAccount。
struct AccountsSheet: View {
    @Environment(ReSignModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("管理账号").font(.headline)
            List {
                ForEach(model.accounts) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.displayName)
                            Text(a.issuerID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.deleteAccount(id: a.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
            }.frame(minHeight: 160)
            HStack {
                Button {
                    importConfig()
                } label: { Label("导入账号配置文件…", systemImage: "square.and.arrow.down") }
                .disabled(importing)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let banner = model.banner { Text(banner).font(.caption).foregroundStyle(.red) }
        }
        .padding(20).frame(width: 460)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择注册助手导出的账号配置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { _ = await model.importAccountConfig(from: url); importing = false }
    }
}
