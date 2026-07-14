import SwiftUI
import UDIDRegisterKit

/// Popover 内容：当前账号下所有已登记设备（名称 + 状态徽章），可手动刷新。
struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已登记设备（\(model.devices.count)）").font(.headline)
                Spacer()
                Button {
                    Task { refreshing = true; await model.refreshQuota(); refreshing = false }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(refreshing)
                .help("刷新")
            }
            Divider()

            if model.devices.isEmpty {
                Text("暂无已登记设备")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.devices) { d in
                            HStack {
                                Text(d.name.isEmpty ? "（无名称）" : d.name)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 12)
                                Text(statusBadge(d.status))
                                    .font(.callout).foregroundStyle(.secondary).fixedSize()
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
