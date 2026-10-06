import AppKit

// MARK: - 表单弹窗(记一笔/添加目标/预算批量编辑)

/// 多字段表单弹窗(标题+行),确定返回各字段文本,取消返回 nil
func promptForm(title: String, rows: [(String, NSView)]) -> [String: String]? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: t("确定")); alert.addButton(withTitle: t("取消"))
    let col = NSStackView()
    col.orientation = .vertical; col.alignment = .leading; col.spacing = 8
    var fields: [String: NSControl] = [:]
    for (name, ctl) in rows {
        if let tf = ctl as? NSTextField {
            tf.font = .systemFont(ofSize: 12.5)
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let r = NSStackView(views: [label(name, size: 11.5, color: .wdText2), ctl])
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
        col.addView(r, in: .leading)
        fields[name] = ctl as? NSControl
    }
    alert.accessoryView = col
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    var out: [String: String] = [:]
    for (name, ctl) in fields { out[name] = (ctl as? NSTextField)?.stringValue ?? "" }
    if let pop = rows.first(where: { $0.1 is NSPopUpButton })?.1 as? NSPopUpButton {
        out["__popup__"] = pop.titleOfSelectedItem
    }
    return out
}

/// 单行输入弹窗
func inputAlert(title: String, placeholder: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: t("保存")); alert.addButton(withTitle: t("取消"))
    let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    tf.placeholderString = placeholder
    alert.accessoryView = tf
    alert.window.initialFirstResponder = tf
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let s = tf.stringValue.trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
}

/// 预算批量编辑器(每类一行:名称 + 月度 + 年度)→ PUT /api/ledger/budgets/{year}
func showBudgetEditor(cats: [LedgerCategory], done: @escaping () async -> Void) {
    let alert = NSAlert()
    alert.messageText = t("预算编辑") + " \(String(curMonth().prefix(4)))"
    alert.addButton(withTitle: t("保存")); alert.addButton(withTitle: t("取消"))
    let col = NSStackView()
    col.orientation = .vertical; col.alignment = .leading; col.spacing = 6
    var monthFields: [(Int, NSTextField)] = [], yearFields: [(Int, NSTextField)] = []
    let head = NSStackView(views: [
        label(t("分类"), size: 10, color: .wdText3),
        label(t("月度"), size: 10, color: .wdText3),
        label(t("年度"), size: 10, color: .wdText3),
    ])
    head.orientation = .horizontal; head.alignment = .centerY
    head.spacing = 16
    col.addView(head, in: .leading)
    for cat in cats {
        let nameL = label(cat.name, size: 11.5, color: .wdText2)
        nameL.translatesAutoresizingMaskIntoConstraints = false
        nameL.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let mf = NSTextField(frame: NSRect(x: 0, y: 0, width: 78, height: 22))
        mf.stringValue = cat.budgetMonth > 0 ? String(format: "%.0f", cat.budgetMonth) : ""
        let yf = NSTextField(frame: NSRect(x: 0, y: 0, width: 88, height: 22))
        yf.stringValue = cat.budgetYear > 0 ? String(format: "%.0f", cat.budgetYear) : ""
        monthFields.append((cat.id, mf)); yearFields.append((cat.id, yf))
        let r = NSStackView(views: [nameL, mf, yf])
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 16
        col.addView(r, in: .leading)
    }
    let sv = NSScrollView()
    sv.documentView = col
    sv.hasVerticalScroller = true
    sv.translatesAutoresizingMaskIntoConstraints = false
    sv.widthAnchor.constraint(equalToConstant: 340).isActive = true
    sv.heightAnchor.constraint(equalToConstant: min(CGFloat(cats.count) * 34 + 54, 330)).isActive = true
    alert.accessoryView = sv
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    var items: [[String: Any]] = []
    for (cid, f) in monthFields {
        let annual = Double(yearFields.first { $0.0 == cid }?.1.stringValue ?? "") ?? 0
        items.append(["category_id": cid, "monthly": Double(f.stringValue) ?? 0, "annual": annual])
    }
    let year = Int(curMonth().prefix(4)) ?? 2026
    Task {
        _ = try? await API.request("PUT", "/api/ledger/budgets/\(year)", ["year": year, "items": items])
        await done()
    }
}
