import XCTest
@testable import WatchdogCore

// MARK: - 总览面板离屏渲染(三指标方块 + 待办明细;数据取真实后端,渲染不依赖数据到位)

final class OverviewRenderTests: XCTestCase {
    @MainActor
    func testOverviewCardRendersOffscreenPNG() async throws {
        let card = makeOverviewCard(openGroup: { _ in })
        card.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        card.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 2_500_000_000)   // 等首轮数据
        card.layoutSubtreeIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
            return XCTFail("bitmapImageRep 创建失败")
        }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/overview_offscreen.png"))
        XCTAssertGreaterThan(png.count, 15_000, "PNG 过小,疑似空白渲染")

        // 三个方块的 accessibility 标识应存在(布局塌陷时会丢)
        let ids = Set(card.recursiveAccessIds())
        for want in ["wd-ov-spend", "wd-ov-todo", "wd-ov-pnl"] {
            XCTAssertTrue(ids.contains(want), "缺少方块 \(want)(疑似布局塌陷)")
        }
    }
}

private extension NSView {
    func recursiveAccessIds() -> [String] {
        var out: [String] = []
        let id = accessibilityIdentifier()
        if !id.isEmpty { out.append(id) }
        for v in subviews { out += v.recursiveAccessIds() }
        return out
    }
}
