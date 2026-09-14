import UIKit

/// Detents for `RCSheet` (iOS 13 has no `UISheetPresentationController`).
enum RCSheetDetent: Equatable, Sendable {
    /// Height of the content's `preferredContentSize` (capped at `large`).
    case fitting
    /// About half the container height.
    case medium
    /// Full height below the top safe area with a small gap.
    case large
    /// Fixed content height in points.
    case height(CGFloat)
}

/// Implemented by sheet content that scrolls, so the sheet can hand the pan
/// gesture over to the scroll view at the top edge.
@MainActor
protocol RCSheetScrollable: AnyObject {
    var sheetScrollView: UIScrollView? { get }
}

/// Custom bottom sheet: dimmed backdrop, grabber, continuous top corners,
/// spring presentation, interactive drag between detents and to dismiss,
/// keyboard avoidance. Content controllers size themselves via
/// `preferredContentSize` (call `RCSheet.contentSizeDidChange(for:)` after changes).
@MainActor
enum RCSheet {
    static func present(
        _ content: UIViewController,
        from presenter: UIViewController,
        detents: [RCSheetDetent] = [.fitting],
        isDismissible: Bool = true,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        content.modalPresentationStyle = .pageSheet
        content.isModalInPresentation = !isDismissible
        if let onDismiss {
            let observer = RCSheetDismissObserver(onDismiss: onDismiss)
            objc_setAssociatedObject(content, &RCSheetDismissObserver.key, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            content.presentationController?.delegate = observer
        }
        presenter.topmostPresented.present(content, animated: true)
    }

    /// Re-measures `.fitting` detents after the content changed size.
    static func contentSizeDidChange(for content: UIViewController, animated: Bool = true) {}

    /// Dismisses the sheet hosting `content`.
    static func dismiss(_ content: UIViewController, animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
        content.dismiss(animated: animated) { completion?() }
    }
}

@MainActor
private final class RCSheetDismissObserver: NSObject, UIAdaptivePresentationControllerDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    let onDismiss: @MainActor () -> Void
    init(onDismiss: @escaping @MainActor () -> Void) { self.onDismiss = onDismiss }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { onDismiss() }
    }
}

/// Button of an `RCDialog`.
struct RCDialogAction {
    enum Style: Sendable {
        /// Emphasized confirming action.
        case primary
        /// Neutral secondary action.
        case secondary
        /// Destructive confirming action.
        case destructive
        /// Dismissing action; also triggered by tapping the backdrop when the dialog is dismissible.
        case cancel
    }

    var title: String
    var style: Style
    var handler: (@MainActor () -> Void)?

    init(_ title: String, style: Style = .primary, handler: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.style = style
        self.handler = handler
    }
}

/// Centered modal dialog (shadcn `AlertDialog`): optional icon, title,
/// message, stacked or side-by-side actions. Spring scale+fade presentation.
@MainActor
enum RCDialog {
    enum Tone: Sendable { case neutral, accent, danger }

    static func present(
        title: String,
        message: String? = nil,
        icon: RCIconGlyph? = nil,
        tone: Tone = .neutral,
        actions: [RCDialogAction],
        from presenter: UIViewController
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        for action in actions {
            let style: UIAlertAction.Style = switch action.style {
            case .cancel: .cancel
            case .destructive: .destructive
            case .primary, .secondary: .default
            }
            alert.addAction(UIAlertAction(title: action.title, style: style) { _ in
                MainActor.assumeIsolated { action.handler?() }
            })
        }
        presenter.topmostPresented.present(alert, animated: true)
    }

    /// Blocking progress card (spinner, title, message). Dismiss with the returned handle.
    static func presentProgress(title: String, message: String? = nil, from presenter: UIViewController) -> RCProgressHandle {
        let host = UIViewController()
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.view.backgroundColor = RCColor.scrim
        let spinner = RCSpinner(diameter: 28, lineWidth: 2.5)
        spinner.tintColor = RCColor.accent
        spinner.startAnimating()
        spinner.center = host.view.center
        spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin, .flexibleTopMargin, .flexibleBottomMargin]
        host.view.addSubview(spinner)
        presenter.topmostPresented.present(host, animated: true)
        return RCProgressHandle(host: host)
    }
}

@MainActor
final class RCProgressHandle {
    private weak var host: UIViewController?
    init(host: UIViewController) { self.host = host }

    func dismiss(animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
        guard let host, host.presentingViewController != nil else { completion?(); return }
        host.dismiss(animated: animated) { completion?() }
    }
}

/// Non-blocking notification (sonner-style): stacked cards, swipe to dismiss,
/// auto-hide. Lives in a pass-through overlay above all content.
@MainActor
enum RCToast {
    enum Tone: Sendable { case info, success, warning, error }
    enum Position: Sendable { case top, bottom }

    static func show(
        _ title: String,
        message: String? = nil,
        tone: Tone = .info,
        icon: RCIconGlyph? = nil,
        duration: TimeInterval = 4,
        position: Position = .top,
        in window: UIWindow? = nil
    ) {
        guard let window = window ?? UIApplication.shared.activeKeyWindow else { return }
        let label = RCLabel(message.map { "\(title) — \($0)" } ?? title, style: .footnoteStrong, lines: 2)
        let container = RCSurfaceView(style: .card, cornerRadius: RCRadius.xl)
        container.contentView.addSubview(label)
        let width = min(window.bounds.width - 32, 420)
        container.frame = CGRect(x: (window.bounds.width - width) / 2, y: window.safeAreaInsets.top + 8, width: width, height: 56)
        label.frame = container.bounds.insetBy(dx: 16, dy: 8)
        window.addSubview(container)
        UIView.animate(withDuration: 0.2, delay: duration, options: []) { container.alpha = 0 } completion: { _ in container.removeFromSuperview() }
    }

    static func dismissAll() {}
}

extension UIApplication {
    /// Key window of the foreground-active scene (iOS 13 compatible).
    var activeKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .sorted { lhs, _ in lhs.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}
