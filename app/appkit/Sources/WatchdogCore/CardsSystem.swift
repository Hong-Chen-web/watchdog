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
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
                try? await Task.sleep(nanoseconds: 500_000_000)
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


// MARK: 飞书推送(通知群+机器人列表+测试按钮;失败 10s 重试)

func makeFeishuCard() -> CardView {
    let c = CardView(title: t("飞书推送"), icon: "paper-plane-tilt", meta: "CHAN", id: "feishu")
    let rows = NSStackView()
    rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
    c.block(rows)
    Task {
        while true {
            if let f = try? await API.get("/api/chan/feishu/config", as: FeishuCfg.self) {
                await MainActor.run {
                    rows.views.forEach { $0.removeFromSuperview() }
                    for n in f.notify {
                        let r = NSStackView(views: [
                            label("🟢 \(n.name)", size: 12.5),
                            textButton(wdLang == "en" ? "Test" : "测试") { Task { _ = try? await API.post("/api/chan/feishu/test") } },
                        ])
                        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
                        rows.addView(r, in: .leading)
                    }
                    for b in f.bots {
                        let bid = b.id ?? ""
                        let r = NSStackView(views: [
                            label("🔵 \(b.name)", size: 12.5),
                            label("\(b.codes?.count ?? 0) 只", size: 10.5, color: .wdText3, mono: true),
                            textButton(wdLang == "en" ? "Test" : "测试") { Task { _ = try? await API.post("/api/chan/feishu/test", body: ["bot_id": bid]) } },
                        ])
                        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
                        rows.addView(r, in: .leading)
                    }
                }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
    return c
}
