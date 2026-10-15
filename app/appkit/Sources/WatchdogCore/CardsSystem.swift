import AppKit

// MARK: - 系统类卡:系统监控 / 磁盘与清理 / 飞书推送

// MARK: 系统监控(左健康大环+硬件信息 / 右六环 3×2 + TOP 进程)

func makeSysmonCard() -> CardView {
    let c = CardView(title: wdLang == "en" ? "System & Disk" : "系统与磁盘",
                     icon: "stethoscope", meta: "MOLE", id: "sysmon")

    // 左列:健康分大环 + 硬件信息
    let ring = RingLabelView(); ring.lineWidth = 8; ring.ringSize = 100
    let info = label("…", size: 10.5, color: .wdText2)
    let leftCol = NSStackView(views: [ring, info])
    leftCol.orientation = .vertical; leftCol.alignment = .centerX; leftCol.spacing = 8

    // 六环阵列 3×2(设计稿同款)
    func cell(_ iconName: String, _ name: String) -> (NSStackView, RingLabelView, NSTextField) {
        let r = RingLabelView(); r.lineWidth = 5; r.ringSize = 62; r.caption = name
        let n = label("—", size: 9.5, color: .wdText2, mono: true)
        let col = NSStackView(views: [r, n])
        col.orientation = .vertical; col.alignment = .centerX; col.spacing = 2
        return (col, r, n)
    }
    let cpuC = cell("cpu", "CPU"), memC = cell("memory", wdLang == "en" ? "MEM" : "内存"), gpuC = cell("gauge", "GPU")
    let dskC = cell("hard-drive", wdLang == "en" ? "DISK" : "磁盘"), netC = cell("wifi-high", wdLang == "en" ? "NET" : "网络"), batC = cell("battery-high", wdLang == "en" ? "BAT" : "电池")
    func gridRow(_ a: (NSStackView, RingLabelView, NSTextField), _ b: (NSStackView, RingLabelView, NSTextField), _ d: (NSStackView, RingLabelView, NSTextField)) -> NSStackView {
        let r = NSStackView(views: [a.0, b.0, d.0])
        r.orientation = .horizontal; r.alignment = .top; r.spacing = 30
        return r
    }
    let row1 = gridRow(cpuC, memC, gpuC)
    let row2 = gridRow(dskC, netC, batC)
    let metrics = NSStackView()
    metrics.orientation = .vertical; metrics.alignment = .leading; metrics.spacing = 4
    let rightCol = NSStackView(views: [row1, row2, metrics])
    rightCol.orientation = .vertical; rightCol.alignment = .leading; rightCol.spacing = 12

    // 右列:磁盘与清理(合并原磁盘卡)
    let cleanItems = FlippedStack()
    cleanItems.orientation = .vertical; cleanItems.alignment = .leading; cleanItems.spacing = 5
    let cleanScroll = NSScrollView()
    cleanScroll.documentView = cleanItems
    cleanScroll.hasVerticalScroller = true
    cleanScroll.drawsBackground = false
    cleanScroll.scrollerStyle = .overlay
    cleanScroll.translatesAutoresizingMaskIntoConstraints = false
    cleanScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
    cleanItems.widthAnchor.constraint(greaterThanOrEqualTo: cleanScroll.contentView.widthAnchor).isActive = true
    let diskTotal = label(wdLang == "en" ? "Scanning… (~30s)" : "扫描中…(约30秒)", size: 17, bold: true, mono: true)
    let cleaner = CleanerBox(); cleaner.bind()
    let diskCol = NSStackView(views: [
        label(wdLang == "en" ? "RECLAIMABLE" : "可释放空间", size: 10.5, color: .wdText3),
        diskTotal, cleaner.btn,
        label(wdLang == "en" ? "TOP ITEMS" : "清理项", size: 10.5, bold: true, color: .wdText3),
        cleanScroll,
    ])
    diskCol.orientation = .vertical; diskCol.alignment = .leading; diskCol.spacing = 8
    // 可释放空间:加载/清理后共用;后端清理完会作废缓存并重扫,期间返回 scanning=true → 轮询
    func loadScan() {
        Task {
            while true {
                if let d = try? await API.get("/api/disk/clean-scan", as: DiskScan.self), d.scanning != true {
                    await MainActor.run {
                        diskTotal.stringValue = fmtGB(d.totalBytes)
                        diskTotal.textColor = .wdUp
                        cleanItems.views.forEach { $0.removeFromSuperview() }
                        struct T { let g: String; let i: DiskScan.Item }
                        let top = d.groups.flatMap { g in g.items.map { T(g: g.group, i: $0) } }
                            .sorted { $0.i.sizeBytes > $1.i.sizeBytes }.prefix(8)
                        for t in top {
                            let nm = label(t.i.name, size: 11, color: .wdText2)
                            nm.translatesAutoresizingMaskIntoConstraints = false
                            nm.widthAnchor.constraint(equalToConstant: 160).isActive = true
                            let grpL = label("· " + t.g, size: 9.5, color: .wdText3)
                            grpL.translatesAutoresizingMaskIntoConstraints = false
                            grpL.widthAnchor.constraint(equalToConstant: 130).isActive = true
                            let r = NSStackView(views: [nm, grpL, label(t.i.sizeTxt, size: 10.5, color: .wdText3, mono: true)])
                            r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
                            cleanItems.addView(r, in: .leading)
                        }
                        cleanItems.fitTo(minHeight: 120)
                    }
                    break
                }
                await MainActor.run {
                    diskTotal.stringValue = wdLang == "en" ? "Scanning… (~30s)" : "扫描中…(约30秒)"
                    diskTotal.textColor = .wdText3
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
    loadScan()
    cleaner.onFinished = { loadScan() }

    let hWrap = NSStackView(views: [leftCol, rightCol, diskCol])
    hWrap.orientation = .horizontal; hWrap.alignment = .top; hWrap.spacing = 28
    c.block(hWrap)
    leftCol.translatesAutoresizingMaskIntoConstraints = false
    leftCol.widthAnchor.constraint(equalTo: hWrap.widthAnchor, multiplier: 0.22).isActive = true
    diskCol.translatesAutoresizingMaskIntoConstraints = false
    diskCol.widthAnchor.constraint(equalTo: hWrap.widthAnchor, multiplier: 0.30).isActive = true

    Task {
        while true {
            if let m = try? await API.get("/api/sysmon", as: SysmonMetrics.self) {
                await MainActor.run {
                    ring.pct = Double(m.healthScore) / 100
                    ring.valueText = "\(m.healthScore)"
                    ring.caption = m.healthScoreMsg ?? ""
                    ring.tint = m.healthScore >= 80 ? .wdDown : m.healthScore >= 60 ? .wdWarn : .wdUp
                    info.stringValue = "\(m.hardware?.cpuModel ?? "")\n\(m.hardware?.totalRam ?? "") · \(m.hardware?.osVersion ?? "")\n\(wdLang == "en" ? "Up" : "运行") \(m.uptime ?? "")"
                    func setCell(_ c: (NSStackView, RingLabelView, NSTextField), _ pct: Double, _ txt: String) {
                        c.1.pct = pct / 100
                        c.1.valueText = String(format: "%.0f%%", pct)
                        c.1.tint = pct > 90 ? .wdUp : pct > 80 ? .wdWarn : .wdDown
                        c.2.stringValue = txt
                    }
                    setCell(cpuC, m.cpu?.usage ?? 0, String(format: "%dP+%dE", m.cpu?.pCoreCount ?? 0, m.cpu?.eCoreCount ?? 0))
                    setCell(memC, m.memory?.usedPercent ?? 0, String(format: "%.0f/%.0fG", Double(m.memory?.used ?? 0)/1e9, Double(m.memory?.total ?? 0)/1e9))
                    // 后端 gpu 是数组,取 [0];usage 为 -1/nil 表示无占比(半环常显)
                    if let g = m.gpu?.first {
                        let u = g.usage ?? -1
                        setCell(gpuC, u >= 0 ? Double(u) : 0, u >= 0 ? "" : "n/a")
                    }
                    if let d = m.disks?.first { setCell(dskC, d.usedPercent, String(format: "%.0fG", Double(d.total ?? 0)/1e9)) }
                    if let n = m.network?.first {
                        netC.1.pct = 0.5  // 网络无百分比,半环常显
                        netC.1.valueText = String(format: "%.1fM", n.rxRateMbs ?? 0)
                        netC.1.tint = .wdAccent
                        netC.2.stringValue = "↓"
                    }
                    if let b = m.batteries?.first {
                        // 电池语义与负载相反:高电量=好(绿),<20 红 / <40 黄
                        batC.1.pct = b.percent / 100
                        batC.1.valueText = String(format: "%.0f%%", b.percent)
                        batC.1.tint = b.percent < 20 ? .wdUp : b.percent < 40 ? .wdWarn : .wdDown
                        batC.2.stringValue = b.status == "charging" ? (wdLang == "en" ? "chg" : "充电") : ""
                    }
                    metrics.views.forEach { $0.removeFromSuperview() }
                    func ml(_ k: String, _ v: String) {
                        let r = NSStackView(views: [label(k, size: 10.5, color: .wdText3), label(v, size: 11, mono: true)])
                        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
                        metrics.addView(r, in: .leading)
                    }
                    if let procs = m.topProcesses?.prefix(3) {
                        for p in procs { ml(p.name, String(format: "%.0f%%", p.cpu)) }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
    return c
}

// MARK: 一键清理(后台跑 + 按钮内进度;box 必须被强持有,weak 会随工厂返回释放成死键)

final class CleanerBox: NSObject {
    var busy = false
    var onFinished: (() -> Void)?          // 清理完成 → 卡片自动重扫刷新"可释放"
    let btn = ProgressButton(title: t("一键清理"))
    func bind() {
        btn.controlSize = .small
        btn.onAction { [self] in run() }   // onAction 成对设 target+action;强持有 box
    }
    func run() {
        guard !busy else { return }
        busy = true
        btn.progress = 0
        btn.title = wdLang == "en" ? "Starting…" : "启动清理…"
        Task {
            var lastFreed: UInt64 = 0
            _ = try? await API.post("/api/disk/clean-run")
            while true {
                if let s = try? await API.get("/api/disk/clean-status", as: CleanStatus.self) {
                    lastFreed = s.freed
                    let pct = s.total > 0 ? Double(s.done) / Double(s.total) : 0
                    let pctTxt = s.total > 0 ? String(format: "%.0f%%", pct * 100) : "—"
                    let txt = (wdLang == "en" ? "Clean \(s.done)/\(s.total) · \(pctTxt)" : "清理 \(s.done)/\(s.total) · \(pctTxt)")
                              + " · " + fmtGB(s.freed)
                    await MainActor.run {
                        btn.progress = pct
                        btn.title = txt
                        btn.progressTint = .wdUp
                    }
                    if !s.running { break }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await MainActor.run {
                btn.progress = 1
                btn.title = (wdLang == "en" ? "✓ Done · freed " : "✓ 清理完成 · 已释放 ") + fmtGB(lastFreed)
                busy = false
            }
            onFinished?()   // 触发卡片重扫(后端已在后台重扫,轮询 scanning 即可)
        }
    }
}

// MARK: 磁盘与清理(左 TOP 清单 / 右合计+清理按钮)


// MARK: 飞书推送(卡上直接编辑 webhook + 票池下拉;选项=自选行情+期货)

private var feishuCardObserver: NSObjectProtocol?

func makeFeishuCard() -> CardView {
    let c = CardView(title: t("飞书推送"), icon: "paper-plane-tilt", meta: "CHAN", id: "feishu")

    let rows = FlippedStack()
    rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
    let scroll = NSScrollView()
    scroll.documentView = rows
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.scrollerStyle = .overlay
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.heightAnchor.constraint(equalToConstant: 300).isActive = true
    rows.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor).isActive = true
    c.block(scroll)

    func reloadCard() {
        Task {
            struct ScopeResp: Codable {
                let allStocks: [[String: String]]?
                let allFutures: [[String: String]]?
            }
            guard let f = try? await API.get("/api/chan/feishu/config", as: FeishuCfg.self) else { return }
            let sc = try? await API.get("/api/push/scope", as: ScopeResp.self)
            await MainActor.run {
                rows.views.forEach { $0.removeFromSuperview() }
                let stocks = sc?.allStocks ?? [], futures = sc?.allFutures ?? []
                for n in f.notify { rows.addView(webhookRow(name: "🟢 " + n.name, id: n.id ?? "",
                                                            webhook: n.webhook, codes: nil,
                                                            reload: reloadCard), in: .leading) }
                for bt in f.bots { rows.addView(botRow(bt, stocks: stocks, futures: futures,
                                                       reload: reloadCard), in: .leading) }
                // 新增机器人(设置窗已移除该页,这里是唯一入口)
                let nf = NSTextField(string: "")
                nf.placeholderString = t("名称")
                let hf = NSTextField(string: "")
                hf.placeholderString = "https://open.feishu.cn/open-apis/bot/v2/hook/..."
                for fl in [nf, hf] {
                    fl.isBezeled = true; fl.bezelStyle = .roundedBezel; fl.drawsBackground = true
                    fl.font = .systemFont(ofSize: 10.5)
                }
                let addBtn = textButton("＋ " + t("添加机器人"), size: 10.5) {
                    let nm = nf.stringValue.trimmingCharacters(in: .whitespaces)
                    let hk = hf.stringValue.trimmingCharacters(in: .whitespaces)
                    guard !nm.isEmpty, hk.hasPrefix("https://open.feishu.cn/") else { return }
                    nf.stringValue = ""; hf.stringValue = ""
                    Task {
                        _ = try? await API.post("/api/chan/feishu/bots",
                                                body: ["name": nm, "webhook": hk, "codes": []])
                        await MainActor.run { reloadCard() }
                    }
                }
                nf.translatesAutoresizingMaskIntoConstraints = false
                hf.translatesAutoresizingMaskIntoConstraints = false
                addBtn.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    nf.widthAnchor.constraint(equalToConstant: 90),
                    hf.widthAnchor.constraint(equalToConstant: 210),
                ])
                let addRow = NSStackView(views: [label(t("新增机器人"), size: 10.5, color: .wdText3),
                                                 nf, hf, addBtn])
                addRow.orientation = .horizontal; addRow.alignment = .centerY; addRow.spacing = 8
                rows.addView(addRow, in: .leading)
                rows.fitTo(minHeight: 300)
            }
        }
    }

    func webhookRow(name: String, id: String, webhook: String, codes: [String]?,
                    stocks: [[String: String]] = [], futures: [[String: String]] = [],
                    reload: @escaping () -> Void) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 5

        func put(_ codesNew: [String]?, webhookNew: String? = nil) {
            Task {
                _ = try? await API.request("PUT", "/api/chan/feishu/bots/\(id)", [
                    "name": name.replacingOccurrences(of: "🔵 ", with: "").replacingOccurrences(of: "🟢 ", with: ""),
                    "webhook": webhookNew ?? webhook,
                    "codes": codesNew ?? codes ?? []])
                await MainActor.run { reload() }
            }
        }

        // 行1: 名称 + webhook 输入 + 保存 + 测试
        let wf = NSTextField(string: webhook)
        wf.isBezeled = true; wf.bezelStyle = .roundedBezel; wf.drawsBackground = true
        wf.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        wf.translatesAutoresizingMaskIntoConstraints = false
        let save = textButton(t("保存"), size: 10.5) { put(codes, webhookNew: wf.stringValue) }
        save.translatesAutoresizingMaskIntoConstraints = false
        let test = textButton(t("测试"), size: 10.5) {
            Task { _ = try? await API.post("/api/chan/feishu/test", body: ["bot_id": id]) }
        }
        test.translatesAutoresizingMaskIntoConstraints = false
        let l1 = NSStackView(views: [label(name, size: 12), wf, save, test])
        l1.orientation = .horizontal; l1.alignment = .centerY; l1.spacing = 8
        NSLayoutConstraint.activate([
            wf.widthAnchor.constraint(equalToConstant: 190),
            save.widthAnchor.constraint(equalToConstant: 42),
            test.widthAnchor.constraint(equalToConstant: 42),
        ])
        col.addView(l1, in: .leading)

        // 行2(有票池概念的机器人): 下拉添加标的 + 已选 chips
        guard var cur = codes else { return col }
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 22), pullsDown: false)
        pop.font = .systemFont(ofSize: 10.5)
        let head = cur.isEmpty ? t("票池=全部信号") : t("票池 \(cur.count)只 · 添加↓")
        pop.addItem(withTitle: head)
        pop.itemArray.forEach { $0.isEnabled = false }
        pop.addItem(withTitle: t("清除票池(推全部)"))
        pop.addItem(withTitle: "—")
        var idxCode: [Int: String] = [:]
        if !cur.isEmpty { pop.addItem(withTitle: t("自选行情")); pop.lastItem?.isEnabled = false
            for st in stocks { pop.addItem(withTitle: "\(st["name"] ?? "")  \(st["code"] ?? "")")
                pop.lastItem?.indentationLevel = 1
                idxCode[pop.itemArray.count - 1] = st["code"] } }
        if !futures.isEmpty { pop.addItem(withTitle: t("期货")); pop.lastItem?.isEnabled = false
            for fu in futures { pop.addItem(withTitle: "\(fu["name"] ?? "")  \(fu["code"] ?? "")")
                pop.lastItem?.indentationLevel = 1
                idxCode[pop.itemArray.count - 1] = fu["code"] } }
        pop.onAction {
            let i = pop.indexOfSelectedItem
            if i == 1 { put([]); return }                      // 清除=推全部
            if let code = idxCode[i] {
                var next = cur.map { $0.split(separator: ".").last.map(String.init) ?? $0 }
                let bareCode = code.split(separator: ".").last.map(String.init) ?? code
                if !next.contains(bareCode) { next.append(bareCode) }
                put(next)
            }
            pop.selectItem(at: 0)
        }
        // chips 显示"名称 代码"(带前缀的旧数据归一成裸代码;名称来自自选+期货清单)
        func bare(_ c: String) -> String { c.split(separator: ".").last.map(String.init) ?? c }
        func nameOf(_ bc: String) -> String? {
            stocks.first(where: { $0["code"] == bc })?["name"]
                ?? futures.first(where: { $0["code"] == bc })?["name"]
        }
        let norm = cur.map(bare)
        let l2 = NSStackView(views: [pop])
        l2.orientation = .horizontal; l2.alignment = .centerY; l2.spacing = 6
        for bc in norm.suffix(8) {
            let nm = nameOf(bc)
            let captured = bc
            let snapshot = norm
            let chip = textButton("✕ " + (nm.map { $0 + " " } ?? "") + bc, size: 9.5) {
                put(snapshot.filter { $0 != captured })
            }
            chip.layer?.backgroundColor = NSColor.wdOverlaySoft.cgColor
            chip.layer?.cornerRadius = 4
            l2.addView(chip, in: .leading)
        }
        if norm.count > 8 { l2.addView(label(t("…共\(norm.count)只"), size: 9.5, color: .wdText3), in: .leading) }
        col.addView(l2, in: .leading)
        return col
    }

    func botRow(_ b: FeishuCfg.Bot, stocks: [[String: String]], futures: [[String: String]],
                reload: @escaping () -> Void) -> NSView {
        webhookRow(name: "🔵 " + b.name, id: b.id ?? "", webhook: b.webhook,
                   codes: b.codes ?? [], stocks: stocks, futures: futures, reload: reload)
    }

    // 自选删票 → 后端联动清机器人票池 → 卡片刷新(观察者随卡重建换新,旧的先摘)
    if let old = feishuCardObserver { NotificationCenter.default.removeObserver(old) }
    feishuCardObserver = NotificationCenter.default.addObserver(
        forName: .init("wd.marketRefresh"), object: nil, queue: .main) { _ in
        reloadCard()
    }
    reloadCard()
    return c
}
