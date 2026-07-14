import UDIDRegisterKit

func statusText(_ s: DeviceStatus) -> String {
    switch s {
    case .enabled:    return "✅ 已可用 — 可直接用于真机调试/打包"
    case .processing: return "⏳ 处理中 — 苹果正在处理，可能需 24~72 小时才可供开发使用"
    case .disabled:   return "🚫 已禁用 — 仍占用 100 台/年额度"
    case .unknown:    return "ℹ️ 未知状态"
    }
}

/// 列表行用的精简状态徽章（`statusText` 太长，不适合每行显示）。
func statusBadge(_ s: DeviceStatus) -> String {
    switch s {
    case .enabled:    return "✅ 已可用"
    case .processing: return "⏳ 处理中"
    case .disabled:   return "🚫 已禁用"
    case .unknown:    return "ℹ️ 未知"
    }
}

func outcomeText(_ o: RegistrationOutcome) -> String {
    switch o {
    case .created(let s):                 return "✅ 注册成功 · \(statusText(s))"
    case .alreadyExisted(let name, let s): return "ℹ️ 已存在（苹果记录名：\(name)） · \(statusText(s))"
    case .failed(let m):                  return "❌ \(m)"
    }
}
