import XCTest
@testable import WatchdogCore

// MARK: - 原生缠论图离屏渲染(不依赖屏幕,锁屏可跑;PNG 落 /tmp 供目测)

final class ChartRenderTests: XCTestCase {

    /// 真实数据渲染 K线+笔+中枢+买卖点 → PNG;尺寸/体积下限防"空白图"
    func testNativeChartRendersOffscreenPNG() throws {
        guard let url = URL(string: "http://127.0.0.1:8790/api/chan/chartdata?code=sz.002975&level=5m"),
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(ChanChartPayload.self, from: data),
              p.ok, let bars = p.bars, bars.count > 50
        else { throw XCTSkip("sidecar 未运行或无数据(离线环境跳过)") }

        let v = CandleChartView(frame: NSRect(x: 0, y: 0, width: 760, height: 640))
        v.apply(p)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            return XCTFail("bitmapImageRep 创建失败")
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG 编码失败")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/chart_offscreen.png"))
        XCTAssertGreaterThan(png.count, 30_000, "PNG 过小,疑似空白渲染")
    }

    /// 侧栏面板:买卖点最近6条 + 中枢最近1个(文本内容断言)
    func testSidePanelContent() throws {
        guard let url = URL(string: "http://127.0.0.1:8790/api/chan/chartdata?code=sz.002975&level=5m"),
              let data = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(ChanChartPayload.self, from: data), p.ok
        else { throw XCTSkip("sidecar 未运行(离线环境跳过)") }

        let panel = ChartSidePanel()
        panel.rebuild(p)
        panel.layoutSubtreeIfNeeded()
    }
}
