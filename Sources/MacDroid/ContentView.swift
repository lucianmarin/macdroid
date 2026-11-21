import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var session = ScrcpySession()
    @StateObject private var scanner = WirelessADBScanner()
    @State private var selectedServiceID: String?
    @State private var showWirelessSheet = false
    @State private var showControlsBar = true
    @State private var hostWindow: NSWindow?
    @State private var didAutoReconnect = false

    private var connectableServices: [DiscoveredADBService] {
        scanner.services.filter { $0.kind == .connect && $0.host != nil && $0.port != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                switch session.state {
                case .streaming:
                    DeviceStreamView(session: session)
                case .connecting(let message):
                    ProgressView(message)
                        .foregroundStyle(.white)
                case .error(let message):
                    ContentUnavailableView("Connection Error", systemImage: "exclamationmark.triangle", description: Text(message))
                case .idle:
                    ContentUnavailableView(
                        "No Active Stream",
                        systemImage: "wifi",
                        description: Text("Enable Wireless Debugging on your Android phone, then click Wi-Fi to pair or connect.")
                    )
                }

                if let status = session.transferStatus {
                    VStack {
                        Spacer()
                        Text(status)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .transition(.opacity)
                }
            }
            .frame(minWidth: 260, minHeight: 480)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { session.viewportSize = proxy.size }
                        .onChange(of: proxy.size) { _, newSize in
                            session.viewportSize = newSize
                        }
                }
            )

            if showControlsBar {
                HStack(spacing: 16) {
                    Button { session.sendKeyTap(.back) } label: { Image(systemName: "chevron.backward") }
                    Button { session.sendKeyTap(.home) } label: { Image(systemName: "circle") }
                    Button { session.sendKeyTap(.appSwitch) } label: { Image(systemName: "square") }
                    Divider().frame(height: 16)
                    Button {
                        Task { await session.toggleAudioMode() }
                    } label: {
                        Image(systemName: audioModeIcon)
                    }
                    .help(audioModeHelp)

                    Button {
                        session.toggleScreenOff()
                    } label: {
                        Image(systemName: session.isScreenOff ? "moon.fill" : "moon")
                    }
                    .help(session.isScreenOff ? "Turn phone screen on" : "Turn phone screen off while mirroring")

                    Button { session.sendKeyTap(.power) } label: { Image(systemName: "power") }
                        .help("Power button")
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .disabled(!isStreaming)
            }
        }
        .background(FullscreenAutoHideToolbarView { window in
            if hostWindow !== window {
                hostWindow = window
            }
        })
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    fitWindowToStream()
                } label: {
                    Label("Fit Window", systemImage: "aspectratio")
                }
                .help("Match window size to device screen")
                .disabled(!isStreaming)

                Button {
                    Task { await session.setDesktopMode(!session.desktopMode) }
                } label: {
                    Label(
                        session.desktopMode ? "Desktop" : "Phone",
                        systemImage: session.desktopMode ? "desktopcomputer" : "iphone"
                    )
                }
                .help("Toggle Android Desktop Mode")

                Button {
                    showControlsBar.toggle()
                } label: {
                    Label("Controls", systemImage: showControlsBar ? "menubar.dock.rectangle.badge.record" : "menubar.dock.rectangle")
                }
                .help(showControlsBar ? "Hide device controls bar" : "Show device controls bar")

                Button("Wi-Fi", systemImage: "wifi") {
                    showWirelessSheet = true
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if isStreaming {
                    Button("Disconnect") {
                        Task { await session.disconnect() }
                    }
                } else {
                    Button("Connect") {
                        guard let service = connectableServices.first(where: { $0.id == selectedServiceID }) ?? connectableServices.first,
                              let host = service.host, let port = service.port else { return }
                        UserDefaults.standard.set(service.name, forKey: ScrcpySession.lastServiceKey)
                        Task { await session.connectWiFi(host: host, port: port, useTLS: true) }
                    }
                    .disabled(connectableServices.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showWirelessSheet) {
            WirelessConnectSheet { host, port, useTLS in
                Task { await session.connectWiFi(host: host, port: port, useTLS: useTLS) }
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: connectableServices) { _, newServices in
            if selectedServiceID == nil {
                selectedServiceID = newServices.first?.id
            }
            // Auto-reconnect once on launch if the last-connected phone appears on Wi-Fi.
            if !didAutoReconnect,
               case .idle = session.state,
               let lastName = UserDefaults.standard.string(forKey: ScrcpySession.lastServiceKey),
               let match = newServices.first(where: { $0.name == lastName }),
               let host = match.host, let port = match.port {
                didAutoReconnect = true
                selectedServiceID = match.id
                Task { await session.connectWiFi(host: host, port: port, useTLS: true) }
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming = session.state { return true }
        return false
    }

    private var audioModeIcon: String {
        switch session.audioMode {
        case .desktop: return "speaker.wave.2"
        case .phone: return "iphone.radiowaves.left.and.right"
        }
    }

    private var audioModeHelp: String {
        switch session.audioMode {
        case .desktop: return "Audio: Desktop (click for Phone)"
        case .phone: return "Audio: Phone (click for Desktop)"
        }
    }

    private func fitWindowToStream() {
        guard let window = hostWindow ?? NSApp.keyWindow,
              !window.styleMask.contains(.fullScreen),
              session.videoSize.width > 0,
              session.videoSize.height > 0 else { return }

        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let aspect = session.videoSize.width / session.videoSize.height
        let fallbackChrome = (window.frame.height - window.contentLayoutRect.height) + (showControlsBar ? 32 : 0)
        let overheadHeight = session.viewportSize.height > 0
            ? (window.frame.height - session.viewportSize.height)
            : fallbackChrome

        // Match 1:1 Android dp to macOS points (capped to the available screen).
        let maxVideoHeight = max(200, visible.height - overheadHeight)
        let maxVideoWidth = visible.width
        let idealHeight = session.deviceLogicalSize?.height ?? session.videoSize.height
        var targetHeight = min(idealHeight, maxVideoHeight)
        var targetWidth = targetHeight * aspect
        if targetWidth > maxVideoWidth {
            targetWidth = maxVideoWidth
            targetHeight = targetWidth / aspect
        }
        if targetWidth < 260 {
            targetWidth = 260
            targetHeight = min(maxVideoHeight, targetWidth / aspect)
            targetWidth = targetHeight * aspect
        }

        let newFrameSize = NSSize(
            width: floor(targetWidth),
            height: ceil(targetHeight + overheadHeight)
        )
        var newFrame = window.frame
        // Keep the top-left corner anchored, then clamp within the visible screen.
        newFrame.origin.y += newFrame.height - newFrameSize.height
        newFrame.size = newFrameSize
        if newFrame.minY < visible.minY {
            newFrame.origin.y = visible.minY
        }
        if newFrame.maxY > visible.maxY {
            newFrame.origin.y = visible.maxY - newFrame.height
        }
        if newFrame.maxX > visible.maxX {
            newFrame.origin.x = max(visible.minX, visible.maxX - newFrame.width)
        }
        window.setFrame(newFrame, display: true, animate: true)
    }
}

/// Configures the hosting NSWindow so the toolbar autohides in fullscreen.
private struct FullscreenAutoHideToolbarView: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            context.coordinator.attach(to: window)
            DispatchQueue.main.async { onWindow(window) }
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var attachedWindow: NSWindow?
        private weak var originalDelegate: NSWindowDelegate?

        func attach(to window: NSWindow) {
            guard attachedWindow !== window else { return }
            attachedWindow = window
            window.titleVisibility = .hidden
            originalDelegate = window.delegate
            window.delegate = self
        }

        func window(
            _ window: NSWindow,
            willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
        ) -> NSApplication.PresentationOptions {
            return proposedOptions.union(.autoHideToolbar)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return originalDelegate?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let originalDelegate, originalDelegate.responds(to: aSelector) {
                return originalDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
