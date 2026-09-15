#if DEBUG
import UIKit

extension GalleryCatalog {
    /// Gallery specimens for the primitives design-system area. All sections
    /// share the id `primitives`; `--rctl-gallery-part=buttons|icons|indicators|surfaces|type`
    /// narrows them further for screenshots, and `part@N` skips the first N items.
    static func primitives() -> [GallerySection] {
        let sections: [(part: String, section: GallerySection)] = [
            ("buttons", GallerySection(id: "primitives", title: "Buttons", items: primitiveButtonItems())),
            ("icons", GallerySection(id: "primitives", title: "Icon buttons", items: primitiveIconButtonItems())),
            ("indicators", GallerySection(id: "primitives", title: "Indicators", items: primitiveIndicatorItems())),
            ("surfaces", GallerySection(id: "primitives", title: "Surfaces", items: primitiveSurfaceItems())),
            ("type", GallerySection(id: "primitives", title: "Typography", items: primitiveTypeItems())),
        ]
        guard let argument = DebugLaunch.argument("rctl-gallery-part") else { return sections.map(\.section) }
        let components = argument.split(separator: "@")
        let part = components.first.map(String.init)
        let skip = components.count > 1 ? Int(components[1]) ?? 0 : 0
        return sections.filter { $0.part == part }.map { entry in
            GallerySection(id: entry.section.id, title: entry.section.title, items: Array(entry.section.items.dropFirst(skip)))
        }
    }

    // MARK: Buttons

    private static func primitiveButtonItems() -> [GalleryItem] {
        let variants: [(String, RCButton.Variant)] = [
            ("Primary", .primary), ("Accent", .accent), ("Secondary", .secondary),
            ("Ghost", .ghost), ("Delete", .destructive), ("Remove", .destructiveSoft),
        ]
        let sizes: [(String, RCButton.Size)] = [("Small", .small), ("Medium", .medium), ("Large", .large)]
        return [
            GalleryItem("Variants") { _ in
                GalleryFlowView(variants.map { RCButton(title: $0.0, variant: $0.1) })
            },
            GalleryItem("Variant × size") { _ in
                GalleryStackView(variants.map { name, variant in
                    GalleryFlowView(sizes.map { RCButton(title: $0.0, icon: variant == .destructive || variant == .destructiveSoft ? .trash2 : .plus, variant: variant, size: $0.1) })
                }, spacing: 12)
            },
            GalleryItem("Icon placement · icon only") { _ in
                GalleryFlowView([
                    RCButton(title: "Pair with relay", icon: .qrCode, variant: .accent, size: .medium),
                    trailingIconButton(),
                    RCButton(icon: .refreshCw, variant: .secondary, size: .medium),
                    RCButton(icon: .ellipsis, variant: .ghost, size: .small),
                ])
            },
            GalleryItem("States · loading, disabled, pressed") { _ in
                let loadingIcon = RCButton(title: "Connecting", icon: .plugZap, variant: .primary, size: .medium)
                loadingIcon.setLoading(true, animated: false)
                let loadingText = RCButton(title: "Save", variant: .accent, size: .medium)
                loadingText.setLoading(true, animated: false)
                let disabled = RCButton(title: "Disabled", icon: .lock, variant: .primary, size: .medium)
                disabled.isEnabled = false
                let disabledSecondary = RCButton(title: "Disabled", variant: .secondary, size: .medium)
                disabledSecondary.isEnabled = false
                let pressedPrimary = RCButton(title: "Pressed", variant: .primary, size: .medium)
                pressedPrimary.isHighlighted = true
                let pressedGhost = RCButton(title: "Pressed", variant: .ghost, size: .medium)
                pressedGhost.isHighlighted = true
                return GalleryFlowView([loadingIcon, loadingText, disabled, disabledSecondary, pressedPrimary, pressedGhost])
            },
            GalleryItem("Disabled filled · full width") { _ in
                let accent = RCButton(title: "Connect", icon: .arrowRight, variant: .accent)
                accent.iconPlacement = .trailing
                accent.isEnabled = false
                let destructive = RCButton(title: "Delete relay", icon: .trash2, variant: .destructive, size: .medium)
                destructive.isEnabled = false
                let toggling = RCButton(title: "Replace address and connect", icon: .arrowRight, variant: .accent)
                toggling.iconPlacement = .trailing
                let stack = GalleryStackView([accent, destructive, toggling], spacing: 12)
                stack.ticker = GalleryTicker(interval: 1.6) { tick in toggling.isEnabled = tick % 2 == 0 }
                return stack
            },
            GalleryItem("Loading · press demo (toggles)") { _ in
                let withIcon = RCButton(title: "Refresh", icon: .refreshCw, variant: .secondary, size: .medium)
                let textOnly = RCButton(title: "Pair device", variant: .primary, size: .medium)
                let pressed = RCButton(title: "Press", variant: .accent, size: .medium)
                let flow = GalleryFlowView([withIcon, textOnly, pressed])
                flow.ticker = GalleryTicker(interval: 0.8) { tick in
                    if tick % 2 == 0 {
                        withIcon.isLoading = tick % 4 == 0
                        textOnly.isLoading = tick % 4 == 0
                    }
                    pressed.isHighlighted = tick % 2 == 1
                }
                return flow
            },
            GalleryItem("Full width · truncation") { _ in
                let full = RCButton(title: "Pair with relay", icon: .qrCode, variant: .accent)
                let long = RCButton(title: "Forget this device and every saved address", icon: .trash2, variant: .destructiveSoft, size: .medium)
                return GalleryStackView([full, GalleryFixedWidthView(long, width: 220)], spacing: 12, stretches: [true, false])
            },
            GalleryItem("Right-to-left") { _ in
                let flow = GalleryFlowView([
                    RCButton(title: "Continue", icon: .arrowRight, variant: .primary, size: .medium),
                    trailingIconButton(),
                ])
                flow.semanticContentAttribute = .forceRightToLeft
                flow.subviews.forEach { $0.semanticContentAttribute = .forceRightToLeft }
                return flow
            },
        ]
    }

    private static func trailingIconButton() -> RCButton {
        let button = RCButton(title: "Next", icon: .chevronRight, variant: .secondary, size: .medium)
        button.iconPlacement = .trailing
        return button
    }

    // MARK: Icon buttons

    private static func primitiveIconButtonItems() -> [GalleryItem] {
        [
            GalleryItem("Adaptive variants · selected") { _ in
                let plainSelected = RCIconButton(icon: .keyboard, variant: .plain, accessibilityLabel: "Keyboard")
                plainSelected.isSelected = true
                let ghostSelected = RCIconButton(icon: .eye, variant: .ghost, accessibilityLabel: "View mode")
                ghostSelected.isSelected = true
                return GalleryFlowView([
                    RCIconButton(icon: .chevronLeft, variant: .plain, accessibilityLabel: "Back"),
                    RCIconButton(icon: .plus, variant: .primary, accessibilityLabel: "Add"),
                    RCIconButton(icon: .qrCode, variant: .accent, accessibilityLabel: "Scan"),
                    RCIconButton(icon: .ellipsis, variant: .ghost, accessibilityLabel: "More"),
                    plainSelected,
                    ghostSelected,
                    RCIconButton(icon: .settings, variant: .plain, shape: .rounded, diameter: 44, iconSize: 20, accessibilityLabel: "Settings"),
                    RCIconButton(icon: .x, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "Close"),
                ], spacing: 12)
            },
            GalleryItem("Stage variants", onStage: true) { _ in
                let overlaySelected = RCIconButton(icon: .flashlight, variant: .overlay, diameter: 44, iconSize: 20, accessibilityLabel: "Torch")
                overlaySelected.isSelected = true
                let stageSelected = RCIconButton(icon: .hand, variant: .stage, diameter: 44, iconSize: 20, accessibilityLabel: "Control mode")
                stageSelected.isSelected = true
                return GalleryFlowView([
                    RCIconButton(icon: .x, variant: .overlay, diameter: 44, iconSize: 20, accessibilityLabel: "Close"),
                    overlaySelected,
                    RCIconButton(icon: .camera, variant: .overlayProminent, diameter: 44, iconSize: 20, accessibilityLabel: "Camera"),
                    RCIconButton(icon: .eye, variant: .stage, diameter: 44, iconSize: 20, accessibilityLabel: "View mode"),
                    stageSelected,
                    RCIconButton(icon: .keyboard, variant: .stage, shape: .rounded, diameter: 44, iconSize: 20, accessibilityLabel: "Keyboard"),
                ], spacing: 12)
            },
            GalleryItem("Spinning · disabled · selection demo") { _ in
                let spinning = RCIconButton(icon: .refreshCw, variant: .plain, accessibilityLabel: "Refresh")
                spinning.isSpinning = true
                let disabled = RCIconButton(icon: .trash2, variant: .plain, accessibilityLabel: "Delete")
                disabled.isEnabled = false
                let toggling = RCIconButton(icon: .hand, variant: .plain, accessibilityLabel: "Control mode")
                let togglingGhost = RCIconButton(icon: .volume2, variant: .ghost, accessibilityLabel: "Sound")
                let stopStart = RCIconButton(icon: .rotateCw, variant: .ghost, accessibilityLabel: "Reload")
                let flow = GalleryFlowView([spinning, disabled, toggling, togglingGhost, stopStart], spacing: 12)
                flow.ticker = GalleryTicker(interval: 1.5) { tick in
                    toggling.isSelected = tick % 2 == 1
                    togglingGhost.isSelected = tick % 2 == 0
                    stopStart.isSpinning = tick % 3 != 2
                }
                return flow
            },
        ]
    }

    // MARK: Indicators

    private static func primitiveIndicatorItems() -> [GalleryItem] {
        [
            GalleryItem("Spinners") { _ in
                let specs: [(CGFloat, CGFloat, UIColor)] = [
                    (14, 1.5, RCColor.textTertiary), (20, 2, RCColor.textTertiary), (20, 2, RCColor.accent),
                    (28, 2.5, RCColor.text), (36, 3, RCColor.accent),
                ]
                return GalleryFlowView(specs.map { diameter, width, tint in
                    let spinner = RCSpinner(diameter: diameter, lineWidth: width)
                    spinner.tintColor = tint
                    spinner.startAnimating()
                    return spinner
                }, spacing: 20)
            },
            GalleryItem("Status badges") { _ in
                let busy = RCStatusBadge()
                busy.configure(text: "Checking", tone: .neutral, busy: true)
                let pulsing = RCStatusBadge()
                pulsing.configure(text: "Live", tone: .success, pulsing: true)
                let attentionPulse = RCStatusBadge()
                attentionPulse.configure(text: "Control", tone: .attention, pulsing: true)
                return GalleryFlowView([
                    RCStatusBadge(text: "Online", tone: .success),
                    RCStatusBadge(text: "Needs attention", tone: .attention),
                    RCStatusBadge(text: "Offline", tone: .danger),
                    RCStatusBadge(text: "Unknown", tone: .neutral),
                    RCStatusBadge(text: "New", tone: .accent),
                    busy,
                    pulsing,
                    attentionPulse,
                ], spacing: 8)
            },
            GalleryItem("Badge transitions (trailing-anchored)") { _ in
                let badge = RCStatusBadge()
                let states: [(String, RCStatusBadge.Tone, Bool, Bool)] = [
                    ("Connecting", .neutral, true, false),
                    ("Online", .success, false, true),
                    ("Relay unreachable", .danger, false, false),
                    ("Local", .accent, false, false),
                ]
                badge.configure(text: states[0].0, tone: states[0].1, busy: states[0].2, pulsing: states[0].3)
                let row = GalleryTrailingRow(badge)
                row.ticker = GalleryTicker(interval: 2) { [weak row] tick in
                    let state = states[tick % states.count]
                    badge.configure(text: state.0, tone: state.1, busy: state.2, pulsing: state.3, animated: true)
                    row?.setNeedsLayout()
                }
                return row
            },
            GalleryItem("Skeleton rows") { _ in
                GalleryStackView((0..<3).map { index in GallerySkeletonRow(widths: [0.62 - CGFloat(index) * 0.1, 0.38 + CGFloat(index) * 0.08]) }, spacing: 14)
            },
            GalleryItem("Separator", height: 20) { _ in
                let holder = GalleryCenteredLine()
                return holder
            },
        ]
    }

    // MARK: Surfaces

    private static func primitiveSurfaceItems() -> [GalleryItem] {
        [
            GalleryItem("Card") { _ in
                GallerySurfaceSample(style: .card, text: "Kitchen iPad · 192.168.1.30:8080\nContact and ambient shadows sit under the fill.")
            },
            GalleryItem("Inset") { _ in
                GallerySurfaceSample(style: .inset, text: "Sunken well for secondary content, no shadow.")
            },
            GalleryItem("Floating (stage)", onStage: true) { _ in
                GallerySurfaceSample(style: .floating, text: "Floating chrome over video: opaque, Console tokens.")
            },
            GalleryItem("Callouts · tones") { _ in
                GalleryStackView([
                    RCCallout(text: "Devices on this network appear automatically.", icon: .info, tone: .neutral),
                    RCCallout(text: "View mode is on. Remote input is blocked until you switch to Control.", icon: .eye, tone: .accent),
                    RCCallout(text: "Paired with relay.", icon: .circleCheck, tone: .success),
                    RCCallout(text: "The relay did not answer. Check the address and try again.", icon: .circleAlert, tone: .danger),
                ], spacing: 10)
            },
            GalleryItem("Callouts · long text, actions, shake") { _ in
                let long = RCCallout(
                    text: "Only pair with a relay you control. Anyone with access to the relay can see and control the devices you add to it, including the screen, camera and keyboard input.",
                    icon: .shieldAlert,
                    tone: .accent
                )
                let retry = RCCallout(text: "Relay unreachable.", icon: .wifiOff, tone: .danger)
                retry.setAction(title: "Retry") {}
                let wrapped = RCCallout(text: "This device’s address changed since it was saved. Update the saved entry to keep using it.", icon: .triangleAlert, tone: .neutral)
                wrapped.setAction(title: "Update address") {}
                let stack = GalleryStackView([long, retry, wrapped], spacing: 10)
                stack.ticker = GalleryTicker(interval: 3) { tick in
                    if tick % 2 == 1 { retry.shake() }
                }
                return stack
            },
            GalleryItem("Section headers") { _ in
                let refresh = RCIconButton(icon: .refreshCw, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "Refresh")
                let spinner = RCSpinner(diameter: 16, lineWidth: 1.75)
                spinner.startAnimating()
                let more = RCIconButton(icon: .ellipsis, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "More")
                let withAccessory = RCSectionHeader(title: "Nearby", subtitle: "Scanning Wi-Fi")
                withAccessory.accessoryView = refresh
                let busy = RCSectionHeader(title: "Relay devices", subtitle: "3 online")
                busy.accessoryView = spinner
                let long = RCSectionHeader(title: "Saved on this iPhone", subtitle: "Addresses you added manually stay on this device only")
                long.accessoryView = more
                return GalleryStackView([RCSectionHeader(title: "Devices"), withAccessory, busy, long], spacing: 4)
            },
            GalleryItem("Icon tiles") { _ in
                let tones: [RCIconTile.Tone] = [.accent, .neutral, .success, .danger, .dashed, .muted]
                let glyphs: [RCIconGlyph] = [.tabletSmartphone, .server, .wifi, .unplug, .plus, .monitor]
                var tiles: [UIView] = zip(tones, glyphs).map { RCIconTile(glyph: $1, tone: $0) }
                tiles.append(RCIconTile(glyph: .radar, tone: .accent, side: 32))
                tiles.append(RCIconTile(glyph: .scanQrCode, tone: .neutral, side: 52))
                return GalleryFlowView(tiles, spacing: 12)
            },
            GalleryItem("Empty state · actions") { _ in
                RCEmptyStateView(
                    icon: .tabletSmartphone,
                    title: "No devices yet",
                    message: "Pair with your relay to reach devices anywhere, or add one on this network.",
                    actions: [
                        RCButton(title: "Pair with relay", icon: .qrCode, variant: .accent),
                        RCButton(title: "Add local device", icon: .wifi, variant: .secondary),
                    ]
                )
            },
            GalleryItem("Empty state · message only") { _ in
                RCEmptyStateView(icon: .radar, title: "Nothing nearby", message: "Devices running rctl on this Wi-Fi network show up here.")
            },
        ]
    }

    // MARK: Typography

    private static func primitiveTypeItems() -> [GalleryItem] {
        [
            GalleryItem("Type scale") { _ in
                GalleryStackView(RCTextStyle.allCases.map { style in
                    GalleryTypeSpecimen(style: style)
                }, spacing: 10)
            },
            GalleryItem("Optical centering · RCLabel vs UILabel") { _ in
                GalleryStackView([RCTextStyle.title2, .headline, .body, .footnote, .caption, .overline].map { GalleryCenteringSpecimen(style: $0) }, spacing: 8)
            },
            GalleryItem("Wrapping · two-line truncation · digits") { _ in
                let wrap = RCLabel("Pairing links a relay to this controller. The relay never sees your device passwords, and you can remove it at any time.", style: .body, color: RCColor.textSecondary, lines: 0)
                let clamp = RCLabel("A very long device name that keeps going well past the second line so it has to be truncated with an ellipsis at the end", style: .bodyStrong, lines: 2)
                let digits = RCLabel("↓ 1 204 kbps · 48 fps · 12 ms", style: .monoSmall, color: RCColor.textTertiary)
                let tabular = RCLabel("Latency 118 ms · 00:41:07", style: .footnote, color: RCColor.textSecondary)
                tabular.usesMonospacedDigits = true
                return GalleryStackView([wrap, clamp, digits, tabular], spacing: 12)
            },
        ]
    }
}

// MARK: - Gallery layout helpers (file-private)

/// Repeating main-thread timer that runs only while its owner is in a window.
@MainActor
private final class GalleryTicker {
    private let interval: TimeInterval
    private let action: @MainActor (Int) -> Void
    private var timer: Timer?
    private var tick = 0

    init(interval: TimeInterval, action: @escaping @MainActor (Int) -> Void) {
        self.interval = interval
        self.action = action
    }

    func setRunning(_ running: Bool) {
        guard running != (timer != nil) else { return }
        if running {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.tick += 1
                    self.action(self.tick)
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

@MainActor
private class GalleryContainerView: UIView {
    var ticker: GalleryTicker? { didSet { ticker?.setRunning(window != nil) } }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        ticker?.setRunning(window != nil)
    }
}

/// Wrapping horizontal flow; items keep their natural size and are centered per row.
@MainActor
private final class GalleryFlowView: GalleryContainerView {
    private let items: [UIView]
    private let spacing: CGFloat

    init(_ items: [UIView], spacing: CGFloat = 10) {
        self.items = items
        self.spacing = spacing
        super.init(frame: .zero)
        items.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func frames(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var frames: [CGRect] = []
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (index, item) in items.enumerated() {
            var size = item.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                rows.append([])
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            rows[rows.count - 1].append(index)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        for row in rows where !row.isEmpty {
            let height = row.map { frames[$0].height }.max() ?? 0
            for index in row { frames[index].origin.y += (height - frames[index].height) / 2 }
        }
        return (frames, y + rowHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: frames(width: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (item, frame) in zip(items, frames(width: bounds.width).frames) {
            item.frame = rtl ? CGRect(x: bounds.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
        }
    }
}

/// Vertical stack; items span the width unless `stretches` says otherwise.
@MainActor
private final class GalleryStackView: GalleryContainerView {
    private let items: [UIView]
    private let spacing: CGFloat
    private let stretches: [Bool]

    init(_ items: [UIView], spacing: CGFloat, stretches: [Bool]? = nil) {
        self.items = items
        self.spacing = spacing
        self.stretches = stretches ?? items.map { _ in true }
        super.init(frame: .zero)
        items.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func frames(width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        var y: CGFloat = 0
        var frames: [CGRect] = []
        for (index, item) in items.enumerated() {
            let size = item.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            frames.append(CGRect(x: 0, y: y, width: stretches[index] ? width : min(size.width, width), height: size.height))
            y += size.height + spacing
        }
        return (frames, max(0, y - spacing))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: frames(width: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (item, frame) in zip(items, frames(width: bounds.width).frames) { item.frame = frame }
    }
}

@MainActor
private final class GalleryFixedWidthView: UIView {
    private let item: UIView
    private let width: CGFloat

    init(_ item: UIView, width: CGFloat) {
        self.item = item
        self.width = width
        super.init(frame: .zero)
        addSubview(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: min(width, size.width), height: item.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        item.frame = bounds
    }
}

/// A row with the badge anchored to the trailing edge, like a list row accessory.
@MainActor
private final class GalleryTrailingRow: GalleryContainerView {
    private let item: UIView
    private let caption = RCLabel("Device", style: .bodyStrong)

    init(_ item: UIView) {
        self.item = item
        super.init(frame: .zero)
        addSubview(caption)
        addSubview(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 44) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = item.sizeThatFits(.zero)
        item.frame = CGRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let captionHeight = caption.sizeThatFits(bounds.size).height
        caption.frame = CGRect(x: 0, y: (bounds.height - captionHeight) / 2, width: 120, height: captionHeight)
    }
}

@MainActor
private final class GallerySkeletonRow: UIView {
    private let tile = RCSkeletonView()
    private let lines: [RCSkeletonView]
    private let widths: [CGFloat]

    init(widths: [CGFloat]) {
        self.widths = widths
        lines = widths.map { _ in RCSkeletonView() }
        super.init(frame: .zero)
        tile.cornerRadius = RCRadius.md
        addSubview(tile)
        lines.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 40) }

    override func layoutSubviews() {
        super.layoutSubviews()
        tile.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let x: CGFloat = 52
        let available = bounds.width - x
        for (index, line) in lines.enumerated() {
            line.frame = CGRect(x: x, y: index == 0 ? 7 : 25, width: available * widths[index], height: index == 0 ? 12 : 9)
        }
    }
}

@MainActor
private final class GalleryCenteredLine: UIView {
    private let separator = RCSeparator()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(separator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        separator.frame = CGRect(x: 0, y: RCLayout.pixelAligned(bounds.midY), width: bounds.width, height: RCLayout.hairline)
    }
}

@MainActor
private final class GallerySurfaceSample: RCSurfaceView {
    private let label: RCLabel

    init(style: Style, text: String) {
        label = RCLabel(text, style: .subheadline, color: style == .floating ? RCColor.onStage : RCColor.textSecondary, lines: 0)
        super.init(style: style, cornerRadius: style == .floating ? RCRadius.xl : RCRadius.lg)
        contentInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentView.addSubview(label)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }
}

@MainActor
private final class GalleryTypeSpecimen: UIView {
    private let name: RCLabel
    private let sample: RCLabel

    init(style: RCTextStyle) {
        let spec = style.spec
        name = RCLabel("\(style) · \(Int(spec.size))/\(Int(spec.lineHeight))", style: .monoSmall, color: RCColor.textTertiary)
        let text: String
        switch style {
        case .display: text = "Devices"
        case .title1: text = "Pair with relay"
        case .title2: text = "No devices yet"
        case .mono, .monoSmall: text = "192.168.1.30:8080"
        case .overline: text = "Nearby"
        default: text = "Kitchen iPad is online"
        }
        sample = RCLabel(text, style: style)
        super.init(frame: .zero)
        addSubview(name)
        addSubview(sample)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: name.sizeThatFits(size).height + sample.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let nameHeight = name.sizeThatFits(bounds.size).height
        name.frame = CGRect(x: 0, y: 0, width: bounds.width, height: nameHeight)
        sample.frame = CGRect(x: 0, y: nameHeight, width: bounds.width, height: sample.sizeThatFits(bounds.size).height)
    }
}

/// RCLabel in a box of its line height next to a plain UILabel centered in a
/// box of the same height; the ink should sit on the same rows, on the guide.
@MainActor
private final class GalleryCenteringSpecimen: UIView {
    private let style: RCTextStyle
    private let styled: RCLabel
    private let plain = UILabel()
    private let boxes = [UIView(), UIView()]
    private let guides = [UIView(), UIView()]

    init(style: RCTextStyle) {
        self.style = style
        styled = RCLabel("Hxg \(style)", style: style)
        super.init(frame: .zero)
        plain.text = style.spec.uppercase ? "HXG \(style)".uppercased() : "Hxg \(style)"
        for (box, guide) in zip(boxes, guides) {
            box.backgroundColor = RCColor.accentSoft
            guide.backgroundColor = RCColor.accent.withAlphaComponent(0.5)
            addSubview(box)
            addSubview(guide)
        }
        addSubview(styled)
        addSubview(plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: RCTypography.lineHeight(style, compatibleWith: traitCollection))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        plain.font = RCTypography.font(style, compatibleWith: traitCollection)
        plain.textColor = RCColor.text
        let half = (bounds.width - 12) / 2
        let height = bounds.height
        boxes[0].frame = CGRect(x: 0, y: 0, width: half, height: height)
        boxes[1].frame = CGRect(x: half + 12, y: 0, width: half, height: height)
        for (index, guide) in guides.enumerated() {
            guide.frame = CGRect(x: boxes[index].frame.minX, y: RCLayout.pixelAligned(height / 2), width: half, height: RCLayout.hairline)
        }
        styled.frame = CGRect(x: 4, y: 0, width: half - 8, height: height)
        let plainHeight = plain.sizeThatFits(bounds.size).height
        plain.frame = CGRect(x: half + 16, y: (height - plainHeight) / 2, width: half - 8, height: plainHeight)
    }
}
#endif
