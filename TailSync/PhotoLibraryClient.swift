import Foundation
import Photos
import UniformTypeIdentifiers

struct ExportedAssetFile: Sendable {
    let url: URL
    let filename: String
    let mimeType: String
    let byteCount: Int64
}

struct PhotoAssetSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let filename: String
    let mediaType: String
    let creationDate: Date?
    let byteCount: Int64?
}

struct PhotoAlbumSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
}

final class PhotoLibraryClient: @unchecked Sendable {
    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func countTransferableAssets() async -> Int {
        fetchTransferableAssets().count
    }

    func fetchTransferableAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        return PHAsset.fetchAssets(with: options)
    }

    func snapshots(for assets: [PHAsset]) -> [PhotoAssetSnapshot] {
        assets.map { asset in
            PhotoAssetSnapshot(
                id: asset.localIdentifier,
                filename: originalFilename(for: asset),
                mediaType: asset.mediaType == .video ? "Video" : "Photo",
                creationDate: asset.creationDate,
                byteCount: byteCount(for: asset)
            )
        }
    }

    func exportOriginalResource(for asset: PHAsset) async throws -> ExportedAssetFile {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { resource in
            switch resource.type {
            case .photo, .video, .fullSizePhoto, .fullSizeVideo:
                return true
            default:
                return false
            }
        }) else {
            throw PhotoTransferError.noResource
        }

        let filename = sanitizedFilename(resource.originalFilename, fallbackExtension: fallbackExtension(for: asset))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return ExportedAssetFile(
            url: destination,
            filename: filename,
            mimeType: mimeType(for: destination),
            byteCount: fileSize(for: destination)
        )
    }

    func delete(asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    func asset(for localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    func userAlbumSummaries() -> [PhotoAlbumSummary] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var albums: [PhotoAlbumSummary] = []
        albums.reserveCapacity(collections.count)
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            guard count > 0 else { return }
            albums.append(
                PhotoAlbumSummary(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled Album",
                    assetCount: count
                )
            )
        }
        return albums.sorted { lhs, rhs in
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    func asset(_ asset: PHAsset, isInAnyAlbum albumIDs: Set<String>) -> Bool {
        guard !albumIDs.isEmpty else { return false }
        let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var isIgnored = false
        collections.enumerateObjects { collection, _, stop in
            if albumIDs.contains(collection.localIdentifier) {
                isIgnored = true
                stop.pointee = true
            }
        }
        return isIgnored
    }

    private func fallbackExtension(for asset: PHAsset) -> String {
        asset.mediaType == .video ? "mov" : "jpg"
    }

    private func originalFilename(for asset: PHAsset) -> String {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { resource in
            switch resource.type {
            case .photo, .video, .fullSizePhoto, .fullSizeVideo:
                return true
            default:
                return false
            }
        }) else {
            return "\(asset.localIdentifier.replacingOccurrences(of: "/", with: "_")).\(fallbackExtension(for: asset))"
        }
        return sanitizedFilename(resource.originalFilename, fallbackExtension: fallbackExtension(for: asset))
    }

    private func byteCount(for asset: PHAsset) -> Int64? {
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { resource in
            switch resource.type {
            case .photo, .video, .fullSizePhoto, .fullSizeVideo:
                return true
            default:
                return false
            }
        }) else {
            return nil
        }
        return resource.value(forKey: "fileSize") as? Int64
    }

    private func sanitizedFilename(_ filename: String, fallbackExtension: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "\(UUID().uuidString).\(fallbackExtension)" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return base.components(separatedBy: invalidCharacters).joined(separator: "_")
    }

    private func mimeType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }

    private func fileSize(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
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
