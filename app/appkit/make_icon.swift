// AppIcon 生成器:白底圆角 + 蓝色犬形(SF Symbols dog.fill,矢量逐尺寸光栅化)
// 用法:swift app/appkit/make_icon.swift  →  产出 /tmp/DogFull.iconset
//       xattr -rc /tmp/DogFull.iconset && iconutil -c icns /tmp/DogFull.iconset -o app/appkit/Assets/AppIcon.icns
// 改色:改 BLUE;改形:换 systemSymbolName;改占比:改 glyphW 系数
import AppKit
import CoreGraphics

let BLUE = NSColor(srgbRed: 0.22, green: 0.50, blue: 0.96, alpha: 1)
let OUT = "/tmp/DogFull.iconset"

func ctxFor(_ size: CGFloat) -> CGContext {
    let c = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}
func save(_ img: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

// 单个尺寸渲染:图形按目标像素重新光栅化,保证小尺寸锐利
func icon(_ S: CGFloat) -> CGImage {
    let ctx = ctxFor(S)
    let side = 0.824 * S, inset = (S - side)/2
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: side, height: side),
                       cornerWidth: 0.2237*side, cornerHeight: 0.2237*side, transform: nil))
    ctx.fillPath()

    guard let base = NSImage(systemSymbolName: "dog.fill", accessibilityDescription: nil) else { return ctx.makeImage()! }
    let glyphW = 0.72 * side
    let glyphH = glyphW * 668.0/818.0
    let pt = glyphH * 1024.0/512.0          // 让符号以接近目标像素的尺寸光栅化
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .medium)
        .applying(.init(paletteColors: [BLUE]))
    guard let img = base.withSymbolConfiguration(cfg) else { return ctx.makeImage()! }
    var r = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
    let cgImg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
    let rect = CGRect(x: (S - glyphW)/2, y: (S - glyphH)/2 - 0.008*S, width: glyphW, height: glyphH)
    ctx.draw(cgImg, in: rect)
    return ctx.makeImage()!
}

// ---- 生成 iconset ----
try? FileManager.default.removeItem(atPath: OUT)
try! FileManager.default.createDirectory(atPath: OUT, withIntermediateDirectories: true)
let jobs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in jobs { save(icon(px), "\(OUT)/\(name).png") }
save(icon(1024), "/tmp/icon_final.png")

// ---- 小尺寸可读性检查条(4x 最近邻放大) ----
let sizes: [CGFloat] = [16, 32, 64, 128]
let scale: CGFloat = 4
let stripW = sizes.reduce(CGFloat(0)) { $0 + $1*scale + 16 } + 16
let stripH = 128*scale + 32 + 40
let strip = ctxFor(stripW)
strip.setFillColor(NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1).cgColor)
strip.fill(CGRect(x: 0, y: 0, width: stripW, height: stripH))
strip.interpolationQuality = .none
var x: CGFloat = 16
for s in sizes {
    let img = icon(s)
    strip.draw(img, in: CGRect(x: x, y: 24, width: s*scale, height: s*scale))
    x += s*scale + 16
}
save(strip.makeImage()!, "/tmp/icon_strip.png")
print("iconset done")
