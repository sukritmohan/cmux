import SwiftUI
import CoreImage.CIFilterBuiltins

/// SwiftUI settings section for the mobile companion bridge server.
///
/// Provides controls for enabling/disabling the bridge, configuring the port,
/// pairing new devices via QR code, and managing (revoking) paired devices.
struct BridgeSettingsView: View {
    @AppStorage(BridgeSettings.enabledKey) private var isEnabled = BridgeSettings.defaultEnabled
    @AppStorage(BridgeSettings.portKey) private var port = BridgeSettings.defaultPort

    @State private var devices: [BridgeAuth.PairedDevice] = []
    @State private var showPairingSheet = false
    @State private var pairingDevice: BridgeAuth.PairedDevice?
    @State private var newDeviceName = ""

    /// The width used for control columns in the settings UI, passed from SettingsView.
    let controlWidth: CGFloat

    var body: some View {
        SettingsCardRow(
            String(localized: "settings.bridge.enabled", defaultValue: "Mobile Companion"),
            subtitle: String(localized: "settings.bridge.enabled.subtitle",
                           defaultValue: "Allow mobile devices to connect over Tailscale"),
            controlWidth: controlWidth
        ) {
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .onChange(of: isEnabled) { _ in
                    updateBridgeState()
                }
        }

        if isEnabled {
            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.bridge.port", defaultValue: "Port"),
                controlWidth: controlWidth
            ) {
                TextField("", value: $port, format: .number)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit {
                        updateBridgeState()
                    }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.bridge.pairDevice", defaultValue: "Pair New Device"),
                subtitle: String(localized: "settings.bridge.pairDevice.subtitle",
                               defaultValue: "Scan the QR code with the cmux companion app"),
                controlWidth: controlWidth
            ) {
                Button(String(localized: "settings.bridge.pairDevice.button", defaultValue: "Pair…")) {
                    showPairingSheet = true
                }
            }

            if !devices.isEmpty {
                SettingsCardDivider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "settings.bridge.pairedDevices", defaultValue: "Paired Devices"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)

                    ForEach(devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.body)
                                Text(String(localized: "settings.bridge.lastSeen",
                                          defaultValue: "Last seen: \(device.lastSeenAt.formatted(.relative(presentation: .named)))"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(String(localized: "settings.bridge.revoke", defaultValue: "Revoke")) {
                                BridgeAuth.shared.revokeDevice(id: device.id)
                                refreshDevices()
                            }
                            .foregroundColor(.red)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Pairing Sheet

    /// Generates a QR code containing the pairing payload for the companion app.
    ///
    /// The QR code encodes a JSON object: `{"host": "<tailscale-ip>", "port": 17377, "token": "<base64>"}`
    /// The companion app scans this to configure the connection.
    @ViewBuilder
    private var pairingSheet: some View {
        VStack(spacing: 16) {
            Text(String(localized: "settings.bridge.pairing.title", defaultValue: "Pair Device"))
                .font(.headline)

            TextField(
                String(localized: "settings.bridge.pairing.deviceName", defaultValue: "Device Name"),
                text: $newDeviceName
            )
            .frame(width: 200)

            if let device = pairingDevice {
                let payload = pairingPayload(for: device)
                if let qrImage = generateQRCode(from: payload) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                }

                Text(String(localized: "settings.bridge.pairing.instruction",
                           defaultValue: "Scan this QR code with the cmux companion app on your phone."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(String(localized: "settings.bridge.pairing.done", defaultValue: "Done")) {
                    showPairingSheet = false
                    pairingDevice = nil
                    newDeviceName = ""
                    refreshDevices()
                }
            } else {
                Button(String(localized: "settings.bridge.pairing.generate", defaultValue: "Generate Pairing Code")) {
                    let name = newDeviceName.isEmpty
                        ? String(localized: "settings.bridge.pairing.defaultName", defaultValue: "Mobile Device")
                        : newDeviceName
                    pairingDevice = BridgeAuth.shared.generatePairing(deviceName: name)
                }
                .disabled(false)
            }

            if pairingDevice == nil {
                Button(String(localized: "settings.bridge.pairing.cancel", defaultValue: "Cancel")) {
                    showPairingSheet = false
                    newDeviceName = ""
                }
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    // MARK: - Helpers

    private func refreshDevices() {
        devices = BridgeAuth.shared.listDevices()
    }

    private func updateBridgeState() {
        if isEnabled {
            BridgeServer.shared.start()
            BridgeEventRelay.shared.start()
        } else {
            BridgeEventRelay.shared.stop()
            BridgeServer.shared.stop()
        }
    }

    /// Builds the JSON pairing payload that the companion app reads from the QR code.
    private func pairingPayload(for device: BridgeAuth.PairedDevice) -> String {
        let payload: [String: Any] = [
            "host": tailscaleIP(),
            "port": port,
            "token": device.token,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .sortedKeys),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Returns the local Tailscale IP address, or a fallback placeholder.
    ///
    /// Checks network interfaces for a `utun` interface with a `100.x.x.x` address,
    /// which is the standard Tailscale CGNAT range.
    private func tailscaleIP() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return "0.0.0.0"
        }
        defer { freeifaddrs(ifaddr) }

        var current = firstAddr
        while true {
            let name = String(cString: current.pointee.ifa_name)
            if name.hasPrefix("utun"),
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &hostname, socklen_t(hostname.count),
                              nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    // Tailscale uses 100.x.x.x (CGNAT range).
                    if ip.hasPrefix("100.") {
                        return ip
                    }
                }
            }
            guard let next = current.pointee.ifa_next else { break }
            current = next
        }
        return "0.0.0.0"
    }

    /// Generates a QR code image from a string using CoreImage.
    private func generateQRCode(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for crisp rendering.
        let scale = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: scale)

        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - Sheet Modifier

extension BridgeSettingsView {
    /// Wraps this view with the pairing sheet presentation.
    ///
    /// Call this on the `BridgeSettingsView` instance in the settings layout to
    /// attach the sheet presentation. Returns a modified view.
    func withPairingSheet() -> some View {
        self
            .sheet(isPresented: $showPairingSheet) {
                pairingSheet
            }
            .onAppear {
                refreshDevices()
            }
    }
}
