import Foundation

// MARK: - 缠论图代码推导(纯函数,可单测)

/// 纯数字代码 → 带点前缀(6→sh. 0/3→sz. 4/8→bj),期货字母代码原样,带前缀原样
public func chanFullCode(_ c: String) -> String {
    if c.range(of: "^[a-z]{2}\\.", options: .regularExpression) != nil { return c }
    if c.range(of: "^[A-Za-z]{1,3}\\d", options: .regularExpression) != nil { return c }
    guard let f = c.first else { return c }
    let pre = f == "6" ? "sh." : (f == "4" || f == "8") ? "bj." : "sz."
    return pre + c
}

// MARK: - 交易时段(8787 同款:股票 9:25-11:35/12:55-15:05;期货日盘 9:00-15:15+夜盘 21:00-02:30)

public enum TradingHours {
    private static var dayCache: (day: String, ok: Bool)?

    /// 交易日:上证行情日期==今天(缓存到天;节假日 weekday 拦不住);拉不到退化为工作日
    public static func isTradingDay(_ now: Date = Date()) -> Bool {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: now)
        if dayCache?.day == today { return dayCache!.ok }
        var ok = Calendar.current.component(.weekday, from: now) != 1
            && Calendar.current.component(.weekday, from: now) != 7
        if let url = URL(string: "http://qt.gtimg.cn/q=sh000001"),
           let raw = try? String(contentsOf: url, encoding: .utf8),
           let dateField = raw.split(separator: "~").dropFirst(30).first {
            let qd = String(dateField.prefix(8))
            ok = qd == today.replacingOccurrences(of: "-", with: "")
        }
        dayCache = (today, ok)
        return ok
    }

    /// 股票时段(9:25-11:35 / 12:55-15:05)
    public static func stock(_ now: Date = Date()) -> Bool {
        let hm = hm(now)
        return "09:25" <= hm && hm <= "11:35" || "12:55" <= hm && hm <= "15:05"
    }

    /// 期货时段(日盘 9:00-15:15 + 夜盘 21:00-02:30)
    public static func futures(_ now: Date = Date()) -> Bool {
        let hm = hm(now)
        return "09:00" <= hm && hm <= "15:15" || hm >= "21:00" || hm <= "02:30"
    }

    private static func hm(_ now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: now)
    }
}

// MARK: - 曲线周期重采样(日=原样;月/年=该周期最后一个点,纯函数可单测)

public func resampleCurve(_ pts: [(date: String, equity: Double)], span: String) -> [(date: String, equity: Double)] {
    let keyLen: Int?
    switch span {
    case "month": keyLen = 7    // YYYY-MM
    case "year": keyLen = 4     // YYYY
    default: return pts         // day
    }
    var last: [String: (date: String, equity: Double)] = [:]
    for p in pts {
        guard p.date.count >= keyLen! else { continue }
        last[String(p.date.prefix(keyLen!))] = p
    }
    return last.keys.sorted().map { last[$0]! }
}

// MARK: - dense 网格槽位分配(纯函数,可单测;与 Web grid-auto-flow:dense 同语义)
//
// wide 卡占整行;普通卡从左到右配对;wide 打断半行时右槽成"洞",
// 后续普通卡优先回填最早的洞。

public enum DenseLayout {
    public struct Slot: Equatable {
        public let index: Int    // 输入序列下标
        public let row: Int
        public let isLeft: Bool
        public let isWide: Bool
    }

    public static func plan(wides: [Bool]) -> [Slot] {
        var slots: [Slot] = []
        var holes: [(row: Int, left: Bool)] = []
        var row = 0, leftOpen = true
        for (i, wide) in wides.enumerated() {
            if wide {
                if !leftOpen { holes.append((row, false)); row += 1; leftOpen = true }
                slots.append(Slot(index: i, row: row, isLeft: true, isWide: true))
                row += 1
            } else if let hi = holes.firstIndex(where: { $0.row < row }) {
                let h = holes.remove(at: hi)
                slots.append(Slot(index: i, row: h.row, isLeft: h.left, isWide: false))
            } else {
                slots.append(Slot(index: i, row: row, isLeft: leftOpen, isWide: false))
                if leftOpen { leftOpen = false } else { row += 1; leftOpen = true }
            }
        }
        return slots
    }
}
