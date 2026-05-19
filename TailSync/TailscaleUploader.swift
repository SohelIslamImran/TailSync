import Foundation
import Photos

protocol TailscaleUploading: Sendable {
    func upload(
        file: ExportedAssetFile,
        asset: PHAsset?,
        to peerAPIBaseURL: URL,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?
    ) async throws
}

struct TailscaleUploader: TailscaleUploading {
    func upload(
        file: ExportedAssetFile,
        asset: PHAsset?,
        to peerAPIBaseURL: URL,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)? = nil
    ) async throws {
        let uploadURL = try taildropUploadURL(baseURL: peerAPIBaseURL, filename: file.filename)
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(file.filename, forHTTPHeaderField: "Tailscale-File-Name")

        if let creationDate = asset?.creationDate {
            request.setValue(ISO8601DateFormatter().string(from: creationDate), forHTTPHeaderField: "X-TailSync-Created-At")
        }

        let delegate = UploadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
            delegate.invalidate()
        }

        let (_, response) = try await session.upload(for: request, fromFile: file.url)
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

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?
    private var isValid = true

    init(progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?) {
        self.progress = progress
    }

    func invalidate() {
        isValid = false
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard isValid, let progress else { return }
        Task {
            await progress(totalBytesSent, totalBytesExpectedToSend)
        }
    }
}
