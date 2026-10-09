import AppKit

// MARK: - 主窗口:dense 网格内容区 + 毛玻璃侧栏 + 46px 顶栏

var currentGroup = "总览"

/// 卡片工厂(id → 卡)
func makeCard(for id: String) -> CardView? {
    switch id {
    case "portfolio": return makePortfolioCard()
    case "backtest": return makeBacktestCard()
    case "todo": return makeTodoCard()
    case "ledger": return makeLedgerCard()
    case "annual": return makeAnnualCard()
    case "budget": return makeBudgetCard()
    case "market": return makeMarketCard { openChartWindow(code: $0, name: $1) }
    case "strategy": return makeStrategyCard()
    case "futures": return makeFuturesCard { openChartWindow(code: $0, name: $1) }
    case "calendar": return makeCalendarCard()
    case "feishu": return makeFeishuCard()
    case "sysmon": return makeSysmonCard()
    case "journal": return makeJournalCard()
    default: return nil
    }
}

/// 内容网格:dense 槽位(纯函数)+ 逐行等高摆放
final class GridView: NSView {
    var cards: [(CardView, Bool)] = [] { didSet { needsLayout = true } }  // (卡, wide)
    let gap: CGFloat = 16, pad: CGFloat = 16
    override var isFlipped: Bool { true }
    func relayout() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }
    override func viewDidEndLiveResize() { relayout() }
    override func layout() {
        super.layout()
        // 切组后清掉不在当前列表的旧卡,否则旧卡叠在新布局上(切组乱象根因)
        let keep = Set(cards.map { ObjectIdentifier($0.0) })
        for sub in subviews where !keep.contains(ObjectIdentifier(sub)) {
            sub.removeFromSuperview()
        }
        guard !cards.isEmpty else { return }
        let vw = bounds.width > 100 ? bounds.width
            : (superview as? NSClipView)?.bounds.width ?? 1000
        // 关键:documentView 自身宽度必须铺满 clipView,否则滚动区按 0 宽裁剪
        frame.size.width = max(vw, (superview as? NSClipView)?.bounds.width ?? vw)
        let inner = vw - pad * 2 - gap
        let colL = inner * 1.15 / 2.10, colR = inner * 0.95 / 2.10

        let slots = DenseLayout.plan(wides: cards.map(\.1))
        let byRow = Dictionary(grouping: slots, by: \.row)
        var y: CGFloat = pad
        for r in byRow.keys.sorted() {
            guard let rowSlots = byRow[r] else { continue }
            // 行高 = 行内最高卡(左右等高,与 Web align-items:stretch 对齐)
            let rh = rowSlots.map { max(cards[$0.index].0.fittingSize.height, 110) }.max() ?? 110
            for s in rowSlots {
                let card = cards[s.index].0
                card.layoutSubtreeIfNeeded()
                let w = s.isWide ? inner : (s.isLeft ? colL : colR)
                let x = s.isWide || s.isLeft ? pad : pad + colL + gap
                card.frame = NSRect(x: x, y: y, width: w, height: rh)
                if card.superview !== self { addSubview(card) }
            }
            y += rh + gap
        }
        frame.size.height = max(y + pad - gap, (superview?.bounds.height ?? 0))
    }
}

/// 构建主窗口(侧栏装配开关 / 顶栏胶囊+时钟+双语+编辑布局 / 五组视图)
public func buildMainWindow() -> NSWindow {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
    win.title = t("看门狗") + " Watchdog"
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden   // 不布局标题文本:否则重建界面后标题残影会浮在内容区(用户看到的"watchdog"水印)
    // 外观跟随主题:系统控件(输入框/下拉/开关)按对应模式渲染,否则浅色主题下白字白底全看不见
    win.appearance = NSAppearance(named: wdThemeID == "mist" ? .aqua : .darkAqua)
    win.backgroundColor = .wdWin
    win.center()

    // ---- 内容滚动区 ----
    let content = GridView()
    var cardsById: [String: CardView] = [:]
    let backdrop = GradientBackdrop()
    backdrop.autoresizingMask = [.width, .height]

    let scroll = NSScrollView()
    scroll.documentView = content
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.scrollerStyle = .overlay

    // ---- 组子项导航条(顶栏下方:标明当前组及其成员,点击滚动到对应卡) ----
    let subHost = NSView()
    subHost.wantsLayer = true
    subHost.layer?.backgroundColor = NSColor.wdOverlaySoft.cgColor
    let groupLabel = label("", size: 11, bold: true, color: .wdText3)
    let subItems = NSStackView()
    subItems.orientation = .horizontal; subItems.alignment = .centerY; subItems.spacing = 4
    subHost.addSubview(groupLabel)
    subHost.addSubview(subItems)
    groupLabel.translatesAutoresizingMaskIntoConstraints = false
    subItems.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        subHost.heightAnchor.constraint(equalToConstant: 34),
        groupLabel.leadingAnchor.constraint(equalTo: subHost.leadingAnchor, constant: 18),
        groupLabel.centerYAnchor.constraint(equalTo: subHost.centerYAnchor),
        subItems.leadingAnchor.constraint(greaterThanOrEqualTo: groupLabel.trailingAnchor, constant: 16),
        subItems.centerYAnchor.constraint(equalTo: subHost.centerYAnchor),
    ])

    func show(group: String) {
        let groupChanged = group != currentGroup
        currentGroup = group
        // 顺序与开关均以后端为准(与 Web 端同源);未认识的 id 由 compactMap 自然过滤
        let ids = (group == "总览" ? moduleOrder : (groupDefs.first { $0.0 == group }?.1 ?? []))
            .filter { moduleEnabled[$0] ?? true }
        for id in ids where cardsById[id] == nil {
            if let c = makeCard(for: id) { cardsById[id] = c }
        }
        content.cards = ids.compactMap { id in
            cardsById[id].map { ($0, moduleDefs.first { $0.id == id }?.wide ?? false) }
        }
        content.relayout()
        // 数据是异步到的:卡内数据到达后必须重摆,否则 fittingSize 停留在空态
        for delay in [0.3, 0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak content] in
                content?.relayout()
            }
        }
        // 子项导航:标明当前组及其成员,点击滚动到对应卡
        groupLabel.stringValue = group == "总览"
            ? (wdLang == "en" ? "ALL MODULES · \(ids.count)" : "全部模块 · \(ids.count) 张卡")
            : (wdLang == "en" ? t(group) + " · \(ids.count) modules" : t(group) + "组 · \(ids.count) 个模块")
        subItems.views.forEach { $0.removeFromSuperview() }
        if group != "总览" {
            for id in ids {
                let title = moduleDefs.first { $0.id == id }.map { t($0.zh) } ?? id
                let btn = textButton(title) { [weak scroll] in
                    guard let sv = scroll, let card = cardsById[id] else { return }
                    sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, card.frame.minY - 12)))
                    sv.reflectScrolledClipView(sv.contentView)
                }
                subItems.addView(btn, in: .leading)
            }
        }
        // 切组时滚动复位,避免停在上一个组的滚动深度看到空白
        if groupChanged {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // 语言切换 / 后端模块变化 → 全部重建
    var rebuildSidebar: () -> Void = {}
    func rebuildAll() {
        for (_, c) in cardsById { c.removeFromSuperview() }
        cardsById.removeAll()
        show(group: currentGroup)
        rebuildSidebar()
        // 层内容失效:重建后窗口服务器 surface 可能残留旧帧(v23 标题水印/卡片底色不换都是它),
        // 对整棵内容树强制重绘
        if let cv = win.contentView {
            cv.setNeedsDisplay(cv.bounds)
            for sub in cv.subviews { sub.setNeedsDisplay(sub.bounds) }
        }
    }
    NotificationCenter.default.addObserver(forName: .init("wd.langChanged"), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
            rebuildAll()
            backdrop.setNeedsDisplay(backdrop.bounds)
        }
    }
    NotificationCenter.default.addObserver(forName: .init("wd.modulesChanged"), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { show(group: currentGroup) }
    }
    NotificationCenter.default.addObserver(forName: .init("wd.smartRefresh"), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { rebuildAll() }
    }


    // ---- 顶部标题栏(46px + hairline,胶囊居中,右:时钟/EN/编辑布局) ----
    let seg = PillBar(items: [("总览", t("总览")), ("待办", t("待办")), ("账本", t("账本")),
                              ("行情", t("行情")), ("系统", t("系统"))])
    seg.onSelect = { id in show(group: id) }

    let clock = label("", size: 11.5, color: .wdText2, mono: true)
    let langBtn = NSButton(title: wdLang == "zh" ? "EN" : "中", target: nil, action: nil)
    langBtn.bezelStyle = .recessed; langBtn.controlSize = .small; langBtn.font = .systemFont(ofSize: 11.5)
    langBtn.onAction {
        wdLang = wdLang == "zh" ? "en" : "zh"
        langBtn.title = wdLang == "zh" ? "EN" : "中"
        NotificationCenter.default.post(name: .init("wd.langChanged"), object: nil)
    }
    // 主题按钮:两个主题来回切,标题显示将切换到的目标(与 EN/中 同款交互)
    let themeBtn = NSButton(title: wdThemeID == "sky" ? t("浅色") : t("深色"), target: nil, action: nil)
    themeBtn.bezelStyle = .recessed; themeBtn.controlSize = .small; themeBtn.font = .systemFont(ofSize: 11.5)
    themeBtn.onAction {
        wdThemeID = wdThemeID == "sky" ? "mist" : "sky"
        themeBtn.title = wdThemeID == "sky" ? t("浅色") : t("深色")
        NotificationCenter.default.post(name: .init("wd.themeChanged"), object: nil)
    }
    let editBtn = NSButton(title: t("编辑布局"), target: nil, action: nil)
    editBtn.bezelStyle = .recessed; editBtn.controlSize = .small; editBtn.font = .systemFont(ofSize: 11.5)
    editBtn.onAction {
        wdEditMode.toggle()
        editBtn.title = wdEditMode ? t("完成") : t("编辑布局")
    }

    // 设置(大模型配置区)
    let gearBtn: NSButton
    if let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置") {
        gearBtn = NSButton(image: img, target: nil, action: nil)
    } else {
        gearBtn = NSButton(title: "设置", target: nil, action: nil)
    }
    gearBtn.bezelStyle = .recessed; gearBtn.controlSize = .small
    gearBtn.onAction { openSettingsWindow() }

    func updateClock() {
        let f = DateFormatter()
        f.dateFormat = wdLang == "zh" ? "M月d日 EEE HH:mm" : "MMM d EEE HH:mm"
        f.locale = Locale(identifier: wdLang == "zh" ? "zh_CN" : "en_US")
        clock.stringValue = f.string(from: Date())
    }
    updateClock()
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
        MainActor.assumeIsolated { updateClock() }
    }

    // 全局命令条(最显眼入口):一句话→自动识别账单/待办/目标
    let smartTV = NSTextField()
    smartTV.placeholderString = wdLang == "en"
        ? "Anything: lunch ¥35 / buy cat food tomorrow / goal…" : "随便说:午饭35块 / 明天买猫粮 / 今年存5万…"
    smartTV.font = .systemFont(ofSize: 12)
    smartTV.bezelStyle = .roundedBezel
    smartTV.translatesAutoresizingMaskIntoConstraints = false
    smartTV.widthAnchor.constraint(equalToConstant: 330).isActive = true
    let smartFeedback = label("", size: 9.5, color: .wdDown)
    smartFeedback.isHidden = false
    let smartGo = NullableTarget {
        let txt = smartTV.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !txt.isEmpty else { return }
        smartTV.stringValue = ""
        smartFeedback.textColor = .wdText3
        smartFeedback.stringValue = wdLang == "en" ? "…" : "识别中…"
        Task {
            struct R: Codable { let engine: String?; let results: [String]?; let dedup: Bool? }
            func send() async throws -> R {
                var req = URLRequest(url: URL(string: API.base + "/api/ledger/smart-any")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["text": txt])
                let (data, _) = try await API.session.data(for: req)
                return try API.decoder.decode(R.self, from: data)
            }
            do {
                var r: R
                do { r = try await send() }
                catch {   // 后端重启窗口等瞬断:重试一次(服务端 120s 防重保证不记两遍)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    r = try await send()
                }
                await MainActor.run {
                    let lines = (r.results ?? []).prefix(3).joined(separator: "  ")
                    smartFeedback.textColor = .wdDown
                    let dup = r.dedup == true ? (wdLang == "en" ? " · duplicate skipped" : " · 重复已忽略") : ""
                    smartFeedback.stringValue = lines.isEmpty
                        ? (wdLang == "en" ? "not recognized" : "没识别出来,试试带金额或『记得…』")
                        : "✓ " + lines + dup
                }
                NotificationCenter.default.post(name: .init("wd.smartRefresh"), object: nil)
                // 8 秒后淡出反馈
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await MainActor.run { smartFeedback.stringValue = "" }
            } catch {
                await MainActor.run {
                    smartFeedback.textColor = .wdWarn
                    smartFeedback.stringValue = wdLang == "en"
                        ? "network error · retry in 2s" : "网络波动,已重试仍不通(数据多半已记录,稍后刷新查看)"
                }
            }
        }
    }
    smartTV.target = smartGo
    smartTV.action = #selector(NullableTarget.fire)

    let top = NSStackView()
    top.orientation = .horizontal
    top.spacing = 12
    top.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    top.setViews([seg], in: .center)
    top.setViews([smartTV, smartFeedback, clock, langBtn, themeBtn, editBtn, gearBtn], in: .trailing)
    // hairline 底边
    let topHost = NSView()
    topHost.wantsLayer = true
    topHost.layer?.backgroundColor = NSColor.wdOverlaySoft.cgColor
    let hairline = NSBox()
    hairline.boxType = .separator
    topHost.addSubview(top)
    topHost.addSubview(hairline)
    top.translatesAutoresizingMaskIntoConstraints = false
    hairline.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        top.topAnchor.constraint(equalTo: topHost.topAnchor),
        top.bottomAnchor.constraint(equalTo: hairline.topAnchor, constant: -1),
        top.leadingAnchor.constraint(equalTo: topHost.leadingAnchor),
        top.trailingAnchor.constraint(equalTo: topHost.trailingAnchor),
        top.heightAnchor.constraint(equalToConstant: 46),
        hairline.bottomAnchor.constraint(equalTo: topHost.bottomAnchor),
        hairline.leadingAnchor.constraint(equalTo: topHost.leadingAnchor),
        hairline.trailingAnchor.constraint(equalTo: topHost.trailingAnchor),
    ])

    let main = NSStackView()
    main.orientation = .vertical
    main.spacing = 0
    main.addView(topHost, in: .leading)
    main.addView(subHost, in: .leading)
    main.addView(scroll, in: .leading)
    main.alignment = .leading
    main.setHuggingPriority(.defaultHigh, for: .horizontal)

    // ---- 侧栏(深色底 + 品牌区顶部 / 装配开关 / 数据源状态底部) ----
    let sideHost = NSView()
    sideHost.wantsLayer = true
    sideHost.layer?.backgroundColor = NSColor.wdSide.cgColor
    func setupSidebar() {
        let brandBadge = NSView()
        brandBadge.wantsLayer = true
        brandBadge.layer?.backgroundColor = NSColor.wdAccent.cgColor
        brandBadge.layer?.cornerRadius = 8
        let badgeDog = IconView("dog", size: 17, color: .white)   // 与 App 图标同源:蓝底线条狗
        brandBadge.addSubview(badgeDog)
        badgeDog.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brandBadge.widthAnchor.constraint(equalToConstant: 30),
            brandBadge.heightAnchor.constraint(equalToConstant: 30),
            badgeDog.centerXAnchor.constraint(equalTo: brandBadge.centerXAnchor),
            badgeDog.centerYAnchor.constraint(equalTo: brandBadge.centerYAnchor),
        ])
        let brand = NSStackView(views: [
            brandBadge,
            NSStackView(views: [label(t("看门狗"), size: 13.5, bold: true),
                                label("WATCHDOG · v2", size: 9, color: .wdText3, mono: true)]),
        ])
        brand.orientation = .horizontal; brand.alignment = .centerY; brand.spacing = 9
        let inner = NSStackView(views: [brand])
        inner.orientation = .vertical; inner.alignment = .leading; inner.spacing = 10
        // 顶部避让无边框标题栏(46px)+ 左右呼吸边距,对齐 Web 版 top:46px 侧栏
        inner.edgeInsets = NSEdgeInsets(top: 54, left: 16, bottom: 16, right: 14)
        inner.addView(label(t("模块装配"), size: 10, bold: true, color: .wdText3), in: .leading)
        let switchRows = NSStackView()
        switchRows.orientation = .vertical; switchRows.alignment = .leading; switchRows.spacing = 6
        inner.addView(switchRows, in: .leading)
        // 弹性 spacer:吸收剩余高度,把品牌钉顶部、状态行钉底部
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        inner.addView(spacer, in: .leading)
        let status = NSStackView(views: [
            label("● " + t("数据服务"), size: 10, color: .wdDown, mono: true),
            label(t("腾讯 · 东财 · 新浪 · Mole"), size: 9.5, color: .wdText3, mono: true),
        ])
        status.orientation = .vertical; status.alignment = .leading; status.spacing = 2
        inner.addView(status, in: .leading)
        // 关键:栈必须四边钉死在侧栏容器上,否则按 fitting size 沉底、品牌飘中部
        sideHost.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: sideHost.topAnchor),
            inner.bottomAnchor.constraint(equalTo: sideHost.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: sideHost.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: sideHost.trailingAnchor),
        ])
        // 装配开关(读 /api/modules:图标 + 定宽名称 + 开关右对齐,行撑满侧栏)
        Task {
            if let mods = try? await API.get("/api/modules", as: [ModuleRow].self) {
                let byId = Dictionary(uniqueKeysWithValues: mods.map { ($0.id, $0.enabled) })
                await MainActor.run {
                    for def in moduleDefs {
                        let sw = NSSwitch()
                        sw.state = (byId[def.id] ?? true) ? .on : .off
                        sw.controlSize = .mini
                        sw.onAction {
                            Task {
                                _ = try? await API.request("PUT", "/api/modules/\(def.id)", ["enabled": sw.state == .on])
                                await refreshModulesFromServer()
                            }
                        }
                        let iconV = IconView(def.icon, size: 12, color: wdModuleAccent(def.id))
                        iconV.translatesAutoresizingMaskIntoConstraints = false
                        iconV.widthAnchor.constraint(equalToConstant: 16).isActive = true
                        let nameL = label(t(def.zh), size: 11, color: .wdText2)
                        nameL.translatesAutoresizingMaskIntoConstraints = false
                        nameL.widthAnchor.constraint(equalToConstant: 96).isActive = true
                        let nameRow = NSStackView(views: [iconV, nameL])
                        nameRow.orientation = .horizontal; nameRow.alignment = .centerY; nameRow.spacing = 7
                        let r = NSStackView()
                        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 4
                        r.setViews([nameRow], in: .leading)
                        r.setViews([sw], in: .trailing)
                        r.translatesAutoresizingMaskIntoConstraints = false
                        switchRows.addView(r, in: .leading)
                        // 行撑满列表宽 → 每行开关右缘对齐同一列;统一行高让节奏均匀
                        r.leadingAnchor.constraint(equalTo: switchRows.leadingAnchor).isActive = true
                        r.trailingAnchor.constraint(equalTo: switchRows.trailingAnchor).isActive = true
                        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
                    }
                }
            }
        }
    }
    setupSidebar()
    rebuildSidebar = { setupSidebar() }

    let split = NSSplitViewController()
    let sideVC = NSViewController(); sideVC.view = sideHost
    let sideItem = NSSplitViewItem(sidebarWithViewController: sideVC)
    sideItem.minimumThickness = 200
    sideItem.maximumThickness = 240
    let mainVC = NSViewController(); mainVC.view = main
    let mainItem = NSSplitViewItem(viewController: mainVC)
    split.addSplitViewItem(sideItem)
    split.addSplitViewItem(mainItem)
    split.splitView.dividerStyle = .thin
    win.contentViewController = split
    // 渐变背景垫在 splitView 最底层(不在 scroll 内,消除裁剪/层级差异)
    let backdropHost = win.contentView!
    backdropHost.addSubview(backdrop, positioned: .below, relativeTo: split.view)
    backdrop.frame = backdropHost.bounds
    win.setContentSize(NSSize(width: 1280, height: 840))
    win.center()
    content.layoutSubtreeIfNeeded()
    content.needsLayout = true

    show(group: "总览")
    // 兜底:卡内数据异步到达后,任何时刻都能在 1.5s 内自动重摆
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak content] _ in
        MainActor.assumeIsolated { content?.relayout() }
    }
    // NSSplitViewController 会把窗口压回 fittingSize——布局完成后强制终态尺寸
    win.setFrame(NSRect(origin: win.frame.origin, size: NSSize(width: 1280, height: 840)), display: true)
    return win
}
