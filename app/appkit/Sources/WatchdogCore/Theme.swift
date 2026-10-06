import AppKit

// MARK: - 主题:设计 token(CSS 直读对齐)+ 双语 + 基础控件 + 格式化

// ---- 双语(全局语言状态,UserDefaults 持久化) ----
public var wdLang: String = UserDefaults.standard.string(forKey: "wd.lang") ?? "zh" {
    didSet { UserDefaults.standard.set(wdLang, forKey: "wd.lang") }
}
let enDict: [String: String] = [
    "总览": "Overview", "待办": "Todos", "账本": "Finance", "行情": "Market", "系统": "System",
    "持仓概览": "Portfolio", "策略回测": "Backtest", "今日待办": "To-Dos", "收支账本": "Ledger",
    "自选行情": "Quotes", "策略信号": "Signals", "期货监控": "Futures", "市场日历": "Calendar",
    "飞书推送": "Feishu", "系统监控": "Sys Monitor", "磁盘与清理": "Disk & Clean",
    "日志与复盘": "Journal", "预算": "Budget", "目标": "Goals",
    "模块装配": "MODULES", "数据服务": "Data service", "编辑布局": "Edit Layout", "完成": "Done",
    "总资产": "Total", "今日盈亏": "Day P&L", "可用资金": "Cash", "持仓市值": "Positions",
    "仓位": "Exposure", "收入": "Income", "支出": "Expense", "结余": "Net",
    "最近明细": "Recent", "今日完成": "Done today",
    "今日总结": "Daily summary", "写今日总结": "Write summary", "记一笔": "Add entry",
    "添加待办,回车保存": "Add a to-do, press Enter", "代码回车添加,如 601318": "Code + Enter to add",
    "同步缠论自选": "Sync chan list", "添加目标": "Add goal", "添加": "Add", "编辑": "Edit",
    "一键清理": "Clean Now", "级别": "Level", "引擎": "Engine", "日期": "Date", "事项": "Payee",
    "分类": "Category", "金额": "Amount", "范围": "Scope", "目标内容": "Goal title",
    "长期": "Long-term", "确定": "OK", "取消": "Cancel", "保存": "Save",
    "暂无图表": "No chart yet", "周期": "Span", "日": "Day", "月": "Month", "年": "Year", "删除自选": "Remove from watchlist", "预算编辑": "Edit budgets",
    "腾讯 · 东财 · 新浪 · Mole": "Tencent · EastMoney · Sina · Mole",
    "看门狗": "Watchdog",
]
/// 词条查询:英文缺失时回退中文原文
public func t(_ zh: String) -> String { wdLang == "en" ? (enDict[zh] ?? zh) : zh }

// ---- 主题系统:调色板 + 切换持久化 ----

public struct WdPalette {
    public let id: String
    public let win: NSColor          // 窗口底
    public let card: NSColor         // 卡面
    public let side: NSColor         // 侧栏
    public let text: NSColor
    public let text2: NSColor
    public let text3: NSColor
    public let icon: NSColor
    public let accent: NSColor
    public let up: NSColor           // A股红涨
    public let down: NSColor         // 绿跌
    public let warn: NSColor
    public let border: NSColor
    public let overlayStrong: NSColor  // 图标盒/按钮底
    public let overlaySoft: NSColor    // 顶栏/子导航条底
    public let track: NSColor          // 圆环/进度条轨道
    public let cardGradTop: NSColor    // 卡面渐变
    public let cardGradBottom: NSColor
    public let backdropTop: NSColor    // 背景纵向基线
    public let backdropMid: NSColor
    public let backdropBottom: NSColor
    public let glow1: NSColor          // 背景三极光晕
    public let glow2: NSColor
    public let glow3: NSColor
    public let pillBg: NSColor         // 胶囊栏
    public let pillBorder: NSColor
    public let pillSelectedBg: NSColor
    public let pillSelectedText: NSColor
}

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}
private func w(_ v: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedWhite: v, alpha: a)
}

/// 深色(常用中性黑,macOS 暗黑风:#1c1c1e 卡面/纯黑底)
private let skyPalette = WdPalette(
    id: "sky",
    win: w(0.07), card: w(0.11),
    side: w(0.055), text: w(1, 0.93), text2: w(1, 0.56), text3: w(1, 0.38),
    icon: w(0.72), accent: rgb(0.039, 0.518, 1.0), up: rgb(1.0, 0.353, 0.373),
    down: rgb(0.188, 0.82, 0.345), warn: rgb(1.0, 0.839, 0.039), border: w(1, 0.10),
    overlayStrong: w(1, 0.08), overlaySoft: w(1, 0.03), track: w(1, 0.13),
    cardGradTop: w(1, 0.055), cardGradBottom: w(1, 0.015),
    backdropTop: w(0.055), backdropMid: w(0.04), backdropBottom: w(0.028),
    glow1: rgb(0.35, 0.35, 0.40, 0.10), glow2: rgb(0.25, 0.25, 0.30, 0.07), glow3: rgb(0.30, 0.28, 0.38, 0.06),
    pillBg: w(1, 0.07), pillBorder: w(1, 0.11), pillSelectedBg: w(1), pillSelectedText: w(0.08))

/// 浅色
private let mistPalette = WdPalette(
    id: "mist",
    win: rgb(0.945, 0.953, 0.973), card: rgb(0.992, 0.995, 0.998),
    side: rgb(0.902, 0.918, 0.945), text: w(0.04, 0.97), text2: w(0.04, 0.80), text3: w(0.04, 0.64),
    icon: rgb(0.16, 0.18, 0.23), accent: rgb(0.039, 0.518, 1.0), up: rgb(0.878, 0.192, 0.208),
    down: rgb(0.047, 0.612, 0.424), warn: rgb(0.851, 0.604, 0.024), border: w(0, 0.16),
    overlayStrong: w(0, 0.07), overlaySoft: w(0, 0.05), track: w(0, 0.14),
    cardGradTop: w(1), cardGradBottom: rgb(0.955, 0.965, 0.985),
    backdropTop: rgb(0.93, 0.94, 0.96), backdropMid: rgb(0.894, 0.906, 0.933), backdropBottom: rgb(0.859, 0.875, 0.906),
    glow1: rgb(0.55, 0.68, 0.95, 0.22), glow2: rgb(0.50, 0.75, 0.80, 0.14), glow3: rgb(0.70, 0.60, 0.90, 0.10),
    pillBg: w(0, 0.07), pillBorder: w(0, 0.16), pillSelectedBg: rgb(0.086, 0.098, 0.122), pillSelectedText: w(1))

/// 全部主题(id 唯一;新增主题只需在此注册)
/// 全部主题(深色/浅色两套;新增主题只需在此注册)
public let wdThemes: [(id: String, palette: WdPalette)] = [
    ("sky", skyPalette), ("mist", mistPalette),
]

/// 当前主题 id(UserDefaults 持久化)
public var wdThemeID: String {
    get { UserDefaults.standard.string(forKey: "wd.theme") ?? "sky" }
    set { UserDefaults.standard.set(newValue, forKey: "wd.theme") }
}

/// 当前调色板
public var wdPalette: WdPalette {
    (wdThemes.first { $0.id == wdThemeID } ?? wdThemes[0]).palette
}

// ---- 颜色(全部走当前调色板;主题切换后经 wd.themeChanged 全量重绘) ----
public extension NSColor {
    static var wdWin: NSColor { wdPalette.win }
    static var wdCard: NSColor { wdPalette.card }
    static var wdSide: NSColor { wdPalette.side }
    static var wdText: NSColor { wdPalette.text }
    static var wdText2: NSColor { wdPalette.text2 }
    static var wdText3: NSColor { wdPalette.text3 }
    static var wdIcon: NSColor { wdPalette.icon }
    static var wdAccent: NSColor { wdPalette.accent }
    static var wdUp: NSColor { wdPalette.up }
    static var wdDown: NSColor { wdPalette.down }
    static var wdWarn: NSColor { wdPalette.warn }
    static var wdBorder: NSColor { wdPalette.border }
    static var wdOverlayStrong: NSColor { wdPalette.overlayStrong }
    static var wdOverlaySoft: NSColor { wdPalette.overlaySoft }
    static var wdTrack: NSColor { wdPalette.track }
    static var wdCardGradTop: NSColor { wdPalette.cardGradTop }
    static var wdCardGradBottom: NSColor { wdPalette.cardGradBottom }
    static var wdPillBg: NSColor { wdPalette.pillBg }
    static var wdPillBorder: NSColor { wdPalette.pillBorder }
    static var wdPillSelectedBg: NSColor { wdPalette.pillSelectedBg }
    static var wdPillSelectedText: NSColor { wdPalette.pillSelectedText }
}

// ---- 模块主题色(每卡一色,图标芯片/点缀用;两主题通用中明度) ----
public func wdModuleAccent(_ id: String) -> NSColor {
    let hex: String
    switch id {
    case "portfolio": hex = "0A84FF"   // 蓝
    case "backtest":  hex = "BF5AF2"   // 紫
    case "todo":      hex = "FF9F0A"   // 橙
    case "ledger":    hex = "30D158"   // 绿
    case "budget":    hex = "64D2FF"   // 青
    case "goals":     hex = "FF375F"   // 粉
    case "market":    hex = "5E5CE6"   // 靛
    case "strategy":  hex = "FFD60A"   // 金
    case "futures":   hex = "40C8E0"   // 湖蓝
    case "calendar":  hex = "FF453A"   // 红
    case "feishu":    hex = "00C7BE"   // 薄荷
    case "sysmon":    hex = "FF6482"   // 玫瑰
    case "disk":      hex = "FF6B22"   // 橘
    case "journal":   hex = "AF52DE"   // 淡紫
    default:          hex = "0A84FF"
    }
    return NSColor(hex: hex)
}

public extension NSColor {
    /// "#RRGGBB"/"RRGGBB" → NSColor(失败回中性灰)
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0x888888
        Scanner(string: h).scanHexInt64(&v)
        self.init(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// ---- 基础控件 ----
/// 单行文本
public func label(_ text: String, size: CGFloat = 13, bold: Bool = false,
                  color: NSColor = .wdText, mono: Bool = false) -> NSTextField {
    let v = NSTextField(labelWithString: text)
    v.font = mono
        ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        : .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    v.textColor = color
    v.lineBreakMode = .byTruncatingTail
    return v
}

/// 文字按钮
public func textButton(_ title: String, size: CGFloat = 11.5, action: @escaping () -> Void) -> NSButton {
    let b = NSButton(title: title, target: NullableTarget(action), action: #selector(NullableTarget.fire))
    b.bezelStyle = .recessed
    b.font = .systemFont(ofSize: size)
    b.controlSize = .small
    b.setContentHuggingPriority(.required, for: .horizontal)
    return b
}

// ---- 格式化 ----
/// 金额:≥1亿 → 亿,≥1万 → 万
public func fmtWan(_ v: Double) -> String {
    v >= 1_0000_0000 ? String(format: "%.2f亿", v / 1_0000_0000)
    : v >= 10_000 ? String(format: "%.1f万", v / 10_000)
    : String(format: "%.0f", v)
}
/// A股红涨绿跌
public func pctColor(_ p: Double) -> NSColor { p >= 0 ? .wdUp : .wdDown }
public func fmtGB(_ b: UInt64) -> String { String(format: "%.1fGB", Double(b) / 1_073_741_824) }

// ---- 日期 ----
/// 当月 "2026-10"
public func curMonth() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM"
    return f.string(from: Date())
}
/// 月份平移:"2026-10" ± n 月;越界(>当前月/解析失败)返回 nil
public func shiftMonth(_ m: String, _ delta: Int) -> String? {
    let parts = m.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 1, (1...12).contains(parts[1]) else { return nil }
    let total = parts[0] * 12 + (parts[1] - 1) + delta   // 总月数偏移,免整除截断坑
    let y = total / 12, mo = total % 12 + 1
    let out = String(format: "%04d-%02d", y, mo)
    return out <= curMonth() ? out : nil   // 未来月不可选
}

public func todayStr() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}
