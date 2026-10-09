import AppKit

// MARK: - 卡片容器(radius 18 + 蓝调渐变面 + 描边,对齐 .card)+ 编辑布局移除按钮

/// 编辑布局模式(所有卡右上角显示移除 ✕)
public var wdEditMode = false {
    didSet { NotificationCenter.default.post(name: .init("wd.editMode"), object: nil) }
}

public final class CardView: NSView {
    public let body = NSStackView()
    public let metaLabel = NSTextField(labelWithString: "")
    let moduleId: String
    private let grad = CAGradientLayer()
    private let rmBtn = NSButton()

    public init(title: String, icon: String, meta: String = "", id: String = "") {
        moduleId = id
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        wantsLayer = true
        layer?.backgroundColor = NSColor.wdCard.cgColor
        layer?.cornerRadius = 18
        layer?.borderColor = NSColor.wdBorder.cgColor
        layer?.borderWidth = 1
        // 卡面渐变(主题调色板)
        grad.colors = [NSColor.wdCardGradTop.cgColor, NSColor.wdCardGradBottom.cgColor]
        grad.startPoint = CGPoint(x: 0.5, y: 0)
        grad.endPoint = CGPoint(x: 0.5, y: 1)
        grad.cornerRadius = 18
        layer?.addSublayer(grad)

        let accent = wdModuleAccent(moduleId)
        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = accent.withAlphaComponent(wdThemeID == "mist" ? 0.16 : 0.18).cgColor
        iconBox.layer?.cornerRadius = 8
        let iconV = IconView(icon, size: 14, color: accent)
        iconBox.addSubview(iconV)
        iconV.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 27),
            iconBox.heightAnchor.constraint(equalToConstant: 27),
            iconV.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconV.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])
        let titleV = label(title, size: 13.5, bold: true)
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        metaLabel.textColor = .wdText3
        metaLabel.stringValue = meta

        let head = NSStackView(views: [iconBox, titleV, metaLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        // 移除按钮(编辑布局模式)
        rmBtn.bezelStyle = .accessoryBar
        rmBtn.controlSize = .mini
        rmBtn.font = .systemFont(ofSize: 10)
        rmBtn.title = "✕"
        rmBtn.isHidden = true
        rmBtn.translatesAutoresizingMaskIntoConstraints = false
        rmBtn.onAction { [self] in
            guard !moduleId.isEmpty else { return }
            Task {
                _ = try? await API.request("PUT", "/api/modules/\(moduleId)", ["enabled": false])
                await refreshModulesFromServer()   // 触发 wd.modulesChanged → 主窗重渲染
            }
        }
        addSubview(rmBtn)

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12

        addSubview(head)
        addSubview(body)
        head.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            body.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 13),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            rmBtn.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rmBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        NotificationCenter.default.addObserver(forName: .init("wd.editMode"), object: nil, queue: .main) { [weak self] _ in
            self?.rmBtn.isHidden = !wdEditMode
        }
    }

    public required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    public override func layout() {
        super.layout()
        grad.frame = bounds
    }

    /// 一行(水平,垂直居中)
    public func row(_ views: [NSView], spacing: CGFloat = 10) {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = spacing
        body.addView(r, in: .leading)
    }

    /// 占满卡宽的块
    public func block(_ v: NSView) {
        body.addView(v, in: .leading)
        v.leadingAnchor.constraint(equalTo: body.leadingAnchor).isActive = true
        v.trailingAnchor.constraint(equalTo: body.trailingAnchor).isActive = true
    }

    public func caption(_ text: String) { body.addView(label(text, size: 10.5, bold: true, color: .wdText3), in: .leading) }
}
