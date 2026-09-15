#if DEBUG
import UIKit

extension GalleryCatalog {
    /// Gallery specimens for the modals design-system area.
    ///
    /// `--rctl-gallery-open=<specimen>[,<specimen>…]` triggers specimens after
    /// launch (≈ 0.9 s apart) for screenshots, e.g.
    /// `--rctl-route=gallery --rctl-gallery=modals --rctl-gallery-open=sheet-detents`.
    static func modals() -> [GallerySection] {
        let specimens = GalleryModalSpecimens.all
        func item(_ title: String, _ names: [String]) -> GalleryItem {
            GalleryItem(title) { host in
                GalleryModalSpecimens.scheduleLaunchSpecimens(host: host)
                var actions: [(String, @MainActor () -> Void)] = []
                for name in names {
                    guard let specimen = specimens.first(where: { $0.id == name }) else { continue }
                    actions.append((specimen.label, { @MainActor [weak host] in
                        guard let host else { return }
                        specimen.run(host)
                    }))
                }
                return GalleryActionFlow(actions: actions)
            }
        }
        return [
            GallerySection(id: "modals", title: "Sheets", items: [
                item("Detents", ["sheet-fitting", "sheet-detents", "sheet-large"]),
                item("Behavior", ["sheet-keyboard", "sheet-locked", "sheet-drag"]),
                GalleryItem("Dark host (stage)", onStage: true) { host in
                    let child = GalleryDarkHostController()
                    host.addChild(child)
                    child.didMove(toParent: host)
                    return child.view
                },
            ]),
            GallerySection(id: "modals", title: "Dialogs", items: [
                item("Alert dialog", ["dialog-neutral", "dialog-danger", "dialog-accent"]),
                item("Actions", ["dialog-stacked", "dialog-three", "dialog-long"]),
                item("Queue and progress", ["dialog-queue", "progress", "progress-quick"]),
            ]),
            GallerySection(id: "modals", title: "Toasts", items: [
                item("Tones", ["toast-info", "toast-success", "toast-warning", "toast-error"]),
                item("Placement", ["toast-bottom", "toast-stack", "toast-sticky", "toast-dismiss-all"]),
            ]),
        ]
    }
}

@MainActor
private struct GalleryModalSpecimen {
    let id: String
    let label: String
    let run: @MainActor (UIViewController) -> Void
}

@MainActor
private enum GalleryModalSpecimens {
    private static var launchScheduled = false

    static func scheduleLaunchSpecimens(host: UIViewController) {
        guard !launchScheduled, let value = DebugLaunch.argument("rctl-gallery-open") else { return }
        launchScheduled = true
        let names = value.split(separator: ",").map(String.init)
        for (offset, name) in names.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 + 0.9 * Double(offset)) { [weak host] in
                MainActor.assumeIsolated {
                    guard let host, let specimen = all.first(where: { $0.id == name }) else { return }
                    specimen.run(host)
                }
            }
        }
    }

    static let all: [GalleryModalSpecimen] = [
        // Sheets
        GalleryModalSpecimen(id: "sheet-fitting", label: "Fitting") { host in
            RCSheet.present(GallerySheetTextController(), from: host, onDismiss: { RCToast.show("Sheet dismissed", duration: 1.6) })
        },
        GalleryModalSpecimen(id: "sheet-detents", label: "Medium + large") { host in
            RCSheet.present(GallerySheetListController(), from: host, detents: [.medium, .large])
        },
        GalleryModalSpecimen(id: "sheet-large", label: "Large, expanded") { host in
            let content = GallerySheetListController()
            RCSheet.present(content, from: host, detents: [.medium, .large])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated {
                    RCSheetSession.session(for: content)?.presentationController?.selectDetent(at: 1, animated: true)
                }
            }
        },
        GalleryModalSpecimen(id: "sheet-keyboard", label: "Text field") { host in
            RCSheet.present(GallerySheetFormController(), from: host)
        },
        GalleryModalSpecimen(id: "sheet-locked", label: "Not dismissible") { host in
            RCSheet.present(GallerySheetLockedController(), from: host, isDismissible: false)
        },
        GalleryModalSpecimen(id: "sheet-drag", label: "Scripted drag") { host in
            let content = GallerySheetTextController()
            RCSheet.present(content, from: host)
            // Holds the sheet 120 pt below rest to inspect a mid-drag frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    guard let controller = RCSheetSession.session(for: content)?.presentationController else { return }
                    controller.beginDrag()
                    controller.updateDrag(fingerY: 120)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        MainActor.assumeIsolated { controller.endDrag(velocity: 0) }
                    }
                }
            }
        },
        GalleryModalSpecimen(id: "sheet-grow", label: "Grow content") { host in
            let content = GallerySheetTextController()
            RCSheet.present(content, from: host)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { content.toggleMore() }
            }
        },
        GalleryModalSpecimen(id: "sheet-dark", label: "Dark host sheet") { host in
            host.children.compactMap { $0 as? GalleryDarkHostController }.first?.presentTools()
        },
        GalleryModalSpecimen(id: "dialog-dark", label: "Dark host dialog") { host in
            host.children.compactMap { $0 as? GalleryDarkHostController }.first?.presentLock()
        },
        // Dialogs
        GalleryModalSpecimen(id: "dialog-neutral", label: "Neutral") { host in
            RCDialog.present(
                title: "Device unavailable",
                message: "Kitchen iPad did not answer on 192.168.1.30:8080. Check that it is awake and on the same network.",
                icon: .wifiOff,
                actions: [RCDialogAction("OK")],
                from: host
            )
        },
        GalleryModalSpecimen(id: "dialog-danger", label: "Danger confirm") { host in
            RCDialog.present(
                title: "Delete this relay?",
                message: "The relay revokes this controller and closes its sessions, then the profile and its keys are removed from this phone. Other relays and saved local devices are not affected.",
                icon: .trash2,
                tone: .danger,
                actions: [
                    RCDialogAction("Cancel", style: .cancel),
                    RCDialogAction("Revoke and delete", style: .destructive) { RCToast.show("Relay deleted", tone: .success) },
                ],
                from: host
            )
        },
        GalleryModalSpecimen(id: "dialog-accent", label: "Accent") { host in
            RCDialog.present(
                title: "Switch to Control?",
                message: "Taps and keys are sent to Studio iPad until you return to View mode.",
                icon: .pointer,
                tone: .accent,
                actions: [RCDialogAction("Stay in View", style: .cancel), RCDialogAction("Control")],
                from: host
            )
        },
        GalleryModalSpecimen(id: "dialog-stacked", label: "Long titles") { host in
            RCDialog.present(
                title: "Remove saved local device?",
                message: "Only the saved address is removed. The device is not changed.",
                icon: .trash2,
                tone: .danger,
                actions: [
                    RCDialogAction("Keep saved device", style: .cancel),
                    RCDialogAction("Remove from this phone", style: .destructive),
                ],
                from: host
            )
        },
        GalleryModalSpecimen(id: "dialog-three", label: "Three actions") { host in
            RCDialog.present(
                title: "Relay did not confirm",
                message: "The relay could not be reached to revoke this controller. You can delete the profile anyway; the relay keeps its record until an administrator removes it.",
                icon: .triangleAlert,
                tone: .danger,
                actions: [
                    RCDialogAction("Keep", style: .cancel),
                    RCDialogAction("Try again", style: .secondary),
                    RCDialogAction("Delete anyway", style: .destructive),
                ],
                from: host
            )
        },
        GalleryModalSpecimen(id: "dialog-long", label: "Scrolling message") { host in
            let paragraph = "The relay revokes this controller and closes its sessions, then the profile and its keys are removed from this phone. Other relays and saved local devices are not affected. "
            RCDialog.present(
                title: "Very long explanation",
                message: String(repeating: paragraph, count: 9),
                icon: .info,
                actions: [RCDialogAction("Close", style: .cancel), RCDialogAction("Continue")],
                from: host
            )
        },
        GalleryModalSpecimen(id: "dialog-queue", label: "Queue two") { host in
            RCDialog.present(title: "Request failed", message: "The relay returned 503 Service Unavailable.", icon: .circleAlert, tone: .danger, actions: [RCDialogAction("OK")], from: host)
            RCDialog.present(title: "Local devices", message: "Could not save the address list.", icon: .circleAlert, tone: .danger, actions: [RCDialogAction("OK")], from: host)
        },
        GalleryModalSpecimen(id: "progress", label: "Progress 2 s") { host in
            let handle = RCDialog.presentProgress(title: "Connecting to relay", message: "relay.example.net", from: host)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    handle.dismiss { RCToast.show("Connected", tone: .success, duration: 2) }
                }
            }
        },
        GalleryModalSpecimen(id: "progress-quick", label: "Progress (instant)") { host in
            let handle = RCDialog.presentProgress(title: "Saving", from: host)
            // Finishes immediately; the card still stays for its 450 ms minimum.
            handle.dismiss()
        },
        // Toasts
        GalleryModalSpecimen(id: "toast-info", label: "Info") { _ in
            RCToast.show("Copied address", message: "192.168.1.30:8080")
        },
        GalleryModalSpecimen(id: "toast-success", label: "Success") { _ in
            RCToast.show("Paired with relay", message: "home-relay is ready for remote sessions.", tone: .success)
        },
        GalleryModalSpecimen(id: "toast-warning", label: "Warning") { _ in
            RCToast.show("Weak connection", message: "Video lowered to 540p to keep input responsive.", tone: .warning)
        },
        GalleryModalSpecimen(id: "toast-error", label: "Error") { _ in
            RCToast.show("Reconnect failed", message: "The device stopped answering. Try again from the device list.", tone: .error)
        },
        GalleryModalSpecimen(id: "toast-bottom", label: "Bottom") { _ in
            RCToast.show("Saved", tone: .success, position: .bottom)
        },
        GalleryModalSpecimen(id: "toast-stack", label: "Stack of four") { _ in
            let items: [(String, RCToast.Tone)] = [("Relay reachable", .info), ("Presence restored", .success), ("Clock skew detected", .warning), ("Session ended", .error)]
            for (index, item) in items.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(index)) {
                    MainActor.assumeIsolated { RCToast.show(item.0, tone: item.1, duration: 6) }
                }
            }
        },
        GalleryModalSpecimen(id: "toast-sticky", label: "Persistent") { _ in
            RCToast.show("Waiting for approval", message: "Tap or swipe up to dismiss.", icon: .history, duration: .infinity)
        },
        GalleryModalSpecimen(id: "toast-dismiss-all", label: "Dismiss all") { _ in
            RCToast.dismissAll()
        },
    ]
}

// MARK: - Button flow

/// Wrapping row of small secondary buttons.
@MainActor
private final class GalleryActionFlow: UIView {
    private let buttons: [RCButton]
    private static let spacing: CGFloat = 8

    init(actions: [(String, @MainActor () -> Void)]) {
        buttons = actions.map { title, action in
            let button = RCButton(title: title, variant: .secondary, size: .small)
            button.onTap = { action() }
            return button
        }
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func frames(for width: CGFloat) -> [CGRect] {
        var x: CGFloat = 0
        var y: CGFloat = 0
        return buttons.map { button in
            let size = button.sizeThatFits(CGSize(width: width, height: 36))
            let buttonWidth = min(width, size.width)
            if x > 0, x + buttonWidth > width {
                x = 0
                y += size.height + Self.spacing
            }
            defer { x += buttonWidth + Self.spacing }
            return CGRect(x: x, y: y, width: buttonWidth, height: size.height)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: frames(for: size.width).last?.maxY ?? 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (button, frame) in zip(buttons, frames(for: bounds.width)) { button.frame = frame }
    }
}

// MARK: - Demo content

/// Frame-laid-out column used by the demo sheets.
@MainActor
private class GallerySheetColumnController: UIViewController {
    var views: [UIView] = []
    var spacings: [CGFloat] = []
    static let insets = UIEdgeInsets(top: 32, left: 24, bottom: 16, right: 24)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        views.forEach(view.addSubview)
    }

    func height(for width: CGFloat) -> CGFloat {
        let inner = min(width, RCLayout.maxFormWidth) - Self.insets.left - Self.insets.right
        var y = Self.insets.top
        for (index, subview) in views.enumerated() where !subview.isHidden {
            y += subview.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            y += index < spacings.count ? spacings[index] : RCSpace.md
        }
        return ceil(y + Self.insets.bottom)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let column = min(width, RCLayout.maxFormWidth)
        let inner = column - Self.insets.left - Self.insets.right
        let x = (width - column) / 2 + Self.insets.left
        var y = Self.insets.top
        for (index, subview) in views.enumerated() where !subview.isHidden {
            let height = subview.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            subview.frame = CGRect(x: x, y: y, width: inner, height: height)
            y += height + (index < spacings.count ? spacings[index] : RCSpace.md)
        }
        let preferred = CGSize(width: 0, height: height(for: width))
        if width > 0, preferredContentSize != preferred { preferredContentSize = preferred }
    }
}

@MainActor
private final class GallerySheetTextController: GallerySheetColumnController {
    private let extra = RCLabel(style: .body, color: RCColor.textSecondary, lines: 0)
    private let toggle = RCButton(title: "Show more", variant: .secondary, size: .medium)
    private let insetsLabel = RCLabel(style: .monoSmall, color: RCColor.textTertiary)

    override func viewDidLoad() {
        let title = RCLabel("Nearby device", style: .title2)
        let body = RCLabel("Kitchen iPad answers on 192.168.1.30:8080. Open it now, or save the address to reach it later from the device list.", style: .body, color: RCColor.textSecondary, lines: 0)
        extra.text = "Saved devices keep their name and address on this phone only. Nothing is changed on the device itself, and removing the entry later forgets only the address."
        extra.isHidden = true
        toggle.onTap = { [weak self] in self?.toggleMore() }
        let done = RCButton(title: "Open device", variant: .primary, size: .large)
        done.onTap = { [weak self] in
            guard let self else { return }
            RCSheet.dismiss(self)
        }
        views = [title, body, extra, insetsLabel, toggle, done]
        spacings = [RCSpace.sm, RCSpace.md, RCSpace.md, RCSpace.xl, RCSpace.sm]
        super.viewDidLoad()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        insetsLabel.text = "safe area bottom \(Int(view.safeAreaInsets.bottom)) pt"
    }

    func toggleMore() {
        extra.isHidden.toggle()
        toggle.title = extra.isHidden ? "Show more" : "Show less"
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
}

@MainActor
private final class GallerySheetFormController: GallerySheetColumnController {
    private let field = RCTextField(label: "Name", placeholder: "Kitchen iPad", icon: .tag)

    override func viewDidLoad() {
        let title = RCLabel("Rename device", style: .title2)
        let body = RCLabel("Shown in the device list on this phone.", style: .subheadline, color: RCColor.textSecondary, lines: 0)
        let save = RCButton(title: "Save", variant: .primary, size: .large)
        save.onTap = { [weak self] in
            guard let self else { return }
            let name = self.field.text.isEmpty ? "Kitchen iPad" : self.field.text
            RCSheet.dismiss(self) { RCToast.show("Renamed to \(name)", tone: .success) }
        }
        field.onReturn = { true }
        views = [title, body, field, save]
        spacings = [RCSpace.xs, RCSpace.lg, RCSpace.xl]
        super.viewDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.textField.becomeFirstResponder()
    }
}

@MainActor
private final class GallerySheetLockedController: GallerySheetColumnController {
    override func viewDidLoad() {
        let tile = RCIconTile(glyph: .shieldCheck, tone: .accent, side: 44)
        let title = RCLabel("Approve on the relay", style: .title2)
        let body = RCLabel("This sheet cannot be dragged away or dismissed from the backdrop. Finish the step to continue.", style: .body, color: RCColor.textSecondary, lines: 0)
        let finish = RCButton(title: "Finish", variant: .accent, size: .large)
        finish.onTap = { [weak self] in
            guard let self else { return }
            RCSheet.dismiss(self)
        }
        views = [GalleryLeadingBox(tile), title, body, finish]
        spacings = [RCSpace.lg, RCSpace.sm, RCSpace.xl]
        super.viewDidLoad()
    }
}

/// Wraps a fixed-size view at the leading edge of a column row.
@MainActor
private final class GalleryLeadingBox: UIView {
    private let child: UIView

    init(_ child: UIView) {
        self.child = child
        super.init(frame: .zero)
        addSubview(child)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: child.sizeThatFits(size).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = child.sizeThatFits(bounds.size)
        child.frame = CGRect(origin: .zero, size: size)
    }
}

@MainActor
private final class GallerySheetListController: UIViewController, RCSheetScrollable, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let header = RCLabel("Nearby devices", style: .title2)
    private let subtitle = RCLabel("Drag the sheet up, then scroll. At the top, dragging down moves the sheet again.", style: .subheadline, color: RCColor.textSecondary, lines: 0)
    private var rows: [(RCLabel, RCLabel, RCSeparator)] = []

    var sheetScrollView: UIScrollView? { scrollView }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        scrollView.addSubview(header)
        scrollView.addSubview(subtitle)
        rows = (1...40).map { index in
            let title = RCLabel("Device \(index)", style: .bodyStrong)
            let detail = RCLabel("192.168.1.\(20 + index):8080", style: .mono, color: RCColor.textTertiary)
            let separator = RCSeparator()
            [title, detail, separator].forEach(scrollView.addSubview)
            return (title, detail, separator)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        let column = min(view.bounds.width, RCLayout.maxFormWidth)
        let x = (view.bounds.width - column) / 2 + 24
        let inner = column - 48
        var y: CGFloat = 32
        header.frame = CGRect(x: x, y: y, width: inner, height: header.sizeThatFits(CGSize(width: inner, height: 100)).height)
        y = header.frame.maxY + RCSpace.xs
        subtitle.frame = CGRect(x: x, y: y, width: inner, height: subtitle.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        y = subtitle.frame.maxY + RCSpace.lg
        for (title, detail, separator) in rows {
            title.frame = CGRect(x: x, y: y + 12, width: inner, height: 22)
            detail.frame = CGRect(x: x, y: y + 36, width: inner, height: 19)
            separator.frame = CGRect(x: x, y: y + 67, width: inner, height: RCLayout.hairline)
            y += 68
        }
        scrollView.contentSize = CGSize(width: view.bounds.width, height: y + view.safeAreaInsets.bottom + RCSpace.lg)
    }
}

/// Always-dark host embedded in the gallery; its sheets must be dark too.
@MainActor
private final class GalleryDarkHostController: UIViewController {
    override func loadView() {
        view = GalleryDarkHostView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        let button = RCButton(title: "Session tools", icon: .slidersHorizontal, variant: .secondary, size: .medium)
        button.onTap = { [weak self] in self?.presentTools() }
        let lock = RCButton(title: "Lock device", icon: .lock, variant: .destructiveSoft, size: .medium)
        lock.onTap = { [weak self] in self?.presentLock() }
        (view as? GalleryDarkHostView)?.buttons = [button, lock]
    }

    func presentTools() {
        RCSheet.present(GallerySheetListController(), from: self, detents: [.height(390), .large])
    }

    func presentLock() {
        RCDialog.present(
            title: "Lock Studio iPad?",
            message: "The remote session stays connected after the screen locks.",
            icon: .lock,
            tone: .danger,
            actions: [RCDialogAction("Cancel", style: .cancel), RCDialogAction("Lock device", style: .destructive)],
            from: self
        )
    }
}

@MainActor
private final class GalleryDarkHostView: UIView {
    var buttons: [RCButton] = [] {
        didSet { buttons.forEach(addSubview); setNeedsLayout() }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for button in buttons {
            let width = button.sizeThatFits(bounds.size).width
            button.frame = CGRect(x: x, y: 0, width: width, height: 44)
            x += width + RCSpace.sm
        }
    }
}
#endif
