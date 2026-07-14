import SwiftUI
import UDIDRegisterKit

/// Popover 内容：当前账号下所有已登记设备（名称 + UDID + 状态徽章），
/// 支持按名称 / UDID 模糊筛选，可手动刷新。
struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @State private var refreshing = false
    @State private var query = ""

    /// 按名称或 UDID 做不区分大小写的子串筛选。
    private var filtered: [DeviceRow] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.devices }
        return model.devices.filter {
            $0.name.lowercased().contains(q) || $0.udid.lowercased().contains(q)
        }
    }

    private var countLabel: String {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            ? "\(model.devices.count)"
            : "\(filtered.count)/\(model.devices.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已登记设备（\(countLabel)）").font(.headline)
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

            if !model.devices.isEmpty {
                TextField("搜索名称或 UDID", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            // 固定高度：无论筛选出多少条，弹窗高度恒定，列表在固定区域内滚动。
            Group {
                if model.devices.isEmpty {
                    emptyState("暂无已登记设备")
                } else if filtered.isEmpty {
                    emptyState("无匹配设备")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { d in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(d.name.isEmpty ? "（无名称）" : d.name)
                                            .lineLimit(1).truncationMode(.middle)
                                        Text(d.udid)
                                            .font(.caption).monospaced()
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                            .textSelection(.enabled)
                                    }
                                    Spacer(minLength: 12)
                                    Text(statusBadge(d.status))
                                        .font(.callout).foregroundStyle(.secondary).fixedSize()
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(12)
        .frame(width: 360)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
