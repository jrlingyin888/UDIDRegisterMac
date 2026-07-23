import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReSignAppCore
import UDIDRegisterKit

struct ReSignRootView: View {
    @Environment(ReSignModel.self) private var model
    @State private var showAccounts = false
    @State private var pwSheet: PasswordAction?

    enum PasswordAction: Identifiable {
        case importP12(URL), exportP12(URL)
        var id: String { switch self { case .importP12(let u): return "in:\(u.path)"; case .exportP12(let u): return "out:\(u.path)" } }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            accountRow(model)
            Divider()
            identitySection
            Divider()
            ipaSection
            pluginSection
            resignSection
            logSection
            if let banner = model.banner { Text(banner).font(.callout).foregroundStyle(.red) }
        }
        .padding()
        .frame(minWidth: 660, minHeight: 560, alignment: .topLeading)
        .sheet(isPresented: $showAccounts) { AccountsSheet().environment(model) }
        .sheet(item: $pwSheet) { action in passwordSheet(for: action) }
    }

    @ViewBuilder private func accountRow(_ model: ReSignModel) -> some View {
        @Bindable var model = model
        HStack {
            Text("账号").font(.subheadline)
            Picker("账号", selection: $model.selectedID) {
                ForEach(model.accounts) { a in Text(a.displayName).tag(Optional(a.id)) }
            }.labelsHidden().frame(maxWidth: 240)
            Button("管理账号…") { showAccounts = true }
            Spacer()
        }
        if model.selected == nil {
            Text("请先在「管理账号…」里导入一个账号配置文件").foregroundStyle(.secondary)
        }
    }

    private var identityReady: Bool {
        model.selected.map { model.identityStatus(for: $0.id) == .ready } ?? false
    }

    @ViewBuilder private var identitySection: some View {
        let ready = identityReady
        HStack(spacing: 10) {
            Label(ready ? "签名身份已就绪" : "尚未创建签名身份",
                  systemImage: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
            Spacer()
            Button("自动创建") { Task { _ = await model.createIdentity() } }
                .disabled(model.selected == nil || model.busy)
            Button("导入 p12…") { pickP12ToImport() }
                .disabled(model.selected == nil || model.busy)
            Button("导出 p12…") { pickP12ToExport() }
                .disabled(!ready || model.busy)
        }
    }

    @ViewBuilder private var ipaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IPA").font(.subheadline)
                Spacer()
                Button("选择 IPA…") { pickIPA() }
            }
            RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .frame(height: 64).foregroundStyle(.secondary.opacity(0.5))
                .overlay(Text(model.selectedIPA?.lastPathComponent ?? "把 .ipa 拖到这里，或点「选择 IPA…」")
                    .foregroundStyle(.secondary))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
                    model.selectedIPA = u; return true
                }
        }
    }

    @ViewBuilder private var pluginSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("插件（dylib，可选）").font(.subheadline)
                Spacer()
                if model.selectedPlugin != nil {
                    Button("清除") { model.selectedPlugin = nil }
                }
                Button("选择插件…") { pickPlugin() }
            }
            RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .frame(height: 44).foregroundStyle(.secondary.opacity(0.5))
                .overlay(Text(model.selectedPlugin?.lastPathComponent ?? "选一个 .dylib 注入（不选则只重签）")
                    .foregroundStyle(.secondary))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first(where: { $0.pathExtension.lowercased() == "dylib" }) else { return false }
                    model.selectedPlugin = u; return true
                }
        }
    }

    @ViewBuilder private var resignSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    Task { await model.resign() }
                } label: {
                    Label(model.selectedPlugin == nil ? "一键重签" : "注入并重签",
                          systemImage: model.selectedPlugin == nil ? "signature" : "syringe")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
                .disabled(model.busy || model.selected == nil || model.selectedIPA == nil)
                if model.busy { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                Button("导出描述文件…") { pickProfileToExport() }
                    .disabled(model.busy || model.selected == nil || !identityReady)
                Text("含当前全部设备，配 p12 可在别处重签（快照，加设备后需重导）；不选 IPA 则导出通配描述文件（对任意 app 通用）")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder private var logSection: some View {
        if !model.log.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }

    // MARK: - 面板

    private func pickIPA() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let ipa = UTType(filenameExtension: "ipa") { panel.allowedContentTypes = [ipa] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectedIPA = url
    }
    private func pickPlugin() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let dylib = UTType(filenameExtension: "dylib") { panel.allowedContentTypes = [dylib] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectedPlugin = url
    }
    private func pickP12ToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let p12 = UTType(filenameExtension: "p12") { panel.allowedContentTypes = [p12] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pwSheet = .importP12(url)
    }
    private func pickP12ToExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.selected?.displayName ?? "identity").p12"
        if let p12 = UTType(filenameExtension: "p12") { panel.allowedContentTypes = [p12] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pwSheet = .exportP12(url)
    }
    private func pickProfileToExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ReSign AdHoc.mobileprovision"
        if let mp = UTType(filenameExtension: "mobileprovision") { panel.allowedContentTypes = [mp] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await model.exportProfile(to: url) }
    }

    @ViewBuilder private func passwordSheet(for action: PasswordAction) -> some View {
        switch action {
        case .importP12(let url):
            PasswordSheet(title: "输入 p12 密码", confirmLabel: "导入",
                          onConfirm: { pw in pwSheet = nil; Task { _ = await model.importP12(from: url, password: pw) } },
                          onCancel: { pwSheet = nil })
        case .exportP12(let url):
            PasswordSheet(title: "为导出的 p12 设置密码", confirmLabel: "导出",
                          onConfirm: { pw in pwSheet = nil; _ = model.exportP12(to: url, password: pw) },
                          onCancel: { pwSheet = nil })
        }
    }
}
