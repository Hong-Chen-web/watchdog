import XCTest
@testable import WatchdogCore

final class FuturesCardRenderTests: XCTestCase {
    @MainActor
    func testFuturesCardHeaderPillRenders() async throws {
        let card = makeFuturesCard(openChart: { _, _ in })
        card.frame = NSRect(x: 0, y: 0, width: 620, height: 420)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        card.layoutSubtreeIfNeeded()
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
            return XCTFail("rep")
        }
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("png")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/futures_card.png"))
        XCTAssertGreaterThan(png.count, 15_000)
    }
}
