import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Network

final class ShareViewController: UIViewController {
    private let model = ShareExtensionModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let rootView = ShareRootView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        Task { await model.loadItems(from: extensionContext) }
    }
}

@MainActor
@Observable
final class ShareExtensionModel {
    var devices: [TaildropDevice] = SharedDeviceStorage.loadDevices(fallback: [])
    var selectedDeviceIDs: Set<TaildropDevice.ID> = []
    var items: [ShareItem] = []
    var statusMessage = "Preparing files..."
    var isSending = false
    var progress: Double = 0
    var transferredBytes: Int64 = 0
    var totalBytes: Int64 = 0

    private let uploader = TailscaleUploader()

    var eligibleDevices: [TaildropDevice] {
        devices.filter { $0.peerAPIURL != nil }
    }

    var canSend: Bool {
        !selectedDeviceIDs.isEmpty && !items.isEmpty && !isSending
    }

    func loadItems(from context: NSExtensionContext?) async {
        let autoSyncIDs = eligibleDevices.filter(\.autoSync).map(\.id)
        selectedDeviceIDs = Set(autoSyncIDs.isEmpty ? eligibleDevices.map(\.id) : autoSyncIDs)
        guard let providers = context?.inputItems
            .compactMap({ $0 as? NSExtensionItem })
            .flatMap({ $0.attachments ?? [] }),
              !providers.isEmpty else {
            statusMessage = "No shareable files found."
            return
        }

        var loadedItems: [ShareItem] = []
        for provider in providers {
            if let item = await loadItem(from: provider) {
                loadedItems.append(item)
            }
        }
        items = loadedItems
        statusMessage = loadedItems.isEmpty ? "No shareable files found." : "\(loadedItems.count) file(s) ready."
    }

    func send(completion: @escaping () -> Void) async {
        guard canSend else { return }
        let targets = devices.filter { selectedDeviceIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        isSending = true
        transferredBytes = 0
        totalBytes = items.reduce(0) { $0 + $1.byteCount } * Int64(max(1, targets.count))
        defer { isSending = false }

        let totalSteps = max(1, items.count * targets.count)
        var completedSteps = 0
        var completedBytes: Int64 = 0
        do {
            for item in items {
                let file = ExportedAssetFile(
                    url: item.url,
                    filename: item.filename,
                    mimeType: item.mimeType,
                    byteCount: item.byteCount
                )
                for device in targets {
                    statusMessage = "Sending \(item.filename) to \(device.name)..."
                    guard let port = await resolvedPeerAPIPort(for: device),
                          let endpoint = TaildropDevice.peerAPIURL(from: device.endpoint, preferredPort: port) else {
                        throw PhotoTransferError.taildropUnavailable
                    }
                    try await uploader.upload(file: file, creationDate: nil, to: endpoint) { sentBytes, totalBytes in
                        await MainActor.run {
                            let currentTotal = totalBytes > 0 ? totalBytes : item.byteCount
                            let itemProgress = currentTotal > 0 ? Double(sentBytes) / Double(currentTotal) : 0
                            self.progress = (Double(completedSteps) + min(0.99, itemProgress)) / Double(totalSteps)
                            self.transferredBytes = completedBytes + sentBytes
                            self.totalBytes = max(self.totalBytes, completedBytes + currentTotal)
                        }
                    }
                    completedSteps += 1
                    completedBytes += item.byteCount
                    transferredBytes = completedBytes
                    progress = Double(completedSteps) / Double(totalSteps)
                }
            }
            statusMessage = "Sent."
            try? await Task.sleep(nanoseconds: 650_000_000)
            completion()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func resolvedPeerAPIPort(for device: TaildropDevice) async -> Int? {
        let address = TaildropDevice.normalizedAddress(from: device.endpoint)
        guard TaildropDevice.isValidAddress(address) else { return nil }
        for port in TaildropDevice.peerAPIPortCandidates(for: address, preferredPort: device.peerAPIPort) {
            if await canOpenTCPConnection(host: address, port: port, timeout: 3) {
                return port
            }
        }
        return nil
    }

    private func canOpenTCPConnection(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 1,
                using: .tcp
            )
            let resumeBox = ShareTCPProbeResumeBox()

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

    private func loadItem(from provider: NSItemProvider) async -> ShareItem? {
        let preferredTypes = [UTType.movie.identifier, UTType.image.identifier, UTType.item.identifier]
        guard let typeIdentifier = preferredTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0) }) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(url.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: url, to: destination)
                    let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                    let mimeType = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
                    continuation.resume(returning: ShareItem(
                        url: destination,
                        filename: destination.lastPathComponent,
                        mimeType: mimeType,
                        byteCount: Int64(values?.fileSize ?? 0)
                    ))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let mimeType: String
    let byteCount: Int64
}

private struct ShareRootView: View {
    @Bindable var model: ShareExtensionModel
    let complete: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ShareStatusCard(model: model)

                    ShareSection(title: "Files") {
                        if model.items.isEmpty {
                            Text("No shareable files found.")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(model.items) { item in
                                ShareFileRow(item: item)
                            }
                        }
                    }

                    ShareSection(title: "Devices") {
                        if model.eligibleDevices.isEmpty {
                            Text("Enable Auto Sync for at least one device in TailSync.")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(model.eligibleDevices) { device in
                                ShareDeviceRow(
                                    device: device,
                                    isSelected: model.selectedDeviceIDs.contains(device.id)
                                ) {
                                    if model.selectedDeviceIDs.contains(device.id) {
                                        model.selectedDeviceIDs.remove(device.id)
                                    } else {
                                        model.selectedDeviceIDs.insert(device.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Send with TailSync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task { await model.send(completion: complete) }
                    }
                    .disabled(!model.canSend)
                }
            }
        }
    }
}

private final class ShareTCPProbeResumeBox: @unchecked Sendable {
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

private struct ShareStatusCard: View {
    let model: ShareExtensionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.isSending ? "paperplane.circle.fill" : "square.and.arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text(model.statusMessage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isSending {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(ShareByteFormat.string(model.transferredBytes)) of \(ShareByteFormat.string(model.totalBytes))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(Int(model.progress * 100))%")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: model.progress)
                        .tint(.blue)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ShareSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline.weight(.bold))
            VStack(spacing: 0) {
                content
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.black.opacity(0.06), lineWidth: 1)
            }
        }
    }
}

private struct ShareFileRow: View {
    let item: ShareItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.filename)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ShareByteFormat.string(item.byteCount))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

private struct ShareDeviceRow: View {
    let device: TaildropDevice
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(device.displayAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum ShareByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
