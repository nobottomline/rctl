// TEMPORARY foundation stub. Replaced by RCIconPaths.generated.swift + RCIcon.swift
// from the Lucide generator; delete this file when those land.
import UIKit

enum RCIconGlyph: String, CaseIterable, Sendable {
    case tabletSmartphone = "tablet-smartphone"
    case smartphone = "smartphone"
    case tablet = "tablet"
    case monitor = "monitor"
    case monitorSmartphone = "monitor-smartphone"
    case camera = "camera"
    case cameraOff = "camera-off"
    case eye = "eye"
    case eyeOff = "eye-off"
    case hand = "hand"
    case pointer = "pointer"
    case mousePointerClick = "mouse-pointer-click"
    case mousePointer2 = "mouse-pointer-2"
    case keyboard = "keyboard"
    case slidersHorizontal = "sliders-horizontal"
    case house = "house"
    case lock = "lock"
    case lockOpen = "lock-open"
    case volume2 = "volume-2"
    case volume1 = "volume-1"
    case volumeX = "volume-x"
    case bell = "bell"
    case toggleRight = "toggle-right"
    case panelTop = "panel-top"
    case panelBottom = "panel-bottom"
    case layoutPanelTop = "layout-panel-top"
    case wifi = "wifi"
    case wifiOff = "wifi-off"
    case wifiHigh = "wifi-high"
    case globe = "globe"
    case earth = "earth"
    case server = "server"
    case qrCode = "qr-code"
    case scanLine = "scan-line"
    case scan = "scan"
    case scanQrCode = "scan-qr-code"
    case scanEye = "scan-eye"
    case clipboard = "clipboard"
    case clipboardPaste = "clipboard-paste"
    case copy = "copy"
    case flashlight = "flashlight"
    case flashlightOff = "flashlight-off"
    case arrowLeft = "arrow-left"
    case arrowRight = "arrow-right"
    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case chevronUp = "chevron-up"
    case check = "check"
    case circleCheck = "circle-check"
    case circleCheckBig = "circle-check-big"
    case x = "x"
    case circleX = "circle-x"
    case plus = "plus"
    case minus = "minus"
    case refreshCw = "refresh-cw"
    case rotateCw = "rotate-cw"
    case listRestart = "list-restart"
    case ellipsis = "ellipsis"
    case ellipsisVertical = "ellipsis-vertical"
    case trash2 = "trash-2"
    case pencil = "pencil"
    case squarePen = "square-pen"
    case tag = "tag"
    case network = "network"
    case info = "info"
    case circleAlert = "circle-alert"
    case triangleAlert = "triangle-alert"
    case circleHelp = "circle-help"
    case octagonX = "octagon-x"
    case shieldCheck = "shield-check"
    case shieldAlert = "shield-alert"
    case keyRound = "key-round"
    case radar = "radar"
    case search = "search"
    case loaderCircle = "loader-circle"
    case settings = "settings"
    case sun = "sun"
    case moon = "moon"
    case sunMoon = "sun-moon"
    case palette = "palette"
    case power = "power"
    case delete = "delete"
    case cornerDownLeft = "corner-down-left"
    case arrowLeftRight = "arrow-left-right"
    case `repeat` = "repeat"
    case save = "save"
    case download = "download"
    case arrowDownToLine = "arrow-down-to-line"
    case externalLink = "external-link"
    case link = "link"
    case unplug = "unplug"
    case plugZap = "plug-zap"
    case circleStop = "circle-stop"
    case activity = "activity"
    case gauge = "gauge"
    case signal = "signal"
    case radioTower = "radio-tower"
    case router = "router"
    case satelliteDish = "satellite-dish"
    case zap = "zap"
    case sparkles = "sparkles"
    case circleDot = "circle-dot"
    case circle = "circle"
    case badgeCheck = "badge-check"
    case layers = "layers"
    case textCursorInput = "text-cursor-input"
    case logOut = "log-out"
    case history = "history"
    case appWindow = "app-window"
    case lightbulb = "lightbulb"
    case lightbulbOff = "lightbulb-off"
    case hardDrive = "hard-drive"
    case cpu = "cpu"
    case vibrate = "vibrate"
    case rectangleHorizontal = "rectangle-horizontal"
    case touchpad = "touchpad"
    case move = "move"
    case command = "command"
    case option = "option"
    case undo2 = "undo-2"
    case squareDashed = "square-dashed"
}

extension RCIconGlyph {
    func makePath() -> CGPath {
        CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 16, height: 16), transform: nil)
    }
}

@MainActor enum RCIcon {
    static func image(_ glyph: RCIconGlyph, pointSize: CGFloat = 20, strokeWidth: CGFloat = 2) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: pointSize, height: pointSize)).image { context in
            context.cgContext.scaleBy(x: pointSize / 24, y: pointSize / 24)
            context.cgContext.addPath(glyph.makePath())
            context.cgContext.setLineWidth(strokeWidth)
            context.cgContext.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }

    static func path(_ glyph: RCIconGlyph) -> CGPath { glyph.makePath() }

    static func path(_ glyph: RCIconGlyph, pointSize: CGFloat) -> CGPath {
        var transform = CGAffineTransform(scaleX: pointSize / 24, y: pointSize / 24)
        return glyph.makePath().copy(using: &transform) ?? glyph.makePath()
    }
}

@MainActor final class RCIconView: UIView {
    private let shape = CAShapeLayer()
    var glyph: RCIconGlyph? { didSet { setNeedsLayout() } }
    var pointSize: CGFloat { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var strokeWidth: CGFloat { didSet { setNeedsLayout() } }
    var strokeEnd: CGFloat {
        get { shape.strokeEnd }
        set { shape.strokeEnd = newValue }
    }

    init(_ glyph: RCIconGlyph? = nil, pointSize: CGFloat = 20, strokeWidth: CGFloat = 2) {
        self.glyph = glyph
        self.pointSize = pointSize
        self.strokeWidth = strokeWidth
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize { CGSize(width: pointSize, height: pointSize) }

    override func layoutSubviews() {
        super.layoutSubviews()
        shape.frame = CGRect(x: (bounds.width - pointSize) / 2, y: (bounds.height - pointSize) / 2, width: pointSize, height: pointSize)
        shape.path = glyph.map { RCIcon.path($0, pointSize: pointSize) }
        shape.lineWidth = strokeWidth * pointSize / 24
        shape.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        shape.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
    }

    func setGlyph(_ glyph: RCIconGlyph?, animated: Bool) { self.glyph = glyph }
    func drawIn(duration: CFTimeInterval = 0.35) {}
}
