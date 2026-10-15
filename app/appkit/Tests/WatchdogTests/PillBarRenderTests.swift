import XCTest
@testable import WatchdogCore

// MARK: - 胶囊分段栏回归:选中态必须"底/字对比度够、文案不被裁"
// 起因(2026-10-15 用户截图):浅色主题下"总览"药丸是近黑底 + 近黑字 = 看不见。
// 两个叠加原因:①浅色调色板把选中药丸底色写成近黑;②语言切换走 setLabels 会把所有 tab
// 文字刷成普通灰(wdText2),把选中态覆盖掉。判据与具体配色无关:在渲染结果里自动定位药丸,
// 要求"药丸底色 vs 药丸内字形"的 WCAG 对比度 ≥ 3,且换文案后按钮宽度跟着变。

final class PillBarRenderTests: XCTestCase {

    @MainActor
    private func renderedBar(labels: [String], fontSize: CGFloat = 12) -> NSBitmapImageRep {
        let bar = PillBar(items: [("总览", "总览")], fontSize: fontSize)
        bar.frame = NSRect(x: 0, y: 0, width: 120, height: fontSize + 19)
        bar.layoutSubtreeIfNeeded()
        bar.setLabels(labels)          // 语言切换路径(回归点)
        bar.layoutSubtreeIfNeeded()
        guard let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else {
            fatalError("bitmapImageRep 创建失败")
        }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        return rep
    }

    /// 在渲染结果里自动定位"选中药丸":与当前调色板 pillSelectedBg 同色且不透明的像素包围盒
    private func pillBox(_ rep: NSBitmapImageRep) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        guard let want = NSColor.wdPillSelectedBg.usingColorSpace(.sRGB) else { return nil }
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if abs(c.redComponent - want.redComponent) < 0.12,
                   abs(c.greenComponent - want.greenComponent) < 0.12,
                   abs(c.blueComponent - want.blueComponent) < 0.12 {
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                }
            }
        }
        return x1 - x0 > 8 && y1 - y0 > 4 ? (x0, y0, x1, y1) : nil
    }

    private func relLuminance(_ c: NSColor) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(Double(c.redComponent)) + 0.7152 * f(Double(c.greenComponent))
            + 0.0722 * f(Double(c.blueComponent))
    }

    /// 药丸底色(取中位数)与药丸内最深处字形(取最深 5%)的 WCAG 对比度
    private func pillContrast(_ rep: NSBitmapImageRep, box: (x0: Int, y0: Int, x1: Int, y1: Int)) -> (ratio: Double, count: Int) {
        let inset = 5
        var lums: [Double] = []
        for y in max(0, box.y0 + inset)...max(0, box.y1 - inset) {
            for x in max(0, box.x0 + inset)...max(0, box.x1 - inset) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                lums.append(relLuminance(c))
            }
        }
        guard lums.count > 30 else { return (0, lums.count) }
        let s = lums.sorted()
        let bg = s[s.count / 2]
        let ink = s[max(0, s.count / 20)]
        return ((max(bg, ink) + 0.05) / (min(bg, ink) + 0.05), lums.count)
    }

    @MainActor
    private func assertPillReadable(theme: String, labels: [String]) {
        let savedTheme = wdThemeID
        defer { wdThemeID = savedTheme }
        wdThemeID = theme

        let tag = "\(theme)/\(labels.first ?? "")"
        let rep = renderedBar(labels: labels)
        guard let box = pillBox(rep) else {
            return XCTFail("\(tag):在渲染结果里找不到选中药丸(底色与 pillSelectedBg 不符)")
        }
        let (ratio, count) = pillContrast(rep, box: box)
        XCTAssertGreaterThan(count, 30, "\(tag):药丸取样像素过少(\(count))")
        XCTAssertGreaterThan(ratio, 3.0,
            "\(tag):药丸底/字对比度仅 \(String(format: "%.2f", ratio)):1(需 ≥3)→ 选中文案看不清")
    }

    @MainActor func testSelectedPillReadableInBothThemes() {
        assertPillReadable(theme: "mist", labels: ["总览"])
        assertPillReadable(theme: "mist", labels: ["Overview"])   // 语言切换后(原 bug 触发路径)
        assertPillReadable(theme: "sky", labels: ["总览"])
        assertPillReadable(theme: "sky", labels: ["Overview"])
    }

    /// 卡片级别胶囊用 10pt:选中文案不能被写死的 12pt 覆盖
    /// 判据:同一文案在 10pt / 12pt 下的墨迹高度必须不同(写死时两者相等)
    @MainActor func testSmallFontPillKeepsItsFontSize() {
        func inkHeight(_ size: CGFloat) -> Int {
            let rep = renderedBar(labels: ["4h"], fontSize: size)
            guard let box = pillBox(rep) else { return 0 }
            var rows = 0
            for y in box.y0...box.y1 {
                var hit = false
                for x in box.x0...box.x1 {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if relLuminance(c) < 0.05 { hit = true; break }
                }
                if hit { rows += 1 }
            }
            return rows
        }
        let h10 = inkHeight(10), h12 = inkHeight(12)
        XCTAssertGreaterThan(h10, 0, "10pt 药丸内没有字形")
        XCTAssertGreaterThan(h12, h10 + 1, "10pt 与 12pt 墨迹等高(\(h12) vs \(h10))→ 字号被写死的 12pt 覆盖")
    }

    /// 换文案要重算按钮宽度(英文比中文宽,不重算会被裁)
    @MainActor func testLabelSwitchReflowsWidth() {
        let savedTheme = wdThemeID
        defer { wdThemeID = savedTheme }
        wdThemeID = "mist"
        let bar = PillBar(items: [("总览", "总览")])
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 31)
        bar.layoutSubtreeIfNeeded()
        let zhW = bar.fittingSize.width
        bar.setLabels(["Overview"])
        bar.layoutSubtreeIfNeeded()
        let enW = bar.fittingSize.width
        XCTAssertGreaterThan(enW, zhW + 20, "换文案后宽度没跟着变(中文 \(Int(zhW)) → 英文 \(Int(enW)))")
    }
}
