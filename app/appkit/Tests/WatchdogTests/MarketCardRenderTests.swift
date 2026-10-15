import XCTest
@testable import WatchdogCore

final class MarketCardRenderTests: XCTestCase {
    @MainActor
    func testMarketCardHeaderPillRenders() async throws {
        let card = makeMarketCard(openChart: { _, _ in })
        card.frame = NSRect(x: 0, y: 0, width: 620, height: 470)
        try await Task.sleep(nanoseconds: 1_200_000_000)   // 等级别回填+首轮行情
        card.layoutSubtreeIfNeeded()
        for v in card.subviews where v.accessibilityIdentifier() == "wd-monitor-level" {
            print("pill frame:", v.frame, "| translates:", v.translatesAutoresizingMaskIntoConstraints)
            for c in v.constraints { print("   self-c:", c) }
        }
        for c in card.constraints {
            let items = [c.firstItem as? NSView, c.secondItem as? NSView]
            if items.contains(where: { $0?.accessibilityIdentifier() == "wd-monitor-level" }) {
                print("   card-c:", c.firstAttribute.rawValue, c.relation.rawValue, c.secondAttribute.rawValue, c.constant)
            }
        }
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
            return XCTFail("rep")
        }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("png")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/market_card.png"))
        XCTAssertGreaterThan(png.count, 20_000)
    }
}
