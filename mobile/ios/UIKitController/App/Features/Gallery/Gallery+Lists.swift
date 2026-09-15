#if DEBUG
import RctlRealtime
import UIKit

/// Lists, text inputs and segmented controls.
///
/// Debug hooks for screenshots (combine with `--rctl-gallery=lists`):
/// - `--rctl-gallery-scroll=<points>` scrolls the gallery after launch.
/// - `--rctl-gallery-lists-autoplay` cycles the animated group, the loading
///   group and row updates every 1.6 s.
/// - `--rctl-gallery-lists-focus` focuses the "Focused" text field.
/// - `--rctl-gallery-lists-press` holds the highlight on a local device row.
extension GalleryCatalog {
    /// Gallery specimens for the lists design-system area.
    static func lists() -> [GallerySection] {
        [
            GallerySection(id: "lists", title: "Lists and inputs", items: [
                GalleryItem("Local devices") { host in
                    ListsGalleryHooks.install(on: host)
                    let group = RCListGroupView()
                    let rows = ListsFixtures.localRows.map { RCListRow(content: $0) }
                    rows.forEach { $0.accessibilityHintText = "Opens remote control" }
                    group.setItems(rows.enumerated().map { RCListGroupView.Item(id: "local-\($0.offset)", view: $0.element) }, animated: false)
                    if DebugLaunch.flag("rctl-gallery-lists-press") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            MainActor.assumeIsolated { rows[1].isHighlighted = true }
                        }
                    }
                    return group
                },
                GalleryItem("Relay devices") { _ in
                    let group = RCListGroupView()
                    let office = RCListRow(content: .init(title: "Office iPad", detail: "iPad Pro · iOS 17.4", glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)))
                    let workshop = RCListRow(content: .init(title: "Workshop iPad", detail: "Last seen 2 h ago", glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Offline", tone: .neutral, busy: false), appearsEnabled: false))
                    workshop.accessibilityHintText = "Shows why this device is unavailable"
                    let legacy = RCListRow(content: .init(title: "Hallway iPad", detail: "rctl 0.2 · needs update", glyph: .tabletSmartphone, trailing: .badge(text: "Needs update", tone: .attention, busy: false), appearsEnabled: false))
                    let more = RCIconButton(icon: .ellipsis, variant: .ghost, diameter: 32, iconSize: 18, accessibilityLabel: "More for Hallway iPad")
                    legacy.trailingView = more
                    let pair = RCListRow(content: .init(title: "Pair with relay", detail: "Scan a one-time code from relay admin", glyph: .scanQrCode, tileTone: .dashed, trailing: .plus))
                    group.setItems([
                        .init(id: "office", view: office),
                        .init(id: "workshop", view: workshop),
                        .init(id: "legacy", view: legacy),
                        .init(id: "pair", view: pair),
                    ], animated: false)
                    return group
                },
                GalleryItem("Animated insert, remove, move, update") { host in
                    ListsAnimatedGroupDemo(host: host)
                },
                GalleryItem("Loading placeholder") { host in
                    ListsPlaceholderDemo(host: host)
                },
                GalleryItem("Selection and long content") { _ in
                    let group = RCListGroupView()
                    group.separatorInset = RCListRow.insets.left
                    let rows = [
                        RCListRow(content: .init(title: "Match system", trailing: .check)),
                        RCListRow(content: .init(title: "Warm", trailing: .none)),
                        RCListRow(content: .init(title: "Living room iPad Pro 12.9-inch (6th generation) on the bookshelf", detail: "192.168.100.200:8080 · saved as Living room", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Discovered", tone: .neutral, busy: false))),
                    ]
                    group.setItems(rows.enumerated().map { .init(id: "select-\($0.offset)", view: $0.element) }, animated: false)
                    return group
                },
                GalleryItem("Accessibility size preview (AX3)") { host in
                    ListsTraitPreview.make(host: host, category: .accessibilityExtraLarge) {
                        let group = RCListGroupView()
                        let rows = ListsFixtures.localRows.prefix(3).map { RCListRow(content: $0) }
                        group.setItems(rows.enumerated().map { .init(id: "ax-\($0.offset)", view: $0.element) }, animated: false)
                        return group
                    }
                },
                GalleryItem("Text field · empty") { _ in
                    RCTextField(label: "Name", placeholder: "Optional, for example Living room", icon: .tag)
                },
                GalleryItem("Text field · focused") { _ in
                    let field = RCTextField(label: "Address", placeholder: "192.168.1.20:8080", icon: .network)
                    field.isMonospaced = true
                    field.text = "192.168.1.2"
                    ListsGalleryHooks.focusTarget = field
                    return field
                },
                GalleryItem("Text field · error") { _ in
                    let field = RCTextField(label: "Address", placeholder: "192.168.1.20:8080", icon: .network)
                    field.isMonospaced = true
                    field.text = "192.168.1"
                    field.helperText = "Port 8080 is used when none is given."
                    field.errorMessage = "Enter a private IPv4 address, like 192.168.1.20:8080."
                    return field
                },
                GalleryItem("Text field · address with helper") { _ in
                    let field = RCTextField(label: "Address", placeholder: "192.168.1.20:8080", icon: .network)
                    field.isMonospaced = true
                    field.text = "10.0.0.7:8080"
                    field.helperText = "Local access has no authentication. Use it only on a trusted network."
                    return field
                },
                GalleryItem("Text field · disabled") { _ in
                    let field = RCTextField(label: "Name", placeholder: "Optional", icon: .tag)
                    field.text = "Studio"
                    field.isEnabled = false
                    return field
                },
                GalleryItem("Text field · validate and shake") { host in
                    ListsValidationDemo(host: host)
                },
                GalleryItem("Segmented · standard") { _ in
                    ListsInline(RCSegmentedControl(items: [
                        .init(title: "Screen", icon: .monitorSmartphone),
                        .init(title: "Camera", icon: .camera),
                    ]), stretches: true)
                },
                GalleryItem("Segmented · accent on Control") { _ in
                    let control = RCSegmentedControl(items: [
                        .init(title: "View", icon: .eye),
                        .init(title: "Control", icon: .pointer),
                    ], selectedIndex: 1, style: .accentOn([1]))
                    control.accessibilityHint = "View mode blocks all remote input"
                    return ListsInline(control, stretches: true)
                },
                GalleryItem("Segmented · icon only, small") { _ in
                    let control = RCSegmentedControl(items: [
                        .init(icon: .eye, accessibilityLabel: "View"),
                        .init(icon: .pointer, accessibilityLabel: "Control"),
                        .init(icon: .keyboard, accessibilityLabel: "Keyboard"),
                    ], style: .accentOn([1]))
                    control.showsTitles = false
                    control.size = .small
                    return ListsInline(control, stretches: false)
                },
                GalleryItem("Segmented · disabled segment") { _ in
                    let control = RCSegmentedControl(items: [
                        .init(title: "View", icon: .eye),
                        .init(title: "Control", icon: .pointer),
                        .init(title: "Keys", icon: .keyboard),
                    ], style: .accentOn([1]))
                    control.setEnabled(false, forSegmentAt: 1)
                    control.accessibilityHint = "View mode blocks all remote input"
                    return ListsInline(control, stretches: true)
                },
            ]),
        ]
    }
}

@MainActor
private enum ListsFixtures {
    static let localRows: [RCListRow.Content] = [
        .init(title: "Studio iPad Pro", detail: "192.168.1.20:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)),
        .init(title: "Kitchen iPad", detail: "10.0.0.7:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Offline", tone: .attention, busy: false)),
        .init(title: "Living room", detail: "192.168.1.31:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Checking", tone: .neutral, busy: true)),
        .init(title: "Guest iPad", detail: "192.168.1.44:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Discovered", tone: .neutral, busy: false)),
        .init(title: "Bedroom iPad mini", detail: "192.168.1.52:8080", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Saved", tone: .neutral, busy: false)),
        .init(title: "Old iPad", detail: "Protocol mismatch", glyph: .tablet, trailing: .badgeAndChevron(text: "Incompatible", tone: .danger, busy: false), appearsEnabled: false),
        .init(title: "Add local device", detail: "Private IP address, optional port", glyph: .wifi, tileTone: .dashed, trailing: .plus),
    ]
}

/// Re-lays out the gallery inside the caller's animation (group height sync).
@MainActor
private func relayoutGallery(_ host: UIViewController?) {
    host?.view.setNeedsLayout()
    host?.view.layoutIfNeeded()
}

/// Launch-argument hooks for screenshots.
@MainActor
private enum ListsGalleryHooks {
    static weak var focusTarget: RCTextField?
    static var autoplayActions: [() -> Void] = []
    private static var installed = false

    static func install(on host: UIViewController) {
        guard !installed else { return }
        installed = true
        if let value = DebugLaunch.argument("rctl-gallery-scroll"), let offset = Double(value) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    guard let scrollView = host.view.subviews.compactMap({ $0 as? UIScrollView }).first else { return }
                    let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                    scrollView.setContentOffset(CGPoint(x: 0, y: min(CGFloat(offset), maxY)), animated: false)
                }
            }
        }
        if DebugLaunch.flag("rctl-gallery-lists-focus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                MainActor.assumeIsolated {
                    // No software keyboard in screenshots: it would cover the specimen.
                    focusTarget?.textField.inputView = UIView(frame: .zero)
                    _ = focusTarget?.becomeFirstResponder()
                }
            }
        }
        if DebugLaunch.flag("rctl-gallery-lists-autoplay") {
            scheduleAutoplay()
        }
    }

    private static func scheduleAutoplay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            MainActor.assumeIsolated {
                autoplayActions.forEach { $0() }
                scheduleAutoplay()
            }
        }
    }
}

/// Lays a control out at its natural size (or stretched to the column).
@MainActor
private final class ListsInline: UIView {
    private let content: UIView
    private let stretches: Bool

    init(_ content: UIView, stretches: Bool) {
        self.content = content
        self.stretches = stretches
        super.init(frame: .zero)
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: content.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let natural = content.sizeThatFits(bounds.size)
        content.frame = CGRect(x: 0, y: 0, width: stretches ? bounds.width : min(bounds.width, natural.width), height: bounds.height)
    }
}

/// Buttons above a group that insert, remove, move and update rows.
@MainActor
private final class ListsAnimatedGroupDemo: UIView {
    private let group = RCListGroupView()
    private let buttons: [RCButton]
    private weak var host: UIViewController?
    private var rows: [String: RCListRow] = [:]
    private var order: [String] = ["studio", "kitchen", "living"]
    private let pool: [String: RCListRow.Content] = [
        "studio": .init(title: "Studio iPad Pro", detail: "192.168.1.20:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)),
        "kitchen": .init(title: "Kitchen iPad", detail: "10.0.0.7:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Offline", tone: .attention, busy: false)),
        "living": .init(title: "Living room", detail: "Resolving address…", glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Checking", tone: .neutral, busy: true)),
        "guest": .init(title: "Guest iPad", detail: "192.168.1.44:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Discovered", tone: .neutral, busy: false)),
        "office": .init(title: "Office iPad", detail: "192.168.1.60:8080", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Saved", tone: .neutral, busy: false)),
    ]
    private var step = 0
    private var livingResolved = false

    init(host: UIViewController) {
        self.host = host
        buttons = [
            RCButton(title: "Add", icon: .plus, variant: .secondary, size: .small),
            RCButton(title: "Remove", icon: .minus, variant: .secondary, size: .small),
            RCButton(title: "Move", icon: .arrowDown, variant: .secondary, size: .small),
            RCButton(title: "Update", icon: .refreshCw, variant: .secondary, size: .small),
        ]
        super.init(frame: .zero)
        buttons.forEach(addSubview)
        addSubview(group)
        buttons[0].onTap = { [weak self] in self?.add() }
        buttons[1].onTap = { [weak self] in self?.remove() }
        buttons[2].onTap = { [weak self] in self?.move() }
        buttons[3].onTap = { [weak self] in self?.update() }
        group.onHeightChange = { [weak self] _ in relayoutGallery(self?.host) }
        apply(animated: false)
        ListsGalleryHooks.autoplayActions.append { [weak self] in self?.autoplay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func row(_ id: String) -> RCListRow {
        if let row = rows[id] { return row }
        let row = RCListRow(content: pool[id]!)
        rows[id] = row
        return row
    }

    private func apply(animated: Bool) {
        group.setItems(order.map { RCListGroupView.Item(id: $0, view: row($0)) }, animated: animated)
    }

    private func add() {
        guard let id = ["guest", "office", "kitchen", "studio", "living"].first(where: { !order.contains($0) }) else { return }
        order.insert(id, at: min(1, order.count))
        apply(animated: true)
    }

    private func remove() {
        guard order.count > 1 else { return }
        order.remove(at: min(1, order.count - 1))
        apply(animated: true)
    }

    private func move() {
        guard order.count > 1 else { return }
        order.append(order.removeFirst())
        apply(animated: true)
    }

    private func update() {
        livingResolved.toggle()
        let content: RCListRow.Content = livingResolved
            ? .init(title: "Living room", detail: "192.168.1.31:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false))
            : pool["living"]!
        if !order.contains("living") {
            order.insert("living", at: 0)
            apply(animated: true)
        }
        row("living").configure(content, animated: true)
    }

    private func autoplay() {
        switch step % 4 {
        case 0: add()
        case 1: update()
        case 2: move()
        default: remove()
        }
        step += 1
    }

    /// Buttons in one row when they fit, otherwise a two-column grid (large text).
    private func buttonFrames(width: CGFloat) -> [CGRect] {
        let height = RCButton.Size.small.height
        let widths = buttons.map { $0.sizeThatFits(.zero).width }
        let total = widths.reduce(0, +) + RCSpace.sm * CGFloat(buttons.count - 1)
        if total <= width {
            var x: CGFloat = 0
            return widths.map { buttonWidth in
                defer { x += buttonWidth + RCSpace.sm }
                return CGRect(x: x, y: 0, width: buttonWidth, height: height)
            }
        }
        let column = floor((width - RCSpace.sm) / 2)
        return buttons.indices.map { index in
            CGRect(x: CGFloat(index % 2) * (column + RCSpace.sm), y: CGFloat(index / 2) * (height + RCSpace.sm), width: column, height: height)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let buttonsHeight = buttonFrames(width: size.width).map(\.maxY).max() ?? 0
        return CGSize(width: size.width, height: buttonsHeight + RCSpace.md + group.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = buttonFrames(width: bounds.width)
        zip(buttons, frames).forEach { $0.frame = $1 }
        let top = (frames.map(\.maxY).max() ?? 0) + RCSpace.md
        group.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }
}

/// Skeleton rows that crossfade into loaded rows.
@MainActor
private final class ListsPlaceholderDemo: UIView {
    private let group = RCListGroupView.placeholder(rows: 3)
    private let button = RCButton(title: "Load", icon: .refreshCw, variant: .secondary, size: .small)
    private weak var host: UIViewController?
    private lazy var loadedRows: [RCListGroupView.Item] = ListsFixtures.localRows.prefix(2).enumerated().map {
        RCListGroupView.Item(id: "loaded-\($0.offset)", view: RCListRow(content: $0.element))
    }

    init(host: UIViewController) {
        self.host = host
        super.init(frame: .zero)
        addSubview(button)
        addSubview(group)
        button.onTap = { [weak self] in self?.toggle() }
        group.onHeightChange = { [weak self] _ in relayoutGallery(self?.host) }
        ListsGalleryHooks.autoplayActions.append { [weak self] in self?.toggle() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func toggle() {
        if group.isShowingPlaceholder {
            group.setItems(loadedRows, animated: true)
            button.title = "Reload"
        } else {
            group.showPlaceholder(rows: 3, animated: true)
            button.title = "Load"
        }
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: RCButton.Size.small.height + RCSpace.md + group.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = CGRect(x: 0, y: 0, width: button.sizeThatFits(.zero).width, height: RCButton.Size.small.height)
        let top = RCButton.Size.small.height + RCSpace.md
        group.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }
}

/// Address field validated with the real parser; errors shake the field.
@MainActor
private final class ListsValidationDemo: UIView {
    private let field = RCTextField(label: "Address", placeholder: "192.168.1.20:8080", icon: .network)
    private let button = RCButton(title: "Check address", icon: .arrowRight, variant: .accent, size: .medium)
    private weak var host: UIViewController?

    init(host: UIViewController) {
        self.host = host
        super.init(frame: .zero)
        field.isMonospaced = true
        field.helperText = "Port 8080 is used when none is given."
        field.textField.keyboardType = .URL
        field.textField.autocapitalizationType = .none
        field.textField.autocorrectionType = .no
        field.textField.returnKeyType = .go
        field.onReturn = { [weak self] in self?.validate() ?? true }
        field.onChange = { [weak self] _ in
            guard let self, self.field.errorMessage != nil else { return }
            self.field.errorMessage = nil
            self.relayout()
        }
        button.iconPlacement = .trailing
        button.onTap = { [weak self] in _ = self?.validate() }
        addSubview(field)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func validate() -> Bool {
        do {
            let address = try LocalDeviceAddress(field.text)
            field.errorMessage = nil
            field.helperText = "Looks good: \(address.displayAddress)"
            relayout()
            return true
        } catch {
            field.errorMessage = LocalDevicesModel.message(for: error)
            field.shake()
            relayout()
            return false
        }
    }

    private func relayout() {
        RCMotion.animate(RCMotion.standard) { relayoutGallery(self.host) }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: field.sizeThatFits(size).height + RCSpace.md + RCButton.Size.medium.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fieldHeight = field.sizeThatFits(bounds.size).height
        field.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fieldHeight)
        button.frame = CGRect(x: 0, y: fieldHeight + RCSpace.md, width: bounds.width, height: RCButton.Size.medium.height)
    }
}

/// Renders a specimen under an overridden content size category.
@MainActor
private enum ListsTraitPreview {
    static func make(host: UIViewController, category: UIContentSizeCategory, content: () -> UIView) -> UIView {
        let child = UIViewController()
        let container = ListsTraitContainer(content: content())
        container.onHeightChange = { [weak host] in
            RCMotion.animate(RCMotion.standard) { relayoutGallery(host) }
        }
        child.view = container
        host.addChild(child)
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child)
        child.didMove(toParent: host)
        return container
    }
}

@MainActor
private final class ListsTraitContainer: UIView {
    private let content: UIView
    var onHeightChange: (() -> Void)?

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        addSubview(content)
        (content as? RCListGroupView)?.onHeightChange = { [weak self] _ in self?.onHeightChange?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: content.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
    }
}
#endif
