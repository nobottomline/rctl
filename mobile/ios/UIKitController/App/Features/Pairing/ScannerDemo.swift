#if DEBUG
import UIKit

/// Replays a scripted detection sequence so the scanner can be reviewed in
/// the Simulator, which has no camera (`--rctl-route=scan --rctl-scanner-demo`).
/// `--rctl-scanner-demo-script=idle` keeps the frame empty (idle breathing
/// and render-server cost). Never compiled into Release.
@MainActor
final class ScannerDemo {
    static var isEnabled: Bool { DebugLaunch.flag("rctl-scanner-demo") }

    /// Simulated claim duration before the demo reports a failed claim.
    static let claimDuration: TimeInterval = 1.5

    static let pairingPayload = #"{"v":1,"origin":"https://relay.example","pairing_id":"pair_demo","secret":"demo","expires_at":0,"protocol_major":1,"relay_id":"demo"}"#
    static let foreignPayload = "https://example.com/menu"

    var onDetection: (@MainActor (ScannerDetection?) -> Void)?
    private var task: Task<Void, Never>?
    private var stageSize: CGSize = .zero

    /// Starts (or restarts, when the stage size changed) the script.
    func start(stageSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        guard task == nil || size != stageSize else { return }
        stop()
        stageSize = size
        let foreign = ScannerDetection(
            payload: Self.foreignPayload,
            bounds: CGRect(x: size.width * 0.62 - 75, y: size.height * 0.36 - 75, width: 150, height: 150)
        )
        let pairing = ScannerDetection(
            payload: Self.pairingPayload,
            bounds: CGRect(x: size.width * 0.4 - 85, y: size.height * 0.56 - 85, width: 170, height: 170)
        )
        // The pairing code stays in view past the simulated claim result and
        // then leaves, so the window returns to rest in the same update that
        // starts breathing (the case that used to oscillate).
        let script: [(ScannerDetection?, TimeInterval)] = DebugLaunch.argument("rctl-scanner-demo-script") == "idle"
            ? [(nil, 3_600)]
            : [(nil, 1.5), (foreign, 2), (nil, 3.5), (pairing, 3), (nil, 3.5)]
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                for (detection, hold) in script {
                    guard let self, !Task.isCancelled else { return }
                    self.onDetection?(detection)
                    do { try await Task.sleep(seconds: hold) } catch { return }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        onDetection?(nil)
    }
}

/// Stand-in for the camera: a dim desk-like gradient with a faint grid and a
/// mock code drawn at the scripted detection bounds.
@MainActor
final class ScannerDemoPreviewView: UIView {
    private let gradient = CAGradientLayer()
    private let grid = CAShapeLayer()
    private let code = CAShapeLayer()
    private var laidOutBounds: CGRect = .zero

    var detection: ScannerDetection? {
        didSet { if detection != oldValue { updateCode() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = RCColor.stage
        gradient.colors = [UIColor(white: 0.34, alpha: 1).cgColor, UIColor(white: 0.16, alpha: 1).cgColor]
        grid.strokeColor = UIColor(white: 1, alpha: 0.06).cgColor
        grid.lineWidth = 1
        grid.fillColor = nil
        code.fillColor = UIColor.black.cgColor
        code.backgroundColor = UIColor.white.cgColor
        code.cornerRadius = 6
        code.isHidden = true
        layer.addSublayer(gradient)
        layer.addSublayer(grid)
        layer.addSublayer(code)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != laidOutBounds else { return }
        laidOutBounds = bounds
        withoutImplicitAnimations {
            gradient.frame = bounds
            grid.frame = bounds
            let path = CGMutablePath()
            for x in stride(from: 0, through: bounds.width, by: 44) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: bounds.height))
            }
            for y in stride(from: 0, through: bounds.height, by: 44) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: bounds.width, y: y))
            }
            grid.path = path
        }
    }

    /// The mock code jumps like a real camera image; only the reticle animates.
    private func updateCode() {
        withoutImplicitAnimations {
            guard let bounds = detection?.bounds, !bounds.isNull else {
                code.isHidden = true
                return
            }
            let quiet: CGFloat = 10
            code.isHidden = false
            code.frame = bounds.insetBy(dx: -quiet, dy: -quiet)
            let modules = CGMutablePath()
            let cell = bounds.width / 9
            for row in 0..<9 {
                for column in 0..<9 where (row * 7 + column * 3 + row * column) % 5 < 2 || (row < 3 && column < 3) {
                    modules.addRect(CGRect(x: quiet + CGFloat(column) * cell, y: quiet + CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            code.path = modules
        }
    }
}
#endif
