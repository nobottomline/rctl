#if DEBUG
import UIKit

/// One specimen in the design gallery. `make` builds a fresh view; the gallery
/// sizes it with `sizeThatFits` at the column width unless `height` is given.
struct GalleryItem {
    let title: String
    var height: CGFloat?
    /// Dark media-stage background (for overlay/stage variants).
    var onStage = false
    let make: @MainActor (_ host: UIViewController) -> UIView

    init(_ title: String, height: CGFloat? = nil, onStage: Bool = false, make: @escaping @MainActor (_ host: UIViewController) -> UIView) {
        self.title = title
        self.height = height
        self.onStage = onStage
        self.make = make
    }
}

struct GallerySection {
    let id: String
    let title: String
    let items: [GalleryItem]
}

/// Sections are contributed by the files `Gallery+<Area>.swift`, each owned by
/// the design-system area it demonstrates.
@MainActor
enum GalleryCatalog {
    static func allSections() -> [GallerySection] {
        primitives() + lists() + chrome() + menus() + modals()
    }
}

/// Design-system gallery for visual review in the Simulator:
/// `--rctl-route=gallery` shows everything, add `--rctl-gallery=<section id>`
/// to show one section, and `--rctl-appearance=warm|console` to pick a palette.
@MainActor
final class DesignGalleryViewController: RCViewController, AppRoutable, UIScrollViewDelegate {
    let route: AppRoute = .gallery
    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let topBar = RCTopBar()
    private var rows: [(title: RCLabel, container: UIView, view: UIView, item: GalleryItem)] = []
    private var headers: [RCLabel] = []
    private var layoutOrder: [UIView] = []

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .adaptive)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        topBar.title = "Design system"
        topBar.showsBackButton = true
        topBar.onBack = { [weak self] in self?.environment.router.pop() }
        let appearance = RCIconButton(icon: .sunMoon, variant: .plain, accessibilityLabel: "Appearance")
        RCMenu.attach(to: appearance) { [weak self] in
            guard let self else { return [] }
            return [RCMenuSection(title: "Appearance", items: RCAppearance.allCases.map { value in
                RCMenuItem(value.title, isChecked: self.environment.appearance.appearance == value) { [weak self] in
                    self?.environment.appearance.set(value)
                }
            })]
        }
        topBar.trailingViews = [appearance]
        view.addSubview(topBar)

        let only = DebugLaunch.argument("rctl-gallery")
        for section in GalleryCatalog.allSections() where only == nil || only == section.id {
            let header = RCLabel(section.title, style: .title2)
            scrollView.addSubview(header)
            layoutOrder.append(header)
            headers.append(header)
            for item in section.items {
                let title = RCLabel(item.title, style: .overline, color: RCColor.textTertiary)
                let container = UIView()
                container.layer.cornerRadius = RCRadius.lg
                container.layer.cornerCurve = .continuous
                container.backgroundColor = item.onStage ? RCColor.stage : .clear
                if item.onStage { container.overrideUserInterfaceStyle = .dark }
                let specimen = item.make(self)
                container.addSubview(specimen)
                scrollView.addSubview(title)
                scrollView.addSubview(container)
                rows.append((title, container, specimen, item))
                layoutOrder.append(container)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        scrollView.frame = view.bounds
        topBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: topBar.preferredHeight(safeAreaTop: safe.top))
        let inset = RCLayout.columnInset(width: view.bounds.width, safeArea: safe)
        let width = view.bounds.width - inset.left - inset.right
        var y = topBar.frame.maxY + RCSpace.lg
        var rowIndex = 0
        for view in layoutOrder {
            if let header = view as? RCLabel, headers.contains(header) {
                y += RCSpace.lg
                header.frame = CGRect(x: inset.left, y: y, width: width, height: header.sizeThatFits(CGSize(width: width, height: 100)).height)
                y = header.frame.maxY + RCSpace.md
                continue
            }
            let row = rows[rowIndex]
            rowIndex += 1
            row.title.frame = CGRect(x: inset.left, y: y, width: width, height: 16)
            y += 16 + RCSpace.sm
            let padding: CGFloat = row.item.onStage ? RCSpace.lg : 0
            let innerWidth = width - padding * 2
            let height = row.item.height ?? row.view.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height
            row.container.frame = CGRect(x: inset.left, y: y, width: width, height: height + padding * 2)
            row.view.frame = CGRect(x: padding, y: padding, width: innerWidth, height: height)
            y = row.container.frame.maxY + RCSpace.xl
        }
        scrollView.contentSize = CGSize(width: view.bounds.width, height: y + safe.bottom + RCSpace.xxl)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        topBar.track(scrollView)
    }
}
#endif
