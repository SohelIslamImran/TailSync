import Foundation

struct ExportedAssetFile: Sendable {
    let url: URL
    let filename: String
    let mimeType: String
    let byteCount: Int64
}

protocol TailscaleUploading: Sendable {
    func upload(
        file: ExportedAssetFile,
        creationDate: Date?,
        to peerAPIBaseURL: URL,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?
    ) async throws
}

struct TailscaleUploader: TailscaleUploading {
    private let session = URLSession(configuration: .default)
    private nonisolated(unsafe) static let dateFormatter = ISO8601DateFormatter()

    func upload(
        file: ExportedAssetFile,
        creationDate: Date?,
        to peerAPIBaseURL: URL,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)? = nil
    ) async throws {
        let uploadURL = try taildropUploadURL(baseURL: peerAPIBaseURL, filename: file.filename)
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(file.filename, forHTTPHeaderField: "Tailscale-File-Name")

        if let creationDate {
            request.setValue(Self.dateFormatter.string(from: creationDate), forHTTPHeaderField: "X-TailSync-Created-At")
        }

        let delegate = UploadProgressDelegate(progress: progress)
        let (_, response) = try await session.upload(for: request, fromFile: file.url, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PhotoTransferError.uploadRejected(statusCode)
        }
    }

    private func taildropUploadURL(baseURL: URL, filename: String) throws -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let escapedFilename = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        let basePath = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""

        if basePath.hasSuffix("v0/put") {
            components?.percentEncodedPath = "/" + basePath + "/" + escapedFilename
        } else if basePath.hasSuffix("v0/put/" + escapedFilename) {
            components?.percentEncodedPath = "/" + basePath
        } else {
            let prefix = basePath.isEmpty ? "v0/put" : basePath + "/v0/put"
            components?.percentEncodedPath = "/" + prefix + "/" + escapedFilename
        }

        guard let url = components?.url else {
            throw PhotoTransferError.invalidTaildropTarget
        }
        return url
    }
}

enum PhotoTransferError: LocalizedError {
    case noResource
    case invalidTaildropTarget
    case taildropUnavailable
    case uploadRejected(Int)

    var errorDescription: String? {
        switch self {
        case .noResource:
            return "No original photo or video resource was available."
        case .invalidTaildropTarget:
            return "The Taildrop PeerAPI target URL is invalid."
        case .taildropUnavailable:
            return "Taildrop is not reachable on this device right now."
        case .uploadRejected(let statusCode):
            return "Taildrop receiver returned HTTP \(statusCode)."
        }
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?
    private var lastEmittedAt = ContinuousClock.now
    private var lastEmittedBytes: Int64 = 0
    private var isValid = true
    private let minimumEmitInterval: Duration = .milliseconds(350)
    private let minimumByteDelta: Int64 = 1_048_576

    init(progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?) {
        self.progress = progress
    }

    func invalidate() {
        lock.lock()
        isValid = false
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let progress, shouldEmitProgress(totalBytesSent: totalBytesSent, totalBytesExpectedToSend: totalBytesExpectedToSend) else { return }
        Task {
            await progress(totalBytesSent, totalBytesExpectedToSend)
        }
    }

    private func shouldEmitProgress(totalBytesSent: Int64, totalBytesExpectedToSend: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isValid else { return false }

        let now = ContinuousClock.now
        let elapsed = lastEmittedAt.duration(to: now)
        let sentDelta = totalBytesSent - lastEmittedBytes
        let isComplete = totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend
        let shouldEmit = isComplete || elapsed >= minimumEmitInterval || sentDelta >= minimumByteDelta
        guard shouldEmit else { return false }

        lastEmittedAt = now
        lastEmittedBytes = totalBytesSent
        return true
    }
}
