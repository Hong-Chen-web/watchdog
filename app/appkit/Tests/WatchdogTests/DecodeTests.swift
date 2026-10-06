import XCTest
@testable import WatchdogCore

/// 解码回归:用真实接口抓取的夹具验证模型可解码。
/// 这是"卡片没数据"一类 bug 的防线——后端 snake_case、模型键名不符、
/// 字段形状不符(如 gpu 数组)都会在这里爆炸,而不是在界面上静默空白。
final class DecodeTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)
            ?? Bundle.module.url(forResource: name, withExtension: nil)
        return try Data(contentsOf: XCTUnwrap(url, "fixture \(name) missing"))
    }

    func testDecodePortfolio() throws {
        let p = try API.decoder.decode(Portfolio.self, from: fixture("portfolio.json"))
        XCTAssertGreaterThan(p.total, 0)
        XCTAssertFalse(p.holdings.isEmpty)
        let h = p.holdings[0]
        XCTAssertFalse(h.name.isEmpty)
        XCTAssertNotNil(h.last)
        XCTAssertNotEqual(h.pnlPct, 0, "pnl_pct 键名必须映射到 pnlPct")
    }

    func testDecodeBacktestRuns() throws {
        let runs = try API.decoder.decode([BacktestRun].self, from: fixture("backtest_runs.json"))
        XCTAssertFalse(runs.isEmpty)
        let r = runs[0]
        XCTAssertEqual(r.finalEquity ?? 0, 3_836_000, accuracy: 1)
        XCTAssertEqual(r.totalReturn ?? 0, 3736, accuracy: 0.5)
        XCTAssertEqual(r.trades, 1170)
        XCTAssertEqual(r.winRate ?? 0, 50, accuracy: 0.1)
        XCTAssertEqual(r.plRatio ?? 0, 2.01, accuracy: 0.01)
    }

    func testDecodeBacktestLive() throws {
        let b = try API.decoder.decode(LiveBacktest.self, from: fixture("backtest_live.json"))
        XCTAssertEqual(b.principal, 100000)
        XCTAssertEqual(b.realizedNet, -14054)
        XCTAssertEqual(b.rounds, 115)
        XCTAssertEqual(b.winRounds, 46)
        XCTAssertEqual(b.worst, -5754)
        XCTAssertGreaterThan(b.curve.count, 20, "实盘曲线点数")
        XCTAssertFalse(b.curve.first?.date.isEmpty ?? true)
    }

    func testDecodeMarketQuotes() throws {
        let q = try API.decoder.decode(QuotesResponse.self, from: fixture("market_quotes.json"))
        let idx = try XCTUnwrap(q.indices?["上证指数"])
        XCTAssertGreaterThan(idx.price, 0)
        let wl = try XCTUnwrap(q.watchlist?.first)
        XCTAssertFalse(wl.name.isEmpty)
        XCTAssertNotNil(wl.chgPct, "chg_pct 必须映射到 chgPct")
    }

    func testDecodeLedgerSummary() throws {
        let s = try API.decoder.decode(LedgerSummary.self, from: fixture("ledger_summary.json"))
        XCTAssertGreaterThan(s.expense, 0)
        let cat = try XCTUnwrap(s.categories.first)
        XCTAssertNotEqual(cat.budgetMonth, 0, "budget_month 必须映射到 budgetMonth")
        XCTAssertNotEqual(cat.budgetYear, 0, "budget_year 必须映射到 budgetYear")
        XCTAssertFalse(cat.name.isEmpty)
    }

    func testDecodeLedgerEntries() throws {
        let entries = try API.decoder.decode([LedgerEntry].self, from: fixture("ledger_entries.json"))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].amount, -85)
        XCTAssertEqual(entries[0].category, "食物")
    }

    func testDecodeAnnual() throws {
        let r = try API.decoder.decode(AnnualReport.self, from: fixture("ledger_annual.json"))
        XCTAssertEqual(r.year, 2026)
        XCTAssertEqual(r.entries, 296)
        XCTAssertGreaterThan(r.totalOut, 50000)
        XCTAssertFalse(r.months.isEmpty, "月度趋势")
        XCTAssertFalse(r.cats.isEmpty, "分类结构")
        XCTAssertNotNil(r.anomalies)
        XCTAssertNotNil(r.tips)
        XCTAssertNotNil(r.nextYearPlan)
    }

    func testDecodeTodos() throws {
        let todos = try API.decoder.decode([TodoItem].self, from: fixture("todos.json"))
        XCTAssertGreaterThanOrEqual(todos.count, 5)
        XCTAssertNotNil(todos[0].dueDate, "due_date 必须映射到 dueDate")
        XCTAssertFalse(todos[0].title.isEmpty)
    }

    func testDecodeJournal() throws {
        let j = try API.decoder.decode(JournalDay.self, from: fixture("journal.json"))
        XCTAssertEqual(j.entries?.first?.content, "v2 总结覆盖测试")
        XCTAssertNotNil(j.entries?.first?.createdAt, "created_at 必须映射到 createdAt")
    }

    func testDecodeSysmon() throws {
        let m = try API.decoder.decode(SysmonMetrics.self, from: fixture("sysmon.json"))
        XCTAssertGreaterThan(m.healthScore, 0)
        XCTAssertNotNil(m.healthScoreMsg)
        XCTAssertGreaterThan(m.cpu?.usage ?? -1, 0)
        XCTAssertNotNil(m.cpu?.pCoreCount, "p_core_count 必须映射到 pCoreCount")
        XCTAssertGreaterThan(m.memory?.usedPercent ?? -1, 0)
        // gpu 是数组:单对象模型会让整个解码失败(历史 bug)
        let gpu = try XCTUnwrap(m.gpu?.first, "gpu 必须按数组解码")
        XCTAssertFalse(gpu.name?.isEmpty ?? true)
        XCTAssertNotNil(m.disks?.first?.usedPercent)
        XCTAssertNotNil(m.network?.first?.rxRateMbs, "rx_rate_mbs 必须映射到 rxRateMbs")
        XCTAssertNotNil(m.batteries?.first?.percent)
        XCTAssertFalse(m.topProcesses?.isEmpty ?? true)
    }

    func testDecodeDiskScan() throws {
        let s = try API.decoder.decode(DiskScan.self, from: fixture("disk_clean_scan.json"))
        XCTAssertGreaterThan(s.totalBytes, 0)
        let item = try XCTUnwrap(s.groups.first?.items.first)
        XCTAssertFalse(item.sizeTxt.isEmpty)
        XCTAssertGreaterThan(item.sizeBytes, 0)
    }

    func testDecodeChanTail() throws {
        let t = try API.decoder.decode(ChanTail.self, from: fixture("chan_tail.json"))
        XCTAssertFalse(t.stocks?.isEmpty ?? true)
        XCTAssertEqual(t.stocks?.first?.name, "雪天盐业")
    }

    func testDecodeChanFutures() throws {
        let f = try API.decoder.decode(FuturesState.self, from: fixture("chan_futures.json"))
        XCTAssertFalse(f.levels?.isEmpty ?? true)
        let s = try XCTUnwrap(f.stocks?.first)
        XCTAssertNotNil(s.chgPct, "chg_pct 必须映射到 chgPct")
        XCTAssertNotNil(s.chanpy?.biCount, "bi_count 必须映射到 biCount")
    }

    func testDecodeFeishuConfig() throws {
        let f = try API.decoder.decode(FeishuCfg.self, from: fixture("chan_feishu_config.json"))
        XCTAssertFalse(f.bots.isEmpty)
        XCTAssertNotNil(f.bots[0].codes)
        XCTAssertEqual(f.notify.count, 1)
    }

    func testDecodeGoals() throws {
        let g = try API.decoder.decode(GoalsResponse.self, from: fixture("goals.json"))
        XCTAssertFalse(g.groups.isEmpty)
        let item = try XCTUnwrap(g.groups.first?.items.first)
        XCTAssertNotNil(item.reviewDate, "review_date 必须映射到 reviewDate")
        XCTAssertFalse(item.title.isEmpty)
    }

    func testDecodeModules() throws {
        let mods = try API.decoder.decode([ModuleRow].self, from: fixture("modules.json"))
        XCTAssertEqual(mods.count, 14)
        XCTAssertTrue(mods.allSatisfy { !$0.id.isEmpty })
    }

    func testDecodePortfolioHistory() throws {
        let hist = try API.decoder.decode([PortfolioHistoryPoint].self, from: fixture("portfolio_history.json"))
        XCTAssertGreaterThan(hist.count, 10)
        XCTAssertGreaterThan(hist[0].total, 0)
    }
}
