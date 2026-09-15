import UIKit

/// Session state centered over the video area: a compact spinner pill while
/// connecting or waiting for frames, or an interruption card with a bounded
/// reconnect progress / Reconnect action. Static while video flows (hidden),
/// and pass-through except for the card itself.
@MainActor
final class RemoteStatusOverlayView: RCView {
    var onReconnect: (() -> Void)?

    private let pill = RCSurfaceView(style: .floating, cornerRadius: 22)
    private let pillSpinner = RCSpinner(diameter: 16, lineWidth: 2)
    private let pillLabel = RCLabel(style: .subheadlineStrong, color: RCColor.textSecondary)

    private let card = RCSurfaceView(style: .floating, cornerRadius: RCRadius.lg)
    private let cardIcon = RCIconTile(glyph: .wifiOff, tone: .danger, side: 44)
    private let cardTitle = RCLabel(style: .headline, lines: 0, alignment: .center)
    private let cardMessage = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0, alignment: .center)
    private let reconnectButton = RCButton(title: "Reconnect", icon: .refreshCw, variant: .accent, size: .medium)
    private let progressSpinner = RCSpinner(diameter: 16, lineWidth: 2)
    private let progressLabel = RCLabel(style: .footnoteStrong, color: RCColor.textSecondary)

    private var overlay: RemoteSessionPresentation.Overlay = .hidden

    private static let cardMaximumWidth: CGFloat = 320
    private static let cardInsets = UIEdgeInsets(top: 22, left: 20, bottom: 20, right: 20)
    private static let hiddenScale = CGAffineTransform(scaleX: 0.96, y: 0.96)

    override func setUp() {
        pill.isUserInteractionEnabled = false
        pill.alpha = 0
        pill.isHidden = true
        pill.isAccessibilityElement = true
        pill.accessibilityTraits = .updatesFrequently
        pillSpinner.tintColor = RCColor.accent
        pill.contentView.addSubview(pillSpinner)
        pill.contentView.addSubview(pillLabel)
        addSubview(pill)

        card.alpha = 0
        card.isHidden = true
        cardTitle.accessibilityTraits = .header
        progressSpinner.tintColor = RCColor.accent
        [cardIcon, cardTitle, cardMessage, reconnectButton, progressSpinner, progressLabel].forEach(card.contentView.addSubview)
        reconnectButton.onTap = { [weak self] in self?.onReconnect?() }
        addSubview(card)
    }

    func apply(_ next: RemoteSessionPresentation.Overlay, animated: Bool) {
        guard next != overlay else { return }
        let previous = overlay
        overlay = next
        let animate = animated && window != nil
        switch next {
        case .hidden:
            setVisible(pill, false, animated: animate)
            setVisible(card, false, animated: animate)
        case let .progress(label):
            pillLabel.text = label
            pill.accessibilityLabel = label
            pillSpinner.startAnimating()
            setVisible(card, false, animated: animate)
            setVisible(pill, true, animated: animate)
        case let .interruption(interruption):
            configureCard(interruption, crossfade: animate && isInterruption(previous))
            setVisible(pill, false, animated: animate)
            setVisible(card, true, animated: animate)
        }
        setNeedsLayout()
    }

    private func isInterruption(_ overlay: RemoteSessionPresentation.Overlay) -> Bool {
        if case .interruption = overlay { return true }
        return false
    }

    private func configureCard(_ interruption: RemoteSessionPresentation.Interruption, crossfade: Bool) {
        let update = {
            self.cardIcon.glyph = interruption.kind == .sessionEnded ? .circleStop : .wifiOff
            self.cardTitle.text = interruption.title
            self.cardMessage.text = interruption.message
            switch interruption.recovery {
            case let .reconnecting(label):
                self.reconnectButton.isHidden = true
                self.progressLabel.text = label
                self.progressLabel.isHidden = false
                self.progressSpinner.startAnimating()
            case .reconnectButton:
                self.reconnectButton.isHidden = false
                self.progressLabel.isHidden = true
                self.progressSpinner.stopAnimating()
            }
        }
        if crossfade {
            UIView.transition(with: card.contentView, duration: RCMotion.quickDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: update)
        } else {
            update()
        }
        if case .reconnecting = interruption.recovery {
            UIAccessibility.post(notification: .layoutChanged, argument: progressLabel)
        }
    }

    private func setVisible(_ view: UIView, _ visible: Bool, animated: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard view.isHidden == visible || view.alpha != target else { return }
        if visible { view.isHidden = false }
        guard animated else {
            view.alpha = target
            view.transform = .identity
            view.isHidden = !visible
            if !visible { stopSpinners(in: view) }
            return
        }
        if visible, view.alpha == 0 { view.transform = RCMotion.reduceMotion ? .identity : Self.hiddenScale }
        RCMotion.animate(RCMotion.snappy, animations: {
            view.alpha = target
            view.transform = visible || RCMotion.reduceMotion ? .identity : Self.hiddenScale
        }, completion: { [weak self, weak view] _ in
            guard let self, let view else { return }
            // A newer state may have re-shown the view while it faded out.
            let stillHidden = view === self.pill ? !self.showsPill : !self.showsCard
            if stillHidden {
                view.isHidden = true
                view.transform = .identity
                self.stopSpinners(in: view)
            }
        })
    }

    private var showsPill: Bool {
        if case .progress = overlay { return true }
        return false
    }

    private var showsCard: Bool { isInterruption(overlay) }

    private func stopSpinners(in view: UIView) {
        if view === pill { pillSpinner.stopAnimating() } else { progressSpinner.stopAnimating() }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutPill()
        layoutCard()
    }

    private func layoutPill() {
        let labelWidth = min(pillLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40)).width, max(0, bounds.width - 32 - 58))
        let height = max(44, RCTypography.lineHeight(.subheadlineStrong, compatibleWith: traitCollection) + 20)
        let width = ceil(18 + 16 + 10 + labelWidth + 20)
        let transform = pill.transform
        pill.transform = .identity
        pill.frame = CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        pill.cornerRadius = height / 2
        pill.transform = transform
        pillSpinner.frame = CGRect(x: 18, y: (height - 16) / 2, width: 16, height: 16)
        let labelHeight = RCTypography.lineHeight(.subheadlineStrong, compatibleWith: traitCollection)
        pillLabel.frame = CGRect(x: 18 + 16 + 10, y: (height - labelHeight) / 2, width: labelWidth, height: labelHeight)
    }

    private func layoutCard() {
        let insets = Self.cardInsets
        let width = min(Self.cardMaximumWidth, max(0, bounds.width - 32))
        let inner = width - insets.left - insets.right
        var y = insets.top
        cardIcon.frame = CGRect(x: (width - 44) / 2, y: y, width: 44, height: 44)
        y += 44 + 14
        let titleHeight = cardTitle.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        cardTitle.frame = CGRect(x: insets.left, y: y, width: inner, height: titleHeight)
        y += titleHeight + 6
        let messageHeight = cardMessage.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        cardMessage.frame = CGRect(x: insets.left, y: y, width: inner, height: messageHeight)
        y += messageHeight + 18
        reconnectButton.frame = CGRect(x: insets.left, y: y, width: inner, height: RCButton.Size.medium.height)
        let progressWidth = progressLabel.sizeThatFits(CGSize(width: inner, height: 40)).width
        let rowWidth = 16 + 8 + progressWidth
        let rowX = insets.left + (inner - rowWidth) / 2
        progressSpinner.frame = CGRect(x: rowX, y: y + (RCButton.Size.medium.height - 16) / 2, width: 16, height: 16)
        let progressHeight = RCTypography.lineHeight(.footnoteStrong, compatibleWith: traitCollection)
        progressLabel.frame = CGRect(x: rowX + 24, y: y + (RCButton.Size.medium.height - progressHeight) / 2, width: progressWidth, height: progressHeight)
        y += RCButton.Size.medium.height + insets.bottom
        let transform = card.transform
        card.transform = .identity
        card.frame = CGRect(x: (bounds.width - width) / 2, y: max(8, (bounds.height - y) / 2), width: width, height: y)
        card.transform = transform
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Only the interruption card takes touches; everything else reaches the viewport.
        guard let hit, !card.isHidden, hit.isDescendant(of: card) else { return nil }
        return hit
    }
}
