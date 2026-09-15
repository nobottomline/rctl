import RctlClient
import UIKit

/// Floating session dock: source, View/Control, Home, Keyboard, Session controls.
///
/// - `horizontal`: regular widths show titled segmented controls; compact widths
///   turn the source into a menu button and show icon-only segments, with the
///   mode control taking the spare width.
/// - `vertical`: a slim trailing rail for landscape phones.
@MainActor
final class RemoteControlDockView: RCSurfaceView {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal { didSet { if axis != oldValue { applyAxis() } } }

    var onSelectMedia: ((ControllerMediaRole) -> Void)?
    var onSelectMode: ((RemoteInteractionMode) -> Void)?
    var onHome: (() -> Void)?
    var onKeyboard: (() -> Void)?
    var onTools: (() -> Void)?

    private let sourceSegments = RCSegmentedControl(items: [
        .init(title: "Screen", icon: .monitor, accessibilityLabel: "Screen source"),
        .init(title: "Camera", icon: .camera, accessibilityLabel: "Camera source"),
    ])
    private let sourceButton = RCIconButton(icon: .monitor, variant: .stage, shape: .rounded, diameter: 40, iconSize: 20, accessibilityLabel: "Source")
    private let modeSegments = RCSegmentedControl(items: [
        .init(title: "View", icon: .eye, accessibilityLabel: "View"),
        .init(title: "Control", icon: .pointer, accessibilityLabel: "Control"),
    ], style: .accentOn([1]))
    private let modeRail = RemoteRailModeControl()
    private let homeButton = RCIconButton(icon: .house, variant: .stage, shape: .rounded, diameter: 40, iconSize: 20, accessibilityLabel: "Home")
    private let keyboardButton = RCIconButton(icon: .keyboard, variant: .stage, shape: .rounded, diameter: 40, iconSize: 20, accessibilityLabel: "Keyboard")
    private let toolsButton = RCIconButton(icon: .slidersHorizontal, variant: .stage, shape: .rounded, diameter: 40, iconSize: 20, accessibilityLabel: "Session controls")

    private var media: ControllerMediaRole = .screen
    private var isCompact = false

    init() {
        super.init(style: .floating, cornerRadius: RCRadius.xl)
    }

    override func setUp() {
        super.setUp()
        [sourceSegments, sourceButton, modeSegments, modeRail, homeButton, keyboardButton, toolsButton].forEach(contentView.addSubview)
        contentView.accessibilityElements = [sourceSegments, sourceButton, modeSegments, modeRail, homeButton, keyboardButton, toolsButton]

        sourceSegments.onChange = { [weak self] index in
            self?.chooseMedia(index == 0 ? .screen : .camera, hapticPlayed: true)
        }
        sourceButton.haptic = nil
        RCMenu.attach(to: sourceButton) { [weak self] in
            guard let self else { return [] }
            return [RCMenuSection(title: "Source", items: [
                RCMenuItem("Screen", icon: .monitor, isChecked: self.media == .screen) { [weak self] in
                    self?.chooseMedia(.screen, hapticPlayed: false)
                },
                RCMenuItem("Camera", icon: .camera, isChecked: self.media == .camera) { [weak self] in
                    self?.chooseMedia(.camera, hapticPlayed: false)
                },
            ])]
        }
        modeSegments.accessibilityHint = "View mode blocks all remote input"
        modeSegments.onChange = { [weak self] index in
            self?.onSelectMode?(index == 1 ? .control : .view)
        }
        modeRail.onChange = { [weak self] index in
            self?.onSelectMode?(index == 1 ? .control : .view)
        }
        homeButton.haptic = .light
        homeButton.onTap = { [weak self] in self?.onHome?() }
        keyboardButton.haptic = .selection
        keyboardButton.onTap = { [weak self] in self?.onKeyboard?() }
        toolsButton.haptic = .selection
        toolsButton.onTap = { [weak self] in self?.onTools?() }
        applyAxis()
    }

    func apply(_ presentation: RemoteSessionPresentation) {
        if presentation.media != media {
            media = presentation.media
            sourceSegments.setSelectedIndex(media == .screen ? 0 : 1, animated: window != nil)
            sourceButton.icon = media == .screen ? .monitor : .camera
        }
        sourceButton.accessibilityValue = media == .screen ? "Screen" : "Camera"
        let modeIndex = presentation.isControlMode ? 1 : 0
        modeSegments.setEnabled(presentation.canSelectControl, forSegmentAt: 1)
        modeSegments.setSelectedIndex(modeIndex, animated: window != nil)
        modeRail.configure(selectedIndex: modeIndex, controlEnabled: presentation.canSelectControl, animated: window != nil)
        if homeButton.isEnabled != presentation.controlsEnabled {
            homeButton.isEnabled = presentation.controlsEnabled
            keyboardButton.isEnabled = presentation.controlsEnabled
        }
    }

#if DEBUG
    /// Screenshot hook (`--rctl-remote-demo=source-menu`): opens the compact source menu.
    func openSourceMenu() {
        guard !sourceButton.isHidden else { return }
        sourceButton.sendActions(for: .primaryActionTriggered)
    }
#endif

    private func chooseMedia(_ value: ControllerMediaRole, hapticPlayed: Bool) {
        guard value != media else { return }
        if !hapticPlayed { RCHaptics.play(.selection) }
        onSelectMedia?(value)
    }

    private func applyAxis() {
        modeRail.isHidden = axis == .horizontal
        setNeedsLayout()
    }

    // MARK: Layout

    private struct Metrics {
        let padding: CGFloat
        let spacing: CGFloat
        let side: CGFloat

        static let regular = Metrics(padding: 10, spacing: 8, side: 40)
        /// 320 pt phones: tighter spacing. Visuals are 40 pt; hit targets stay 44 pt via `RCControl`.
        static let narrow = Metrics(padding: 8, spacing: 6, side: 40)
    }

    private static let minimumHeight: CGFloat = 60
    private struct Measurements {
        let category: UIContentSizeCategory
        let titledSource: CGFloat
        let titledMode: CGFloat
        let iconMode: CGFloat
        let segmentHeight: CGFloat
    }
    private var measurementCache: Measurements?

    override func updateTypography() {
        super.updateTypography()
        measurementCache = nil
    }

    /// Segmented control metrics for the current text size (cached; measuring toggles titles).
    private func measurements() -> Measurements {
        let category = traitCollection.preferredContentSizeCategory
        if let cache = measurementCache, cache.category == category { return cache }
        func width(_ control: RCSegmentedControl, titles: Bool) -> CGFloat {
            let shows = control.showsTitles
            control.showsTitles = titles
            let width = ceil(control.sizeThatFits(.zero).width)
            control.showsTitles = shows
            return width
        }
        let result = Measurements(
            category: category,
            titledSource: width(sourceSegments, titles: true),
            titledMode: width(modeSegments, titles: true),
            iconMode: width(modeSegments, titles: false),
            segmentHeight: ceil(modeSegments.sizeThatFits(.zero).height)
        )
        measurementCache = result
        return result
    }

    private var barHeight: CGFloat { max(Self.minimumHeight, measurements().segmentHeight + 20) }

    private func regularWidth() -> CGFloat {
        let m = measurements()
        let metrics = Metrics.regular
        return metrics.padding * 2 + m.titledSource + m.titledMode + metrics.side * 3 + metrics.spacing * 4
    }

    private func compactWidth(_ metrics: Metrics) -> CGFloat {
        metrics.padding * 2 + metrics.side * 4 + measurements().iconMode + metrics.spacing * 4
    }

    /// Horizontal: natural width for `size.width` (regular content if it fits,
    /// otherwise the compact dock filling the width). Vertical: the rail size.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = Metrics.regular
        switch axis {
        case .vertical:
            let height = metrics.padding * 2 + metrics.side * 4 + RemoteRailModeControl.preferredHeight + metrics.spacing * 4 + 4
            return CGSize(width: metrics.side + metrics.padding * 2, height: height)
        case .horizontal:
            let regular = regularWidth()
            if regular <= size.width { return CGSize(width: regular, height: barHeight) }
            return CGSize(width: max(compactWidth(.narrow), size.width), height: barHeight)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch axis {
        case .horizontal: layoutHorizontal()
        case .vertical: layoutVertical()
        }
    }

    private func layoutHorizontal() {
        let bounds = contentView.bounds
        let centerY = bounds.height / 2
        let m = measurements()
        isCompact = regularWidth() > bounds.width + 0.5
        let metrics = isCompact && bounds.width < compactWidth(.regular) ? Metrics.narrow : Metrics.regular
        let side = metrics.side
        let segmentHeight = m.segmentHeight
        sourceSegments.isHidden = isCompact
        sourceButton.isHidden = !isCompact
        modeSegments.isHidden = false

        var x = metrics.padding
        if isCompact {
            sourceButton.diameter = side
            sourceButton.frame = CGRect(x: x, y: centerY - side / 2, width: side, height: side)
            x += side + metrics.spacing
        } else {
            sourceSegments.frame = CGRect(x: x, y: centerY - segmentHeight / 2, width: m.titledSource, height: segmentHeight)
            x += m.titledSource + metrics.spacing
        }
        var trailing = bounds.width - metrics.padding
        for button in [toolsButton, keyboardButton, homeButton] {
            trailing -= side
            button.diameter = side
            button.frame = CGRect(x: trailing, y: centerY - side / 2, width: side, height: side)
            trailing -= metrics.spacing
        }
        let modeWidth = max(0, trailing - x)
        // Titles return as soon as the flexible mode control has room for them.
        let showsModeTitles = !isCompact || m.titledMode <= modeWidth
        if modeSegments.showsTitles != showsModeTitles { modeSegments.showsTitles = showsModeTitles }
        modeSegments.frame = CGRect(x: x, y: centerY - segmentHeight / 2, width: isCompact ? modeWidth : min(modeWidth, m.titledMode), height: segmentHeight)
    }

    private func layoutVertical() {
        let bounds = contentView.bounds
        let metrics = Metrics.regular
        let side = metrics.side
        let x = (bounds.width - side) / 2
        sourceSegments.isHidden = true
        modeSegments.isHidden = true
        sourceButton.isHidden = false
        var y = metrics.padding
        sourceButton.diameter = side
        sourceButton.frame = CGRect(x: x, y: y, width: side, height: side)
        y += side + metrics.spacing + 2
        modeRail.frame = CGRect(x: x, y: y, width: side, height: RemoteRailModeControl.preferredHeight)
        y += RemoteRailModeControl.preferredHeight + 2 + metrics.spacing
        for button in [homeButton, keyboardButton, toolsButton] {
            button.diameter = side
            button.frame = CGRect(x: x, y: y, width: side, height: side)
            y += side + metrics.spacing
        }
    }
}

/// Vertical View / Control switch for the landscape rail: a sunken track with a
/// sliding thumb that turns accent for Control (mirrors `RCSegmentedControl`).
@MainActor
final class RemoteRailModeControl: RCControl {
    static let preferredHeight: CGFloat = 86

    var onChange: ((Int) -> Void)?

    private(set) var selectedIndex = 0
    private var controlEnabled = false
    private let thumb = CALayer()
    private let viewIcon = RCIconView(.eye, pointSize: 18)
    private let controlIcon = RCIconView(.pointer, pointSize: 18)
    private static let titles = ["View", "Control"]

    override func setUp() {
        isAccessibilityElement = false
        layer.addSublayer(thumb)
        addSubview(viewIcon)
        addSubview(controlIcon)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    func configure(selectedIndex: Int, controlEnabled: Bool, animated: Bool) {
        guard selectedIndex != self.selectedIndex || controlEnabled != self.controlEnabled else { return }
        let moved = selectedIndex != self.selectedIndex
        self.selectedIndex = selectedIndex
        self.controlEnabled = controlEnabled
        if moved, animated {
            RCMotion.animate(RCMotion.snappy) { self.layoutThumb(); self.updateAppearance() }
        } else {
            withoutImplicitAnimations { layoutThumb() }
            updateAppearance()
        }
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
        let control = selectedIndex == 1
        thumb.backgroundColor = (control ? RCColor.accent : RCColor.elevated).cgColor(for: self)
        viewIcon.tintColor = control ? RCColor.textTertiary : RCColor.text
        controlIcon.tintColor = !controlEnabled ? RCColor.textQuaternary : (control ? RCColor.onAccent : RCColor.textTertiary)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: 40, height: Self.preferredHeight) }

    private func segmentFrame(_ index: Int) -> CGRect {
        let height = (bounds.height - 6) / 2
        return CGRect(x: 3, y: 3 + CGFloat(index) * height, width: bounds.width - 6, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        viewIcon.frame = segmentFrame(0)
        controlIcon.frame = segmentFrame(1)
        withoutImplicitAnimations { layoutThumb() }
    }

    private func layoutThumb() {
        thumb.frame = segmentFrame(selectedIndex)
        thumb.cornerRadius = RCRadius.md - 3
        thumb.cornerCurve = .continuous
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let index = gesture.location(in: self).y < bounds.midY ? 0 : 1
        guard isEnabled, index != selectedIndex, index == 0 || controlEnabled else { return }
        RCHaptics.play(.selection)
        configure(selectedIndex: index, controlEnabled: controlEnabled, animated: true)
        sendActions(for: .valueChanged)
        onChange?(index)
    }

    override var accessibilityElements: [Any]? {
        get {
            (0..<2).map { index in
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = Self.titles[index]
                element.accessibilityHint = index == 0 ? "Blocks all remote input" : nil
                var traits: UIAccessibilityTraits = .button
                if index == selectedIndex { traits.insert(.selected) }
                if index == 1, !controlEnabled { traits.insert(.notEnabled) }
                element.accessibilityTraits = traits
                element.accessibilityFrameInContainerSpace = segmentFrame(index)
                return element
            }
        }
        set {}
    }
}
