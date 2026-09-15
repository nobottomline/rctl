import RctlRealtime
import UIKit

/// Add / edit / save-discovered / replace-address form for a LAN device.
/// Connect checks the device's capabilities before anything is saved; on
/// success the stack is replaced with the local session (View mode).
@MainActor
final class LocalDeviceEditorViewController: RCViewController, AppRoutable, UIScrollViewDelegate {
    let route: AppRoute
    let content: LocalDeviceEditorContent
    private let environment: AppEnvironment
    private let editingDevice: LocalDeviceProfile?
    private let suggestedDevice: LocalDeviceProfile?

    /// The running capability check and save, if any.
    private(set) var pendingSave: Task<Void, Never>?
    /// The failure currently shown under the fields.
    private(set) var failure: LocalDeviceEditorFailure?

    private let ambient = RCAmbientBackgroundView()
    private let scrollView = UIScrollView()
    private let topBar = RCTopBar()
    private let titleLabel = RCLabel(style: .display, lines: 0)
    private let introLabel = RCLabel(style: .callout, color: RCColor.textSecondary, lines: 0)
    private let contextView: UIView?
    private let addressField = RCTextField(
        label: LocalDeviceEditorContent.addressLabel,
        placeholder: LocalDeviceEditorContent.addressPlaceholder,
        icon: .network
    )
    private let nameField = RCTextField(
        label: LocalDeviceEditorContent.nameLabel,
        placeholder: LocalDeviceEditorContent.namePlaceholder,
        icon: .tag
    )
    private let errorCallout = RCCallout(text: "", icon: .triangleAlert, tone: .danger)
    private let trustCallout = RCCallout(text: LocalDeviceEditorContent.trustNotice, icon: .lockOpen, tone: .neutral)
    private let actionButton: RCButton

    /// Height of the docked keyboard covering this view's bottom edge.
    private var keyboardOverlap: CGFloat = 0
    private var didAutoFocus = false
    private var errorAnimator: UIViewPropertyAnimator?
#if DEBUG
    private var didRunDebugHook = false
#endif

    private static let columnWidth: CGFloat = 560
    private static let addressHint = "A private IPv4 address or a bracketed IPv6 ULA address. Port 8080 is used when none is given."

    init(environment: AppEnvironment, editing: LocalDeviceProfile?, suggested: LocalDeviceProfile?) {
        self.environment = environment
        self.editingDevice = editing
        self.suggestedDevice = suggested
        if let suggested {
            route = .discoveredDevice(suggested, replacing: editing)
        } else {
            route = .localDevice(editing: editing)
        }
        let content = LocalDeviceEditorContent(editing: editing, suggested: suggested)
        self.content = content
        actionButton = RCButton(title: content.actionTitle, icon: .arrowRight, variant: .accent, size: .large)
        if let change = content.addressChange {
            contextView = LocalDeviceAddressChangeView(change: change)
        } else if let notice = content.discoveryNotice {
            contextView = RCCallout(text: notice, icon: .radar, tone: .neutral)
        } else {
            contextView = nil
        }
        super.init(chrome: .adaptive)
    }

    // MARK: Lifecycle

    override var allowsInteractivePop: Bool { pendingSave == nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        ambient.intensity = 0.7
        view.addSubview(ambient)

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        view.addSubview(scrollView)

        titleLabel.text = content.title
        titleLabel.accessibilityTraits = .header
        introLabel.text = content.intro
        configureFields()
        errorCallout.alpha = 0
        errorCallout.isHidden = true
        actionButton.iconPlacement = .trailing
        actionButton.onTap = { [weak self] in self?.submit() }

        // The error callout sits below the trust callout in z-order so the
        // content moving up covers it while it fades out.
        [titleLabel, introLabel].forEach(scrollView.addSubview)
        if let contextView { scrollView.addSubview(contextView) }
        [addressField, nameField, errorCallout, trustCallout, actionButton].forEach(scrollView.addSubview)

        topBar.title = content.title
        topBar.showsBackButton = true
        topBar.onBack = { [weak self] in self?.goBack() }
        view.addSubview(topBar)

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil
        )
        renderActionState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        ambient.isPaused = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
#if DEBUG
        if runDebugHookIfNeeded() { return }
#endif
        // Focus only after the push has settled: raising the keyboard during
        // the transition makes the keyboard avoidance shift content mid-push.
        guard !didAutoFocus else { return }
        didAutoFocus = true
        guard addressField.text.isEmpty, pendingSave == nil else { return }
        addressField.textField.becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            pendingSave?.cancel()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ambient.isPaused = true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            view.setNeedsLayout()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard pendingSave == nil else { return false }
        goBack()
        return true
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
    }

    private func layoutContent() {
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        ambient.frame = bounds
        scrollView.frame = bounds
        let barHeight = topBar.preferredHeight(safeAreaTop: safe.top)
        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        let inset = RCLayout.columnInset(width: bounds.width, safeArea: safe, maxWidth: Self.columnWidth)
        let x = inset.left
        let width = max(0, bounds.width - inset.left - inset.right)
        var y = barHeight + RCSpace.xs

        func place(_ subview: UIView, height: CGFloat? = nil) {
            let measured = height ?? ceil(subview.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            subview.frame = CGRect(x: x, y: y, width: width, height: measured)
            y += measured
        }

        place(titleLabel)
        y += RCSpace.sm
        place(introLabel)
        y += RCSpace.xxl
        if let contextView {
            place(contextView)
            y += RCSpace.xl
        }
        place(addressField)
        y += RCSpace.md
        place(nameField)

        let errorHeight = ceil(errorCallout.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if failure != nil {
            y += RCSpace.lg
            place(errorCallout, height: errorHeight)
        } else {
            // Collapsed in place; it fades out while the content below moves up.
            errorCallout.frame = CGRect(x: x, y: y + RCSpace.lg, width: width, height: errorHeight)
        }

        y += RCSpace.xl
        place(trustCallout)
        y += RCSpace.xxl
        place(actionButton, height: RCButton.Size.large.height)

        let bottomPadding = max(safe.bottom, RCSpace.lg) + RCSpace.xxl
        scrollView.contentSize = CGSize(width: bounds.width, height: y + bottomPadding)
        applyScrollInsets()
        updateTopBarProgress()
    }

    /// Keyboard-aware insets. Content already pads for the home indicator,
    /// so the keyboard only adds what it covers beyond the safe area.
    private func applyScrollInsets() {
        let safe = view.safeAreaInsets
        var bottom = max(0, keyboardOverlap - safe.bottom)
        if keyboardOverlap > 0 {
            // While typing, allow scrolling far enough to tuck the large title
            // fully under the bar instead of resting with it half clipped.
            let tucked = titleLabel.frame.maxY - topBar.frame.height
            bottom = max(bottom, ceil(tucked + scrollView.bounds.height - scrollView.contentSize.height))
        }
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
        }
        let indicators = UIEdgeInsets(top: topBar.frame.height, left: 0, bottom: max(keyboardOverlap, safe.bottom), right: 0)
        if scrollView.verticalScrollIndicatorInsets != indicators {
            scrollView.verticalScrollIndicatorInsets = indicators
        }
    }

    private var maximumContentOffset: CGFloat {
        max(0, scrollView.contentSize.height + scrollView.contentInset.bottom - scrollView.bounds.height)
    }

    private func updateTopBarProgress() {
        let start = titleLabel.frame.minY - topBar.frame.height
        let distance = max(1, titleLabel.frame.height * 0.75)
        let progress = min(max((scrollView.contentOffset.y - start) / distance, 0), 1)
        topBar.setScrollProgress(progress)
        // Hand the title over to the bar instead of letting it show through.
        let titleAlpha = 1 - progress
        if abs(titleLabel.alpha - titleAlpha) > 0.001 {
            titleLabel.alpha = titleAlpha
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTopBarProgress()
    }

    // MARK: Fields

    private func configureFields() {
        // The danger callout carries the failure text; fields only show the error ring.
        addressField.displaysErrorMessage = false
        nameField.displaysErrorMessage = false
        let address = addressField.textField
        address.text = content.initialAddress
        addressField.isMonospaced = true
        address.keyboardType = .URL
        address.autocorrectionType = .no
        address.autocapitalizationType = .none
        address.spellCheckingType = .no
        address.smartDashesType = .no
        address.smartQuotesType = .no
        address.smartInsertDeleteType = .no
        address.returnKeyType = .next
        address.accessibilityLabel = LocalDeviceEditorContent.addressLabel
        address.accessibilityHint = Self.addressHint
        address.accessibilityIdentifier = "local-address"
        addressField.accessibilityElements = [address]
        addressField.onChange = { [weak self] _ in self?.fieldDidChange(.address) }
        addressField.onReturn = { [weak self] in
            self?.nameField.textField.becomeFirstResponder()
            return false
        }

        let name = nameField.textField
        name.text = content.initialName
        name.keyboardType = .default
        name.autocorrectionType = .no
        name.autocapitalizationType = .sentences
        name.spellCheckingType = .no
        name.returnKeyType = .go
        name.accessibilityLabel = LocalDeviceEditorContent.nameLabel
        name.accessibilityIdentifier = "local-name"
        nameField.accessibilityElements = [name]
        nameField.onChange = { [weak self] _ in self?.fieldDidChange(.name) }
        nameField.onReturn = { [weak self] in
            guard let self else { return true }
            if addressField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addressField.textField.becomeFirstResponder()
                return false
            }
            submit()
            return true
        }

        for field in [address, name] {
            field.addTarget(self, action: #selector(fieldDidBeginEditing), for: .editingDidBegin)
        }
        actionButton.accessibilityIdentifier = "local-connect"
    }

    private func fieldDidChange(_ field: LocalDeviceEditorFailure.Field) {
        // The input changed, so its error mark no longer describes it.
        if failure?.field == field {
            markField(nil)
        }
        if field == .address {
            renderActionState()
        }
    }

    private func markField(_ field: LocalDeviceEditorFailure.Field?) {
        let message = failure?.message
        addressField.errorMessage = field == .address ? message : nil
        nameField.errorMessage = field == .name ? message : nil
        addressField.textField.accessibilityHint = field == .address ? message : Self.addressHint
        nameField.textField.accessibilityHint = field == .name ? message : nil
    }

    @objc private func fieldDidBeginEditing() {
        guard keyboardOverlap > 0 else { return }
        revealFocusedContent(animated: true)
    }

    // MARK: Submit

    /// Validates the device and saves it; success replaces the stack with the local session.
    func submit() {
        guard LocalDeviceEditorContent.canSubmit(address: addressField.text, isPending: pendingSave != nil) else { return }
        let address = addressField.text
        let name = nameField.text
        let editingID = editingDevice?.id
        let model = environment.localDevices
        startSave { try await model.save(address: address, name: name, editing: editingID) }
    }

    private func startSave(_ operation: @escaping @MainActor () async throws -> LocalDeviceProfile) {
        let address = addressField.text
        let name = nameField.text
        let editingID = editingDevice?.id
        view.endEditing(true)
        setFailure(nil, animated: true)
        pendingSave = Task { [weak self] in
            do {
                let device = try await operation()
                try Task.checkCancellation()
                self?.saveSucceeded(device)
            } catch {
                guard let self else { return }
                if Task.isCancelled {
                    pendingSave = nil
                    renderActionState()
                    return
                }
                saveFailed(error, address: address, name: name, editingID: editingID)
            }
        }
        renderActionState()
        UIAccessibility.post(notification: .announcement, argument: LocalDeviceEditorContent.pendingActionTitle)
    }

    private func saveSucceeded(_ device: LocalDeviceProfile) {
        pendingSave = nil
        RCHaptics.play(.success)
        // The button keeps its loading look while the session replaces this screen.
        environment.router.setStack([.localControl(device)])
    }

    private func saveFailed(_ error: Error, address: String, name: String, editingID: UUID?) {
        pendingSave = nil
        renderActionState()
        let failure = LocalDeviceEditorFailure(
            error: error, address: address, name: name,
            editingID: editingID, devices: environment.localDevices.devices
        )
        setFailure(failure, animated: true)
        // `shake()` plays the warning haptic with its motion; under Reduce
        // Motion it does neither, so the haptic is played here instead.
        if RCMotion.reduceMotion {
            RCHaptics.play(.warning)
        }
        errorCallout.shake()
        UIAccessibility.post(notification: .layoutChanged, argument: errorCallout)
    }

    private func renderActionState() {
        let pending = pendingSave != nil
        // Runs on every address keystroke: only touch what changed.
        let title = pending ? LocalDeviceEditorContent.pendingActionTitle : content.actionTitle
        if actionButton.isLoading != pending { actionButton.isLoading = pending }
        if actionButton.title != title { actionButton.title = title }
        // A loading button keeps full opacity; only a missing address dims it.
        let enabled = pending || LocalDeviceEditorContent.canSubmit(address: addressField.text, isPending: false)
        if actionButton.isEnabled != enabled { actionButton.isEnabled = enabled }
        actionButton.accessibilityTraits = enabled && !pending ? .button : [.button, .notEnabled]

        for field in [addressField, nameField] where field.textField.isEnabled == pending {
            field.isUserInteractionEnabled = !pending
            field.textField.isEnabled = !pending
        }
        let backButton = topBar.backButton
        backButton.isUserInteractionEnabled = !pending
        backButton.accessibilityElementsHidden = pending
        let fieldAlpha: CGFloat = pending ? 0.55 : 1
        let backAlpha: CGFloat = pending ? 0 : 1
        guard addressField.alpha != fieldAlpha || backButton.alpha != backAlpha else { return }
        RCMotion.animate(duration: RCMotion.quickDuration) {
            self.addressField.alpha = fieldAlpha
            self.nameField.alpha = fieldAlpha
            backButton.alpha = backAlpha
        }
    }

    private func setFailure(_ newValue: LocalDeviceEditorFailure?, animated: Bool) {
        let wasVisible = failure != nil
        guard newValue != nil || wasVisible else { return }
        errorAnimator?.stopAnimation(true)
        errorAnimator = nil
        if let newValue {
            errorCallout.text = newValue.message
        }
        if newValue != nil, !wasVisible, animated {
            // The collapsed layout already puts the callout in its final slot
            // without moving anything; start it slightly above so it settles in.
            layoutContent()
            errorCallout.isHidden = false
            errorCallout.alpha = 0
            errorCallout.frame.origin.y -= RCMotion.reduceMotion ? 0 : RCSpace.sm
        }
        failure = newValue
        markField(newValue?.field)
        guard animated, view.window != nil else {
            errorCallout.isHidden = newValue == nil
            errorCallout.alpha = newValue == nil ? 0 : 1
            view.setNeedsLayout()
            return
        }
        let visible = newValue != nil
        if !visible {
            RCMotion.animate(duration: RCMotion.quickDuration) { self.errorCallout.alpha = 0 }
        }
        errorAnimator = RCMotion.animate(RCMotion.standard, animations: {
            self.layoutContent()
            if visible { self.errorCallout.alpha = 1 }
        }, completion: { [weak self] finished in
            guard let self, finished, failure == nil else { return }
            errorCallout.isHidden = true
        })
    }

    private func goBack() {
        guard pendingSave == nil else { return }
        environment.router.pop()
    }

    // MARK: Keyboard

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard isViewLoaded, let window = view.window, let info = notification.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let frame = view.convert(endFrame, from: window.screen.coordinateSpace)
        // Only a keyboard docked to the bottom edge covers content; a floating
        // or undocked iPad keyboard leaves the insets alone.
        let docked = frame.intersects(view.bounds) && frame.maxY >= view.bounds.maxY - 1
        let overlap = docked ? max(0, view.bounds.maxY - frame.minY) : 0
        guard abs(overlap - keyboardOverlap) > 0.5 else {
            if overlap > 0 { revealFocusedContent(animated: true) }
            return
        }
        keyboardOverlap = overlap
        let options = UIView.AnimationOptions(rawValue: curve << 16).union([.beginFromCurrentState, .allowUserInteraction])
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.applyScrollInsets()
            if overlap > 0 {
                self.revealFocusedContent(animated: false)
            } else if self.scrollView.contentOffset.y > self.maximumContentOffset {
                self.scrollView.contentOffset.y = self.maximumContentOffset
            }
        }
    }

    /// Scrolls so the focused field and the primary button are both visible
    /// above the keyboard; when both do not fit, the focused field wins.
    private func revealFocusedContent(animated: Bool) {
        let focused: UIView
        if addressField.textField.isFirstResponder {
            focused = addressField
        } else if nameField.textField.isFirstResponder {
            focused = nameField
        } else {
            return
        }
        let top = topBar.frame.height
        let visibleHeight = scrollView.bounds.height - top - max(keyboardOverlap, view.safeAreaInsets.bottom)
        guard visibleHeight > 0 else { return }
        let margin = RCSpace.lg
        let fieldRect = focused.frame.insetBy(dx: 0, dy: -margin)
        let combined = fieldRect.union(actionButton.frame.insetBy(dx: 0, dy: -margin))
        let target = combined.height <= visibleHeight ? combined : fieldRect
        var offset = scrollView.contentOffset.y
        if target.maxY > offset + top + visibleHeight {
            offset = target.maxY - top - visibleHeight
        }
        if target.minY < offset + top {
            offset = target.minY - top
        }
        offset = min(max(0, offset), maximumContentOffset)
        // Never rest with the large title half under the bar: tuck it away
        // completely when that still keeps the target in view.
        let tucked = titleLabel.frame.maxY - top
        if offset > 0.5, offset < tucked, tucked <= maximumContentOffset, target.minY >= tucked + top {
            offset = tucked
        }
        guard abs(offset - scrollView.contentOffset.y) > 0.5 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: animated)
    }

    // MARK: Debug

#if DEBUG
    /// `--rctl-editor-error` submits an invalid address (fails validation, no
    /// network); `--rctl-editor-pending` shows the checking state without a request.
    private func runDebugHookIfNeeded() -> Bool {
        guard !didRunDebugHook else { return false }
        didRunDebugHook = true
        if DebugLaunch.flag("rctl-editor-error") {
            didAutoFocus = true
            addressField.text = "example.com"
            renderActionState()
            submit()
            return true
        }
        if DebugLaunch.flag("rctl-editor-pending") {
            didAutoFocus = true
            if addressField.text.isEmpty { addressField.text = LocalDeviceEditorContent.addressPlaceholder }
            startSave {
                try await Task.sleep(seconds: 3600)
                throw CancellationError()
            }
            return true
        }
        return false
    }
#endif
}
