import Foundation
import Darwin

enum TransferStatus: String, Codable, Sendable {
    case pending
    case sending
    case sent
    case failed
    case deleted

    var title: String {
        switch self {
        case .pending: "Pending"
        case .sending: "Sending"
        case .sent: "Sent"
        case .failed: "Failed"
        case .deleted: "Deleted"
        }
    }
}

struct TransferRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var filename: String
    var mediaType: String
    var creationDate: Date?
    var status: TransferStatus
    var progress: Double
    var byteCount: Int64?
    var transferredByteCount: Int64
    var attempts: Int
    var sentAt: Date?
    var deletedAt: Date?
    var deleteAfter: Date?
    var sentDeviceIDs: Set<String>
    var lastError: String?

    var isTerminalSuccess: Bool {
        status == .sent || status == .deleted
    }

    init(
        id: String,
        filename: String,
        mediaType: String,
        creationDate: Date?,
        status: TransferStatus,
        progress: Double,
        byteCount: Int64?,
        transferredByteCount: Int64,
        attempts: Int,
        sentAt: Date?,
        deletedAt: Date?,
        deleteAfter: Date?,
        sentDeviceIDs: Set<String>,
        lastError: String?
    ) {
        self.id = id
        self.filename = filename
        self.mediaType = mediaType
        self.creationDate = creationDate
        self.status = status
        self.progress = progress
        self.byteCount = byteCount
        self.transferredByteCount = transferredByteCount
        self.attempts = attempts
        self.sentAt = sentAt
        self.deletedAt = deletedAt
        self.deleteAfter = deleteAfter
        self.sentDeviceIDs = sentDeviceIDs
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        filename = try container.decode(String.self, forKey: .filename)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
        status = try container.decode(TransferStatus.self, forKey: .status)
        progress = try container.decode(Double.self, forKey: .progress)
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount)
        transferredByteCount = try container.decodeIfPresent(Int64.self, forKey: .transferredByteCount) ?? 0
        attempts = try container.decode(Int.self, forKey: .attempts)
        sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        deleteAfter = try container.decodeIfPresent(Date.self, forKey: .deleteAfter)
        sentDeviceIDs = try container.decodeIfPresent(Set<String>.self, forKey: .sentDeviceIDs) ?? []
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }
}

enum AutoDeleteDelay: String, CaseIterable, Codable, Sendable, Identifiable {
    case never
    case immediately
    case oneDay
    case oneWeek
    case fifteenDays
    case thirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: "Never"
        case .immediately: "Immediately"
        case .oneDay: "24 hours"
        case .oneWeek: "1 week"
        case .fifteenDays: "15 days"
        case .thirtyDays: "30 days"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never: nil
        case .immediately: 0
        case .oneDay: 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .fifteenDays: 15 * 24 * 60 * 60
        case .thirtyDays: 30 * 24 * 60 * 60
        }
    }
}

enum DeviceStatus: String, Codable, Sendable {
    case unknown
    case checking
    case online
    case offline
    case taildropUnavailable
    case invalidURL

    var title: String {
        switch self {
        case .unknown: "Configured"
        case .checking: "Checking"
        case .online: "Reachable"
        case .offline, .taildropUnavailable: "Taildrop Unavailable"
        case .invalidURL: "Invalid URL"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: "checkmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath.circle.fill"
        case .online: "checkmark.circle.fill"
        case .offline, .taildropUnavailable: "exclamationmark.triangle.fill"
        case .invalidURL: "exclamationmark.triangle.fill"
        }
    }
}

struct TaildropDevice: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var endpoint: String
    var peerAPIPort: Int?
    var autoSync: Bool
    var status: DeviceStatus
    var lastCheckedAt: Date?
    var lastReachableAt: Date?
    var lastError: String?

    init(
        id: String,
        name: String,
        endpoint: String,
        peerAPIPort: Int? = nil,
        autoSync: Bool,
        status: DeviceStatus = .unknown,
        lastCheckedAt: Date? = nil,
        lastReachableAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.peerAPIPort = peerAPIPort
        self.autoSync = autoSync
        self.status = status
        self.lastCheckedAt = lastCheckedAt
        self.lastReachableAt = lastReachableAt
        self.lastError = lastError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        peerAPIPort = try container.decodeIfPresent(Int.self, forKey: .peerAPIPort)
        autoSync = try container.decode(Bool.self, forKey: .autoSync)
        let decodedStatus = try container.decodeIfPresent(DeviceStatus.self, forKey: .status) ?? .unknown
        status = decodedStatus == .offline ? .taildropUnavailable : decodedStatus
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastReachableAt = try container.decodeIfPresent(Date.self, forKey: .lastReachableAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    static let sampleDevice = TaildropDevice(
        id: "sample-device",
        name: "My Taildrop Device",
        endpoint: "device-name.example.ts.net",
        autoSync: false
    )
}

extension TaildropDevice {
    var displayAddress: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var peerAPIURL: URL? {
        Self.peerAPIURL(from: endpoint, preferredPort: peerAPIPort)
    }

    var peerAPIURLs: [URL] {
        Self.peerAPIURLs(from: endpoint, preferredPort: peerAPIPort)
    }

    static func normalizedAddress(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased()
    }

    static func isValidAddress(_ rawValue: String) -> Bool {
        let address = normalizedAddress(from: rawValue)
        guard !address.isEmpty else { return false }
        guard !address.contains("://"),
              !address.contains("/"),
              !address.contains(":"),
              !address.contains(" ") else {
            return false
        }
        return true
    }

    static func peerAPIURL(from rawValue: String, preferredPort: Int? = nil) -> URL? {
        peerAPIURLs(from: rawValue, preferredPort: preferredPort).first
    }

    static func peerAPIURLs(from rawValue: String, preferredPort: Int? = nil) -> [URL] {
        let address = normalizedAddress(from: rawValue)
        guard isValidAddress(address) else { return [] }
        let ports = peerAPIPortCandidates(for: address, preferredPort: preferredPort)
        return ports.compactMap { URL(string: "http://\(address):\($0)") }
    }

    static func peerAPIPortCandidates(for address: String, preferredPort: Int? = nil) -> [Int] {
        var ports: [Int] = []
        if let preferredPort, (1...65535).contains(preferredPort) {
            ports.append(preferredPort)
        }
        ports.append(1)
        ports.append(contentsOf: deterministicPeerAPIPorts(for: address))
        return Array(NSOrderedSet(array: ports)) as? [Int] ?? ports
    }

    private static func deterministicPeerAPIPorts(for address: String) -> [Int] {
        guard let bytes = ipv4Bytes(from: address) ?? resolveIPv4Bytes(for: address),
              bytes.count == 4 else {
            return []
        }
        return (0..<5).map { attempt in
            var hashBytes = Array(bytes.suffix(3))
            hashBytes[0] &+= UInt8(attempt)
            let checksum = crc32IEEE(hashBytes)
            return Int(UInt16(32 << 10) | UInt16(truncatingIfNeeded: checksum))
        }
    }

    private static func ipv4Bytes(from address: String) -> [UInt8]? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private static func resolveIPv4Bytes(for host: String) -> [UInt8]? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
        defer { freeaddrinfo(result) }
        let sockaddr = result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        let raw = sockaddr.sin_addr.s_addr.bigEndian
        return [
            UInt8((raw >> 24) & 0xff),
            UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff),
            UInt8(raw & 0xff)
        ]
    }

    private static func crc32IEEE(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            var current = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                if current & 1 == 1 {
                    current = 0xedb88320 ^ (current >> 1)
                } else {
                    current >>= 1
                }
            }
            crc = (crc >> 8) ^ current
        }
        return crc ^ 0xffffffff
    }
}

struct TransferManifest: Codable, Sendable {
    var records: [String: TransferRecord] = [:]
}
