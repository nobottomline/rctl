#if DEBUG
import UIKit

extension GalleryCatalog {
    /// Gallery specimens for the menus design-system area.
    ///
    /// Screenshot hooks (DEBUG only):
    /// - `--rctl-gallery-open=<specimen>` opens a specimen shortly after launch:
    ///   `relay`, `add`, `source`, `submenu`, `edge-leading`, `edge-center`,
    ///   `edge-trailing`, `clamped`, `bottom`, `long`, `card`, `row`.
    /// - `--rctl-gallery-cycle` replays open → select / dismiss → submenu →
    ///   context lift in a loop, for recording motion without touch automation.
    static func menus() -> [GallerySection] {
        let log = GalleryMenuLog()
        let hooks = GalleryMenuHooks()
        let items: [GalleryItem] = [
            GalleryItem("Dropdown menus") { _ in
                GalleryFlowView(views: [
                    hooks.register("relay", menuButton("Relay", sections: relaySections(log: log))),
                    hooks.register("add", addDeviceButton(log: log)),
                    hooks.register("source", menuButton("Source", sections: sourceSections(log: log))),
                    hooks.register("submenu", menuButton("Saved device", sections: savedDeviceSections(log: log))),
                    hooks.register("long", menuButton("Long list", sections: longSections(log: log))),
                ])
            },
            GalleryItem("Anchored near edges (align + clamp)") { _ in
                GalleryEdgesView(
                    leading: hooks.register("edge-leading", menuButton("Leading", sections: sourceSections(log: log))),
                    center: hooks.register("edge-center", menuButton("Center", sections: relaySections(log: log), alignment: .center)),
                    trailing: hooks.register("edge-trailing", menuButton("Trailing", sections: sourceSections(log: log))),
                    clamped: hooks.register("clamped", iconMenuButton(.ellipsisVertical, label: "Centered on edge", sections: relaySections(log: log), alignment: .center))
                )
            },
            GalleryItem("Bottom dock (flips up)") { host in
                let toggle = RCButton(title: "Show bottom dock", icon: .panelBottom, variant: .secondary, size: .medium)
                let dock = GalleryDockView(log: log)
                // The toggle owns the dock while it is hidden.
                toggle.onTap = { [weak host, weak toggle] in
                    guard let host else { return }
                    dock.toggle(in: host.view)
                    toggle?.title = dock.superview == nil ? "Show bottom dock" : "Hide bottom dock"
                }
                hooks.registerAction("bottom") { [weak host, weak dock, weak toggle] in
                    guard let host, let dock else { return }
                    if dock.superview == nil { dock.toggle(in: host.view) }
                    toggle?.title = "Hide bottom dock"
                    dock.layoutIfNeeded()
                    RCMenu.present(dockMoreSections(log: log), from: dock.moreButton)
                }
                return GalleryFlowView(views: [toggle])
            },
            GalleryItem("Context menu (long press)") { _ in
                let card = GalleryDeviceCard()
                let interaction = RCContextMenuInteraction { deviceContextSections(name: "Living room iPad", log: log) }
                interaction.attach(to: card)
                card.onTap = { log.record("Tapped “Living room iPad” (no menu)") }
                hooks.registerAction("card") { [weak card] in
                    guard let card else { return }
                    GalleryMenuHooks.reveal(card)
                    interaction.present()
                }
                return card
            },
            GalleryItem("Context menu on list rows") { _ in
                let group = RCListGroupView()
                let kitchen = RCListRow(content: .init(title: "Kitchen iPad", detail: "192.168.1.30:8080", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)))
                let studio = RCListRow(content: .init(title: "Studio", detail: "192.168.1.2:8080", detailIsMonospaced: true, glyph: .monitor, tileTone: .neutral, trailing: .badgeAndChevron(text: "Offline", tone: .neutral, busy: false)))
                let plain = RCListRow(content: .init(title: "No context menu", detail: "Provider returns nil: no feedback", glyph: .squareDashed, tileTone: .neutral, trailing: .none))
                var interactions: [RCContextMenuInteraction] = []
                for (row, name) in [(kitchen, "Kitchen iPad"), (studio, "Studio")] {
                    let interaction = RCContextMenuInteraction { deviceContextSections(name: name, log: log) }
                    interaction.previewCornerRadius = RCRadius.md
                    interaction.attach(to: row)
                    interactions.append(interaction)
                    row.onTap = { log.record("Opened “\(name)”") }
                }
                RCContextMenuInteraction { nil }.attach(to: plain)
                plain.onTap = { log.record("Tapped the row without a menu") }
                let kitchenInteraction = interactions[0]
                hooks.registerAction("row") { [weak kitchen, weak kitchenInteraction] in
                    guard let kitchen else { return }
                    GalleryMenuHooks.reveal(kitchen)
                    kitchenInteraction?.present()
                }
                group.setItems([
                    .init(id: "kitchen", view: kitchen),
                    .init(id: "studio", view: studio),
                    .init(id: "plain", view: plain),
                ], animated: false)
                return group
            },
            GalleryItem("Last action", height: 36) { _ in log.label },
        ]
        hooks.scheduleLaunchHooks()
        return [GallerySection(id: "menus", title: "Menus", items: items)]
    }

    // MARK: Specimen content (mirrors the controller's real menus)

    private static func relaySections(log: GalleryMenuLog) -> [RCMenuSection] {
        [
            RCMenuSection(title: "Relays", items: [
                RCMenuItem("relay.example.net", icon: .server, isChecked: true) { log.record("Selected relay.example.net") },
                RCMenuItem("home-relay.local", icon: .server) { log.record("Selected home-relay.local") },
            ]),
            RCMenuSection(items: [
                RCMenuItem("Add relay", icon: .plus) { log.record("Add relay") },
                RCMenuItem("Refresh", subtitle: "Disabled while a request is running", icon: .refreshCw, isEnabled: false),
                RCMenuItem("Delete relay", icon: .trash2, role: .destructive) { log.record("Delete relay (would confirm)") },
            ]),
        ]
    }

    private static func sourceSections(log: GalleryMenuLog) -> [RCMenuSection] {
        [RCMenuSection(title: "Source", items: [
            RCMenuItem("Screen", icon: .monitor, isChecked: true) { log.record("Source: Screen") },
            RCMenuItem("Camera", icon: .camera) { log.record("Source: Camera") },
        ])]
    }

    private static func addDeviceSections(log: GalleryMenuLog) -> [RCMenuSection] {
        [RCMenuSection(items: [
            RCMenuItem("Scan pairing code", subtitle: "Pair with a relay using its QR code", icon: .scanQrCode) { log.record("Scan pairing code") },
            RCMenuItem("Add local device", subtitle: "Private IP address, optional port", icon: .wifi) { log.record("Add local device") },
        ])]
    }

    private static func savedDeviceSections(log: GalleryMenuLog) -> [RCMenuSection] {
        [
            RCMenuSection(items: [
                RCMenuItem("Open in View mode", icon: .eye) { log.record("Open in View mode") },
                RCMenuItem("Use address for a saved device", icon: .arrowLeftRight, children: savedDeviceChoices(log: log)),
            ]),
            RCMenuSection(items: [
                RCMenuItem("Remove", icon: .trash2, role: .destructive) { log.record("Remove (would confirm)") },
            ]),
        ]
    }

    private static func savedDeviceChoices(log: GalleryMenuLog) -> [RCMenuSection] {
        [RCMenuSection(title: "Saved devices", items: [
            RCMenuItem("Studio", subtitle: "192.168.1.2:8080") { log.record("Replaced address of Studio") },
            RCMenuItem("Kitchen iPad", subtitle: "192.168.1.30:8080", isChecked: true) { log.record("Replaced address of Kitchen iPad") },
            RCMenuItem("Garage", subtitle: "192.168.1.77:8080", isEnabled: false),
        ])]
    }

    private static func longSections(log: GalleryMenuLog) -> [RCMenuSection] {
        let names = ["Atlas", "Beacon", "Cedar", "Dune", "Ember", "Fjord", "Grove", "Harbor", "Iris", "Juniper", "Kestrel", "Lumen", "Meadow", "Nimbus", "Orchid", "Pioneer"]
        return [RCMenuSection(title: "Devices", items: names.enumerated().map { index, name in
            RCMenuItem(name, subtitle: "192.168.1.\(10 + index):8080", icon: .tablet, isChecked: index == 2) { log.record("Selected \(name)") }
        })]
    }

    fileprivate static func dockMoreSections(log: GalleryMenuLog) -> [RCMenuSection] {
        [
            RCMenuSection(title: "Input", items: [
                RCMenuItem("View mode", subtitle: "Blocks all remote input", icon: .eye, isChecked: true) { log.record("View mode") },
                RCMenuItem("Control", icon: .pointer) { log.record("Control") },
            ]),
            RCMenuSection(items: [
                RCMenuItem("Keyboard", icon: .keyboard) { log.record("Keyboard") },
                RCMenuItem("Disconnect", icon: .unplug, role: .destructive) { log.record("Disconnect") },
            ]),
        ]
    }

    fileprivate static func deviceContextSections(name: String, log: GalleryMenuLog) -> [RCMenuSection] {
        [
            // The title names the device, as dropdowns do; a context menu hides
            // it because the lifted preview already shows the device.
            RCMenuSection(title: name, items: [
                RCMenuItem("Open in View mode", icon: .eye) { log.record("Open “\(name)” in View mode") },
                RCMenuItem("Edit", icon: .pencil) { log.record("Edit “\(name)”") },
                RCMenuItem("Use address for a saved device", icon: .arrowLeftRight, children: savedDeviceChoices(log: log)),
            ]),
            RCMenuSection(items: [
                RCMenuItem("Remove", icon: .trash2, role: .destructive) { log.record("Remove “\(name)” (would confirm)") },
            ]),
        ]
    }

    // MARK: Controls

    private static func menuButton(_ title: String, sections: [RCMenuSection], alignment: RCMenu.Alignment = .automatic) -> RCButton {
        let button = RCButton(title: title, icon: .chevronDown, variant: .secondary, size: .small)
        button.iconPlacement = .trailing
        button.haptic = nil
        RCMenu.attach(to: button, alignment: alignment) { sections }
        return button
    }

    private static func iconMenuButton(_ icon: RCIconGlyph, label: String, sections: [RCMenuSection], alignment: RCMenu.Alignment) -> RCIconButton {
        let button = RCIconButton(icon: icon, variant: .plain, accessibilityLabel: label)
        RCMenu.attach(to: button, alignment: alignment) { sections }
        return button
    }

    private static func addDeviceButton(log: GalleryMenuLog) -> RCIconButton {
        let button = RCIconButton(icon: .plus, variant: .primary, diameter: 36, accessibilityLabel: "Add device")
        RCMenu.attach(to: button) { addDeviceSections(log: log) }
        return button
    }
}

// MARK: - Log

@MainActor
private final class GalleryMenuLog {
    let label = RCLabel("Choose an item: its action runs after the menu has closed.", style: .footnote, color: RCColor.textTertiary, lines: 2)

    func record(_ text: String) {
        // Actions run from the presentation's finish(), so the menu is already gone here.
        label.text = "\(text) · menu visible when action ran: \(RCMenu.isPresented ? "yes" : "no")"
    }
}

// MARK: - Launch hooks

@MainActor
private final class GalleryMenuHooks {
    private static var didScheduleLaunchHook = false
    private var actions: [String: () -> Void] = [:]

    @discardableResult
    func register<Control: UIControl>(_ name: String, _ control: Control) -> Control {
        actions[name] = { [weak control] in
            guard let control else { return }
            GalleryMenuHooks.reveal(control)
            control.sendActions(for: .touchDown)
            control.sendActions(for: .touchUpInside)
        }
        return control
    }

    func registerAction(_ name: String, _ action: @escaping () -> Void) {
        actions[name] = action
    }

    /// Scrolls the gallery so `view` is fully visible before a menu opens.
    static func reveal(_ view: UIView) {
        var ancestor = view.superview
        while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
        guard let scrollView = ancestor as? UIScrollView else { return }
        let rect = view.convert(view.bounds, to: scrollView).insetBy(dx: 0, dy: -96)
        scrollView.scrollRectToVisible(rect, animated: false)
        scrollView.layoutIfNeeded()
    }

    func scheduleLaunchHooks() {
        guard !Self.didScheduleLaunchHook else { return }
        let open = DebugLaunch.argument("rctl-gallery-open")
        let cycle = DebugLaunch.flag("rctl-gallery-cycle")
        guard open != nil || cycle else { return }
        Self.didScheduleLaunchHook = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            MainActor.assumeIsolated {
                if cycle {
                    self.runCycle(step: 0)
                } else if let open {
                    self.open(open)
                }
            }
        }
    }

    private func open(_ name: String) {
        actions[name]?()
        guard name == "submenu" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated { Self.activateSubmenuRow() }
        }
    }

    private static func activateSubmenuRow() {
        guard let presentation = RCMenuPresentation.current,
              let row = presentation.panel.currentPage?.rows.first(where: \.hasChildren) else { return }
        presentation.activate(row)
    }

    /// Scripted motion loop for screen recordings.
    private func runCycle(step: Int) {
        let steps: [(TimeInterval, () -> Void)] = [
            (1.2, { self.actions["relay"]?() }),
            (1.0, {
                if let row = RCMenuPresentation.current?.panel.currentPage?.rows.first(where: { $0.item?.title == "home-relay.local" }) {
                    RCMenuPresentation.current?.activate(row)
                }
            }),
            (1.4, { self.actions["submenu"]?() }),
            (1.2, { Self.activateSubmenuRow() }),
            (1.2, {
                if let back = RCMenuPresentation.current?.panel.currentPage?.rows.first(where: \.isBack) {
                    RCMenuPresentation.current?.activate(back)
                }
            }),
            (1.0, { RCMenu.dismissAll() }),
            (1.2, { self.actions["bottom"]?() }),
            (1.2, { RCMenu.dismissAll() }),
            (1.2, { self.actions["card"]?() }),
            (1.6, { RCMenu.dismissAll() }),
        ]
        let (delay, action) = steps[step % steps.count]
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { self.runCycle(step: step + 1) }
        }
    }
}

// MARK: - Specimen views

/// Wrapping row of controls, frame laid out.
@MainActor
private final class GalleryFlowView: UIView {
    private let views: [UIView]

    init(views: [UIView]) {
        self.views = views
        super.init(frame: .zero)
        views.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width, apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layout(width: bounds.width, apply: true)
    }

    @discardableResult
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in views {
            let size = view.sizeThatFits(CGSize(width: width, height: 44))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + RCSpace.sm
                lineHeight = 0
            }
            if apply { view.frame = CGRect(x: x, y: y, width: size.width, height: size.height) }
            x += size.width + RCSpace.sm
            lineHeight = max(lineHeight, size.height)
        }
        return y + lineHeight
    }
}

/// Buttons pinned to the leading edge, center and trailing edge of the column.
@MainActor
private final class GalleryEdgesView: UIView {
    private let leading: UIView
    private let centerView: UIView
    private let trailing: UIView
    private let clamped: UIView

    init(leading: UIView, center: UIView, trailing: UIView, clamped: UIView) {
        self.leading = leading
        self.centerView = center
        self.trailing = trailing
        self.clamped = clamped
        super.init(frame: .zero)
        [leading, centerView, trailing, clamped].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 36 + RCSpace.md + 40)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let leadingSize = leading.sizeThatFits(bounds.size)
        let centerSize = centerView.sizeThatFits(bounds.size)
        let trailingSize = trailing.sizeThatFits(bounds.size)
        leading.frame = CGRect(x: 0, y: 0, width: leadingSize.width, height: leadingSize.height)
        centerView.frame = CGRect(x: (bounds.width - centerSize.width) / 2, y: 0, width: centerSize.width, height: centerSize.height)
        trailing.frame = CGRect(x: bounds.width - trailingSize.width, y: 0, width: trailingSize.width, height: trailingSize.height)
        clamped.frame = CGRect(x: bounds.width - 40, y: 36 + RCSpace.md, width: 40, height: 40)
    }
}

/// Floating dock pinned to the bottom safe area of the gallery screen, like
/// the remote session dock: its menus have no room below and flip up.
@MainActor
private final class GalleryDockView: RCSurfaceView {
    let sourceButton = RCIconButton(icon: .monitor, variant: .plain, accessibilityLabel: "Source")
    let moreButton = RCIconButton(icon: .ellipsis, variant: .plain, accessibilityLabel: "More")
    let settingsButton = RCIconButton(icon: .settings, variant: .plain, accessibilityLabel: "Settings")

    init(log: GalleryMenuLog) {
        super.init(style: .card, cornerRadius: RCRadius.xl)
        [sourceButton, moreButton, settingsButton].forEach(contentView.addSubview)
        RCMenu.attach(to: sourceButton) {
            [RCMenuSection(title: "Source", items: [
                RCMenuItem("Screen", icon: .monitor, isChecked: true) { log.record("Dock source: Screen") },
                RCMenuItem("Camera", icon: .camera) { log.record("Dock source: Camera") },
            ])]
        }
        RCMenu.attach(to: moreButton) { GalleryCatalog.dockMoreSections(log: log) }
        RCMenu.attach(to: settingsButton) {
            [RCMenuSection(title: "Quality", items: [
                RCMenuItem("Auto", isChecked: true) { log.record("Quality: Auto") },
                RCMenuItem("Data saver", subtitle: "Lower frame rate and resolution") { log.record("Quality: Data saver") },
            ])]
        }
    }

    func toggle(in host: UIView) {
        if superview != nil {
            removeFromSuperview()
            return
        }
        let width = min(host.bounds.width - RCLayout.gutter * 2, 360)
        let height: CGFloat = 60
        frame = CGRect(
            x: (host.bounds.width - width) / 2,
            y: host.bounds.height - host.safeAreaInsets.bottom - height - RCSpace.md,
            width: width,
            height: height
        )
        autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin]
        host.addSubview(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 40
        let y = (contentView.bounds.height - side) / 2
        sourceButton.frame = CGRect(x: RCSpace.md, y: y, width: side, height: side)
        moreButton.frame = CGRect(x: (contentView.bounds.width - side) / 2, y: y, width: side, height: side)
        settingsButton.frame = CGRect(x: contentView.bounds.width - side - RCSpace.md, y: y, width: side, height: side)
    }
}

/// Sample device card: tappable, with a context menu attached by the catalog.
@MainActor
private final class GalleryDeviceCard: RCSurfaceView {
    var onTap: (() -> Void)?
    private let tile = RCIconTile(glyph: .tabletSmartphone, tone: .accent, side: 44)
    private let titleLabel = RCLabel("Living room iPad", style: .headline)
    private let detailLabel = RCLabel("Relay · last seen just now", style: .footnote, color: RCColor.textTertiary)
    private let badge = RCStatusBadge(text: "Online", tone: .success)
    private let hint = RCLabel("Long press for actions", style: .caption, color: RCColor.textTertiary)

    init() {
        super.init(style: .card, cornerRadius: RCRadius.lg)
        [tile, titleLabel, detailLabel, badge, hint].forEach(contentView.addSubview)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Living room iPad, Online"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    @objc private func tapped() { onTap?() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 104)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = RCSpace.lg
        tile.frame = CGRect(x: inset, y: inset, width: 44, height: 44)
        let badgeSize = badge.sizeThatFits(.zero)
        badge.frame = CGRect(x: bounds.width - inset - badgeSize.width, y: inset + (44 - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
        let textX = tile.frame.maxX + RCSpace.md
        let textWidth = max(0, badge.frame.minX - RCSpace.sm - textX)
        titleLabel.frame = CGRect(x: textX, y: inset, width: textWidth, height: 22)
        detailLabel.frame = CGRect(x: textX, y: inset + 24, width: textWidth, height: 18)
        hint.frame = CGRect(x: inset, y: bounds.height - inset - 16, width: bounds.width - inset * 2, height: 16)
    }
}
#endif
