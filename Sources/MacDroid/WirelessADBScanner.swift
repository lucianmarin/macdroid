import Darwin
import Foundation
import Network

public struct DiscoveredADBService: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case connect
        case pairing
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let host: String?
    public let port: UInt16?

    public var address: String? {
        guard let host, let port else { return nil }
        if host.contains(":") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }
}

@MainActor
public final class WirelessADBScanner: NSObject, ObservableObject {
    @Published public private(set) var services: [DiscoveredADBService] = []

    private var connectBrowser: NWBrowser?
    private var pairingBrowser: NWBrowser?
    private var resolvedByID: [String: DiscoveredADBService] = [:]
    private var activeResolvers: [String: NetService] = [:]

    public override init() {
        super.init()
    }

    public func start() {
        stop()
        connectBrowser = startBrowser(type: "_adb-tls-connect._tcp", kind: .connect)
        pairingBrowser = startBrowser(type: "_adb-tls-pairing._tcp", kind: .pairing)
    }

    public func stop() {
        connectBrowser?.cancel()
        connectBrowser = nil
        pairingBrowser?.cancel()
        pairingBrowser = nil
        for resolver in activeResolvers.values {
            resolver.stop()
            resolver.delegate = nil
        }
        activeResolvers.removeAll()
        resolvedByID.removeAll()
        services = []
    }

    private func startBrowser(type: String, kind: DiscoveredADBService.Kind) -> NWBrowser {
        let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: "local.")
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                self?.handleResults(results, kind: kind)
            }
        }
        browser.start(queue: .global(qos: .utility))
        return browser
    }

    private func handleResults(_ results: Set<NWBrowser.Result>, kind: DiscoveredADBService.Kind) {
        let prefix = "\(kind.rawValue):"
        let currentIDs = Set(results.compactMap { result -> String? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return prefix + name
        })

        for key in resolvedByID.keys where key.hasPrefix(prefix) && !currentIDs.contains(key) {
            resolvedByID.removeValue(forKey: key)
            activeResolvers[key]?.stop()
            activeResolvers.removeValue(forKey: key)
        }

        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let id = prefix + name
            if resolvedByID[id] == nil {
                resolvedByID[id] = DiscoveredADBService(id: id, name: name, kind: kind, host: nil, port: nil)
                resolveViaNetService(id: id, name: name, type: type, domain: domain)
            }
        }
        publishServices()
    }

    private func resolveViaNetService(id: String, name: String, type: String, domain: String) {
        // Resolve mDNS SRV/A/AAAA records without opening a TCP connection to the phone.
        let service = NetService(domain: domain, type: type, name: name)
        service.delegate = self
        activeResolvers[id] = service
        service.resolve(withTimeout: 5.0)
    }

    private func publishServices() {
        services = resolvedByID.values.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .connect }
            return lhs.name < rhs.name
        }
    }

    private static func preferredIPAddress(from addresses: [Data]) -> String? {
        var ipv6Fallback: String?
        for data in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = data.withUnsafeBytes { rawBuffer -> Int32 in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                    return -1
                }
                return getnameinfo(
                    base,
                    socklen_t(data.count),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
            guard result == 0 else { continue }
            var ip = String(cString: hostname)
            if let pct = ip.firstIndex(of: "%") {
                ip = String(ip[..<pct])
            }
            if !ip.contains(":") {
                return ip
            }
            if ipv6Fallback == nil && !ip.lowercased().hasPrefix("fe80:") {
                ipv6Fallback = ip
            }
        }
        return ipv6Fallback
    }
}

extension WirelessADBScanner: NetServiceDelegate {
    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        let port = sender.port
        let addresses = sender.addresses ?? []
        let name = sender.name
        let type = sender.type
        Task { @MainActor [weak self] in
            guard let self, port > 0, let ip = Self.preferredIPAddress(from: addresses) else { return }
            let kind: DiscoveredADBService.Kind = type.contains("pairing") ? .pairing : .connect
            let id = "\(kind.rawValue):\(name)"
            self.resolvedByID[id] = DiscoveredADBService(
                id: id,
                name: name,
                kind: kind,
                host: ip,
                port: UInt16(port)
            )
            self.activeResolvers.removeValue(forKey: id)
            self.publishServices()
        }
    }
}
