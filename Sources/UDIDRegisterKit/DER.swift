import Foundation

/// 极简 DER 编码器：只覆盖构造 PKCS#10 CSR 所需的类型。
public enum DER {
    /// DER 长度字段（短式 <128 一字节，否则长式）
    public static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + length(value.count) + value
    }

    public static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    public static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }

    public static func integer(_ value: [UInt8]) -> [UInt8] {
        var v = value.isEmpty ? [0x00] : value
        if let first = v.first, first & 0x80 != 0 { v = [0x00] + v }  // 防负数误读
        return tlv(0x02, v)
    }

    public static func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }
    public static func null() -> [UInt8] { [0x05, 0x00] }
    public static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }
    public static func utf8String(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    public static func printableString(_ s: String) -> [UInt8] { tlv(0x13, Array(s.utf8)) }

    /// [tagNumber] 上下文构造标签（如 CSR 的 attributes [0]）
    public static func contextConstructed(_ tagNumber: UInt8, _ value: [UInt8]) -> [UInt8] {
        tlv(0xA0 | tagNumber, value)
    }
}
