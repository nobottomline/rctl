#if DEBUG
import UIKit

extension GalleryCatalog {
    /// Gallery specimens for the chrome design-system area.
    ///
    /// Extra debug arguments:
    /// - `--rctl-gallery-open=ambient` pushes a full-screen ambient backdrop with a large title.
    /// - `--rctl-ambient-paused` starts that screen paused.
    /// - `--rctl-ambient-resize` makes that screen alternate the backdrop between
    ///   full width and a split-view-like width every 3 s (relayout crossfade check);
    ///   `--rctl-ambient-live-resize` drags the width frame by frame instead, like a
    ///   Stage Manager resize (one rebuild when it starts, one when it settles).
    /// - `--rctl-ambient-idle=<seconds>` shortens that screen's idle freeze.
    /// - `--rctl-ambient-overlay` holds an overlay activity token on that screen
    ///   from 2 s after launch, as a dialog would (overlay freeze check).
    /// - `--rctl-chrome-demo=pull|refreshing` poses the refresh panel for screenshots;
    ///   `--rctl-chrome-demo=pulse` pulses the brand marks every 2 s.
    /// - `--rctl-chrome-scroll=ambient|topbar|refresh` scrolls the gallery to that specimen.
    static func chrome() -> [GallerySection] {
        GalleryChromeLaunch.openRequestedSpecimen()
        return [
            GallerySection(id: "chrome", title: "Chrome", items: [
                GalleryItem("Brand mark · 24 32 44 64", height: 96) { _ in GalleryBrandMarkRow() },
                GalleryItem("Ambient · Warm", height: 240) { _ in GalleryChromeSpecimens.ambient(style: .light, title: "Warm") },
                GalleryItem("Ambient · Console", height: 240) { _ in GalleryChromeSpecimens.ambient(style: .dark, title: "Console") },
                GalleryItem("Ambient · Pause, intensity and overlay", height: 200) { host in
                    GalleryChromeLaunch.revealed(GalleryChromeSpecimens.ambientControls(), key: "ambient", in: host)
                },
                GalleryItem("Top bar · At rest", height: 150) { host in
                    GalleryChromeLaunch.revealed(GalleryChromeSpecimens.topBar(scrolled: false), key: "topbar", in: host)
                },
                GalleryItem("Top bar · Scrolled", height: 150) { _ in GalleryChromeSpecimens.topBar(scrolled: true) },
                GalleryItem("Top bar · Home", height: 52) { _ in GalleryChromeSpecimens.homeBar() },
                GalleryItem("Top bar · Crowded, long title", height: 52) { _ in GalleryChromeSpecimens.crowdedBar() },
                GalleryItem("Top bar · Right to left", height: 52) { _ in GalleryChromeSpecimens.rightToLeftBar() },
                GalleryItem("Top bar · Overlay on stage", height: 52, onStage: true) { _ in GalleryChromeSpecimens.overlayBar() },
                GalleryItem("Large title") { _ in RCLargeTitleView(title: "Devices", subtitle: "2 nearby · 1 through your relay") },
                GalleryItem("Refresh · Pull the panel", height: 440) { host in
                    GalleryChromeLaunch.revealed(GalleryRefreshPanel(), key: "refresh", in: host)
                },
            ]),
        ]
    }
}

/// Handles `--rctl-gallery-open=ambient` once per launch.
@MainActor
enum GalleryChromeLaunch {
    private static var didOpen = false

    static func openRequestedSpecimen() {
        guard !didOpen, DebugLaunch.argument("rctl-gallery-open") == "ambient" else { return }
        didOpen = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let navigation = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .compactMap { $0.rootViewController as? UINavigationController }
                    .first
                navigation?.pushViewController(GalleryAmbientViewController(), animated: false)
            }
        }
    }

    /// Scrolls the gallery so `specimen` sits near the top when
    /// `--rctl-chrome-scroll=<key>` matches (screenshots without touch input).
    static func revealed(_ specimen: UIView, key: String, in host: UIViewController) -> UIView {
        guard DebugLaunch.argument("rctl-chrome-scroll") == key else { return specimen }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak specimen, weak host] in
            MainActor.assumeIsolated {
                guard let specimen, let host,
                      let scrollView = host.view.subviews.compactMap({ $0 as? UIScrollView }).first
                else { return }
                let frame = specimen.convert(specimen.bounds, to: scrollView)
                let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                scrollView.contentOffset.y = min(max(0, frame.minY - 140), maxOffset)
            }
        }
        return specimen
    }
}

/// Full-screen ambient backdrop and a large title, nothing else: for
/// screenshots, motion recordings and main-thread sampling.
@MainActor
final class GalleryAmbientViewController: RCViewController {
    private let ambient = RCAmbientBackgroundView()
    private let largeTitle = RCLargeTitleView(title: "Devices", subtitle: "Your iPhone and iPad, within reach.")
    private var isNarrow = false
    /// 1 = full width; driven per frame by the live resize demo.
    private var widthFraction: CGFloat = 1
    private var liveResize: CADisplayLink?
    private var liveResizeStart: CFTimeInterval = 0
    private var overlayToken: RCOverlayToken?

    init() {
        super.init(chrome: .adaptive)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ambient.isPaused = DebugLaunch.flag("rctl-ambient-paused")
        if let idle = DebugLaunch.argument("rctl-ambient-idle").flatMap(Double.init) {
            ambient.idleTimeout = idle
        }
        view.addSubview(ambient)
        view.addSubview(largeTitle)
        if DebugLaunch.flag("rctl-ambient-resize") { scheduleResize() }
        if DebugLaunch.flag("rctl-ambient-live-resize") { scheduleLiveResize() }
        if DebugLaunch.flag("rctl-ambient-overlay") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.overlayToken = RCOverlayActivity.begin() }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        overlayToken?.end()
        overlayToken = nil
        liveResize?.invalidate()
        liveResize = nil
    }

    private func scheduleLiveResize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.view.window != nil else { return }
                self.liveResizeStart = CACurrentMediaTime()
                let link = CADisplayLink(target: GalleryDisplayLinkTarget { [weak self] in self?.stepLiveResize() }, selector: #selector(GalleryDisplayLinkTarget.step))
                link.add(to: .main, forMode: .common)
                self.liveResize = link
            }
        }
    }

    /// 0.9 s drag between full and 60% width, then a pause, repeated.
    private func stepLiveResize() {
        let t = min((CACurrentMediaTime() - liveResizeStart) / 0.9, 1)
        let eased = CGFloat(t * t * (3 - 2 * t))
        widthFraction = isNarrow ? 0.6 + 0.4 * eased : 1 - 0.4 * eased
        view.setNeedsLayout()
        view.layoutIfNeeded()
        guard t >= 1 else { return }
        isNarrow.toggle()
        liveResize?.invalidate()
        liveResize = nil
        scheduleLiveResize()
    }

    private func scheduleResize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isNarrow.toggle()
                self.view.setNeedsLayout()
                self.scheduleResize()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let fraction = DebugLaunch.flag("rctl-ambient-live-resize") ? widthFraction : (isNarrow ? 0.6 : 1)
        ambient.frame = CGRect(x: 0, y: 0, width: (view.bounds.width * fraction).rounded(), height: view.bounds.height)
        let safe = view.safeAreaInsets
        let inset = RCLayout.columnInset(width: view.bounds.width, safeArea: safe)
        let width = view.bounds.width - inset.left - inset.right
        let height = largeTitle.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        largeTitle.frame = CGRect(x: inset.left, y: safe.top + RCLayout.topBarHeight + RCSpace.sm, width: width, height: height)
    }
}

/// Breaks the display link's strong reference to its owner.
@MainActor
private final class GalleryDisplayLinkTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func step() {
        action()
    }
}

/// Container whose layout is a closure; clips like a card.
@MainActor
private final class GalleryChromePanel: UIView {
    var onLayout: ((GalleryChromePanel) -> Void)?
    var onWindowChange: ((UIWindow?) -> Void)?

    init(clips: Bool = true) {
        super.init(frame: .zero)
        if clips {
            layer.cornerRadius = RCRadius.lg
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = RCLayout.hairline
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = RCColor.line.cgColor(for: self)
        backgroundColor = RCColor.background
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layer.borderColor = RCColor.line.cgColor(for: self)
        backgroundColor = RCColor.background
        onWindowChange?(window)
    }
}

@MainActor
private enum GalleryChromeSpecimens {
    static func ambient(style: UIUserInterfaceStyle, title: String) -> UIView {
        let panel = GalleryChromePanel()
        panel.overrideUserInterfaceStyle = style
        let ambient = RCAmbientBackgroundView()
        let largeTitle = RCLargeTitleView(title: title, subtitle: "Blooms, texture and drifting motes on the render server.")
        panel.addSubview(ambient)
        panel.addSubview(largeTitle)
        panel.onLayout = { panel in
            ambient.frame = panel.bounds
            let width = panel.bounds.width - RCLayout.gutter * 2
            let height = largeTitle.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            largeTitle.frame = CGRect(x: RCLayout.gutter, y: RCSpace.xxl, width: width, height: height)
        }
        return panel
    }

    static func ambientControls() -> UIView {
        let panel = GalleryChromePanel()
        let ambient = RCAmbientBackgroundView()
        let pause = RCButton(title: "Pause", variant: .secondary, size: .small)
        let intensity = RCButton(title: "Intensity 100%", variant: .secondary, size: .small)
        let overlay = RCButton(title: "Overlay", variant: .secondary, size: .small)
        overlay.accessibilityHint = "Simulates a dialog over the backdrop, which freezes its motion"
        let levels: [CGFloat] = [1, 0.6, 0.3]
        var level = 0
        var overlayToken: RCOverlayToken?
        overlay.onTap = { [weak overlay] in
            if let token = overlayToken {
                token.end()
                overlayToken = nil
            } else {
                overlayToken = RCOverlayActivity.begin()
            }
            overlay?.title = overlayToken == nil ? "Overlay" : "End overlay"
            relayoutContainer(overlay)
        }
        pause.onTap = { [weak ambient, weak pause] in
            guard let ambient else { return }
            ambient.isPaused.toggle()
            pause?.title = ambient.isPaused ? "Resume" : "Pause"
            relayoutContainer(pause)
        }
        intensity.onTap = { [weak ambient, weak intensity] in
            level = (level + 1) % levels.count
            ambient?.intensity = levels[level]
            intensity?.title = "Intensity \(Int(levels[level] * 100))%"
            relayoutContainer(intensity)
        }
        // A simulated overlay never outlives the specimen on screen.
        panel.onWindowChange = { [weak overlay] window in
            guard window == nil, let token = overlayToken else { return }
            token.end()
            overlayToken = nil
            overlay?.title = "Overlay"
        }
        [ambient, pause, intensity, overlay].forEach(panel.addSubview)
        panel.onLayout = { panel in
            ambient.frame = panel.bounds
            let pauseSize = pause.sizeThatFits(.zero)
            let intensitySize = intensity.sizeThatFits(.zero)
            let overlaySize = overlay.sizeThatFits(.zero)
            let y = panel.bounds.height - RCSpace.lg - pauseSize.height
            pause.frame = CGRect(x: RCSpace.lg, y: y, width: max(pauseSize.width, 84), height: pauseSize.height)
            intensity.frame = CGRect(x: pause.frame.maxX + RCSpace.sm, y: y, width: intensitySize.width, height: intensitySize.height)
            // Wraps above the first row when the panel is narrow or text is large.
            let overlayWidth = max(overlaySize.width, 112)
            if intensity.frame.maxX + RCSpace.sm + overlayWidth <= panel.bounds.width - RCSpace.lg {
                overlay.frame = CGRect(x: intensity.frame.maxX + RCSpace.sm, y: y, width: overlayWidth, height: overlaySize.height)
            } else {
                overlay.frame = CGRect(x: RCSpace.lg, y: y - RCSpace.sm - overlaySize.height, width: overlayWidth, height: overlaySize.height)
            }
        }
        return panel
    }

    private static func relayoutContainer(_ view: UIView?) {
        view?.superview?.setNeedsLayout()
    }

    /// A screen top: bar over a large title and the first rows. `scrolled`
    /// shows the state after the large title has slid under the bar.
    static func topBar(scrolled: Bool) -> UIView {
        let panel = GalleryChromePanel()
        let bar = RCTopBar()
        bar.title = "Local device"
        bar.showsBackButton = true
        bar.trailingViews = [RCIconButton(icon: .refreshCw, accessibilityLabel: "Refresh")]
        let largeTitle = RCLargeTitleView(title: "Local device", subtitle: "Kitchen iPad · 192.168.1.30")
        let row = RCListRow(content: RCListRow.Content(title: "Address", detail: "192.168.1.30:8080", detailIsMonospaced: true, glyph: .network, tileTone: .neutral, trailing: .chevron))
        [largeTitle, row, bar].forEach(panel.addSubview)
        bar.setScrollProgress(scrolled ? 1 : 0)
        panel.onLayout = { panel in
            let width = panel.bounds.width
            bar.frame = CGRect(x: 0, y: 0, width: width, height: RCLayout.topBarHeight)
            let columnWidth = width - RCLayout.gutter * 2
            let titleHeight = largeTitle.sizeThatFits(CGSize(width: columnWidth, height: .greatestFiniteMagnitude)).height
            let shift: CGFloat = scrolled ? -(titleHeight + RCSpace.lg) : 0
            largeTitle.frame = CGRect(x: RCLayout.gutter, y: RCLayout.topBarHeight + RCSpace.xs + shift, width: columnWidth, height: titleHeight)
            let rowHeight = row.sizeThatFits(CGSize(width: columnWidth, height: .greatestFiniteMagnitude)).height
            row.frame = CGRect(x: RCLayout.gutter - 12, y: largeTitle.frame.maxY + RCSpace.lg, width: columnWidth + 12, height: rowHeight)
        }
        return panel
    }

    static func homeBar() -> UIView {
        let bar = RCTopBar()
        bar.title = "Devices"
        let wordmark = RCLabel("rctl", style: .title2)
        wordmark.isAccessibilityElement = true
        wordmark.accessibilityTraits = .header
        bar.leadingViews = [RCBrandMark(side: 32), wordmark]
        bar.trailingViews = [
            RCIconButton(icon: .refreshCw, accessibilityLabel: "Refresh devices"),
            RCIconButton(icon: .plus, variant: .primary, accessibilityLabel: "Add device"),
        ]
        return bar
    }

    static func crowdedBar() -> UIView {
        let bar = RCTopBar()
        bar.title = "Kitchen iPad Pro on the living room wall"
        bar.showsBackButton = true
        bar.trailingViews = [
            RCIconButton(icon: .keyboard, accessibilityLabel: "Keyboard"),
            RCIconButton(icon: .settings, accessibilityLabel: "Settings"),
            RCIconButton(icon: .ellipsis, accessibilityLabel: "More"),
        ]
        bar.setScrollProgress(1)
        return bar
    }

    static func rightToLeftBar() -> UIView {
        let bar = RCTopBar()
        bar.semanticContentAttribute = .forceRightToLeft
        bar.title = "Devices"
        bar.showsBackButton = true
        bar.leadingViews = [RCBrandMark(side: 28)]
        bar.trailingViews = [RCIconButton(icon: .ellipsis, accessibilityLabel: "More")]
        bar.setScrollProgress(1)
        return bar
    }

    static func overlayBar() -> UIView {
        let bar = RCTopBar()
        bar.isOverlayStyle = true
        bar.showsTitleAtRest = true
        bar.title = "Kitchen iPad"
        bar.showsBackButton = true
        bar.trailingViews = [
            RCIconButton(icon: .keyboard, variant: .overlay, accessibilityLabel: "Keyboard"),
            RCIconButton(icon: .ellipsis, variant: .overlay, accessibilityLabel: "More"),
        ]
        return bar
    }
}

/// Brand marks at the supported sizes; tapping Pulse ripples all of them.
@MainActor
private final class GalleryBrandMarkRow: UIView {
    private let marks = [24, 32, 44, 64].map { RCBrandMark(side: CGFloat($0)) }
    private let captions = [24, 32, 44, 64].map { RCLabel("\($0)", style: .monoSmall, color: RCColor.textTertiary) }
    private let pulse = RCButton(title: "Pulse", variant: .secondary, size: .small)

    init() {
        super.init(frame: .zero)
        marks.forEach(addSubview)
        captions.forEach(addSubview)
        addSubview(pulse)
        pulse.onTap = { [weak self] in self?.marks.forEach { $0.pulse() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, DebugLaunch.argument("rctl-chrome-demo") == "pulse" { schedulePulse() }
    }

    private func schedulePulse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else { return }
                self.marks.forEach { $0.pulse() }
                self.schedulePulse()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 4
        let baseline: CGFloat = 70
        for (mark, caption) in zip(marks, captions) {
            mark.frame = CGRect(x: x, y: baseline - mark.side, width: mark.side, height: mark.side)
            let captionSize = caption.sizeThatFits(.zero)
            caption.frame = CGRect(x: mark.frame.midX - captionSize.width / 2, y: baseline + RCSpace.sm, width: captionSize.width, height: captionSize.height)
            x += mark.side + RCSpace.xxl
        }
        let size = pulse.sizeThatFits(.zero)
        pulse.frame = CGRect(x: bounds.width - size.width - 4, y: baseline - size.height, width: size.width, height: size.height)
    }
}

/// A miniature screen: ambient backdrop, top bar driven by the large title's
/// collapse, grouped rows and the refresh control. The trailing button starts
/// a refresh programmatically.
@MainActor
private final class GalleryRefreshPanel: UIView, UIScrollViewDelegate {
    private let ambient = RCAmbientBackgroundView()
    private let scrollView = UIScrollView()
    private let topBar = RCTopBar()
    private let largeTitle = RCLargeTitleView(title: "Devices", subtitle: "Pull down to refresh")
    private let group = RCListGroupView()
    private var refresh: RCRefreshControl?
    private var refreshCount = 0
    private var didApplyDemo = false

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = RCRadius.lg
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.contentInset.top = RCLayout.topBarHeight
        scrollView.delegate = self
        addSubview(ambient)
        addSubview(scrollView)
        scrollView.addSubview(largeTitle)
        scrollView.addSubview(group)

        let rows: [RCListRow.Content] = [
            .init(title: "Kitchen iPad", detail: "192.168.1.30:8080", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)),
            .init(title: "Studio iPhone", detail: "192.168.1.44:8080", detailIsMonospaced: true, glyph: .smartphone, tileTone: .neutral, trailing: .badgeAndChevron(text: "Offline", tone: .neutral, busy: false)),
            .init(title: "Office iPad", detail: "Through relay", glyph: .globe, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)),
            .init(title: "Living room", detail: "Through relay", glyph: .globe, tileTone: .neutral, trailing: .badgeAndChevron(text: "Checking", tone: .neutral, busy: true)),
        ]
        group.setItems(rows.enumerated().map { RCListGroupView.Item(id: "\($0.offset)", view: RCListRow(content: $0.element)) }, animated: false)

        topBar.title = "Devices"
        topBar.leadingViews = [RCBrandMark(side: 28)]
        let refreshButton = RCIconButton(icon: .refreshCw, accessibilityLabel: "Refresh devices")
        refreshButton.onTap = { [weak self] in self?.refresh?.beginRefreshing() }
        topBar.trailingViews = [refreshButton]
        addSubview(topBar)

        let control = RCRefreshControl(scrollView: scrollView) { [weak self] in
            await self?.reload()
        }
        control.topOffset = RCLayout.topBarHeight
        refresh = control
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func reload() async {
        // The posed demo holds the spinner long enough for a screenshot.
        try? await Task.sleep(seconds: DebugLaunch.argument("rctl-chrome-demo") == "refreshing" ? 8 : 1.6)
        refreshCount += 1
        largeTitle.subtitle = refreshCount == 1 ? "Refreshed just now" : "Refreshed \(refreshCount) times"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundColor = RCColor.background
        ambient.frame = bounds
        scrollView.frame = bounds
        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: RCLayout.topBarHeight)
        let width = bounds.width - RCLayout.gutter * 2
        let titleHeight = largeTitle.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        largeTitle.frame = CGRect(x: RCLayout.gutter, y: RCSpace.xs, width: width, height: titleHeight)
        let groupHeight = group.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        group.frame = CGRect(x: RCLayout.gutter, y: largeTitle.frame.maxY + RCSpace.xl, width: width, height: groupHeight)
        let contentSize = CGSize(width: bounds.width, height: group.frame.maxY + RCSpace.xxl)
        if scrollView.contentSize != contentSize { scrollView.contentSize = contentSize }
        applyDemoPoseIfNeeded()
        scrollViewDidScroll(scrollView)
    }

    private func applyDemoPoseIfNeeded() {
        guard !didApplyDemo, window != nil, bounds.height > 0 else { return }
        didApplyDemo = true
        let demo = DebugLaunch.argument("rctl-chrome-demo")
        guard demo == "pull" || demo == "refreshing" else { return }
        // After the gallery has settled its layout (a size change would snap
        // an out-of-range offset back).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if demo == "pull" {
                    self.scrollView.contentOffset.y = -(self.scrollView.adjustedContentInset.top + 58)
                } else {
                    self.refresh?.beginRefreshing()
                }
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        topBar.setScrollProgress(largeTitle.collapseProgress(in: scrollView, topBarHeight: topBar.frame.height))
        refresh?.scrollViewDidScroll()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        refresh?.scrollViewWillEndDragging()
    }
}
#endif
