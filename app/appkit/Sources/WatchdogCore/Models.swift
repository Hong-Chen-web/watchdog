import Foundation

// MARK: - 数据模型(键名与后端 snake_case 经 API.decoder 全局转换对齐)

public struct TodoItem: Codable {
    public let id: Int
    public let title: String
    public let dueDate: String?
    public let priority: Int
    public let done: Bool
    public let summary: String?
    public let completedAt: String?
}

public struct LedgerCategory: Codable {
    public let id: Int
    public let name: String
    public let nameEn: String?
    public let color: String
    public let budgetMonth: Double
    public let budgetYear: Double
    public let actual: Double
}

public struct LedgerSummary: Codable {
    public let income: Double
    public let expense: Double
    public let net: Double
    public let categories: [LedgerCategory]
}

public struct LedgerEntry: Codable {
    public let id: Int
    public let date: String
    public let payee: String?
    public let category: String
    public let amount: Double
}

public struct AnnualReport: Codable {
    public struct Month: Codable { public let month: String; public let expense: Double }
    public struct Cat: Codable { public let cat: String; public let total: Double; public let pct: Double }
    public struct Anomaly: Codable { public let date: String; public let payee: String; public let cat: String?; public let amount: Double; public let why: String }
    public let year: Int
    public let entries: Int
    public let totalIn: Double
    public let totalOut: Double
    public let net: Double
    public let avgMonth: Double
    public let maxItem: Double
    public let saveRate: Double
    public let months: [Month]
    public let cats: [Cat]
    public let anomalies: [Anomaly]?
    public let tips: [String]?
    public let nextYearPlan: [String: Double]?
}

public struct GoalItem: Codable {
    public let id: Int
    public let scope: String
    public let title: String
    public let reviewDate: String?
    public let detail: String?
    public let result: String?
    public let source: String
}

public struct GoalsResponse: Codable {
    public struct Group: Codable {
        public let scope: String
        public let label: String
        public let items: [GoalItem]
    }
    public let groups: [Group]
}

public struct PortfolioHolding: Codable {
    public let code: String
    public let name: String
    public let buyPrice: Double
    public let last: Double?
    public let shares: Double
    public let value: Double
    public let pnlPct: Double
}

public struct Portfolio: Codable {
    public let total: Double
    public let cash: Double
    public let marketValue: Double
    public let dayPnl: Double
    public let calibrated: Bool?
    public let holdings: [PortfolioHolding]
}

public struct QuoteIndex: Codable {
    public let code: String?
    public let price: Double
    public let chgPct: Double
}

/// /api/market/quotes 容器:indices + watchlist(条目键在条目里,不在顶层)
public struct QuotesResponse: Codable {
    public let indices: [String: QuoteIndex]?
    public let watchlist: [WatchItem]?
}

public struct WatchItem: Codable {
    public let code: String
    public let name: String
    public let price: Double?
    public let chgPct: Double?
}

public struct BacktestRun: Codable {
    public struct Yearly: Codable { public let year: Int; public let returnPct: Double }
    public struct CurveP: Codable { public let seq: Int; public let date: String?; public let equity: Double }
    public let id: Int
    public let label: String
    public let finalEquity: Double?
    public let totalReturn: Double?
    public let trades: Int?
    public let winRate: Double?
    public let plRatio: Double?
    public let worstHit: Double?
    public let yearly: [Yearly]?
    public let curve: [CurveP]?
}

public struct LiveBacktest: Codable {
    public struct P: Codable { public let date: String; public let equity: Double }
    public let startDate: String?
    public let principal: Double
    public let realizedNet: Double
    public let retPct: Double
    public let rounds: Int
    public let winRounds: Int
    public let best: Double
    public let worst: Double
    public let totalNow: Double?
    public let curve: [P]
    public let syncedAt: String?
}

public struct SysmonMetrics: Codable {
    public struct CPU: Codable { public let usage: Double; public let pCoreCount: Int?; public let eCoreCount: Int? }
    public struct Mem: Codable { public let usedPercent: Double; public let used: UInt64?; public let total: UInt64? }
    public struct GPUInfo: Codable { public let name: String?; public let usage: Int? }
    public struct Disk: Codable { public let mount: String?; public let usedPercent: Double; public let used: UInt64?; public let total: UInt64? }
    public struct Net: Codable { public let name: String?; public let rxRateMbs: Double?; public let txRateMbs: Double? }
    public struct Bat: Codable { public let percent: Double; public let status: String? }
    public struct Proc: Codable { public let name: String; public let cpu: Double }
    public struct Hardware: Codable { public let cpuModel: String?; public let totalRam: String?; public let osVersion: String? }
    public let healthScore: Int
    public let healthScoreMsg: String?
    public let uptime: String?
    public let procs: UInt64?
    public let hardware: Hardware?
    public let cpu: CPU?
    public let memory: Mem?
    public let gpu: [GPUInfo]?      // 后端为数组,取 [0]
    public let disks: [Disk]?
    public let network: [Net]?
    public let batteries: [Bat]?
    public let topProcesses: [Proc]?
}

public struct DiskScan: Codable {
    public struct Item: Codable { public let name: String; public let path: String?; public let sizeTxt: String; public let sizeBytes: UInt64 }
    public struct Group: Codable { public let group: String; public let items: [Item] }
    public let freeGb: String?
    public let groups: [Group]
    public let totalBytes: UInt64
}

public struct CleanStatus: Codable {
    public let running: Bool
    public let current: String?
    public let done: Int
    public let total: Int
    public let freed: UInt64
}

public struct JournalDay: Codable {
    public struct Ev: Codable {
        public let title: String
        public let summary: String?
        public let completedAt: String?
        public let priority: Int
        public let todoId: Int?
    }
    public struct Entry: Codable {
        public let id: Int
        public let date: String
        public let kind: String
        public let content: String
        public let createdAt: String?
    }
    public let date: String?
    public let events: [Ev]
    public let entries: [Entry]?
    public let todaySummary: String?
}

public struct FeishuCfg: Codable {
    public struct Bot: Codable { public let id: String?; public let name: String; public let webhook: String; public let codes: [String]? }
    public let bots: [Bot]
    public let notify: [Bot]
}

public struct ChanTail: Codable {
    public struct S: Codable {
        public let code: String
        public let name: String
        public let price: Double?
        public let score: Double?
        public let dayPct: Double?
        public let ago: Int?
        public let hits: [String]?
        public let exitWhy: String?
    }
    public let date: String?
    public let nextRunDay: String?
    public let stocks: [S]?
}

public struct FuturesState: Codable {
    public struct Chanpy: Codable {
        public let biCount: Int?; public let segCount: Int?; public let zsCount: Int?
        public let lastBiDir: String?; public let lastZs: [Double]?
    }
    public struct F: Codable {
        public let code: String
        public let name: String?
        public let livePrice: Double?
        public let close: Double?
        public let chgPct: Double?
        public let chanpy: Chanpy?
    }
    public let level: String?
    public let levels: [String]?
    public let quoteAt: String?
    public let stocks: [F]?
}


public struct ChartLevels: Codable {
    public struct Chart: Codable { public let level: String; public let engine: String }
    public let code: String?
    public let charts: [Chart]?
}

public struct HealthOK: Codable { public let status: String }

public struct ModuleRow: Codable { public let id: String; public let enabled: Bool }

public struct PortfolioHistoryPoint: Codable { public let date: String; public let total: Double }
