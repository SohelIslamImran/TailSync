import Foundation
import Network

struct DeviceReachabilityClient: Sendable {
    func check(device: TaildropDevice) async -> DeviceReachabilityResult {
        let urls = device.peerAPIURLs
        guard !urls.isEmpty else {
            return DeviceReachabilityResult(status: .invalidURL, error: "Enter a valid MagicDNS name or Tailscale IP.", resolvedPort: nil)
        }

        for url in urls {
            guard let host = url.host(), let port = url.port else { continue }
            if await canOpenTCPConnection(host: host, port: port, timeout: 3) {
                return DeviceReachabilityResult(status: .online, error: nil, resolvedPort: port)
            }
        }

        return DeviceReachabilityResult(
            status: .taildropUnavailable,
            error: "Taildrop is not reachable from this iPhone.",
            resolvedPort: nil
        )
    }

    private func canOpenTCPConnection(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 1,
                using: .tcp
            )
            let resumeBox = TCPProbeResumeBox()

            let finish: @Sendable (Bool) -> Void = { value in
                guard resumeBox.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }
}

struct DeviceReachabilityResult: Sendable {
    let status: DeviceStatus
    let error: String?
    let resolvedPort: Int?
}

private final class TCPProbeResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}
