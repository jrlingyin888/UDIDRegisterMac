import SwiftUI
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
    @State private var importing = false

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
                            Button(role: .destructive) { model.deleteAccount(id: a.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                    }
                }.frame(height: 140)
            }

            Divider()
            Text("添加账号").font(.subheadline).bold()
            TextField("显示名（如 jgz / 公司A）", text: $displayName)
            TextField("Key ID（如 QA2MC7L8X7）", text: $keyID)
            TextField("Issuer ID（UUID）", text: $issuerID)
            TextField("Team ID（可选，仅展示）", text: $teamID)

            HStack {
                Button("选择 .p8 文件…") { importing = true }
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
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
            if case let .success(url) = result {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    p8PEM = text; p8Filename = url.lastPathComponent
                }
            }
        }
    }
}
