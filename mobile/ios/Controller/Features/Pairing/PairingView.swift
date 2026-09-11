import SwiftUI
import UIKit

/// Pushed introduction to relay pairing. Scanning is a further push; pasting
/// runs in place. Success is observed by the Devices screen, which pops back.
struct PairingView: View {
    @ObservedObject var model: ControllerAppModel
    let scan: () -> Void
    @State private var clipboardEmpty = false

    var body: some View {
        ZStack {
            AmbientBackground(particleOpacity: 0.7)
            ScrollView {
                VStack(spacing: 24) {
                    PairingEmblem()
                        .padding(.top, 12)
                    VStack(spacing: 8) {
                        Text("Pair with your relay")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.6)
                            .foregroundStyle(ControllerPalette.ink)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text("Link this phone to the relay that manages your devices. It takes a few seconds and is done once.")
                            .font(.subheadline)
                            .foregroundStyle(ControllerPalette.inkDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 8)

                    VStack(alignment: .leading, spacing: 18) {
                        PairingStep(
                            number: 1,
                            title: "Open relay admin",
                            text: "Sign in to your relay console on a computer."
                        )
                        PairingStep(
                            number: 2,
                            title: "Create a controller pairing",
                            text: "Choose what this phone may do. The code is one-time and expires within minutes."
                        )
                        PairingStep(
                            number: 3,
                            title: "Scan the code",
                            text: "Your controller key is created in the Secure Enclave and never leaves this device."
                        )
                    }
                    .glassSurface(cornerRadius: 22, padding: 20)

                    VStack(spacing: 10) {
                        Button {
                            ControllerHaptics.tap()
                            scan()
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(PrimaryButtonStyle(tone: .signal))
                        .accessibilityIdentifier("scan-pairing-code")

                        Button(action: paste) {
                            Label("Paste pairing code", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("paste-pairing-code")
                    }
                    .disabled(model.isBusy)
                }
                .pageColumn(maxWidth: 560)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .overlay {
            if model.isBusy {
                PairingProgressCard()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(ControllerMotion.standard, value: model.isBusy)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(model.isBusy)
        .alert("Nothing to paste", isPresented: $clipboardEmpty) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy the pairing code from relay admin first, then paste it here.")
        }
    }

    private func paste() {
        guard UIPasteboard.general.hasStrings,
              let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            clipboardEmpty = true
            return
        }
        ControllerHaptics.tap()
        Task { await model.pair(using: value) }
    }
}

/// Numbered step row.
private struct PairingStep: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(ControllerPalette.onSignal)
                .frame(width: 28, height: 28)
                .background(ControllerPalette.signal, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ControllerPalette.ink)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(ControllerPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(text)")
    }
}

/// QR emblem with corner brackets, echoing the scanner reticle.
private struct PairingEmblem: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(ControllerPalette.elevated.opacity(0.9))
                .shadow(color: ControllerPalette.ink.opacity(0.08), radius: 16, x: 0, y: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(ControllerPalette.line, lineWidth: 1)
                }
            Image(systemName: "qrcode")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(ControllerPalette.ink)
            ReticleBrackets(cornerRadius: 22, length: 22)
                .stroke(ControllerPalette.signal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .padding(10)
        }
        .frame(width: 128, height: 128)
        .accessibilityHidden(true)
    }
}

/// Blocking progress card shown while the relay claim is running.
private struct PairingProgressCard: View {
    var body: some View {
        ZStack {
            ControllerPalette.ink.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(ControllerPalette.signal)
                Text("Pairing with relay")
                    .font(.headline)
                    .foregroundStyle(ControllerPalette.ink)
                Text("Creating your controller key and claiming the code.")
                    .font(.footnote)
                    .foregroundStyle(ControllerPalette.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 260)
            .glassSurface(cornerRadius: 22, padding: 24)
            .padding(24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
