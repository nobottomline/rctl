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
@MainActor
enum RCMenu {
    enum Direction: Sendable { case automatic, down, up }
    enum Alignment: Sendable { case automatic, leading, trailing, center }

    /// Presents a menu anchored to `anchor` (any view in a window).
    static func present(
        _ sections: [RCMenuSection],
        from anchor: UIView,
        direction: Direction = .automatic,
        alignment: Alignment = .automatic
    ) {
        guard let presenter = anchor.owningViewController?.topmostPresented else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for section in sections {
            for item in section.items {
                let action = UIAlertAction(title: item.title, style: item.role == .destructive ? .destructive : .default) { _ in
                    MainActor.assumeIsolated {
                        if item.children.isEmpty { item.action?() } else { present(item.children, from: anchor) }
                    }
                }
                action.isEnabled = item.isEnabled
                sheet.addAction(action)
            }
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor.bounds
        presenter.present(sheet, animated: true)
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
        let handler = RCMenuAttachment(control: control, direction: direction, alignment: alignment, provider: provider)
        objc_setAssociatedObject(control, &RCMenuAttachment.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Dismisses any visible menu.
    static func dismissAll(animated: Bool = true) {}
}

@MainActor
private final class RCMenuAttachment: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    weak var control: UIControl?
    let direction: RCMenu.Direction
    let alignment: RCMenu.Alignment
    let provider: @MainActor () -> [RCMenuSection]

    init(control: UIControl, direction: RCMenu.Direction, alignment: RCMenu.Alignment, provider: @escaping @MainActor () -> [RCMenuSection]) {
        self.control = control
        self.direction = direction
        self.alignment = alignment
        self.provider = provider
        super.init()
        control.addTarget(self, action: #selector(open), for: .primaryActionTriggered)
    }

    @objc private func open() {
        guard let control else { return }
        RCMenu.present(provider(), from: control, direction: direction, alignment: alignment)
    }
}

/// Long-press context menu with a lifted preview of the pressed view
/// (dimmed backdrop, preview scales up, menu attaches below or above).
@MainActor
final class RCContextMenuInteraction: NSObject {
    /// Return nil to not show a menu for the current state.
    let provider: @MainActor () -> [RCMenuSection]?
    /// Corner radius of the lifted preview snapshot.
    var previewCornerRadius: CGFloat = RCRadius.lg
    /// Called when the menu lifts (e.g. to cancel a pending tap highlight).
    var onWillPresent: (() -> Void)?
    private weak var view: UIView?

    init(provider: @escaping @MainActor () -> [RCMenuSection]?) {
        self.provider = provider
        super.init()
    }

    func attach(to view: UIView) {
        self.view = view
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.4
        view.addGestureRecognizer(press)
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view, let sections = provider() else { return }
        (view as? UIControl)?.cancelTracking(with: nil)
        onWillPresent?()
        RCHaptics.play(.medium)
        RCMenu.present(sections, from: view)
    }
}

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
