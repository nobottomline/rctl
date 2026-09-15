import UIKit

/// One menu entry (shadcn `DropdownMenuItem`).
struct RCMenuItem {
    enum Role: Sendable { case normal, destructive }

    var title: String
    var subtitle: String?
    var icon: RCIconGlyph?
    var role: Role
    var isEnabled: Bool
    /// Shows a trailing checkmark (radio/selection state).
    var isChecked: Bool
    /// Non-empty turns the item into a submenu.
    var children: [RCMenuSection]
    /// Runs after the menu has finished dismissing.
    var action: (@MainActor () -> Void)?

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: RCIconGlyph? = nil,
        role: Role = .normal,
        isEnabled: Bool = true,
        isChecked: Bool = false,
        children: [RCMenuSection] = [],
        action: (@MainActor () -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.role = role
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.children = children
        self.action = action
    }
}

/// Group of items separated from neighbors by a divider; optional overline title.
struct RCMenuSection {
    var title: String?
    var items: [RCMenuItem]

    init(title: String? = nil, items: [RCMenuItem]) {
        self.title = title
        self.items = items
    }
}

/// Anchored dropdown menu (shadcn `DropdownMenu`): opens from its anchor with
/// a scale+fade spring, supports sections, checkmarks, destructive items,
/// submenus, press-and-drag selection, and dismisses on outside tap. It is
/// presented in the window's overlay layer and never blocks the main thread.
///
/// Implementation: `RCMenuPresentation` (overlay, motion, dismissal rules),
/// `RCMenuPanelView` (frame-laid-out rows), `RCMenuLayout` (pure placement).
@MainActor
enum RCMenu {
    enum Direction: Sendable { case automatic, down, up }
    enum Alignment: Sendable { case automatic, leading, trailing, center }

    /// Presents a menu anchored to `anchor` (any view in a window). Any menu
    /// already visible is dismissed first. Item actions run after the menu
    /// has finished dismissing.
    static func present(
        _ sections: [RCMenuSection],
        from anchor: UIView,
        direction: Direction = .automatic,
        alignment: Alignment = .automatic
    ) {
        RCMenuPresentation.present(sections, anchor: anchor, style: .dropdown(direction: direction, alignment: alignment))
    }

    /// Makes `control` open a menu on tap, and also on touch-down + drag
    /// (select by releasing over an item), like native iOS menus.
    /// The provider is evaluated each time so items reflect current state.
    static func attach(
        to control: UIControl,
        direction: Direction = .automatic,
        alignment: Alignment = .automatic,
        provider: @escaping @MainActor () -> [RCMenuSection]
    ) {
        RCKeyboardFrameTracker.shared.start()
        (objc_getAssociatedObject(control, &RCMenuAttachment.key) as? RCMenuAttachment)?.detach()
        let handler = RCMenuAttachment(control: control, direction: direction, alignment: alignment, provider: provider)
        objc_setAssociatedObject(control, &RCMenuAttachment.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Dismisses any visible menu. A selection that is already dismissing
    /// still runs its action once the menu is gone.
    static func dismissAll(animated: Bool = true) {
        RCMenuPresentation.current?.dismiss(animated: animated)
    }

    /// True while a dropdown or context menu is on screen (including its exit animation).
    static var isPresented: Bool { RCMenuPresentation.current != nil }
}

/// Target/action bridge for `RCMenu.attach`. Opening rules:
/// - tap (touch up inside) opens the menu; releasing later changes nothing;
/// - holding the control opens it under the finger;
/// - dragging away from the control opens it (outside scrollable containers,
///   where a drag must stay a scroll);
/// - once opened by the in-flight touch, dragging highlights items and
///   releasing over one selects it; releasing away from both the control
///   and the panel closes the menu.
@MainActor
private final class RCMenuAttachment: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private static let holdDelay: TimeInterval = 0.28
    private static let dragThreshold: CGFloat = 10

    weak var control: UIControl?
    let direction: RCMenu.Direction
    let alignment: RCMenu.Alignment
    let provider: @MainActor () -> [RCMenuSection]

    private var touchStart: CGPoint?
    private var travelled = false
    private var holdWork: DispatchWorkItem?
    private weak var trackingPresentation: RCMenuPresentation?

    init(control: UIControl, direction: RCMenu.Direction, alignment: RCMenu.Alignment, provider: @escaping @MainActor () -> [RCMenuSection]) {
        self.control = control
        self.direction = direction
        self.alignment = alignment
        self.provider = provider
        super.init()
        control.addTarget(self, action: #selector(touchDown(_:event:)), for: .touchDown)
        control.addTarget(self, action: #selector(touchDragged(_:event:)), for: [.touchDragInside, .touchDragOutside])
        control.addTarget(self, action: #selector(touchUpInside(_:event:)), for: .touchUpInside)
        control.addTarget(self, action: #selector(touchUpOutside(_:event:)), for: .touchUpOutside)
        control.addTarget(self, action: #selector(touchCancelled), for: .touchCancel)
        control.addTarget(self, action: #selector(primaryAction), for: .primaryActionTriggered)
    }

    func detach() {
        cancelHold()
        control?.removeTarget(self, action: nil, for: .allEvents)
    }

    @objc private func touchDown(_ sender: UIControl, event: UIEvent?) {
        cancelHold()
        trackingPresentation = nil
        travelled = false
        touchStart = location(of: event, in: sender)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.holdElapsed() }
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    @objc private func touchDragged(_ sender: UIControl, event: UIEvent?) {
        guard let point = location(of: event, in: sender), let start = touchStart else { return }
        if hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold { travelled = true }
        if let presentation = trackingPresentation {
            presentation.externalTouch(.moved, atWindowPoint: point)
        } else if travelled, !RCMenuPresentation.isInsideScrollableContainer(sender) {
            openForTrackedTouch()
            trackingPresentation?.externalTouch(.moved, atWindowPoint: point)
        }
    }

    @objc private func touchUpInside(_ sender: UIControl, event: UIEvent?) {
        if trackingPresentation != nil {
            finishTrackedTouch(sender, event: event)
        } else {
            resetTouch()
            open()
        }
    }

    @objc private func touchUpOutside(_ sender: UIControl, event: UIEvent?) {
        finishTrackedTouch(sender, event: event)
    }

    @objc private func touchCancelled() {
        trackingPresentation?.externalTouch(.cancelled, atWindowPoint: .zero)
        resetTouch()
    }

    /// Keyboard / assistive activation without a touch sequence.
    @objc private func primaryAction() {
        guard touchStart == nil, !isPresentedForControl else { return }
        open()
    }

    private func finishTrackedTouch(_ sender: UIControl, event: UIEvent?) {
        defer { resetTouch() }
        guard let presentation = trackingPresentation, let point = location(of: event, in: sender) else { return }
        // Coming back to the control counts as not having left it.
        let home = sender.convert(sender.bounds, to: nil).insetBy(dx: -Self.dragThreshold, dy: -Self.dragThreshold)
        presentation.externalTouch(.ended, atWindowPoint: point, travelled: travelled && !home.contains(point))
    }

    private func holdElapsed() {
        guard let control, control.isTracking, trackingPresentation == nil, !isPresentedForControl else { return }
        openForTrackedTouch()
    }

    private func openForTrackedTouch() {
        cancelHold()
        guard let control, let presentation = open() else { return }
        trackingPresentation = presentation
        // Scroll views must not pick up the finger that now drives the menu.
        RCMenuPresentation.resetScrollGestures(around: control)
        RCHaptics.play(.light)
    }

    @discardableResult
    private func open() -> RCMenuPresentation? {
        guard let control, control.window != nil else { return nil }
        return RCMenuPresentation.present(provider(), anchor: control, style: .dropdown(direction: direction, alignment: alignment))
    }

    private var isPresentedForControl: Bool {
        guard let current = RCMenuPresentation.current else { return false }
        return current.anchor === control && current.isOpen
    }

    private func resetTouch() {
        cancelHold()
        touchStart = nil
        travelled = false
        trackingPresentation = nil
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
    }

    private func location(of event: UIEvent?, in control: UIControl) -> CGPoint? {
        let touch = event?.touches(for: control)?.first ?? event?.allTouches?.first
        return touch?.location(in: nil)
    }
}

// `RCContextMenuInteraction` (long-press menu with a lifted preview) lives in
// `RCContextMenuInteraction.swift` and shares the presentation and panel.

extension UIViewController {
    /// The top of this controller's presentation chain.
    var topmostPresented: UIViewController {
        var current = self
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }
}
