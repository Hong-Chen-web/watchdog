import Foundation

// MARK: - 模块注册表:顺序/开关以后端 /api/modules 为准(与 Web 端同源)

public struct ModuleDef {
    public let id: String
    public let zh: String
    public let icon: String
    public let wide: Bool
    public init(id: String, zh: String, icon: String, wide: Bool) {
        self.id = id; self.zh = zh; self.icon = icon; self.wide = wide
    }
}

/// 宽卡(整行)集合:portfolio/backtest/sysmon/journal
public let moduleDefs: [ModuleDef] = [
    ModuleDef(id: "portfolio", zh: "持仓概览", icon: "chart-line-up", wide: true),
    ModuleDef(id: "backtest", zh: "策略回测", icon: "flask", wide: true),
    ModuleDef(id: "todo", zh: "今日待办", icon: "list-checks", wide: false),
    ModuleDef(id: "ledger", zh: "收支账本", icon: "wallet", wide: false),
    ModuleDef(id: "annual", zh: "年度财务分析", icon: "chart-donut", wide: true),
    ModuleDef(id: "market", zh: "自选行情", icon: "chart-line", wide: false),
    ModuleDef(id: "sysmon", zh: "系统与磁盘", icon: "stethoscope", wide: true),
    ModuleDef(id: "strategy", zh: "策略信号", icon: "lightning", wide: false),
    ModuleDef(id: "futures", zh: "期货监控", icon: "compass", wide: false),
    ModuleDef(id: "calendar", zh: "市场日历", icon: "calendar-blank", wide: false),
    ModuleDef(id: "journal", zh: "日志与复盘", icon: "notebook", wide: true),
    ModuleDef(id: "budget", zh: "预算与目标", icon: "chart-donut", wide: false),
    ModuleDef(id: "feishu", zh: "飞书推送", icon: "paper-plane-tilt", wide: false),
]

public let groupDefs: [(String, [String])] = [
    ("待办", ["todo", "journal"]),
    ("账本", ["annual", "ledger", "budget"]),
    ("行情", ["portfolio", "backtest", "market", "strategy", "futures", "calendar", "feishu"]),
    ("系统", ["sysmon"]),
]

/// 当前生效顺序+开关(启动时从后端拉)
public var moduleOrder: [String] = moduleDefs.map(\.id)
public var moduleEnabled: [String: Bool] = [:]

/// 从后端刷新顺序/开关,变化经 wd.modulesChanged 通知主窗重渲染
@MainActor
public func refreshModulesFromServer() async {
    guard let mods = try? await API.get("/api/modules", as: [ModuleRow].self) else { return }
    let order = mods.map(\.id)
    let enabled = Dictionary(uniqueKeysWithValues: mods.map { ($0.id, $0.enabled) })
    let changed = order != moduleOrder || enabled != moduleEnabled
    moduleOrder = order
    moduleEnabled = enabled
    if changed {
        NotificationCenter.default.post(name: .init("wd.modulesChanged"), object: nil)
    }
}
