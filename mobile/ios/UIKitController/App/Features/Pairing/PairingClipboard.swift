import UIKit

/// Paste handling shared by the pairing intro and the scanner.
@MainActor
enum PairingClipboard {
    /// The trimmed clipboard text, or nil after telling the user there is
    /// nothing to paste. `hasStrings` is checked first so an empty or
    /// non-text clipboard never triggers the system paste prompt.
    static func takePairingCode(presentingIn window: UIWindow?) -> String? {
        let pasteboard = UIPasteboard.general
        let raw = pasteboard.hasStrings ? pasteboard.string : nil
        guard let code = PairingPayload.pastedCode(from: raw) else {
            RCToast.show(
                "Nothing to paste",
                message: "Copy the pairing code from relay admin first, then paste it here.",
                tone: .warning,
                icon: .clipboardPaste,
                in: window
            )
            return nil
        }
        return code
    }
}
