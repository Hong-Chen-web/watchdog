import XCTest
@testable import WatchdogCore

// MARK: - 飞书推送卡离屏渲染(webhook 行内编辑 + 票池下拉;PNG 落 /tmp 目测)

final class FeishuCardRenderTests: XCTestCase {

    @MainActor
    func testFeishuCardRendersOffscreenPNG() async throws {
        let card = makeFeishuCard()
        card.frame = NSRect(x: 0, y: 0, width: 620, height: 420)
        try await Task.sleep(nanoseconds: 2_500_000_000)   // 等 config+scope 拉取渲染
        card.layoutSubtreeIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
            return XCTFail("bitmapImageRep 创建失败")
        }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/feishu_card_offscreen.png"))
        XCTAssertGreaterThan(png.count, 20_000, "PNG 过小,疑似空白")
    }
}
