import SwiftUI
import UIKit

struct PairingView: View {
    @ObservedObject var model: ControllerAppModel
    @State private var scannerPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "ipad.and.iphone")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Pair Controller")
                    .font(.title2.weight(.semibold))
                VStack(spacing: 10) {
                    Button {
                        scannerPresented = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        guard let value = UIPasteboard.general.string else { return }
                        Task { await model.pair(using: value) }
                    } label: {
                        Label("Paste Pairing Code", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: 360)
                Spacer()
            }
            .padding(24)
            .navigationTitle("RCTL Controller")
            .overlay {
                if model.isBusy { ProgressView() }
            }
            .sheet(isPresented: $scannerPresented) {
                NavigationStack {
                    QRScannerView { value in
                        scannerPresented = false
                        Task { await model.pair(using: value) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Pair Controller")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scannerPresented = false }
                        }
                    }
                }
            }
        }
    }
}
