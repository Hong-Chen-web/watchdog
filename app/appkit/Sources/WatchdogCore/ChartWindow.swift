import AppKit
import WebKit

// MARK: - 缠论图弹窗(WKWebView 独立窗口 + 级别/引擎双胶囊)

public func openChartWindow(code: String, name: String) {
    let full = chanFullCode(code)
    let enc = full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? full
    Task {
        let lv = (try? await API.get("/api/chan/chart-levels?code=\(enc)", as: ChartLevels.self))?.charts ?? []
        await MainActor.run {
            guard !lv.isEmpty else {
                let a = NSAlert()
                a.messageText = t("暂无图表")
                a.informativeText = "「\(name) \(full)」\(wdLang == "en" ? "has no chart yet; retry after next chan-monitor scan." : "还没有生成缠论图,等 chan-monitor 下次扫描后再试。")"
                a.runModal()
                return
            }
            _openChart(full: full, name: name, charts: lv)
        }
    }
}

private var chartWindowRefs: [NSWindow] = []   // 图表窗强引用(局部变量窗口在 ARC/关闭时序上不稳)
public var tradesWindowRef: NSWindow?

private func _openChart(full: String, name: String, charts: [ChartLevels.Chart]) {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "\(name)  \(full)"
    win.appearance = NSAppearance(named: .darkAqua)
    win.backgroundColor = .wdWin

    // 级别按周期排序,引擎固定顺序,默认跟随可用集
    let lvOrder = ["1m", "5m", "15m", "30m", "60m", "120m", "day", "week", "mon"]
    let levels = Array(Set(charts.map(\.level))).sorted { lvOrder.firstIndex(of: $0) ?? 99 < lvOrder.firstIndex(of: $1) ?? 99 }
    let engines = Array(Set(charts.map(\.engine)))
    let prefer = ["30m", "day", "60m", "5m", "120m", "1m", "week", "mon"]
    let defLv = prefer.first { levels.contains($0) } ?? levels.first ?? "day"
    let defEng = engines.contains("chanpy") ? "chanpy" : (engines.first ?? "chanpy")

    let lvBar = PillBar(items: levels.map { ($0, $0) })
    let engBar = PillBar(items: engines.map { ($0, $0) })
    let wv = WKWebView()
    func load(_ lv: String, _ eng: String) {
        // 后端契约:code=纯代码,level/engine 独立参数(它自己拼 {code}_{level}_{engine}.html)
        // 之前误传整个文件名当 code,被后端清洗成 SC030mchanpy → 404 乱码
        let encFull = full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? full
        wv.load(URLRequest(url: URL(string: "\(API.base)/api/chan/chart?code=\(encFull)&level=\(lv)&engine=\(eng)")!))
    }
    lvBar.onSelect = { lv in load(lv, engBar.selected.isEmpty ? defEng : engBar.selected) }
    engBar.onSelect = { e in load(lvBar.selected.isEmpty ? defLv : lvBar.selected, e) }
    lvBar.select(defLv, fire: false)
    engBar.select(defEng, fire: false)

    let barRow = NSStackView(views: [
        label(t("级别"), size: 10.5, color: .wdText3), lvBar,
        NSView(),
        label(t("引擎"), size: 10.5, color: .wdText3), engBar,
    ])
    barRow.orientation = .horizontal
    barRow.alignment = .centerY
    barRow.spacing = 10
    barRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    let sep = NSBox()
    sep.boxType = .separator
    let col = NSStackView(views: [barRow, sep, wv])
    col.orientation = .vertical
    col.alignment = .leading
    col.spacing = 0
    col.setClippingResistancePriority(.defaultLow, for: .horizontal)
    wv.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        barRow.leadingAnchor.constraint(equalTo: col.leadingAnchor),
        barRow.trailingAnchor.constraint(lessThanOrEqualTo: col.trailingAnchor),
        sep.leadingAnchor.constraint(equalTo: col.leadingAnchor),
        sep.trailingAnchor.constraint(equalTo: col.trailingAnchor),
        wv.leadingAnchor.constraint(equalTo: col.leadingAnchor),
        wv.trailingAnchor.constraint(equalTo: col.trailingAnchor),
    ])
    win.contentView = col
    win.center()
    win.makeKeyAndOrderFront(nil)
    load(defLv, defEng)
    chartWindowRefs.append(win)
    chartWindowRefs.removeAll { !$0.isVisible }   // 已关的窗清引用
}
