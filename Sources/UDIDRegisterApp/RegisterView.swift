import SwiftUI
import UDIDRegisterKit

struct RegisterView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("批量录入（每行一条，格式 UDID 或 UDID,名称）").font(.subheadline)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Spacer()
                Button(model.registering ? "注册中…" : "注册全部") {
                    Task { await model.register(text: text) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.registering || model.selected == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !model.results.isEmpty {
                Divider()
                Text("结果").font(.subheadline).bold()
                List(model.results) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.name)  ·  \(r.udid)").font(.caption).foregroundStyle(.secondary)
                        Text(outcomeText(r.outcome))
                    }
                }.frame(minHeight: 160)
            }
        }
    }
}
