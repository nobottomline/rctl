import SwiftUI

struct LocalDeviceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LocalDevicesModel
    let editing: LocalDeviceProfile?
    let connect: (LocalDeviceProfile) -> Void
    @State private var address: String
    @State private var name: String
    @State private var error: String?
    @State private var pending: Task<Void, Never>?

    init(model: LocalDevicesModel, editing: LocalDeviceProfile? = nil,
         connect: @escaping (LocalDeviceProfile) -> Void) {
        self.model = model
        self.editing = editing
        self.connect = connect
        _address = State(initialValue: editing?.address.displayAddress ?? "")
        _name = State(initialValue: editing?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP address : port", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("local-address")
                    TextField("Name (optional)", text: $name)
                        .accessibilityIdentifier("local-name")
                } footer: {
                    Text("Local access has no authentication. Use a trusted network.")
                }
                .disabled(pending != nil)
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Local Device" : "Edit Local Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pending?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        error = nil
                        pending = Task { @MainActor in
                            defer { pending = nil }
                            do {
                                let device = try await model.save(address: address, name: name, editing: editing?.id)
                                try Task.checkCancellation()
                                connect(device)
                                dismiss()
                            } catch {
                                if !Task.isCancelled { self.error = LocalDevicesModel.message(for: error) }
                            }
                        }
                    } label: {
                        if pending != nil { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pending != nil)
                    .accessibilityIdentifier("local-connect")
                }
            }
            .interactiveDismissDisabled(pending != nil)
            .onDisappear { pending?.cancel() }
        }
    }
}
