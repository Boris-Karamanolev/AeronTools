import Foundation
import Darwin

// MARK: - Network Environment & Hotspot IP Discovery

nonisolated struct NetworkInterfaceAddress: Identifiable, Hashable, Sendable {
    var id: String { "\(interfaceName)-\(ipAddress)" }
    let interfaceName: String
    let ipAddress: String
    let isHotspotBridge: Bool
    let isNonPrivateTeslaCompatible: Bool
}

nonisolated enum NetworkEnvironmentService {
    /// Returns all active IPv4 interface addresses on the Mac, sorted by relevance
    /// (`bridge100` / hotspot interfaces and non-RFC1918 aliases first, then `en0` / `en1`).
    static func activeIPv4Interfaces() -> [NetworkInterfaceAddress] {
        var results: [NetworkInterfaceAddress] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return results
        }
        defer { freeifaddrs(ifaddrPointer) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && !isLoopback, let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("169.254.") {
                        let isBridge = name.hasPrefix("bridge") || name.hasPrefix("ap")
                        let isTeslaNonPrivate = !isRFC1918PrivateIP(ip)
                        results.append(
                            NetworkInterfaceAddress(
                                interfaceName: name,
                                ipAddress: ip,
                                isHotspotBridge: isBridge,
                                isNonPrivateTeslaCompatible: isTeslaNonPrivate
                            )
                        )
                    }
                }
            }
            ptr = interface.ifa_next
        }

        return results.sorted { a, b in
            if a.isNonPrivateTeslaCompatible != b.isNonPrivateTeslaCompatible {
                return a.isNonPrivateTeslaCompatible
            }
            if a.isHotspotBridge != b.isHotspotBridge {
                return a.isHotspotBridge
            }
            return a.interfaceName < b.interfaceName
        }
    }

    /// Tesla's in-car Chromium browser blocks RFC1918 private IPs (`10.x`, `172.16-31.x`, `192.168.x`)
    /// unless routed via a non-RFC1918 alias such as `198.18.0.1` (IANA benchmark block) on `bridge100`.
    static func isRFC1918PrivateIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }

    /// Shell helper script that adds a `198.18.0.1` alias on `bridge100` (macOS Internet Sharing bridge)
    /// and optionally maps port 80 -> `port` via `pfctl` so Tesla browser can open `http://198.18.0.1:\(port)` or `http://198.18.0.1`.
    static func teslaHotspotAliasScript(port: UInt16) -> String {
        let validPort = max(1024, port)
        return """
        sudo ifconfig bridge100 alias 198.18.0.1 netmask 255.255.255.0 up
        echo "rdr pass on bridge100 inet proto tcp from any to 198.18.0.1 port 80 -> 127.0.0.1 port \(validPort)" | sudo pfctl -ef -
        """
    }
}
