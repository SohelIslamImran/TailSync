import Foundation
import Observation
import Photos
import UIKit
import BackgroundTasks
import UniformTypeIdentifiers

@Observable
final class TransferStore: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    var devices: [TaildropDevice] {
        didSet { saveDevices() }
    }

    var autoDeleteDelay: AutoDeleteDelay {
        didSet { UserDefaults.standard.set(autoDeleteDelay.rawValue, forKey: autoDeleteDelayKey) }
    }

    var smartDeleteEnabled: Bool {
        didSet { UserDefaults.standard.set(smartDeleteEnabled, forKey: smartDeleteKey) }
    }

    private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    private(set) var pendingCount = 0
    private(set) var transferredCount = 0
    private(set) var deletedCount = 0
    private(set) var failedCount = 0
    private(set) var isRunning = false
    private(set) var statusMessage = ""
    private(set) var records: [TransferRecord] = []
    private(set) var currentFilename: String?
    private(set) var currentAssetID: String?
    private(set) var currentAssetIsVideo = false
    private(set) var currentTargetName: String?
    private(set) var currentProgress: Double = 0
    private(set) var currentTransferredBytes: Int64 = 0
    private(set) var currentTotalBytes: Int64 = 0

    private let photoLibrary: PhotoLibraryClient
    private let uploader: TailscaleUploading
    private let reachabilityClient: DeviceReachabilityClient
    private let manifestStore: TransferManifestStore
    private let notificationClient: NotificationClient
    private var transferTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var photoChangeTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var didRegisterBackgroundTasks = false
    private var didRequestNotificationAuthorization = false
    private var unavailableNotificationDates: [TaildropDevice.ID: Date] = [:]

    private let autoDeleteDelayKey = "autoDeleteDelay"
    private let smartDeleteKey = "smartDeleteEnabled"
    private let backgroundRefreshIdentifier = Bundle.main.object(forInfoDictionaryKey: "TailSyncBackgroundRefreshIdentifier") as? String ?? ""
    private let minimumTransferRetryDelaySeconds: UInt64 = 90
    private let maximumTransferRetryDelaySeconds: UInt64 = 15 * 60

    init(
        photoLibrary: PhotoLibraryClient,
        uploader: TailscaleUploading,
        reachabilityClient: DeviceReachabilityClient = DeviceReachabilityClient(),
        manifestStore: TransferManifestStore = TransferManifestStore(),
        notificationClient: NotificationClient = NotificationClient()
    ) {
        self.photoLibrary = photoLibrary
        self.uploader = uploader
        self.reachabilityClient = reachabilityClient
        self.manifestStore = manifestStore
        self.notificationClient = notificationClient
        self.devices = SharedDeviceStorage.loadDevices(fallback: [])
        self.autoDeleteDelay = AutoDeleteDelay(rawValue: UserDefaults.standard.string(forKey: autoDeleteDelayKey) ?? "") ?? .never
        self.smartDeleteEnabled = UserDefaults.standard.bool(forKey: smartDeleteKey)
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        transferTask?.cancel()
        retryTask?.cancel()
        photoChangeTask?.cancel()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var canStartTransfer: Bool {
        isAuthorized && !isRunning && !activeDevices.isEmpty
    }

    var activeDevices: [TaildropDevice] {
        devices.filter { device in
            device.autoSync && device.peerAPIURL != nil
        }
    }

    var targetSummary: String {
        let activeCount = activeDevices.count
        if activeCount == 1, let device = activeDevices.first {
            return device.name
        }
        return "\(activeCount) devices"
    }

    var pendingRecords: [TransferRecord] {
        records.filter { $0.status == .pending || $0.status == .sending }
    }

    var failedRecords: [TransferRecord] {
        records.filter { $0.status == .failed }
    }

    var sentRecords: [TransferRecord] {
        records.filter { $0.status == .sent || $0.status == .deleted }
    }

    var totalByteCount: Int64 {
        records.reduce(0) { $0 + ($1.byteCount ?? 0) }
    }

    var completedByteCount: Int64 {
        records.reduce(0) { total, record in
            switch record.status {
            case .sent, .deleted:
                return total + (record.byteCount ?? record.transferredByteCount)
            case .sending:
                return total + record.transferredByteCount
            case .pending, .failed:
                return total
            }
        }
    }

    var authorizationSummary: String {
        switch authorizationStatus {
        case .authorized:
            return "Full photo access granted"
        case .limited:
            return "Limited photo access granted"
        case .denied, .restricted:
            return "Photo access denied"
        case .notDetermined:
            return "Photo access not requested"
        @unknown default:
            return "Unknown photo access state"
        }
    }

    @MainActor
    func refreshAuthorizationAndCounts() async {
        authorizationStatus = photoLibrary.authorizationStatus()
        if !didRequestNotificationAuthorization {
            didRequestNotificationAuthorization = true
            await notificationClient.requestAuthorization()
        }
        registerBackgroundTasks()
        guard isAuthorized else {
            pendingCount = 0
            scheduleBackgroundRefreshIfNeeded()
            return
        }

        await rebuildManifestFromLibrary()
        await processDueDeletions()
        await refreshDeviceStatuses(devicesToCheck: activeDevices)
        if !activeDevices.isEmpty {
            await startTransfer()
        }
        scheduleBackgroundRefreshIfNeeded()
    }

    @MainActor
    func requestPhotoAccess() async {
        authorizationStatus = await photoLibrary.requestAuthorization()
        await refreshAuthorizationAndCounts()
    }

    @MainActor
    func startTransfer() async {
        guard !isRunning else { return }
        retryTask?.cancel()
        retryTask = nil
        let syncDevices = activeDevices
        guard !syncDevices.isEmpty else {
            statusMessage = "Add or enable at least one Taildrop device."
            return
        }
        guard isAuthorized else {
            statusMessage = "Photo access is required before transferring."
            return
        }

        isRunning = true
        statusMessage = "Preparing library..."
        currentProgress = 0
        currentTransferredBytes = 0
        currentTotalBytes = 0
        currentAssetID = nil
        currentAssetIsVideo = false

        transferTask = Task { [photoLibrary, manifestStore, notificationClient] in
            let assets = photoLibrary.fetchTransferableAssets()
            let snapshots = photoLibrary.snapshots(for: assets)
            await self.mergeSnapshots(snapshots)

            let assetByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
            let allRecords = await manifestStore.allRecords()
            let activeDeviceIDs = Set(syncDevices.map(\.id))
            let unsentRecords = allRecords.filter { record in
                !record.isTerminalSuccess || !activeDeviceIDs.isSubset(of: record.sentDeviceIDs)
            }
            await MainActor.run {
                self.applyRecords(allRecords)
                self.statusMessage = "Found \(unsentRecords.count) item(s) waiting."
            }

            for var record in unsentRecords {
                if Task.isCancelled { break }
                guard let asset = assetByID[record.id] else { continue }

                do {
                    record.status = .sending
                    record.progress = 0.05
                    record.attempts += 1
                    record.lastError = nil
                    try await manifestStore.upsert(record)
                    await MainActor.run {
                        self.currentFilename = record.filename
                        self.currentAssetID = record.id
                        self.currentAssetIsVideo = record.mediaType == "Video"
                        self.currentProgress = record.progress
                        self.applyUpdatedRecord(record)
                    }

                    let file = try await photoLibrary.exportOriginalResource(for: asset)
                    record.filename = file.filename
                    record.byteCount = file.byteCount
                    record.transferredByteCount = 0
                    record.progress = 0
                    try await manifestStore.upsert(record)
                    await MainActor.run {
                        self.currentFilename = record.filename
                        self.currentProgress = record.progress
                        self.currentTransferredBytes = 0
                        self.currentTotalBytes = file.byteCount
                        self.applyUpdatedRecord(record)
                    }

                    for device in syncDevices where !record.sentDeviceIDs.contains(device.id) {
                        let uploadingRecord = record
                        await MainActor.run {
                            self.currentTargetName = device.name
                        }
                        do {
                            try await self.upload(file: file, asset: asset, to: device) { sentBytes, totalBytes in
                                var progressRecord = uploadingRecord
                                progressRecord.transferredByteCount = sentBytes
                                progressRecord.byteCount = totalBytes > 0 ? totalBytes : file.byteCount
                                progressRecord.progress = progressRecord.byteCount.map { total in
                                    guard total > 0 else { return 0 }
                                    return min(0.99, Double(sentBytes) / Double(total))
                                } ?? 0
                                await MainActor.run {
                                    self.currentTransferredBytes = sentBytes
                                    self.currentTotalBytes = progressRecord.byteCount ?? file.byteCount
                                    self.currentProgress = progressRecord.progress
                                    self.applyUpdatedRecord(progressRecord)
                                }
                            }
                            await self.markDevice(device.id, status: .online, error: nil, notifyIfUnavailable: false)
                        } catch {
                            await self.markDevice(device.id, status: .taildropUnavailable, error: error.localizedDescription, notifyIfUnavailable: device.autoSync)
                            throw error
                        }
                        record.sentDeviceIDs.insert(device.id)
                        record.transferredByteCount = file.byteCount
                        try await manifestStore.upsert(record)
                    }
                    record.status = .sent
                    record.progress = 1
                    record.transferredByteCount = file.byteCount
                    record.byteCount = file.byteCount
                    record.sentAt = Date()
                    if await self.shouldDeleteImmediately() {
                        try await photoLibrary.delete(asset: asset)
                        record.status = .deleted
                        record.deletedAt = Date()
                        record.deleteAfter = nil
                    } else {
                        record.deleteAfter = await self.deleteDateAfterSuccessfulTransfer()
                    }
                    try? FileManager.default.removeItem(at: file.url)
                    try await manifestStore.upsert(record)

                    await MainActor.run {
                        self.applyUpdatedRecord(record)
                        self.currentFilename = nil
                        self.currentAssetID = nil
                        self.currentAssetIsVideo = false
                        self.currentTargetName = nil
                        self.currentProgress = 0
                        self.currentTransferredBytes = 0
                        self.currentTotalBytes = 0
                        if record.status == .deleted {
                            self.statusMessage = "Taildropped \(file.filename), then deleted it from Photos."
                        } else {
                            self.statusMessage = "Taildropped \(file.filename)."
                        }
                    }
                } catch {
                    record.status = .failed
                    record.progress = 0
                    record.lastError = error.localizedDescription
                    try? await manifestStore.upsert(record)
                    await notificationClient.notifyFailure(filename: record.filename, reason: error.localizedDescription)
                    await MainActor.run {
                        self.applyUpdatedRecord(record)
                        self.currentFilename = nil
                        self.currentAssetID = nil
                        self.currentAssetIsVideo = false
                        self.currentTargetName = nil
                        self.currentProgress = 0
                        self.currentTransferredBytes = 0
                        self.currentTotalBytes = 0
                        self.statusMessage = "Transfer failed: \(error.localizedDescription)"
                        self.transferTask?.cancel()
                        self.scheduleTransferRetry(reason: error.localizedDescription)
                    }
                    break
                }
            }

            await MainActor.run {
                self.isRunning = false
                self.transferTask = nil
                self.currentFilename = nil
                self.currentAssetID = nil
                self.currentAssetIsVideo = false
                self.currentTargetName = nil
                self.currentProgress = 0
                self.currentTransferredBytes = 0
                self.currentTotalBytes = 0
                self.endBackgroundContinuationIfIdle()
                if Task.isCancelled {
                    self.statusMessage = "Transfer stopped."
                } else {
                    self.statusMessage = "Transfer pass complete."
                }
            }
        }
    }

    @MainActor
    func stopTransfer() {
        transferTask?.cancel()
        retryTask?.cancel()
        retryTask = nil
        transferTask = nil
        isRunning = false
        endBackgroundContinuationIfIdle()
        statusMessage = "Stopping transfer..."
    }

    @MainActor
    func retryFailed() async {
        let updated = failedRecords.map { record in
            var copy = record
            copy.status = .pending
            copy.progress = 0
            copy.transferredByteCount = 0
            copy.lastError = nil
            return copy
        }
        try? await manifestStore.upsert(updated)
        let allRecords = await manifestStore.allRecords()
        applyRecords(allRecords)
        await startTransfer()
    }

    @MainActor
    func resendAllSent() async {
        let updated = sentRecords.map { record in
            var copy = record
            copy.status = .pending
            copy.progress = 0
            copy.transferredByteCount = 0
            copy.sentAt = nil
            copy.deletedAt = nil
            copy.deleteAfter = nil
            copy.sentDeviceIDs = []
            copy.lastError = nil
            return copy
        }
        try? await manifestStore.upsert(updated)
        applyRecords(await manifestStore.allRecords())
        await startTransfer()
    }

    @MainActor
    func sendFile(url: URL) async {
        await sendFile(url: url, to: activeDevices)
    }

    @MainActor
    func sendFile(url: URL, to syncDevices: [TaildropDevice]) async {
        guard !syncDevices.isEmpty else {
            statusMessage = "Choose at least one device first."
            return
        }
        isRunning = true
        currentFilename = url.lastPathComponent
        currentProgress = 0
        currentTransferredBytes = 0
        currentTotalBytes = fileSize(for: url)
        currentAssetID = nil
        currentAssetIsVideo = false
        defer {
            isRunning = false
            currentFilename = nil
            currentAssetID = nil
            currentAssetIsVideo = false
            currentTargetName = nil
            currentProgress = 0
            currentTransferredBytes = 0
            currentTotalBytes = 0
        }

        let file = ExportedAssetFile(
            url: url,
            filename: url.lastPathComponent,
            mimeType: mimeType(for: url),
            byteCount: fileSize(for: url)
        )

        do {
            for device in syncDevices {
                currentTargetName = device.name
                do {
                    try await upload(file: file, asset: nil, to: device) { sentBytes, totalBytes in
                        await MainActor.run {
                            self.currentTransferredBytes = sentBytes
                            self.currentTotalBytes = totalBytes > 0 ? totalBytes : file.byteCount
                            self.currentProgress = self.currentTotalBytes > 0 ? min(0.99, Double(sentBytes) / Double(self.currentTotalBytes)) : 0
                        }
                    }
                    await markDevice(device.id, status: .online, error: nil, notifyIfUnavailable: false)
                } catch {
                    await markDevice(device.id, status: .taildropUnavailable, error: error.localizedDescription, notifyIfUnavailable: device.autoSync)
                    throw error
                }
            }
            statusMessage = "Sent \(file.filename)."
        } catch {
            statusMessage = "File send failed: \(error.localizedDescription)"
            await notificationClient.notifyFailure(filename: file.filename, reason: error.localizedDescription)
        }
    }

    @MainActor
    func resend(recordID: TransferRecord.ID) async {
        guard var record = records.first(where: { $0.id == recordID }) else { return }
        record.status = .pending
        record.progress = 0
        record.transferredByteCount = 0
        record.sentAt = nil
        record.deletedAt = nil
        record.deleteAfter = nil
        record.sentDeviceIDs = []
        record.lastError = nil
        try? await manifestStore.upsert(record)
        applyUpdatedRecord(record)
        await startTransfer()
    }

    @MainActor
    func beginBackgroundContinuation() {
        guard isRunning, backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "TailSyncTransfer") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundContinuationIfIdle()
            }
        }
    }

    @MainActor
    func addDevice() {
        devices.append(TaildropDevice(id: UUID().uuidString, name: "New Device", endpoint: "", autoSync: false))
    }

    @MainActor
    func addDevice(_ device: TaildropDevice) {
        devices.append(device)
    }

    @MainActor
    func removeDevice(_ id: TaildropDevice.ID) {
        devices.removeAll { $0.id == id }
    }

    @MainActor
    func updateDevice(_ device: TaildropDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
    }

    @MainActor
    func checkDeviceStatus(_ id: TaildropDevice.ID) async {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        markDeviceLocally(id, status: .checking, error: nil)
        let result = await reachabilityClient.check(device: device)
        if let resolvedPort = result.resolvedPort {
            rememberPeerAPIPort(resolvedPort, for: id)
        }
        await markDevice(id, status: result.status, error: result.error, notifyIfUnavailable: device.autoSync)
    }

    @MainActor
    func refreshDeviceStatuses() async {
        await refreshDeviceStatuses(devicesToCheck: devices)
    }

    @MainActor
    private func refreshDeviceStatuses(devicesToCheck: [TaildropDevice]) async {
        for device in devicesToCheck {
            guard !Task.isCancelled else { return }
            await checkDeviceStatus(device.id)
        }
    }

    @MainActor
    private func scheduleTransferRetry(reason: String) {
        guard retryTask == nil else { return }
        statusMessage = "Transfer paused. Rechecking devices soon."
        retryTask = Task { [weak self] in
            var retryDelaySeconds = self?.minimumTransferRetryDelaySeconds ?? 90
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(retryDelaySeconds))
                await MainActor.run {
                    self?.statusMessage = "Rechecking Taildrop devices..."
                }
                guard let self else { return }
                let devicesToCheck = await MainActor.run { self.activeDevices }
                await self.refreshDeviceStatuses(devicesToCheck: devicesToCheck)
                let shouldResume = await MainActor.run {
                    self.isAuthorized && !self.isRunning && !self.activeDevices.isEmpty && self.hasRetryableWork
                }
                if shouldResume {
                    await MainActor.run {
                        self.retryTask = nil
                        self.statusMessage = "Device reachable. Resuming transfer..."
                    }
                    await self.retryFailed()
                    return
                }
                retryDelaySeconds = min(
                    retryDelaySeconds * 2,
                    self.maximumTransferRetryDelaySeconds
                )
                await MainActor.run {
                    let minutes = max(1, Int(ceil(Double(retryDelaySeconds) / 60.0)))
                    self.statusMessage = "Transfer paused. Next device check in about \(minutes) min."
                }
            }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        photoChangeTask?.cancel()
        photoChangeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await rebuildManifestFromLibrary()
            if !activeDevices.isEmpty {
                await startTransfer()
            }
            scheduleBackgroundRefreshIfNeeded()
        }
    }

    @MainActor
    private func rebuildManifestFromLibrary() async {
        let assets = photoLibrary.fetchTransferableAssets()
        let snapshots = photoLibrary.snapshots(for: assets)
        await mergeSnapshots(snapshots)
        let allRecords = await manifestStore.allRecords()
        applyRecords(allRecords)
    }

    @MainActor
    private func mergeSnapshots(_ snapshots: [PhotoAssetSnapshot]) async {
        let existing = await manifestStore.allRecords()
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let newRecords = snapshots.compactMap { snapshot -> TransferRecord? in
            if let record = existingByID[snapshot.id] {
                return record
            }
            return TransferRecord(
                id: snapshot.id,
                filename: snapshot.filename,
                mediaType: snapshot.mediaType,
                creationDate: snapshot.creationDate,
                status: .pending,
                progress: 0,
                byteCount: snapshot.byteCount,
                transferredByteCount: 0,
                attempts: 0,
                sentAt: nil,
                deletedAt: nil,
                deleteAfter: nil,
                sentDeviceIDs: [],
                lastError: nil
            )
        }
        if !newRecords.isEmpty {
            try? await manifestStore.upsert(newRecords)
        }
    }

    @MainActor
    private func applyUpdatedRecord(_ record: TransferRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
            recomputeRecordCounts()
        } else {
            records.append(record)
            records.sort(by: recordSortOrder)
            recomputeRecordCounts()
        }
    }

    @MainActor
    private func applyRecords(_ loadedRecords: [TransferRecord]) {
        records = loadedRecords.sorted(by: recordSortOrder)
        recomputeRecordCounts()
    }

    private func recordSortOrder(_ lhs: TransferRecord, _ rhs: TransferRecord) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?):
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.filename < rhs.filename
        }
    }

    @MainActor
    private func recomputeRecordCounts() {
        pendingCount = records.filter { $0.status == .pending || $0.status == .sending }.count
        transferredCount = records.filter { $0.status == .sent || $0.status == .deleted }.count
        deletedCount = records.filter { $0.status == .deleted }.count
        failedCount = records.filter { $0.status == .failed }.count
    }

    @MainActor
    private func markDevice(
        _ id: TaildropDevice.ID,
        status: DeviceStatus,
        error: String?,
        notifyIfUnavailable: Bool
    ) async {
        let oldStatus = devices.first(where: { $0.id == id })?.status ?? .unknown
        markDeviceLocally(id, status: status, error: error)

        guard notifyIfUnavailable,
              status == .taildropUnavailable || status == .invalidURL,
              oldStatus != status,
              let device = devices.first(where: { $0.id == id }),
              shouldNotifyUnavailableDevice(id) else {
            return
        }

        unavailableNotificationDates[id] = Date()
        await notificationClient.notifyDeviceUnavailable(
            deviceName: device.name,
            reason: error ?? status.title
        )
    }

    @MainActor
    private func markDeviceLocally(_ id: TaildropDevice.ID, status: DeviceStatus, error: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].status = status
        devices[index].lastCheckedAt = Date()
        devices[index].lastError = error
        if status == .online {
            devices[index].lastReachableAt = Date()
        }
    }

    private var hasRetryableWork: Bool {
        records.contains { $0.status == .failed || $0.status == .pending || $0.status == .sending }
    }

    @MainActor
    private func upload(
        file: ExportedAssetFile,
        asset: PHAsset?,
        to device: TaildropDevice,
        progress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) async -> Void)?
    ) async throws {
        let currentDevice = devices.first(where: { $0.id == device.id }) ?? device
        let result = await reachabilityClient.check(device: currentDevice)
        guard result.status == .online,
              let port = result.resolvedPort,
              let endpoint = TaildropDevice.peerAPIURL(from: currentDevice.endpoint, preferredPort: port) else {
            throw PhotoTransferError.taildropUnavailable
        }
        rememberPeerAPIPort(port, for: device.id)
        try await uploader.upload(file: file, asset: asset, to: endpoint, progress: progress)
    }

    @MainActor
    private func rememberPeerAPIPort(_ port: Int, for id: TaildropDevice.ID) {
        guard let index = devices.firstIndex(where: { $0.id == id }),
              devices[index].peerAPIPort != port else { return }
        devices[index].peerAPIPort = port
    }

    private func shouldNotifyUnavailableDevice(_ id: TaildropDevice.ID) -> Bool {
        guard let lastDate = unavailableNotificationDates[id] else { return true }
        return Date().timeIntervalSince(lastDate) > 60 * 60
    }

    @MainActor
    private func endBackgroundContinuationIfIdle() {
        guard backgroundTaskID != .invalid, !isRunning else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    @MainActor
    private func shouldDeleteImmediately() async -> Bool {
        if smartDeleteEnabled, isStorageLow {
            return true
        }
        return autoDeleteDelay == .immediately
    }

    @MainActor
    private func deleteDateAfterSuccessfulTransfer() async -> Date? {
        if smartDeleteEnabled, isStorageLow {
            return Date().addingTimeInterval(24 * 60 * 60)
        }
        guard let interval = autoDeleteDelay.interval else { return nil }
        return Date().addingTimeInterval(interval)
    }

    @MainActor
    private func processDueDeletions() async {
        let now = Date()
        var updatedRecords: [TransferRecord] = []
        for var record in records where record.status == .sent {
            guard let deleteAfter = record.deleteAfter, deleteAfter <= now,
                  let asset = photoLibrary.asset(for: record.id) else { continue }
            do {
                try await photoLibrary.delete(asset: asset)
                record.status = .deleted
                record.deletedAt = now
                record.deleteAfter = nil
                updatedRecords.append(record)
            } catch {
                record.lastError = error.localizedDescription
                updatedRecords.append(record)
            }
        }
        try? await manifestStore.upsert(updatedRecords)
        if !updatedRecords.isEmpty {
            applyRecords(await manifestStore.allRecords())
        }
    }

    private var isStorageLow: Bool {
        guard let values = try? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return false
        }
        return available < 5_000_000_000
    }

    @MainActor
    private func registerBackgroundTasks() {
        guard !didRegisterBackgroundTasks, !backgroundRefreshIdentifier.isEmpty else { return }
        didRegisterBackgroundTasks = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshIdentifier, using: nil) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await self.handleBackgroundRefresh(refreshTask)
            }
        }
    }

    @MainActor
    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) async {
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.stopTransfer() }
        }
        await refreshAuthorizationAndCounts()
        task.setTaskCompleted(success: true)
    }

    @MainActor
    private func scheduleBackgroundRefreshIfNeeded() {
        guard shouldScheduleBackgroundRefresh else { return }
        scheduleBackgroundRefresh()
    }

    @MainActor
    private var shouldScheduleBackgroundRefresh: Bool {
        isAuthorized && (!activeDevices.isEmpty || hasPendingDeleteWork)
    }

    @MainActor
    private var hasPendingDeleteWork: Bool {
        records.contains { record in
            record.status == .sent && record.deleteAfter != nil
        }
    }

    @MainActor
    private func scheduleBackgroundRefresh() {
        guard !backgroundRefreshIdentifier.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func saveDevices() {
        SharedDeviceStorage.saveDevices(devices)
    }

    private func fileSize(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func mimeType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
    }
}
