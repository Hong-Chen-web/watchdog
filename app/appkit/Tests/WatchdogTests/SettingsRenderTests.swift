import XCTest
@testable import WatchdogCore

// MARK: - 设置窗离屏渲染(锁屏可跑;PNG 落 /tmp 供目测)

final class SettingsRenderTests: XCTestCase {

    @MainActor
    func testSettingsPaneRendersOffscreenPNG() async throws {
        let pane = SettingsPane()
        pane.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        pane.layoutSubtreeIfNeeded()
        pane.loadNow()                       // 拉真实 LLM 配置 + 机器人列表
        try await Task.sleep(nanoseconds: 1_500_000_000)
        pane.layoutSubtreeIfNeeded()
        // 调试:打印内容栈各行 frame(定位塌陷)
        let mirror = Mirror(reflecting: pane)
        for c in mirror.children where c.label == "content" {
            if let stack = c.value as? NSStackView {
                print("content frame:", stack.frame)
                for (i, v) in stack.arrangedSubviews.enumerated() {
                    print("  [\(i)] \(type(of: v)) frame=\(v.frame)")
                }
            }
        }
        guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else {
            return XCTFail("bitmapImageRep 创建失败")
        }
        pane.cacheDisplay(in: pane.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/settings_offscreen.png"))
        XCTAssertGreaterThan(png.count, 30_000, "PNG 过小,疑似空白渲染")
    }
}

final class SettingsPagesRenderTests: XCTestCase {
    @MainActor
    func testLLMAndFeishuPagesRender() async throws {
        let pane = SettingsPane()
        pane.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        pane.loadNow()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        for (id, name) in [("llm", "llm")] {
            pane.select(id)
            pane.layoutSubtreeIfNeeded()
            guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { continue }
            pane.cacheDisplay(in: pane.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/settings_\(name).png"))
            }
        }
    }
}

final class SettingsThemeTests: XCTestCase {
    @MainActor
    func testLightThemeRendersLight() {
        let saved = wdThemeID
        defer { wdThemeID = saved }
        wdThemeID = "mist"   // 浅色
        let pane = SettingsPane()
        pane.frame = NSRect(x: 0, y: 0, width: 780, height: 560)
        pane.layoutSubtreeIfNeeded()
        guard let rep = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else {
            return XCTFail("rep")
        }
        pane.cacheDisplay(in: pane.bounds, to: rep)
        // 取内容区中心样本(避开侧栏):亮度应为浅色
        // 内容区中心(避开侧栏 184pt):pt(450,300) → 2x 像素 (900,600)
        guard let c = rep.colorAt(x: 900, y: 600) else { return XCTFail("取色失败") }
        let lum = (Double(c.redComponent ?? 0) + Double(c.greenComponent ?? 0)
            + Double(c.blueComponent ?? 0)) / 3 * 255
        XCTAssertGreaterThan(lum, 140, "浅色主题下设置窗仍偏暗(亮度\(Int(lum)))")
    }
}
