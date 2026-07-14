import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UDIDRegisterKit

struct AccountManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var teamID = ""
    @State private var p8PEM = ""
    @State private var p8Filename = ""
    @State private var busy = false
    // 单一文件选择器 + 目标枚举：避免同一 View 上叠加多个 .fileImporter
    // （SwiftUI 会让内层的那个失效，导致按钮点了没反应）。
    @State private var showFilePicker = false
    @State private var pickerTarget: FilePickerTarget = .p8
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteConfirm = false

    private enum FilePickerTarget { case p8, config }

    private var pickerContentTypes: [UTType] {
        switch pickerTarget {
        case .p8:     return [UTType(filenameExtension: "p8") ?? .data]
        case .config: return [UTType(filenameExtension: "udidconfig") ?? .json, .json]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("账号管理").font(.headline)

            if !model.accounts.isEmpty {
                List {
                    ForEach(model.accounts) { a in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(a.displayName).bold()
                                Text("Key \(a.keyID) · Issuer \(a.issuerID.prefix(8))…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("导出配置…") { exportAccount(a) }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                pendingDeleteID = a.id; showDeleteConfirm = true
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }.frame(height: 140)
            }

            Divider()
            HStack {
                Button("导入配置文件…") { pickerTarget = .config; showFilePicker = true }
                Text("同事一键配置：选择管理员给的 .udidconfig")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("配置文件含私钥，请通过安全渠道传递，用完可删除。")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("手动添加账号").font(.subheadline).bold()
            TextField("显示名（如 jgz / 公司A）", text: $displayName)
            TextField("Key ID（如 QA2MC7L8X7）", text: $keyID)
            TextField("Issuer ID（UUID）", text: $issuerID)
            TextField("Team ID（可选，仅展示）", text: $teamID)

            HStack {
                Button("选择 .p8 文件…") { pickerTarget = .p8; showFilePicker = true }
                Text(p8Filename.isEmpty ? "未选择" : p8Filename)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let banner = model.banner {
                Text(banner).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button(busy ? "校验中…" : "添加并校验") {
                    Task {
                        busy = true
                        let ok = await model.addAccount(displayName: displayName, keyID: keyID,
                            issuerID: issuerID, teamID: teamID.isEmpty ? nil : teamID, p8PEM: p8PEM)
                        busy = false
                        if ok { displayName = ""; keyID = ""; issuerID = ""; teamID = ""; p8PEM = ""; p8Filename = "" }
                    }
                }
                .disabled(busy || displayName.isEmpty || keyID.isEmpty || issuerID.isEmpty || p8PEM.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: pickerContentTypes) { result in
            guard case let .success(url) = result else { return }
            switch pickerTarget {
            case .p8:
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    p8PEM = text; p8Filename = url.lastPathComponent
                }
            case .config:
                Task { busy = true; _ = await model.importConfig(from: url); busy = false }
            }
        }
        .alert("确定删除该账号？", isPresented: $showDeleteConfirm, presenting: pendingDeleteID) { id in
            Button("删除", role: .destructive) { model.deleteAccount(id: id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("此操作会移除本机保存的凭据，无法撤销。")
        }
    }

    private func exportAccount(_ a: AppleAccount) {
        let data: Data
        do { data = try model.exportConfig(for: a) }
        catch { model.banner = UserFacingMessage.from(error); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(a.displayName).udidconfig"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do { try data.write(to: url); model.banner = nil }
            catch { model.banner = "导出失败：\(UserFacingMessage.from(error))" }
        }
    }
}
