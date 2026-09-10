import SwiftUI

/// Pushed form for adding or editing a saved LAN address. Connect validates the
/// device before saving and hands the profile to the caller on success.
struct LocalDeviceEditor: View {
    private enum Field { case address, name }

    /// Which flow opened the editor. Discovery hands in a `suggested` profile
    /// whose address answered a preflight moments ago; it is still a hint.
    private enum Mode { case add, saveDiscovered, edit, replaceAddress }

    @ObservedObject var model: LocalDevicesModel
    let editing: LocalDeviceProfile?
    let connect: (LocalDeviceProfile) -> Void
    private let suggested: LocalDeviceProfile?
    @State private var address: String
    @State private var name: String
    @State private var error: String?
    @State private var pending: Task<Void, Never>?
    @FocusState private var focus: Field?

    init(model: LocalDevicesModel, editing: LocalDeviceProfile? = nil, suggested: LocalDeviceProfile? = nil,
         connect: @escaping (LocalDeviceProfile) -> Void) {
        self.model = model
        self.editing = editing
        self.suggested = suggested
        self.connect = connect
        _address = State(initialValue: suggested?.address.displayAddress ?? editing?.address.displayAddress ?? "")
        _name = State(initialValue: editing?.name ?? suggested?.name ?? "")
    }

    private var mode: Mode {
        switch (editing, suggested) {
        case (nil, nil): .add
        case (nil, .some): .saveDiscovered
        case (.some, nil): .edit
        case (.some, .some): .replaceAddress
        }
    }

    private var title: String {
        switch mode {
        case .add: "Local device"
        case .saveDiscovered: "Save device"
        case .edit: "Edit device"
        case .replaceAddress: "Update address"
        }
    }

    private var intro: String {
        switch mode {
        case .add, .edit:
            "Connect directly over the network you are on. The iPad needs the rctl package with LAN control enabled."
        case .saveDiscovered:
            "Keep this device for next time. You can rename it; the address stays the one that answered."
        case .replaceAddress:
            "Point a saved device at the address found on the network. Nothing changes until you save."
        }
    }

    private var action: String {
        switch mode {
        case .add: "Connect"
        case .saveDiscovered, .edit: "Save and connect"
        case .replaceAddress: "Replace address and connect"
        }
    }

    var body: some View {
        ZStack {
            AmbientBackground(particleOpacity: 0.7)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 32, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(ControllerPalette.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(intro)
                            .font(.subheadline)
                            .foregroundStyle(ControllerPalette.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    if let suggested, let editing, mode == .replaceAddress {
                        AddressChangeCard(
                            deviceName: editing.name,
                            discoveredName: suggested.name,
                            oldAddress: editing.address.displayAddress,
                            newAddress: suggested.address.displayAddress
                        )
                    } else if let suggested, mode == .saveDiscovered {
                        Callout(
                            text: "Found on this network as “\(suggested.name)”. Discovery does not verify which iPad answered; use LAN control only on a network you trust.",
                            symbol: "bonjour",
                            tone: .neutral
                        )
                    }

                    VStack(spacing: 0) {
                        FormField(
                            symbol: "network",
                            title: "Address",
                            placeholder: "192.168.1.20:8080",
                            text: $address,
                            keyboard: .URL,
                            submitLabel: .next
                        )
                        .focused($focus, equals: .address)
                        .onSubmit { focus = .name }
                        .accessibilityIdentifier("local-address")
                        Rectangle()
                            .fill(ControllerPalette.line)
                            .frame(height: 1)
                            .padding(.leading, 64)
                        FormField(
                            symbol: "tag",
                            title: "Name",
                            placeholder: "Optional, for example Living room",
                            text: $name,
                            keyboard: .default,
                            submitLabel: .go
                        )
                        .focused($focus, equals: .name)
                        .onSubmit { submit() }
                        .accessibilityIdentifier("local-name")
                    }
                    .glassSurface(cornerRadius: 22, padding: 4)
                    .disabled(pending != nil)

                    if let error {
                        Callout(text: error, symbol: "exclamationmark.triangle.fill", tone: .danger)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Callout(
                        text: "Local access has no authentication. Use it only on a trusted network. Port 8080 is used when none is given.",
                        symbol: "lock.open",
                        tone: .neutral
                    )

                    Button(action: submit) {
                        if pending != nil {
                            HStack(spacing: 10) {
                                ProgressView().tint(ControllerPalette.onSignal)
                                Text("Checking device…")
                            }
                        } else {
                            Label(action, systemImage: "arrow.right")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(tone: .signal))
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending != nil)
                    .accessibilityIdentifier("local-connect")
                    .padding(.top, 4)
                }
                .pageColumn(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(ControllerMotion.standard, value: error)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(pending != nil)
        .onAppear {
            if address.isEmpty { focus = .address }
        }
        .onDisappear { pending?.cancel() }
    }

    private func submit() {
        guard pending == nil, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = nil
        focus = nil
        pending = Task { @MainActor in
            defer { pending = nil }
            do {
                let device = try await model.save(address: address, name: name, editing: editing?.id)
                try Task.checkCancellation()
                ControllerHaptics.success()
                connect(device)
            } catch {
                if !Task.isCancelled {
                    ControllerHaptics.warning()
                    self.error = LocalDevicesModel.message(for: error)
                }
            }
        }
    }
}

/// Shows exactly what a confirmed address replacement will change.
private struct AddressChangeCard: View {
    let deviceName: String
    let discoveredName: String
    let oldAddress: String
    let newAddress: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ControllerPalette.signal)
                    .accessibilityHidden(true)
                Text("Saved device “\(deviceName)”")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ControllerPalette.ink)
                    .lineLimit(2)
            }
            VStack(spacing: 0) {
                addressRow(label: "Current", value: oldAddress, emphasized: false)
                Rectangle().fill(ControllerPalette.line).frame(height: 1)
                addressRow(label: "Found as “\(discoveredName)”", value: newAddress, emphasized: true)
            }
            .background(ControllerPalette.canvasDeep.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Only Replace address and connect changes the saved entry. The name and history stay.")
                .font(.footnote)
                .foregroundStyle(ControllerPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassSurface(cornerRadius: 20, padding: 16)
        .accessibilityElement(children: .combine)
    }

    private func addressRow(label: String, value: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ControllerPalette.muted)
                .lineLimit(2)
            Text(value)
                .font(.body.monospaced().weight(emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? ControllerPalette.signal : ControllerPalette.inkDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Labeled text field row used inside a glass surface.
private struct FormField: View {
    let symbol: String
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboard: UIKeyboardType
    let submitLabel: SubmitLabel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ControllerPalette.signal)
                .frame(width: 36, height: 36)
                .background(ControllerPalette.signalSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ControllerPalette.muted)
                TextField(placeholder, text: $text)
                    .font(.body)
                    .foregroundStyle(ControllerPalette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(keyboard)
                    .submitLabel(submitLabel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Inline note or error message with a leading symbol.
struct Callout: View {
    enum Tone { case neutral, danger }
    let text: String
    let symbol: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tone == .danger ? ControllerPalette.danger : ControllerPalette.muted)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(tone == .danger ? ControllerPalette.danger : ControllerPalette.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (tone == .danger ? ControllerPalette.dangerSoft : ControllerPalette.elevated).opacity(0.85),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tone == .danger ? ControllerPalette.danger.opacity(0.25) : ControllerPalette.line, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}
