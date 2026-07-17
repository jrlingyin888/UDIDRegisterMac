#!/usr/bin/env swift
import AppKit

func render(px: Int, accent: (CGFloat, CGFloat, CGFloat)) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    // 背景：圆角矩形 + 蓝紫渐变
    let bg = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s*0.05, dy: s*0.05)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: s*0.225, cornerHeight: s*0.225, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1),
                 CGColor(red: max(0, accent.0-0.1), green: max(0, accent.1-0.05), blue: max(0, accent.2-0.2), alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: bg.minX, y: bg.maxY),
                           end: CGPoint(x: bg.maxX, y: bg.minY), options: [])
    ctx.restoreGState()

    // 手机机身：白色圆角矩形
    let pw = s*0.34, ph = s*0.56, pcx = s*0.46, pcy = s*0.52
    let phone = CGRect(x: pcx - pw/2, y: pcy - ph/2, width: pw, height: ph)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: s*0.07, cornerHeight: s*0.07, transform: nil))
    ctx.fillPath()

    // 屏幕：浅灰
    let screen = phone.insetBy(dx: s*0.03, dy: s*0.05)
    ctx.setFillColor(CGColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1))
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: s*0.04, cornerHeight: s*0.04, transform: nil))
    ctx.fillPath()

    // 徽章底：右下角圆
    let br = s*0.15, bcx = phone.maxX - s*0.02, bcy = phone.minY + s*0.04
    let badge = CGRect(x: bcx - br, y: bcy - br, width: br*2, height: br*2)

    // 重签徽章：蓝色圆底 + 白色回环箭头
    ctx.setFillColor(CGColor(red: 0.13, green: 0.45, blue: 0.95, alpha: 1))
    ctx.fillEllipse(in: badge)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(s*0.022); ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: bcx, y: bcy), radius: br*0.5,
               startAngle: .pi*0.15, endAngle: .pi*1.7, clockwise: false)
    ctx.strokePath()
    // 箭头头
    ctx.beginPath()
    ctx.move(to: CGPoint(x: bcx + br*0.5, y: bcy + br*0.05))
    ctx.addLine(to: CGPoint(x: bcx + br*0.5, y: bcy - br*0.28))
    ctx.addLine(to: CGPoint(x: bcx + br*0.85, y: bcy - br*0.05))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variant = CommandLine.arguments.dropFirst().first ?? "register"
let (accent, iconset, icns): ((CGFloat,CGFloat,CGFloat), String, String) =
    variant == "resign"
      ? ((0.10, 0.72, 0.60), "Resources/ReSignAppIcon.iconset", "Resources/ReSignAppIcon.icns")
      : ((0.31, 0.40, 0.96), "Resources/AppIcon.iconset", "Resources/AppIcon.icns")

try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let items: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in items {
    try! render(px: px, accent: accent).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", icns]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✅ \(icns) 生成成功" : "❌ iconutil 失败")
