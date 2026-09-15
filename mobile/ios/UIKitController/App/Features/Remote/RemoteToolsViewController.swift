import UIKit

/// Session Controls sheet: connection facts, live transport metrics, device
/// actions (Control only), Lock with confirmation, and Reconnect. Always dark.
/// Metrics update in place at the model's cadence without layout passes.
@MainActor
final class RemoteToolsViewController: UIViewController, RCSheetScrollable {
    var onHardware: ((RemoteHardwareAction) -> Void)?
    var onReconnect: (() -> Void)?

    private let deviceName: String
    private let path: RemoteAccessPathPresentation
    private var tools: RemoteToolsPresentation
    private let scrollView = UIScrollView()
    private lazy var content = RemoteToolsContentView(deviceName: deviceName, path: path, tools: tools)

    var sheetScrollView: UIScrollView? { scrollView }

    /// Last formatted metrics, reused when the raw diagnostics did not change.
    var currentDiagnostics: RemoteDiagnosticsPresentation { tools.diagnostics }

    init(deviceName: String, path: RemoteAccessPathPresentation, tools: RemoteToolsPresentation) {
        self.deviceName = deviceName
        self.path = path
        self.tools = tools
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The sheet draws the surface; content stays transparent.
        view.backgroundColor = .clear
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.addSubview(content)
        view.addSubview(scrollView)

        content.onDone = { [weak self] in self?.close() }
        content.onHardware = { [weak self] action in self?.onHardware?(action) }
        content.onLock = { [weak self] in self?.confirmLock() }
        content.onReconnect = { [weak self] in
            guard let self else { return }
            self.onReconnect?()
            self.close()
        }
        content.onCopyEndpoint = { [weak self] in self?.copyEndpoint() }
        content.onContentHeightChange = { [weak self] in self?.view.setNeedsLayout() }
    }

    func update(_ next: RemoteToolsPresentation) {
        guard next != tools else { return }
        tools = next
        guard isViewLoaded else { return }
        content.update(next)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        let width = view.bounds.width
        let height = content.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if content.frame.size != CGSize(width: width, height: height) {
            content.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
        // `.fitting` describes the content; the sheet adds the bottom safe area itself.
        scrollView.contentSize = CGSize(width: width, height: height + view.safeAreaInsets.bottom)
        let preferred = CGSize(width: width, height: height)
        if abs(preferredContentSize.height - preferred.height) > 0.5 {
            preferredContentSize = preferred
            RCSheet.contentSizeDidChange(for: self)
        }
    }

    private func close() {
        RCSheet.dismiss(self)
    }

#if DEBUG
    /// Screenshot hook (`--rctl-remote-demo=lock`).
    func presentLockConfirmation() { confirmLock() }
#endif

    private func confirmLock() {
        guard tools.actionsEnabled else { return }
        RCHaptics.play(.warning)
        RCDialog.present(
            title: "Lock \(deviceName)?",
            message: "The remote session stays connected after the screen locks.",
            icon: .lock,
            tone: .danger,
            actions: [
                RCDialogAction("Cancel", style: .cancel),
                RCDialogAction("Lock Device", style: .destructive) { [weak self] in
                    guard let self else { return }
                    self.onHardware?(.lock)
                    self.close()
                },
            ],
            from: self
        )
    }

    private func copyEndpoint() {
        guard path.endpoint != "Unavailable" else { return }
        UIPasteboard.general.string = path.endpoint
        RCHaptics.play(.success)
        RCToast.show("Endpoint copied", tone: .success, icon: .copy, duration: 2)
    }
}

// MARK: - Content

@MainActor
private final class RemoteToolsContentView: RCView {
    var onDone: (() -> Void)?
    var onHardware: ((RemoteHardwareAction) -> Void)?
    var onLock: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onCopyEndpoint: (() -> Void)?
    var onContentHeightChange: (() -> Void)?

    private let titleLabel = RCLabel("Session controls", style: .title2)
    private let subtitleLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary)
    private let doneButton = RCIconButton(icon: .x, variant: .plain, diameter: 36, iconSize: 16, accessibilityLabel: "Done")

    private let connectionHeader = RCSectionHeader(title: "Connection")
    private let connectionCard = RCSurfaceView(style: .card, cornerRadius: RCRadius.lg)
    private let pathRow: RemoteToolsInfoRow
    private let endpointRow: RemoteToolsInfoRow
    private let trustRow: RemoteToolsInfoRow
    private let connectionSeparators = [RCSeparator(), RCSeparator()]

    private let metricsHeader = RCSectionHeader(title: "Live transport")
    private let metricsCard = RCSurfaceView(style: .card, cornerRadius: RCRadius.lg)
    private let metricTiles: [RemoteMetricTile] = (0..<5).map { _ in RemoteMetricTile() }
    private let metricSeparators: [RCSeparator] = (0..<4).map { _ in RCSeparator() }

    private let actionsHeader = RCSectionHeader(title: "Device")
    private let actionTiles: [RemoteToolActionTile] = [
        RemoteToolActionTile(title: "Control Center", icon: .panelTop, action: .controlCenter),
        RemoteToolActionTile(title: "Notifications", icon: .bell, action: .notificationCenter),
        RemoteToolActionTile(title: "Volume Up", icon: .volume2, action: .volumeUp),
        RemoteToolActionTile(title: "Volume Down", icon: .volume1, action: .volumeDown),
    ]
    private let actionsNote = RCLabel("Select Control on the screen source to use device actions.", style: .footnote, color: RCColor.textTertiary, lines: 0)
    private let lockButton = RCButton(title: "Lock Device", icon: .lock, variant: .destructiveSoft, size: .large)
    private let reconnectButton = RCButton(title: "Reconnect Session", icon: .refreshCw, variant: .secondary, size: .large)

    private var tools: RemoteToolsPresentation
    private static let gutter: CGFloat = 20

    init(deviceName: String, path: RemoteAccessPathPresentation, tools: RemoteToolsPresentation) {
        self.tools = tools
        let badge = RemoteAccessPathBadge()
        badge.configure(path)
        badge.isAccessibilityElement = false
        pathRow = RemoteToolsInfoRow(title: "Path", value: path.pathDescription, leadingAccessory: badge)
        endpointRow = RemoteToolsInfoRow(title: "Endpoint", value: path.endpoint, monospaced: true)
        trustRow = RemoteToolsInfoRow(title: "Trust", value: path.trust, valueColor: path.trustTone.textColor)
        super.init(frame: .zero)
        subtitleLabel.text = deviceName
        [pathRow, endpointRow, trustRow].forEach(connectionCard.contentView.addSubview)
        connectionSeparators.forEach(connectionCard.contentView.addSubview)
        endpointRow.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleEndpointPress(_:))))
        endpointRow.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Copy endpoint", target: self, selector: #selector(copyEndpointAction))]
        endpointRow.accessibilityHint = "Touch and hold to copy"
        apply(tools)
    }

    override func setUp() {
        titleLabel.accessibilityTraits = .header
        doneButton.haptic = .selection
        doneButton.onTap = { [weak self] in self?.onDone?() }
        [titleLabel, subtitleLabel, doneButton, connectionHeader, connectionCard, metricsHeader, metricsCard, actionsHeader, actionsNote, lockButton, reconnectButton].forEach(addSubview)
        metricTiles.forEach(metricsCard.contentView.addSubview)
        metricSeparators.forEach(metricsCard.contentView.addSubview)
        for tile in actionTiles {
            tile.onTap = { [weak self] action in self?.onHardware?(action) }
            addSubview(tile)
        }
        lockButton.haptic = nil
        lockButton.onTap = { [weak self] in self?.onLock?() }
        reconnectButton.onTap = { [weak self] in self?.onReconnect?() }
    }

    func update(_ next: RemoteToolsPresentation) {
        let enablementChanged = next.actionsEnabled != tools.actionsEnabled
        tools = next
        apply(next)
        if enablementChanged {
            setNeedsLayout()
            onContentHeightChange?()
        }
    }

    private func apply(_ tools: RemoteToolsPresentation) {
        for (tile, metric) in zip(metricTiles, tools.diagnostics.metrics) {
            tile.configure(metric)
        }
        for tile in actionTiles { tile.isEnabled = tools.actionsEnabled }
        lockButton.isEnabled = tools.actionsEnabled
        actionsNote.isHidden = tools.actionsEnabled
    }

    @objc private func handleEndpointPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        onCopyEndpoint?()
    }

    @objc private func copyEndpointAction() -> Bool {
        onCopyEndpoint?()
        return true
    }

    // MARK: Layout

    private var columns: Int {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 1 : 2
    }

    private func columnFrame(width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let available = width - Self.gutter * 2
        let columnWidth = min(available, RCLayout.maxFormWidth)
        return (Self.gutter + (available - columnWidth) / 2, columnWidth)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width, apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layout(width: bounds.width, apply: true)
    }

    /// Single pass used for both measuring and placing, so they never disagree.
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let column = columnFrame(width: width)
        let x = column.x
        let inner = column.width
        func place(_ view: UIView, _ frame: CGRect) {
            if apply { view.frame = frame }
        }
        var y: CGFloat = 24

        let titleHeight = RCTypography.lineHeight(.title2, compatibleWith: traitCollection)
        let subtitleHeight = RCTypography.lineHeight(.subheadline, compatibleWith: traitCollection)
        place(doneButton, CGRect(x: x + inner - 36, y: y - 2, width: 36, height: 36))
        place(titleLabel, CGRect(x: x, y: y, width: inner - 48, height: titleHeight))
        y += titleHeight + 2
        place(subtitleLabel, CGRect(x: x, y: y, width: inner - 48, height: subtitleHeight))
        y += subtitleHeight + 20

        place(connectionHeader, CGRect(x: x, y: y, width: inner, height: 32))
        y += 32 + 4
        var rowY: CGFloat = 4
        for (index, row) in [pathRow, endpointRow, trustRow].enumerated() {
            let height = row.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            place(row, CGRect(x: 0, y: rowY, width: inner, height: height))
            rowY += height
            if index < 2 {
                place(connectionSeparators[index], CGRect(x: 14, y: rowY - RCLayout.hairline / 2, width: inner - 28, height: RCLayout.hairline))
            }
        }
        rowY += 4
        place(connectionCard, CGRect(x: x, y: y, width: inner, height: rowY))
        y += rowY + 20

        place(metricsHeader, CGRect(x: x, y: y, width: inner, height: 32))
        y += 32 + 4
        let metricColumns = columns
        let tileHeight = RemoteMetricTile.height(traits: traitCollection)
        let tileWidth = inner / CGFloat(metricColumns)
        var metricsHeight: CGFloat = 0
        for (index, tile) in metricTiles.enumerated() {
            // Route spans the full width in the two-column grid.
            let spansAll = index == metricTiles.count - 1
            let row = metricColumns == 1 ? index : index / 2
            let col = metricColumns == 1 || spansAll ? 0 : index % 2
            let frame = CGRect(x: CGFloat(col) * tileWidth, y: CGFloat(row) * tileHeight, width: spansAll ? inner : tileWidth, height: tileHeight)
            place(tile, frame)
            metricsHeight = max(metricsHeight, frame.maxY)
        }
        if apply {
            let rows = metricColumns == 1 ? metricTiles.count : 3
            for (index, separator) in metricSeparators.enumerated() {
                if metricColumns == 1 {
                    separator.frame = CGRect(x: 14, y: CGFloat(index + 1) * tileHeight, width: inner - 28, height: RCLayout.hairline)
                    separator.isHidden = false
                } else if index < rows - 1 {
                    separator.frame = CGRect(x: 14, y: CGFloat(index + 1) * tileHeight, width: inner - 28, height: RCLayout.hairline)
                    separator.isHidden = false
                } else if index == rows - 1 {
                    separator.frame = CGRect(x: tileWidth, y: 12, width: RCLayout.hairline, height: tileHeight * 2 - 24)
                    separator.isHidden = false
                } else {
                    separator.isHidden = true
                }
            }
        }
        place(metricsCard, CGRect(x: x, y: y, width: inner, height: metricsHeight))
        y += metricsHeight + 20

        place(actionsHeader, CGRect(x: x, y: y, width: inner, height: 32))
        y += 32 + 4
        let actionColumns = columns
        let spacing: CGFloat = 10
        let actionWidth = (inner - spacing * CGFloat(actionColumns - 1)) / CGFloat(actionColumns)
        // Tiles in a row share the tallest tile's height.
        var rowTop = y
        for rowStart in stride(from: 0, to: actionTiles.count, by: actionColumns) {
            let row = actionTiles[rowStart..<min(rowStart + actionColumns, actionTiles.count)]
            let height = row.map { $0.sizeThatFits(CGSize(width: actionWidth, height: .greatestFiniteMagnitude)).height }.max() ?? 0
            for (col, tile) in row.enumerated() {
                place(tile, CGRect(x: x + CGFloat(col) * (actionWidth + spacing), y: rowTop, width: actionWidth, height: height))
            }
            rowTop += height + spacing
        }
        y = rowTop - spacing + 12
        if !actionsNote.isHidden {
            let noteHeight = actionsNote.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            place(actionsNote, CGRect(x: x + 2, y: y - 2, width: inner - 4, height: noteHeight))
            y += noteHeight + 10
        }
        y += 8
        // Titles wrap at accessibility sizes: heights follow the column width.
        let lockHeight = ceil(lockButton.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        place(lockButton, CGRect(x: x, y: y, width: inner, height: lockHeight))
        y += lockHeight + 10
        let reconnectHeight = ceil(reconnectButton.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        place(reconnectButton, CGRect(x: x, y: y, width: inner, height: reconnectHeight))
        y += reconnectHeight + 20
        return ceil(y)
    }
}

/// "Title · value" row in the connection card. At accessibility text sizes
/// the title stacks above a wrapping value instead of truncating both.
@MainActor
private final class RemoteToolsInfoRow: RCView {
    private let titleLabel: RCLabel
    private let valueLabel: RCLabel
    private let leadingAccessory: UIView?
    private let monospaced: Bool
    private static let titleWidth: CGFloat = 76
    private static let inset: CGFloat = 14

    init(title: String, value: String, monospaced: Bool = false, valueColor: UIColor = RCColor.text, leadingAccessory: UIView? = nil) {
        titleLabel = RCLabel(title, style: .footnote, color: RCColor.textSecondary)
        valueLabel = RCLabel(value, style: monospaced ? .mono : .footnoteStrong, color: valueColor)
        self.leadingAccessory = leadingAccessory
        self.monospaced = monospaced
        super.init(frame: .zero)
        addSubview(titleLabel)
        addSubview(valueLabel)
        if let leadingAccessory { addSubview(leadingAccessory) }
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityValue = value
        updateTypography()
    }

    private var isStacked: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    override func updateTypography() {
        valueLabel.numberOfLines = isStacked ? 0 : 1
        valueLabel.lineBreakMode = isStacked ? .byCharWrapping : (monospaced ? .byTruncatingMiddle : .byTruncatingTail)
    }

    private func valueX(stacked: Bool) -> CGFloat {
        var x = stacked ? Self.inset : Self.inset + Self.titleWidth + 8
        if let leadingAccessory { x += leadingAccessory.sizeThatFits(.zero).width + 8 }
        return x
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if isStacked {
            let valueWidth = max(0, size.width - valueX(stacked: true) - Self.inset)
            let title = RCTypography.lineHeight(.footnote, compatibleWith: traitCollection)
            let value = valueLabel.sizeThatFits(CGSize(width: valueWidth, height: .greatestFiniteMagnitude)).height
            let accessory = leadingAccessory?.sizeThatFits(.zero).height ?? 0
            return CGSize(width: size.width, height: ceil(12 + title + 4 + max(value, accessory) + 12))
        }
        let line = max(RCTypography.lineHeight(.footnote, compatibleWith: traitCollection), RCTypography.lineHeight(valueLabel.style, compatibleWith: traitCollection))
        return CGSize(width: size.width, height: max(44, ceil(line + 20)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let stacked = isStacked
        let titleHeight = RCTypography.lineHeight(.footnote, compatibleWith: traitCollection)
        let x = valueX(stacked: stacked)
        let valueWidth = max(0, bounds.width - x - Self.inset)
        if stacked {
            titleLabel.frame = CGRect(x: Self.inset, y: 12, width: bounds.width - Self.inset * 2, height: titleHeight)
            let top = 12 + titleHeight + 4
            let valueHeight = valueLabel.sizeThatFits(CGSize(width: valueWidth, height: .greatestFiniteMagnitude)).height
            if let leadingAccessory {
                let size = leadingAccessory.sizeThatFits(.zero)
                leadingAccessory.frame = CGRect(x: Self.inset, y: top + max(0, (valueHeight - size.height) / 2), width: size.width, height: size.height)
            }
            valueLabel.frame = CGRect(x: x, y: top, width: valueWidth, height: valueHeight)
            return
        }
        let midY = bounds.height / 2
        titleLabel.frame = CGRect(x: Self.inset, y: midY - titleHeight / 2, width: Self.titleWidth, height: titleHeight)
        if let leadingAccessory {
            let size = leadingAccessory.sizeThatFits(.zero)
            leadingAccessory.frame = CGRect(x: Self.inset + Self.titleWidth + 8, y: midY - size.height / 2, width: size.width, height: size.height)
        }
        let valueHeight = RCTypography.lineHeight(valueLabel.style, compatibleWith: traitCollection)
        valueLabel.frame = CGRect(x: x, y: midY - valueHeight / 2, width: valueWidth, height: valueHeight)
    }
}

/// One live metric: quiet title over a tabular monospaced value.
@MainActor
private final class RemoteMetricTile: RCView {
    private let titleLabel = RCLabel(style: .caption, color: RCColor.textTertiary)
    private let valueLabel = RCLabel(style: .mono, color: RCColor.text)

    static func height(traits: UITraitCollection) -> CGFloat {
        ceil(RCTypography.lineHeight(.caption, compatibleWith: traits) + RCTypography.lineHeight(.mono, compatibleWith: traits) + 4 + 24)
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        valueLabel.usesMonospacedDigits = true
        addSubview(titleLabel)
        addSubview(valueLabel)
    }

    func configure(_ metric: RemoteDiagnosticsPresentation.Metric) {
        titleLabel.text = metric.title
        valueLabel.text = metric.value
        valueLabel.color = metric.value == RemoteDiagnosticsPresentation.unavailable ? RCColor.textTertiary : RCColor.text
        accessibilityLabel = metric.title
        accessibilityValue = metric.value
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleHeight = RCTypography.lineHeight(.caption, compatibleWith: traitCollection)
        let valueHeight = RCTypography.lineHeight(.mono, compatibleWith: traitCollection)
        titleLabel.frame = CGRect(x: 14, y: 12, width: bounds.width - 28, height: titleHeight)
        valueLabel.frame = CGRect(x: 14, y: 12 + titleHeight + 4, width: bounds.width - 28, height: valueHeight)
    }
}

/// Hardware action tile (icon + title).
@MainActor
private final class RemoteToolActionTile: RCControl {
    let action: RemoteHardwareAction
    var onTap: ((RemoteHardwareAction) -> Void)?

    private let iconView: RCIconView
    private let titleLabel: RCLabel

    init(title: String, icon: RCIconGlyph, action: RemoteHardwareAction) {
        self.action = action
        iconView = RCIconView(icon, pointSize: 18)
        titleLabel = RCLabel(title, style: .subheadlineStrong, lines: 2)
        super.init(frame: .zero)
        addSubview(iconView)
        addSubview(titleLabel)
        accessibilityLabel = title
        updateAppearance()
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTapAction { [weak self] in self?.handleTap() }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.42
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted { RCHaptics.prepare(.light) }
            let highlighted = isHighlighted
            RCMotion.animate(duration: highlighted ? RCMotion.pressDuration : RCMotion.releaseDuration) {
                self.transform = highlighted && !RCMotion.reduceMotion ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
                self.layer.backgroundColor = (highlighted ? RCColor.lineStrong : RCColor.elevated).cgColor(for: self)
            }
        }
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
        iconView.tintColor = RCColor.text
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textWidth = max(0, size.width - 14 - 18 - 12 - 14)
        let textHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(width: size.width, height: max(56, ceil(textHeight + 24)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        iconView.frame = CGRect(x: 14, y: (bounds.height - 18) / 2, width: 18, height: 18)
        let textX: CGFloat = 14 + 18 + 12
        let textWidth = max(0, bounds.width - textX - 14)
        let textHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: textX, y: (bounds.height - textHeight) / 2, width: textWidth, height: textHeight)
    }

    @objc private func handleTap() {
        RCHaptics.play(.light)
        onTap?(action)
    }
}
