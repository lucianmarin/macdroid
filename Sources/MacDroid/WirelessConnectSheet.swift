import SwiftUI

struct WirelessConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var scanner = WirelessADBScanner()

    @State private var connectAddress = ""
    @State private var useTLS = true
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var isBusy = false

    let onConnect: (String, UInt16, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wireless Debugging (Wi-Fi)")
                .font(.headline)

            GroupBox("Discovered on Local Network") {
                if scanner.services.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning for Android Wireless Debugging devices…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(scanner.services) { service in
                            HStack {
                                Image(systemName: service.kind == .connect ? "wifi" : "lock.shield")
                                VStack(alignment: .leading) {
                                    Text(service.name)
                                        .font(.subheadline)
                                    Text(service.address ?? "Resolving…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let host = service.host, let port = service.port {
                                    Button(service.kind == .connect ? "Connect" : "Use for Pairing") {
                                        if service.kind == .connect {
                                            dismiss()
                                            onConnect(host, port, true)
                                        } else {
                                            pairAddress = service.address ?? "\(host):\(port)"
                                        }
                                    }
                                    .disabled(isBusy)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }

            GroupBox("Connect to Device") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("192.168.1.42:5555", text: $connectAddress)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") {
                            guard let parsed = HostPortParser.parse(connectAddress) else {
                                isError = true
                                statusMessage = "Enter address as IP:port (e.g. 192.168.1.42:5555)"
                                return
                            }
                            dismiss()
                            onConnect(parsed.host, parsed.port, useTLS)
                        }
                        .disabled(isBusy || connectAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Toggle("Use TLS 1.3 (Android 11+ Wireless Debugging)", isOn: $useTLS)
                        .font(.caption)
                }
                .padding(4)
            }

            GroupBox("Pair New Device (Android 11+)") {
                HStack {
                    TextField("Pairing IP:port (e.g. 192.168.1.42:37123)", text: $pairAddress)
                        .textFieldStyle(.roundedBorder)
                    TextField("6-digit code", text: $pairCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Button("Pair") {
                        Task { await runPair() }
                    }
                    .disabled(isBusy || pairAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pairCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(4)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }

    private func runPair() async {
        guard let parsed = HostPortParser.parse(pairAddress) else {
            isError = true
            statusMessage = "Enter pairing address as IP:port"
            return
        }
        isBusy = true
        isError = false
        statusMessage = "Pairing with \(parsed.host):\(parsed.port)…"
        defer { isBusy = false }
        do {
            let client = try ADBPairingClient()
            let result = try await client.pair(
                host: parsed.host,
                port: parsed.port,
                code: pairCode.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            statusMessage = result
            pairCode = ""
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }
}
