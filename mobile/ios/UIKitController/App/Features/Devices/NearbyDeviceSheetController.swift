import UIKit

/// Decision sheet for a discovered device that answered its capabilities
/// preflight. The copy keeps the trust boundary explicit: the device
/// responded, but discovery does not verify which device it is.
///
/// The sheet never navigates. It reports one choice; the presenter pushes
/// only after the sheet has fully dismissed.
@MainActor
final class NearbyDeviceSheetController: UIViewController, RCSheetScrollable {
    enum Choice: Equatable {
        case open
        case save
        case replace(LocalDeviceProfile)
    }

    let profile: LocalDeviceProfile
    private let savedDevices: [LocalDeviceProfile]
    private let onChoice: @MainActor (NearbyDeviceSheetController, Choice) -> Void
    private var chosen = false

    private let scrollView = UIScrollView()
    private let tile = RCIconTile(glyph: .tabletSmartphone, tone: .accent, side: 48)
    private let nameLabel = RCLabel(style: .title2, lines: 2)
    private let addressLabel = RCLabel(style: .mono, color: RCColor.textTertiary)
    private let badge = RCStatusBadge(text: "Answered just now", tone: .success)
    private let closeButton = RCIconButton(icon: .x, variant: .plain, diameter: 32, iconSize: 16, accessibilityLabel: "Close")
    private let callout = RCCallout(
        text: "Found on this network by name. Discovery does not verify which device this is; connect only on a network you trust. Sessions start in View mode.",
        icon: .shieldAlert,
        tone: .neutral
    )
    private let openButton = RCButton(title: "Open in View mode", icon: .eye, variant: .primary, size: .large)
    private let saveButton = RCButton(title: "Save device", icon: .save, variant: .secondary, size: .large)
    private let replaceButton = RCButton(title: "Use this address for a saved device…", icon: nil, variant: .ghost, size: .medium)

    private static let horizontalPadding: CGFloat = RCSpace.xxl
    private static let topPadding: CGFloat = RCSpace.xxxl
    private static let tileGap: CGFloat = 14

    init(profile: LocalDeviceProfile, savedDevices: [LocalDeviceProfile], onChoice: @escaping @MainActor (NearbyDeviceSheetController, Choice) -> Void) {
        self.profile = profile
        self.savedDevices = savedDevices
        self.onChoice = onChoice
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    var sheetScrollView: UIScrollView? { scrollView }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = RCColor.surface
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)

        nameLabel.text = profile.name
        nameLabel.accessibilityTraits = .header
        addressLabel.text = profile.address.displayAddress
        addressLabel.accessibilityLabel = "Address \(profile.address.displayAddress)"
        closeButton.onTap = { [weak self] in
            guard let self else { return }
            RCSheet.dismiss(self)
        }
        openButton.accessibilityIdentifier = "nearby-open"
        openButton.onTap = { [weak self] in self?.choose(.open) }
        saveButton.accessibilityIdentifier = "nearby-save"
        saveButton.onTap = { [weak self] in self?.choose(.save) }
        replaceButton.isHidden = savedDevices.isEmpty
        replaceButton.accessibilityHint = "Lists saved devices whose address can be replaced"
        RCMenu.attach(to: replaceButton, direction: .up) { [weak self] in
            guard let self else { return [] }
            return [RCMenuSection(title: "Saved devices", items: savedDevices.map { saved in
                RCMenuItem("\(saved.name) · \(saved.address.displayAddress)") { [weak self] in self?.choose(.replace(saved)) }
            })]
        }
        [tile, nameLabel, addressLabel, badge, closeButton, callout, openButton, saveButton, replaceButton].forEach(scrollView.addSubview)
        view.accessibilityElements = [nameLabel, addressLabel, badge, closeButton, callout, openButton, saveButton, replaceButton]
    }

    /// Measures the content before presentation so a `.fitting` detent opens
    /// at its final height.
    func prepareFittingSize(width: CGFloat) {
        loadViewIfNeeded()
        preferredContentSize = CGSize(width: width, height: layoutContent(width: width))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        let height = layoutContent(width: view.bounds.width)
        // The sheet adds the bottom safe area to a `.fitting` height; the
        // scrollable extent includes it so the last button clears the indicator.
        scrollView.contentSize = CGSize(width: view.bounds.width, height: height + view.safeAreaInsets.bottom)
        let preferred = CGSize(width: view.bounds.width, height: height)
        if abs(preferredContentSize.height - preferred.height) > 0.5 {
            preferredContentSize = preferred
            RCSheet.contentSizeDidChange(for: self, animated: false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            view.setNeedsLayout()
        }
    }

    /// Lays out the content for `width` and returns its total height.
    @discardableResult
    private func layoutContent(width: CGFloat) -> CGFloat {
        let safe = view.safeAreaInsets
        let inset = RCLayout.columnInset(width: width, safeArea: .zero, maxWidth: RCLayout.maxFormWidth)
        let left = max(Self.horizontalPadding, inset.left + RCSpace.xs) + safe.left
        let right = max(Self.horizontalPadding, inset.right + RCSpace.xs) + safe.right
        let column = max(0, width - left - right)
        var y = Self.topPadding

        // Header: tile, name / address / badge, close.
        let closeSide: CGFloat = 32
        closeButton.frame = CGRect(x: width - right - closeSide + 4, y: y - 4, width: closeSide, height: closeSide)
        tile.frame = CGRect(x: left, y: y, width: tile.side, height: tile.side)
        let textX = left + tile.side + Self.tileGap
        let textWidth = max(0, closeButton.frame.minX - RCSpace.sm - textX)
        let nameHeight = nameLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        nameLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: nameHeight)
        var textY = nameLabel.frame.maxY + RCSpace.xxs
        let addressHeight = addressLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        addressLabel.frame = CGRect(x: textX, y: textY, width: textWidth, height: addressHeight)
        textY = addressLabel.frame.maxY + RCSpace.sm
        let badgeSize = badge.sizeThatFits(.zero)
        badge.frame = CGRect(x: textX, y: textY, width: min(badgeSize.width, textWidth), height: badgeSize.height)
        y = max(tile.frame.maxY, badge.frame.maxY) + RCSpace.xl

        let calloutHeight = callout.sizeThatFits(CGSize(width: column, height: .greatestFiniteMagnitude)).height
        callout.frame = CGRect(x: left, y: y, width: column, height: calloutHeight)
        y = callout.frame.maxY + RCSpace.xl

        openButton.frame = CGRect(x: left, y: y, width: column, height: RCButton.Size.large.height)
        y = openButton.frame.maxY + RCSpace.sm + 2
        saveButton.frame = CGRect(x: left, y: y, width: column, height: RCButton.Size.large.height)
        y = saveButton.frame.maxY
        if !replaceButton.isHidden {
            y += RCSpace.xs
            replaceButton.frame = CGRect(x: left, y: y, width: column, height: RCButton.Size.medium.height)
            y = replaceButton.frame.maxY
        }
        return ceil(y + RCSpace.xxl)
    }

    private func choose(_ choice: Choice) {
        guard !chosen else { return }
        chosen = true
        onChoice(self, choice)
    }
}
