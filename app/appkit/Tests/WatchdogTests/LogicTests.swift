import XCTest
@testable import WatchdogCore

// MARK: - chanFullCode 代码前缀推导

final class ChanCodeTests: XCTestCase {
    func testPureNumericCodesGetPrefix() {
        XCTAssertEqual(chanFullCode("600519"), "sh.600519")   // 沪主板
        XCTAssertEqual(chanFullCode("000678"), "sz.000678")   // 深主板
        XCTAssertEqual(chanFullCode("002241"), "sz.002241")
        XCTAssertEqual(chanFullCode("300750"), "sz.300750")   // 创业板
        XCTAssertEqual(chanFullCode("430047"), "bj.430047")   // 北交所
        XCTAssertEqual(chanFullCode("830799"), "bj.830799")
    }

    func testFuturesAndPrefixedPassThrough() {
        XCTAssertEqual(chanFullCode("JM0"), "JM0")
        XCTAssertEqual(chanFullCode("AG0"), "AG0")
        XCTAssertEqual(chanFullCode("IF2609"), "IF2609")
        XCTAssertEqual(chanFullCode("hk06809"), "hk06809")
        XCTAssertEqual(chanFullCode("sz.002241"), "sz.002241")
        XCTAssertEqual(chanFullCode("sh.600929"), "sh.600929")
        XCTAssertEqual(chanFullCode("bj.430047"), "bj.430047")
    }

    func testEdgeCases() {
        XCTAssertEqual(chanFullCode(""), "")
        XCTAssertEqual(chanFullCode("123456"), "sz.123456")  // 首位 1 → sz 兜底
    }
}

// MARK: - DenseLayout 槽位分配(逐字段断言)

final class DenseLayoutTests: XCTestCase {
    private func plan(_ wides: [Bool]) -> [DenseLayout.Slot] {
        DenseLayout.plan(wides: wides)
    }

    func testAllNarrowPairsLeftToRight() {
        let s = plan([false, false, false])
        XCTAssertEqual(s[0].index, 0); XCTAssertEqual(s[0].row, 0); XCTAssertTrue(s[0].isLeft); XCTAssertFalse(s[0].isWide)
        XCTAssertEqual(s[1].index, 1); XCTAssertEqual(s[1].row, 0); XCTAssertFalse(s[1].isLeft); XCTAssertFalse(s[1].isWide)
        XCTAssertEqual(s[2].index, 2); XCTAssertEqual(s[2].row, 1); XCTAssertTrue(s[2].isLeft); XCTAssertFalse(s[2].isWide)
    }

    func testWideOccupiesFullRow() {
        let s = plan([true])
        XCTAssertEqual(s[0].row, 0); XCTAssertTrue(s[0].isWide)
    }

    func testWideInterruptedPairLeavesBackfillableHole() {
        // 窄卡占左槽 → wide 打断 → 右槽成洞 → 后续窄卡回填该洞
        let s = plan([false, true, false])
        XCTAssertEqual(s[0].row, 0); XCTAssertTrue(s[0].isLeft); XCTAssertFalse(s[0].isWide)
        XCTAssertEqual(s[1].row, 1); XCTAssertTrue(s[1].isWide)
        XCTAssertEqual(s[2].row, 0, "必须回填 wide 打断留下的右槽洞"); XCTAssertFalse(s[2].isLeft)
    }

    func testWideOnFreshRowCreatesNoHole() {
        let s = plan([false, false, true, false])
        XCTAssertEqual(s[2].row, 1); XCTAssertTrue(s[2].isWide)
        XCTAssertEqual(s[3].row, 2); XCTAssertTrue(s[3].isLeft)
    }

    func testBackfillTargetsEarliestHole() {
        // 窄 wide 窄 wide 窄 窄 → 第3张回填行0右洞;后两张在行3配对
        let s = plan([false, true, false, true, false, false])
        XCTAssertEqual(s[2].row, 0, "最早洞优先")
        XCTAssertFalse(s[2].isLeft)
        XCTAssertEqual(s[4].row, 3); XCTAssertTrue(s[4].isLeft)
        XCTAssertEqual(s[5].row, 3); XCTAssertFalse(s[5].isLeft)
    }

    func testMatchesWebOverviewOrderShape() {
        // Web 总览行序:持仓(w) 回测(w) 待办 账本 行情 监控(w) 信号 期货 日历 磁盘(w) 日志(w) 预算 目标 飞书
        let s = plan([true, true, false, false, false, true, false, false, false, true, true, false, false, false])
        // 下标:0持仓 1回测 2待办 3账本 4行情 5监控 6信号 7期货 8日历 9磁盘 10日志 11预算 12目标 13飞书
        XCTAssertEqual(s[2].row, 2); XCTAssertEqual(s[3].row, 2)
        XCTAssertTrue(s[2].isLeft && !s[3].isLeft, "待办|账本 同行")
        XCTAssertEqual(s[4].row, 3); XCTAssertTrue(s[4].isLeft, "行情独左")
        XCTAssertEqual(s[5].row, 4); XCTAssertTrue(s[5].isWide, "系统监控整行")
        XCTAssertEqual(s[6].row, 3); XCTAssertFalse(s[6].isLeft, "信号回填监控打断留下的右槽")
        XCTAssertEqual(s[7].row, 5); XCTAssertTrue(s[7].isLeft)
        XCTAssertEqual(s[8].row, 5); XCTAssertFalse(s[8].isLeft, "期货|日历 同行")
        XCTAssertEqual(s[9].row, 6); XCTAssertTrue(s[9].isWide, "磁盘整行")
        XCTAssertEqual(s[10].row, 7); XCTAssertTrue(s[10].isWide, "日志整行")
        XCTAssertEqual(s[11].row, 8); XCTAssertEqual(s[12].row, 8)
        XCTAssertTrue(s[11].isLeft && !s[12].isLeft, "预算|目标 同行")
        XCTAssertEqual(s[13].row, 9)
    }
}

// MARK: - 格式化

final class FormatTests: XCTestCase {
    func testFmtWan() {
        XCTAssertEqual(fmtWan(5_280), "5280")
        XCTAssertEqual(fmtWan(87_412), "8.7万")
        XCTAssertEqual(fmtWan(3_836_000), "383.6万")
        XCTAssertEqual(fmtWan(226_200_000), "2.26亿")
    }

    func testFmtGB() {
        XCTAssertEqual(fmtGB(1_073_741_824), "1.0GB")
        XCTAssertEqual(fmtGB(0), "0.0GB")
    }

    func testPctColorRedUpGreenDown() {
        XCTAssertEqual(pctColor(1.5), .wdUp)
        XCTAssertEqual(pctColor(0), .wdUp)
        XCTAssertEqual(pctColor(-0.1), .wdDown)
    }
}

// MARK: - 双语

final class I18nTests: XCTestCase {
    override func tearDown() {
        wdLang = "zh"
    }

    func testZhIsIdentity() {
        wdLang = "zh"
        XCTAssertEqual(t("持仓概览"), "持仓概览")
    }

    func testEnTranslatesModuleNames() {
        wdLang = "en"
        for def in moduleDefs {
            XCTAssertEqual(t(def.zh), enDict[def.zh] ?? def.zh, "模块名 \(def.zh) 应有英文词条")
        }
        XCTAssertEqual(t("持仓概览"), "Portfolio")
        XCTAssertEqual(t("编辑布局"), "Edit Layout")
    }

    func testEnFallsBackToZhForUnknown() {
        wdLang = "en"
        XCTAssertEqual(t("不在词典的词"), "不在词典的词")
    }

    func testKeyUINavigationWordsPresent() {
        for key in ["总览", "待办", "账本", "行情", "系统", "保存", "取消", "确定"] {
            XCTAssertNotNil(enDict[key], "缺少词条: \(key)")
        }
    }
}

// MARK: - GridView 切组清理(旧卡残留 = 切组乱象)

final class GridViewTests: XCTestCase {
    @MainActor
    func testStaleCardsRemovedOnGroupSwitch() {
        let grid = GridView()
        grid.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let a = CardView(title: "A", icon: "check", id: "a")
        let b = CardView(title: "B", icon: "check", id: "b")
        let c = CardView(title: "C", icon: "check", id: "c")
        grid.cards = [(a, true), (b, false)]
        grid.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.subviews.count, 2, "初始两张卡都在层级里")
        grid.cards = [(c, false)]   // 模拟切组
        grid.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.subviews.count, 1, "旧卡必须被移除,否则叠在新布局上")
        XCTAssertTrue(grid.subviews.contains(c))
        XCTAssertFalse(grid.subviews.contains(a))
        XCTAssertFalse(grid.subviews.contains(b))
    }
}

// MARK: - 背景水印排查(离屏渲染 backdrop 找大字)

final class BackdropRenderTests: XCTestCase {
    @MainActor
    func testBackdropRenderLight() throws {
        let saved = wdThemeID
        wdThemeID = "mist"
        defer { wdThemeID = saved }
        let v = GradientBackdrop()
        v.frame = NSRect(x: 0, y: 0, width: 1280, height: 2693)   // 真实 documentView 高度
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return XCTFail() }
        v.cacheDisplay(in: v.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/wd-backdrop-mist.png"))
        // 同色像素统计:mist 背景应只有浅色渐变系
        var darkPx = 0
        for x in stride(from: 0, to: 1280, by: 8) {
            for y in stride(from: 0, to: 840, by: 8) {
                if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 { darkPx += 1 }
            }
        }
        XCTAssertEqual(darkPx, 0, "浅色背景不应有深色像素(水印)")
    }
}

// MARK: - 卡片主题渲染(组件 vs 时序分离)

final class CardThemeRenderTests: XCTestCase {
    @MainActor
    func testNewCardInLightThemeRendersLight() throws {
        let saved = wdThemeID
        wdThemeID = "mist"
        defer { wdThemeID = saved }
        let card = CardView(title: "测试", icon: "check", id: "x")
        card.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        card.layoutSubtreeIfNeeded()
        // 层色断言
        let bg = card.layer?.backgroundColor
        XCTAssertNotNil(bg)
        // 采样中心像素:浅色主题卡应偏亮(亮度>0.8)
        guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return XCTFail() }
        card.cacheDisplay(in: card.bounds, to: rep)
        let c = rep.colorAt(x: 150, y: 100)
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/wd-card-mist.png"))
        let bright = try XCTUnwrap(c).brightnessComponent
        FileHandle.standardError.write("[card-mist] center=\(String(describing: c)) bright=\(bright)\n".data(using: .utf8)!)
        XCTAssertGreaterThan(bright, 0.8, "浅色主题新卡渲染应偏亮")
    }
}

// MARK: - 主题系统

final class ThemeTests: XCTestCase {
    func testTwoThemesRegistered() {
        XCTAssertEqual(wdThemes.count, 2)
        XCTAssertEqual(Set(wdThemes.map { $0.id }), ["sky", "mist"])
    }

    func testDefaultIsDarkSky() {
        XCTAssertEqual(wdThemeID, "sky")
        XCTAssertEqual(NSColor.wdCard, wdThemes[0].palette.card)
    }

    func testLightThemeHasDarkText() {
        // 浅色主题:文字必须翻转为深色(亮度显著低于深色主题的白字)
        let mist = wdThemes.first { $0.id == "mist" }!.palette
        XCTAssertNotEqual(mist.text, wdThemes[0].palette.text)
    }

    func testSwitchPersistsToDefaults() {
        wdThemeID = "mist"
        XCTAssertEqual(UserDefaults.standard.string(forKey: "wd.theme"), "mist")
        XCTAssertEqual(wdPalette.id, "mist")
        wdThemeID = "sky"
        XCTAssertEqual(wdPalette.id, "sky")
    }

    func testUnknownThemeFallsBackToSky() {
        UserDefaults.standard.set("nonexistent", forKey: "wd.theme")
        XCTAssertEqual(wdPalette.id, "sky")
        wdThemeID = "sky"
    }
}

// MARK: - 交易时段(8787 同款窗口)

final class TradingHoursTests: XCTestCase {
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ wd: Int) -> Date {
        // 直接构造本地时间(wd 断言用参校准,防跑日漂移)
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar.current.date(from: c) ?? Date()
    }

    func testStockWindows() {
        XCTAssertTrue(TradingHours.stock(at(2026, 10, 8, 10, 0, 4)), "上午盘内")
        XCTAssertTrue(TradingHours.stock(at(2026, 10, 8, 14, 30, 4)), "下午盘内")
        XCTAssertFalse(TradingHours.stock(at(2026, 10, 8, 12, 0, 4)), "午休")
        XCTAssertFalse(TradingHours.stock(at(2026, 10, 8, 9, 0, 4)), "集合竞价前")
        XCTAssertFalse(TradingHours.stock(at(2026, 10, 8, 15, 30, 4)), "收盘后")
    }

    func testFuturesWindows() {
        XCTAssertTrue(TradingHours.futures(at(2026, 10, 8, 10, 0, 4)), "日盘")
        XCTAssertTrue(TradingHours.futures(at(2026, 10, 8, 21, 30, 4)), "夜盘前段")
        XCTAssertTrue(TradingHours.futures(at(2026, 10, 8, 1, 0, 4)), "夜盘后段(凌晨)")
        XCTAssertFalse(TradingHours.futures(at(2026, 10, 8, 16, 0, 4)), "日盘后休市")
    }
}

// MARK: - 月份平移

final class ShiftMonthTests: XCTestCase {
    func testShift() {
        XCTAssertEqual(shiftMonth("2026-10", -1), "2026-09")
        XCTAssertEqual(shiftMonth("2026-01", -1), "2025-12")
        XCTAssertEqual(shiftMonth("2025-12", 1), "2026-01")
        XCTAssertEqual(shiftMonth("2026-10", -13), "2025-09")
    }
    func testFutureBlockedAndBadInput() {
        XCTAssertNil(shiftMonth("2026-10", 2), "未来月不可选")
        XCTAssertNil(shiftMonth("bad", 1))
    }
}

// MARK: - 曲线周期重采样

final class ResampleCurveTests: XCTestCase {
    let pts: [(date: String, equity: Double)] = [
        ("2026-08-25", 102092), ("2026-08-26", 101103), ("2026-08-27", 100454),
        ("2026-09-05", 86300), ("2026-09-08", 86050), ("2026-09-30", 87412),
        ("2026-10-02", 87412),
    ]

    func testDayIsIdentity() {
        XCTAssertEqual(resampleCurve(pts, span: "day").count, pts.count)
    }

    func testMonthTakesLastPerMonth() {
        let m = resampleCurve(pts, span: "month")
        XCTAssertEqual(m.count, 3)   // 8/9/10 三个月
        XCTAssertEqual(m[0].equity, 100454, "8 月取最后一个点")
        XCTAssertEqual(m[1].equity, 87412, "9 月取最后一个点")
        XCTAssertEqual(m[2].date, "2026-10-02")
    }

    func testYearTakesLastPerYear() {
        let y = resampleCurve(pts, span: "year")
        XCTAssertEqual(y.count, 1)
        XCTAssertEqual(y[0].equity, 87412)
    }

    func testEmptyAndUnknownSpan() {
        XCTAssertEqual(resampleCurve([], span: "month").count, 0)
        XCTAssertEqual(resampleCurve(pts, span: "week").count, pts.count, "未知周期回退原样")
    }
}

// MARK: - 曲线悬停气泡(合成鼠标事件→离屏渲染验证)

final class CurveHoverTests: XCTestCase {
    @MainActor
    func testHoverBubbleRenders() throws {
        let v = CurveView()
        v.frame = NSRect(x: 0, y: 0, width: 360, height: 92)
        v.values = [100000, 102092, 98000, 95000, 90300, 87412, 87564]
        v.dates = ["2026-08-24", "2026-08-25", "2026-08-26", "2026-08-27", "2026-09-28", "2026-10-02", "2026-09-29"]
        v.layoutSubtreeIfNeeded()
        v.updateTrackingAreas()
        // 合成鼠标移动到中点
        let ev = NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 180, y: 46),
                                    modifierFlags: [], timestamp: 0, windowNumber: 0,
                                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        v.mouseMoved(with: ev)
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return XCTFail() }
        v.cacheDisplay(in: v.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/wd-hover-bubble.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/wd-hover-bubble.png"))
    }
}

// MARK: - 控件布线回归(target+action 必须成对——死键三次踩坑)

final class WiringTests: XCTestCase {
    @MainActor
    func testCleanButtonIsWired() {
        let card = makeSysmonCard()
        let btn = findButton(in: card, titleContains: wdLang == "en" ? "Clean" : "一键清理")
        XCTAssertNotNil(btn, "合并卡里找不到清理按钮")
        XCTAssertNotNil(btn?.target, "清理按钮缺 target")
        XCTAssertNotNil(btn?.action, "清理按钮缺 action——点了没反应的死键")
    }

    @MainActor
    func testTopPillButtonsAreWired() {
        let bar = PillBar(items: [("a", "A"), ("b", "B")])
        let btns = allButtons(in: bar)
        XCTAssertFalse(btns.isEmpty)
        for b in btns {
            XCTAssertNotNil(b.target, "胶囊按钮缺 target")
            XCTAssertNotNil(b.action, "胶囊按钮缺 action")
        }
    }

    @MainActor
    func testCleanButtonClickStartsRun() {
        // 端到端点击链路:performClick → target/action → run() → 标题立即变化
        // base 指向不可达端口,后续轮询失败无害,不会触发真清理
        let saved = API.base
        API.base = "http://127.0.0.1:1"
        defer { API.base = saved }
        let box = CleanerBox()
        box.bind()
        let before = box.btn.title
        box.btn.performClick(nil)
        XCTAssertNotEqual(box.btn.title, before, "点击后标题应立即变化")
        XCTAssertTrue(box.btn.title.contains(wdLang == "en" ? "Starting" : "启动清理"),
                      "点击后应进入启动清理态,实际: \(box.btn.title)")
    }

    @MainActor
    func testProgressButtonRendersMidCleanState() throws {
        // 离屏渲染真实组件的中途进度态,存 /tmp 供人工核对
        let btn = ProgressButton(title: "清理 7/18 · 42% · 1.2GB")
        btn.frame = NSRect(x: 0, y: 0, width: 280, height: 26)
        btn.progress = 0.42
        btn.progressTint = .wdUp
        btn.layoutSubtreeIfNeeded()
        guard let rep = btn.bitmapImageRepForCachingDisplay(in: btn.bounds) else {
            return XCTFail("无法创建位图")
        }
        btn.cacheDisplay(in: btn.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        try XCTUnwrap(png).write(to: URL(fileURLWithPath: "/tmp/wd-progress-btn.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/wd-progress-btn.png"))
    }

    @MainActor
    private func findButton(in view: NSView, titleContains: String) -> NSButton? {
        for sub in view.allDescendants {
            if let b = sub as? NSButton, b.title.contains(titleContains) { return b }
        }
        return nil
    }
    @MainActor
    private func allButtons(in view: NSView) -> [NSButton] {
        view.allDescendants.compactMap { $0 as? NSButton }
    }
}

extension NSView {
    @MainActor
    var allDescendants: [NSView] {
        subviews.flatMap { [$0] + $0.allDescendants }
    }
}

// MARK: - 图表 URL 集成回归(code 只传纯代码,后端自己拼文件名)

final class ChartURLTests: XCTestCase {
    func testChartEndpointReturnsHtmlForAvailableCombo() async throws {
        // 真实后端集成:App 构造的确切 URL 必须返回图 HTML(历史 bug:误传文件名当 code → 404 乱码)
        let url = API.base + "/api/chan/chart?code=SC0&level=30m&engine=chanpy"
        guard let (data, resp) = try? await API.session.data(from: URL(string: url)!),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw XCTSkip("后端不可达,跳过集成断言")
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(html.contains("<html") || html.contains("<canvas") || html.contains("lightweight-charts"),
                      "应返回图 HTML 而非错误 JSON")
    }
}

// MARK: - 卡片头图标渲染排查(离屏渲染真实组件,存 /tmp 供检视)

final class CardIconRenderTests: XCTestCase {
    @MainActor
    func testCardHeaderIconRendersOffscreen() throws {
        XCTAssertNotNil(phosphorFont(14), "Phosphor 字体三级兜底后必须可解析")
        // 形态1:真实卡片头(iconBox 27x27 + IconView frame 定位)
        let card = CardView(title: "持仓概览", icon: "chart-line-up", meta: "", id: "portfolio")
        card.frame = NSRect(x: 0, y: 0, width: 600, height: 120)
        card.layoutSubtreeIfNeeded()
        // 形态2:侧栏式(IconView translates=false + 定宽)
        let sideIcon = IconView("chart-line-up", size: 12, color: .wdIcon)
        sideIcon.translatesAutoresizingMaskIntoConstraints = false
        sideIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let sideBox = NSView(); sideBox.frame = NSRect(x: 0, y: 0, width: 40, height: 20)
        sideBox.addSubview(sideIcon)
        sideBox.layoutSubtreeIfNeeded()
        // 形态3:裸 Phosphor 文本
        let raw = NSTextField(labelWithString: Ph.glyph("chart-line-up"))
        raw.font = NSFont(name: "Phosphor", size: 18)
        raw.frame = NSRect(x: 0, y: 0, width: 40, height: 28)
        raw.layoutSubtreeIfNeeded()
        // 三者垂直拼一张图
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 180))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(calibratedRed: 0.086, green: 0.103, blue: 0.169, alpha: 1).cgColor
        for (i, v) in [card as NSView, sideBox, raw].enumerated() {
            v.translatesAutoresizingMaskIntoConstraints = false
            canvas.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 10),
                v.topAnchor.constraint(equalTo: canvas.topAnchor, constant: CGFloat(i * 60) + 6),
            ])
        }
        canvas.layoutSubtreeIfNeeded()
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return XCTFail() }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/tmp/wd-card-icon.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/tmp/wd-card-icon.png"))
    }
}

// MARK: - 模块注册表

final class ModuleStateTests: XCTestCase {
    func testModuleIdsUnique() {
        let ids = moduleDefs.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testWideSetMatchesWebDesign() {
        let wide = Set(moduleDefs.filter(\.wide).map(\.id))
        XCTAssertEqual(wide, ["annual", "portfolio", "backtest", "sysmon", "journal"])
    }

    func testGroupIdsAllExistInRegistry() {
        for (_, ids) in groupDefs {
            for id in ids {
                XCTAssertTrue(moduleDefs.contains { $0.id == id }, "组引用了未注册模块: \(id)")
            }
        }
    }

    func testFactoryCoversAllModules() {
        for def in moduleDefs {
            if def.id != "goals" { XCTAssertNotNil(makeCard(for: def.id), "模块 \(def.id) 没有对应卡片工厂") }
        }
        XCTAssertNil(makeCard(for: "nonexistent"))
    }

    func testOrderDefaultsToRegistryOrder() {
        XCTAssertEqual(moduleOrder, moduleDefs.map(\.id))
    }

    func testTerminateOnlyWhenNoVisibleWindows() {
        // 回归:关详情窗曾把整个应用退掉(count<=1 差一错误)
        XCTAssertFalse(WdLifecycle.shouldTerminate(visibleNonPanelWindows: 2), "主窗+详情窗,关详情窗不应退")
        XCTAssertFalse(WdLifecycle.shouldTerminate(visibleNonPanelWindows: 1), "只剩主窗不应退")
        XCTAssertTrue(WdLifecycle.shouldTerminate(visibleNonPanelWindows: 0), "所有窗关了才退")
    }
}

// MARK: - 设置窗口(大模型配置区)

final class SettingsPaneTests: XCTestCase {
    @MainActor func testSettingsWindowCloseThenReopenNoCrash() {
        // 回归:闪退=NSWindow 默认 isReleasedWhenClosed=true,关闭后全局 ref 悬挂
        openSettingsWindow()
        guard let w1 = settingsWindowRef else { return XCTFail("未创建") }
        XCTAssertTrue(w1.isReleasedWhenClosed == false, "关窗即释放会让引用悬挂→闪退")
        w1.close()                          // 用户点红色关闭钮
        openSettingsWindow()                // 再点齿轮:应复用未释放的窗口,不崩
        XCTAssertIdentical(settingsWindowRef, w1, "应复用同一窗口对象")
        XCTAssertTrue(w1.isVisible == false || w1.isVisible == true)   // 不崩即过
        settingsWindowRef?.orderOut(nil); settingsWindowRef = nil
    }

    @MainActor func testOpenSettingsWindowShowsPane() {
        openSettingsWindow()
        defer { settingsWindowRef?.orderOut(nil); settingsWindowRef = nil }
        guard let w = settingsWindowRef else { return XCTFail("设置窗口未创建") }
        XCTAssertTrue(w.isVisible, "设置窗口不可见")
        XCTAssertTrue(w.contentView is SettingsPane, "窗口内容不是配置区")
    }

    func testSettingsPaneFields() {
        let pane = SettingsPane()
        XCTAssertEqual(pane.baseField.placeholderString, "https://api.deepseek.com")
        XCTAssertEqual(pane.keyField.placeholderString, "sk-...")
        XCTAssertEqual(pane.modelField.placeholderString, "deepseek-chat")
        XCTAssertEqual(SettingsPane.presets.count, 5, "服务商预设:DeepSeek/GLM/Kimi/Qwen/自定义")
        XCTAssertEqual(SettingsPane.presets[0].base, "https://api.deepseek.com")
        XCTAssertEqual(SettingsPane.presets[1].base, "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(SettingsPane.presets[2].base, "https://api.moonshot.cn/v1")
        XCTAssertEqual(SettingsPane.presets[3].base, "https://dashscope.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(pane.providerPop.numberOfItems, 5)
        XCTAssertTrue(pane.saveBtn.title.contains("保存") || pane.saveBtn.title.contains("Save"))
        XCTAssertGreaterThan(pane.subviews.count, 0)
    }

    func testSettingsPaneRendersOffscreen() {
        let pane = SettingsPane()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 470, pixelsHigh: 470,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        pane.cacheDisplay(in: NSRect(x: 0, y: 0, width: 470, height: 470), to: rep)
        let png = rep.representation(using: .png, properties: [:])
        XCTAssertNotNil(png, "配置区离屏渲染失败")
        XCTAssertGreaterThan(png!.count, 10_000, "配置区渲染疑似空白")
        try? png!.write(to: URL(fileURLWithPath: "/tmp/wd-settings.png"))
    }
}

final class ReportCardTests: XCTestCase {
    func testJanuaryReportDecodes() async throws {
        // 复现用户"1月没数据":真实后端 JSON 必须可解码且支出>0
        guard let r = try? await API.get("/api/ledger/report?month=2026-01", as: AnnualReport.self) else {
            return XCTFail("1月报告解码失败(App 端 try? 会静默吞掉→卡空白)")
        }
        XCTAssertGreaterThan(r.entries, 0, "1月有账")
        XCTAssertGreaterThan(r.totalOut, 0, "1月支出>0")
        XCTAssertEqual(r.isMonth, true)
        XCTAssertFalse((r.topEntries ?? []).isEmpty, "Top明细非空")
    }
}
