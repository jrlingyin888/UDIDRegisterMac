#!/usr/bin/env swift
import AppKit

func render(px: Int) -> Data {
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
        colors: [CGColor(red: 0.31, green: 0.40, blue: 0.96, alpha: 1),
                 CGColor(red: 0.58, green: 0.31, blue: 0.93, alpha: 1)] as CFArray,
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

    // 绿色对勾徽章：右下角圆
    let br = s*0.15, bcx = phone.maxX - s*0.02, bcy = phone.minY + s*0.04
    let badge = CGRect(x: bcx - br, y: bcy - br, width: br*2, height: br*2)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(s*0.02)
    ctx.strokeEllipse(in: badge.insetBy(dx: -s*0.012, dy: -s*0.012))
    ctx.setFillColor(CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1))
    ctx.fillEllipse(in: badge)

    // 白色对勾
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(s*0.028); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: bcx - br*0.45, y: bcy + br*0.02))
    ctx.addLine(to: CGPoint(x: bcx - br*0.10, y: bcy - br*0.35))
    ctx.addLine(to: CGPoint(x: bcx + br*0.50, y: bcy + br*0.35))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let items: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in items {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✅ Resources/AppIcon.icns 生成成功" : "❌ iconutil 失败")
