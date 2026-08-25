import RctlProtocol
import SwiftUI

struct RemoteKeyboardPanel: View {
    let sendText: (String) -> RemoteTextInputResult
    let sendKey: (RemoteKeyboardKey) -> Void
    let dismiss: () -> Void

    @State private var draft = ""
    @State private var validationMessage: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Type on iPad", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.send)
                    .focused($inputFocused)
                    .onSubmit(sendDraft)
                    .onChange(of: draft) { value in
                        guard value.count > HIDKeyboard.maximumTextCharacters else {
                            validationMessage = nil
                            return
                        }
                        draft = String(value.prefix(HIDKeyboard.maximumTextCharacters))
                        validationMessage = "Text is limited to \(HIDKeyboard.maximumTextCharacters) characters per send."
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                    .foregroundStyle(RemotePalette.primaryText)
                    .background(RemotePalette.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(validationMessage == nil ? RemotePalette.line : RemotePalette.danger, lineWidth: 1)
                    }

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(RemoteIconButtonStyle(selected: !draft.isEmpty))
                .disabled(draft.isEmpty)
                .accessibilityLabel("Type text on iPad")

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(RemoteIconButtonStyle())
                .accessibilityLabel("Close keyboard")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RemoteKeyboardKey.allCases) { key in
                        keyButton(key)
                    }
                }
            }
            .frame(height: 44)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(RemotePalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RemotePalette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(RemotePalette.line)
                .frame(height: 1)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onAppear {
            DispatchQueue.main.async {
                inputFocused = true
            }
        }
    }

    @ViewBuilder
    private func keyButton(_ key: RemoteKeyboardKey) -> some View {
        Button {
            RemoteHaptics.action()
            sendKey(key)
            inputFocused = true
        } label: {
            Group {
                if let symbol = key.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    Text(key.shortLabel)
                        .font(.caption.weight(.semibold))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(RemoteActionButtonStyle())
        .accessibilityLabel(key.accessibilityLabel)
    }

    private func sendDraft() {
        guard !draft.isEmpty else { return }
        switch sendText(draft) {
        case .sent:
            RemoteHaptics.action()
            draft = ""
            validationMessage = nil
        case let .rejected(message):
            RemoteHaptics.warning()
            validationMessage = message
        }
        inputFocused = true
    }

    private func close() {
        inputFocused = false
        dismiss()
    }
}

private extension RemoteKeyboardKey {
    var shortLabel: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        default: ""
        }
    }

    var symbol: String? {
        switch self {
        case .escape, .tab: nil
        case .enter: "return"
        case .backspace: "delete.left"
        case .deleteForward: "delete.right"
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .enter: "Return"
        case .backspace: "Backspace"
        case .deleteForward: "Forward delete"
        case .left: "Left arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .right: "Right arrow"
        }
    }
}
