import UIKit

/// Custom navigation header used instead of `UINavigationBar`. It sits at the
/// top of a screen (the navigation bar is hidden app-wide), extends under the
/// status bar, and reveals a solid background + hairline and a small centered
/// title as content scrolls beneath it (`setScrollProgress`).
@MainActor
final class RCTopBar: RCView {
    /// Small centered title that fades in on scroll.
    var title: String? { didSet { titleLabel.text = title; setNeedsLayout() } }
    var showsBackButton = false { didSet { backButton.isHidden = !showsBackButton; setNeedsLayout() } }
    var onBack: (() -> Void)?
    /// Views placed at the leading edge after the back button (e.g. brand mark).
    var leadingViews: [UIView] = [] { didSet { replace(oldValue, with: leadingViews) } }
    /// Views placed at the trailing edge, right to left order preserved as given (left → right).
    var trailingViews: [UIView] = [] { didSet { replace(oldValue, with: trailingViews) } }
    /// Use on the media stage: transparent, white glyphs, no hairline.
    var isOverlayStyle = false { didSet { updateAppearance() } }

    let backButton = RCIconButton(icon: .chevronLeft, variant: .plain, diameter: 40, accessibilityLabel: "Back")
    private let titleLabel = RCLabel(style: .headline, alignment: .center)
    private let background = CALayer()
    private let hairline = CALayer()
    private var progress: CGFloat = 0

    override func setUp() {
        layer.addSublayer(background)
        layer.addSublayer(hairline)
        titleLabel.alpha = 0
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        backButton.isHidden = true
        backButton.onTap = { [weak self] in self?.onBack?() }
        addSubview(backButton)
        setScrollProgress(0)
    }

    private func replace(_ old: [UIView], with new: [UIView]) {
        old.forEach { $0.removeFromSuperview() }
        new.forEach(addSubview)
        setNeedsLayout()
    }

    /// 0 = content at rest (transparent bar), 1 = scrolled past the large
    /// title (solid bar, hairline, small title visible).
    func setScrollProgress(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - progress) > 0.001 || value == 0 else { return }
        progress = clamped
        withoutImplicitAnimations {
            background.opacity = isOverlayStyle ? 0 : Float(clamped)
            hairline.opacity = isOverlayStyle ? 0 : Float(clamped)
        }
        titleLabel.alpha = clamped
    }

    /// Convenience: progress from a scroll view's offset, reaching 1 after `distance` points.
    func track(_ scrollView: UIScrollView, distance: CGFloat = 44) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        setScrollProgress(offset / distance)
    }

    override func updateAppearance() {
        background.backgroundColor = RCColor.background.resolved(for: self).withAlphaComponent(0.97).cgColor
        hairline.backgroundColor = RCColor.line.cgColor(for: self)
        titleLabel.color = isOverlayStyle ? .white : RCColor.text
        backButton.variant = isOverlayStyle ? .overlay : .plain
        setScrollProgress(progress)
    }

    /// Height including the top safe-area inset of the hosting view.
    func preferredHeight(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + RCLayout.topBarHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barTop = bounds.height - RCLayout.topBarHeight
        withoutImplicitAnimations {
            background.frame = bounds
            hairline.frame = CGRect(x: 0, y: bounds.height - RCLayout.hairline, width: bounds.width, height: RCLayout.hairline)
        }
        let centerY = barTop + RCLayout.topBarHeight / 2
        let inset = max(RCLayout.gutter - 4, safeAreaInsets.left + 12)
        var leadingX = inset
        if showsBackButton {
            backButton.frame = CGRect(x: leadingX, y: centerY - 20, width: 40, height: 40)
            leadingX += 40 + RCSpace.sm
        }
        for view in leadingViews {
            let size = view.sizeThatFits(CGSize(width: bounds.width / 2, height: RCLayout.topBarHeight))
            view.frame = CGRect(x: leadingX, y: centerY - size.height / 2, width: size.width, height: size.height)
            leadingX += size.width + RCSpace.sm
        }
        var trailingX = bounds.width - max(RCLayout.gutter - 4, safeAreaInsets.right + 12)
        for view in trailingViews.reversed() {
            let size = view.sizeThatFits(CGSize(width: bounds.width / 2, height: RCLayout.topBarHeight))
            trailingX -= size.width
            view.frame = CGRect(x: trailingX, y: centerY - size.height / 2, width: size.width, height: size.height)
            trailingX -= RCSpace.sm
        }
        let side = max(leadingX, bounds.width - trailingX) + RCSpace.sm
        let titleHeight = titleLabel.sizeThatFits(bounds.size).height
        titleLabel.frame = CGRect(x: side, y: centerY - titleHeight / 2, width: max(0, bounds.width - side * 2), height: titleHeight)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Let touches on the transparent bar fall through to scroll content.
        return hit === self && progress < 0.5 ? nil : hit
    }
}

/// Product mark: a tablet outline with a touch point and ripple rings,
/// matching the app icon. Vector shape layers, no images.
@MainActor
final class RCBrandMark: RCView {
    let side: CGFloat
    private let plate = CAGradientLayer()
    private let tablet = CAShapeLayer()
    private let outerRing = CAShapeLayer()
    private let innerRing = CAShapeLayer()
    private let dot = CAShapeLayer()

    init(side: CGFloat = 32) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        [plate, tablet, outerRing, innerRing, dot].forEach(layer.addSublayer)
        tablet.fillColor = nil
        outerRing.fillColor = nil
        innerRing.fillColor = nil
    }

    override func updateAppearance() {
        plate.colors = [UIColor(rgb: 0x453726).cgColor, UIColor(rgb: 0x2D2417).cgColor]
        tablet.strokeColor = UIColor(rgb: 0xFDF6EA, alpha: 0.94).cgColor
        let signal = UIColor(rgb: 0xD4734C)
        outerRing.strokeColor = signal.withAlphaComponent(0.45).cgColor
        innerRing.strokeColor = signal.withAlphaComponent(0.9).cgColor
        dot.fillColor = signal.cgColor
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            plate.frame = bounds
            plate.startPoint = .zero
            plate.endPoint = CGPoint(x: 1, y: 1)
            plate.cornerRadius = side * 0.26
            plate.cornerCurve = .continuous
            let tabletRect = CGRect(x: side * 0.25, y: side * 0.14, width: side * 0.5, height: side * 0.72)
            tablet.lineWidth = side * 0.05
            tablet.path = UIBezierPath(roundedRect: tabletRect, cornerRadius: side * 0.09).cgPath
            let center = CGPoint(x: side / 2, y: side / 2 + side * 0.03)
            outerRing.lineWidth = side * 0.025
            outerRing.path = UIBezierPath(arcCenter: center, radius: side * 0.2, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            innerRing.lineWidth = side * 0.036
            innerRing.path = UIBezierPath(arcCenter: center, radius: side * 0.12, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            dot.path = UIBezierPath(arcCenter: center, radius: side * 0.065, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
        }
    }
}

/// Ambient backdrop for front-door screens: canvas gradient, soft color blooms,
/// paper grain and slowly drifting motes, all animated by Core Animation on
/// the render server (zero per-frame main-thread work). Pause when the screen
/// is not visible; frozen under Reduce Motion.
@MainActor
final class RCAmbientBackgroundView: RCView {
    /// Stops all motion (layer time is frozen, nothing is removed).
    var isPaused = false { didSet { updatePaused() } }
    /// 0...1 visual intensity of blooms and motes.
    var intensity: CGFloat = 1 { didSet { alpha = intensity } }

    private let gradient = CAGradientLayer()

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.addSublayer(gradient)
    }

    override func updateAppearance() {
        gradient.colors = [RCColor.backgroundDeep.cgColor(for: self), RCColor.background.cgColor(for: self)]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations { gradient.frame = bounds }
    }

    private func updatePaused() {
        if isPaused {
            let paused = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = paused
        } else if layer.speed == 0 {
            let paused = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        }
    }
}

/// Custom pull-to-refresh indicator for a scroll view. Draws an arc that
/// fills with the pull distance and spins while refreshing.
@MainActor
final class RCRefreshControl: RCView {
    private weak var scrollView: UIScrollView?
    private let onRefresh: @MainActor () async -> Void
    private let spinner = RCSpinner(diameter: 22, lineWidth: 2)
    private(set) var isRefreshing = false
    private var task: Task<Void, Never>?

    /// Pull distance that triggers a refresh on release.
    var threshold: CGFloat = 72

    init(scrollView: UIScrollView, onRefresh: @escaping @MainActor () async -> Void) {
        self.scrollView = scrollView
        self.onRefresh = onRefresh
        super.init(frame: .zero)
    }

    override func setUp() {
        isUserInteractionEnabled = false
        spinner.hidesWhenStopped = false
        spinner.alpha = 0
        addSubview(spinner)
    }

    override func updateAppearance() {
        spinner.tintColor = RCColor.accent
    }

    /// Forward from `scrollViewDidScroll`.
    func scrollViewDidScroll() {
        guard let scrollView else { return }
        let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        spinner.alpha = isRefreshing ? 1 : min(1, max(0, pull / threshold))
        frame = CGRect(x: 0, y: -max(pull, 0) + scrollView.contentOffset.y + scrollView.adjustedContentInset.top, width: scrollView.bounds.width, height: max(pull, 0))
    }

    /// Forward from `scrollViewWillEndDragging`.
    func scrollViewWillEndDragging() {
        guard let scrollView, !isRefreshing else { return }
        let pull = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        guard pull >= threshold else { return }
        beginRefreshing()
    }

    func beginRefreshing() {
        guard !isRefreshing else { return }
        isRefreshing = true
        spinner.startAnimating()
        RCHaptics.play(.light)
        task = Task { [weak self] in
            await self?.onRefresh()
            self?.endRefreshing()
        }
    }

    func endRefreshing() {
        guard isRefreshing else { return }
        isRefreshing = false
        spinner.stopAnimating()
        RCMotion.animate(duration: RCMotion.quickDuration) { self.spinner.alpha = 0 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.frame = CGRect(x: (bounds.width - 22) / 2, y: max(0, bounds.height - 22) / 2, width: 22, height: 22)
    }
}
