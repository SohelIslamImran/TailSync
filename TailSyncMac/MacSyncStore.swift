import AppKit
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

struct MacSyncRoot: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var url: URL
    var title: String
    var isEnabled: Bool

    init(url: URL) {
        self.id = UUID().uuidString
        self.url = url
        self.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.isEnabled = true
    }
}

struct MacIgnoredFolder: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var url: URL
    var title: String

    init(url: URL) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}

struct MacFileRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var rootID: String
    var url: URL
    var relativePath: String
    var filename: String
    var status: TransferStatus
    var progress: Double
    var byteCount: Int64
    var transferredByteCount: Int64
    var modifiedAt: Date?
    var attempts: Int
    var sentAt: Date?
    var trashedAt: Date?
    var deleteAfter: Date?
    var sentDeviceIDs: Set<String>
    var lastError: String?

    var isTerminalSuccess: Bool {
        status == .sent || status == .deleted
    }
}

struct MacSyncManifest: Codable, Sendable {
    var records: [String: MacFileRecord] = [:]
}

@MainActor
@Observable
final class MacSyncStore {
    var devices: [TaildropDevice] {
        didSet { SharedDeviceStorage.saveDevices(devices) }
    }
    var roots: [MacSyncRoot] {
        didSet {
            saveRoots()
            rebuildWatchers()
        }
    }
    var ignoredDeleteFolders: [MacIgnoredFolder] {
        didSet { saveIgnoredDeleteFolders() }
    }
    var autoDeleteDelay: AutoDeleteDelay {
        didSet { UserDefaults.standard.set(autoDeleteDelay.rawValue, forKey: autoDeleteDelayKey) }
    }
    var smartDeleteEnabled: Bool {
        didSet { UserDefaults.standard.set(smartDeleteEnabled, forKey: smartDeleteKey) }
    }
    var automaticBackgroundSync: Bool {
        didSet {
            UserDefaults.standard.set(automaticBackgroundSync, forKey: automaticBackgroundSyncKey)
            if automaticBackgroundSync {
                scheduleScan()
            }
        }
    }
    var retryWhenDevicesReturn: Bool {
        didSet { UserDefaults.standard.set(retryWhenDevicesReturn, forKey: retryWhenDevicesReturnKey) }
    }
    private(set) var launchAtLoginEnabled = false

    private(set) var records: [MacFileRecord] = []
    private(set) var isRunning = false
    var isPaused = false
    private(set) var statusMessage = "Ready"
    private(set) var currentFilename: String?
    private(set) var currentTargetName: String?
    private(set) var currentProgress: Double = 0
    private(set) var currentTransferredBytes: Int64 = 0
    private(set) var currentTotalBytes: Int64 = 0

    private let uploader: TailscaleUploading
    private let reachabilityClient: DeviceReachabilityClient
    private let manifestStore: MacSyncManifestStore
    private var syncTask: Task<Void, Never>?
    private var rescanTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var watchers: [RootWatcher] = []
    private var activity: NSObjectProtocol?

    private let rootsKey = "macSyncRoots"
    private let autoDeleteDelayKey = "macAutoDeleteDelay"
    private let smartDeleteKey = "macSmartDeleteEnabled"
    private let ignoredDeleteFoldersKey = "macIgnoredDeleteFolders"
    private let automaticBackgroundSyncKey = "macAutomaticBackgroundSync"
    private let retryWhenDevicesReturnKey = "macRetryWhenDevicesReturn"

    init(
        uploader: TailscaleUploading = TailscaleUploader(),
        reachabilityClient: DeviceReachabilityClient = DeviceReachabilityClient(),
        manifestStore: MacSyncManifestStore = MacSyncManifestStore()
    ) {
        self.uploader = uploader
        self.reachabilityClient = reachabilityClient
        self.manifestStore = manifestStore
        self.devices = SharedDeviceStorage.loadDevices(fallback: [])
        self.roots = Self.loadRoots()
        self.ignoredDeleteFolders = Self.loadIgnoredDeleteFolders()
        self.autoDeleteDelay = AutoDeleteDelay(rawValue: UserDefaults.standard.string(forKey: autoDeleteDelayKey) ?? "") ?? .never
        self.smartDeleteEnabled = UserDefaults.standard.bool(forKey: smartDeleteKey)
        self.automaticBackgroundSync = UserDefaults.standard.object(forKey: automaticBackgroundSyncKey) as? Bool ?? true
        self.retryWhenDevicesReturn = UserDefaults.standard.object(forKey: retryWhenDevicesReturnKey) as? Bool ?? true
        self.launchAtLoginEnabled = Self.currentLaunchAtLoginEnabled
        Task {
            self.records = await manifestStore.allRecords()
            self.rebuildWatchers()
            await self.scanOnly()
            self.startRetryLoop()
            if self.automaticBackgroundSync {
                await self.syncNow()
            }
        }
    }

    var activeDevices: [TaildropDevice] {
        devices.filter { $0.autoSync && $0.peerAPIURL != nil }
    }

    var pendingRecords: [MacFileRecord] {
        records.filter { $0.status == .pending || $0.status == .sending }
    }

    var sentRecords: [MacFileRecord] {
        records.filter { $0.status == .sent || $0.status == .deleted }
    }

    var failedRecords: [MacFileRecord] {
        records.filter { $0.status == .failed }
    }

    var totalByteCount: Int64 {
        records.reduce(0) { $0 + $1.byteCount }
    }

    var completedByteCount: Int64 {
        records.reduce(0) { total, record in
            switch record.status {
            case .sent, .deleted:
                total + record.byteCount
            case .sending:
                total + record.transferredByteCount
            case .pending, .failed:
                total
            }
        }
    }

    var canSync: Bool {
        !isRunning && !isPaused && !activeDevices.isEmpty && roots.contains(where: \.isEnabled)
    }

    var backgroundSummary: String {
        if launchAtLoginEnabled && automaticBackgroundSync && retryWhenDevicesReturn {
            return "Launches at login, watches folders, and retries unavailable devices."
        }
        if automaticBackgroundSync {
            return "Watches folders while TailSync is running."
        }
        return "Manual sync only."
    }

    func addFolderFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            let existingPaths = Set(roots.map { $0.url.standardizedFileURL.path })
            let newRoots = panel.urls
                .filter { !existingPaths.contains($0.standardizedFileURL.path) }
                .map { MacSyncRoot(url: $0.standardizedFileURL) }
            roots.append(contentsOf: newRoots)
            scheduleScan()
        }
    }

    func addIgnoredDeleteFolderFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        if panel.runModal() == .OK {
            let existing = Set(ignoredDeleteFolders.map(\.id))
            ignoredDeleteFolders.append(contentsOf: panel.urls
                .map { MacIgnoredFolder(url: $0.standardizedFileURL) }
                .filter { !existing.contains($0.id) })
            ignoredDeleteFolders.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    func removeRoot(_ id: MacSyncRoot.ID) {
        roots.removeAll { $0.id == id }
        scheduleScan()
    }

    func updateRoot(_ root: MacSyncRoot) {
        guard let index = roots.firstIndex(where: { $0.id == root.id }) else { return }
        roots[index] = root
        scheduleScan()
    }

    func removeIgnoredDeleteFolder(_ id: MacIgnoredFolder.ID) {
        ignoredDeleteFolders.removeAll { $0.id == id }
    }

    func addDevice(_ device: TaildropDevice) {
        devices.append(device)
    }

    func updateDevice(_ device: TaildropDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
    }

    func removeDevice(_ id: TaildropDevice.ID) {
        devices.removeAll { $0.id == id }
    }

    func checkDeviceStatus(_ id: TaildropDevice.ID) async {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        markDevice(id, status: .checking, error: nil)
        let result = await reachabilityClient.check(device: device)
        if let port = result.resolvedPort {
            rememberPeerAPIPort(port, for: id)
        }
        markDevice(id, status: result.status, error: result.error)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = Self.currentLaunchAtLoginEnabled
        } catch {
            launchAtLoginEnabled = Self.currentLaunchAtLoginEnabled
            statusMessage = "Launch at login failed: \(error.localizedDescription)"
        }
    }

    func syncNow() async {
        guard !isRunning else { return }
        guard !isPaused else {
            statusMessage = "Sync paused."
            return
        }
        guard !activeDevices.isEmpty else {
            statusMessage = "Add or enable at least one Taildrop device."
            return
        }
        guard roots.contains(where: \.isEnabled) else {
            statusMessage = "Add at least one folder."
            return
        }

        syncTask = Task {
            await self.runSyncPass()
        }
        await syncTask?.value
    }

    func startSyncInBackground() {
        guard syncTask == nil || syncTask?.isCancelled == true else { return }
        syncTask = Task { await self.syncNow() }
    }

    func stopSync() {
        syncTask?.cancel()
        syncTask = nil
        isRunning = false
        resetCurrentTransfer()
        statusMessage = "Sync stopped."
    }

    func togglePaused() {
        isPaused.toggle()
        if isPaused {
            stopSync()
            statusMessage = "Sync paused."
        } else {
            statusMessage = "Ready"
            if automaticBackgroundSync {
                scheduleScan()
            }
        }
    }

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
        records = await manifestStore.allRecords()
        await syncNow()
    }

    private func runSyncPass() async {
        isRunning = true
        beginActivity()
        statusMessage = "Scanning folders..."
        defer {
            isRunning = false
            syncTask = nil
            resetCurrentTransfer()
            endActivity()
        }

        await scanOnly()
        await processDueTrash()

        let devicesToSync = activeDevices
        let activeDeviceIDs = Set(devicesToSync.map(\.id))
        let work = records.filter { record in
            record.status == .failed || !record.isTerminalSuccess || !activeDeviceIDs.isSubset(of: record.sentDeviceIDs)
        }

        statusMessage = "Found \(work.count) item(s) waiting."
        for var record in work {
            guard !Task.isCancelled, !isPaused else { break }
            guard FileManager.default.fileExists(atPath: record.url.path) else { continue }

            do {
                record.status = .sending
                record.progress = 0
                record.attempts += 1
                record.lastError = nil
                try await manifestStore.upsert(record)
                applyUpdatedRecord(record)

                for device in devicesToSync where !record.sentDeviceIDs.contains(device.id) {
                    currentFilename = record.filename
                    currentTargetName = device.name
                    currentProgress = 0
                    currentTransferredBytes = 0
                    currentTotalBytes = record.byteCount

                    let endpoint = try await resolvedEndpoint(for: device)
                    let file = ExportedAssetFile(
                        url: record.url,
                        filename: record.filename,
                        mimeType: mimeType(for: record.url),
                        byteCount: record.byteCount
                    )
                    try await uploader.upload(file: file, creationDate: record.modifiedAt, to: endpoint) { sentBytes, totalBytes in
                        await MainActor.run {
                            self.currentTransferredBytes = sentBytes
                            self.currentTotalBytes = totalBytes > 0 ? totalBytes : record.byteCount
                            self.currentProgress = self.currentTotalBytes > 0 ? min(0.99, Double(sentBytes) / Double(self.currentTotalBytes)) : 0
                        }
                    }
                    record.sentDeviceIDs.insert(device.id)
                    record.transferredByteCount = record.byteCount
                    record.progress = 1
                    rememberOnline(device.id)
                    try await manifestStore.upsert(record)
                    applyUpdatedRecord(record)
                }

                record.status = .sent
                record.sentAt = Date()
                record.deleteAfter = deleteDateAfterSuccessfulTransfer(for: record)
                try await manifestStore.upsert(record)
                applyUpdatedRecord(record)
                statusMessage = "Taildropped \(record.filename)."
            } catch {
                record.status = .failed
                record.progress = 0
                record.lastError = error.localizedDescription
                try? await manifestStore.upsert(record)
                applyUpdatedRecord(record)
                statusMessage = "Sync failed: \(error.localizedDescription)"
                break
            }
        }

        if Task.isCancelled {
            statusMessage = "Sync stopped."
        } else if !isPaused {
            statusMessage = "Sync complete."
        }
    }

    private func scanOnly() async {
        let found = scanRoots()
        let existing = await manifestStore.allRecords()
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for file in found {
            if var existingRecord = byID[file.id] {
                if existingRecord.byteCount != file.byteCount || existingRecord.modifiedAt != file.modifiedAt || existingRecord.url != file.url {
                    existingRecord.url = file.url
                    existingRecord.relativePath = file.relativePath
                    existingRecord.filename = file.filename
                    existingRecord.byteCount = file.byteCount
                    existingRecord.modifiedAt = file.modifiedAt
                    existingRecord.status = .pending
                    existingRecord.progress = 0
                    existingRecord.transferredByteCount = 0
                    existingRecord.sentDeviceIDs = []
                    existingRecord.lastError = nil
                    byID[file.id] = existingRecord
                }
            } else {
                byID[file.id] = file
            }
        }

        try? await manifestStore.replace(Array(byID.values))
        records = await manifestStore.allRecords()
    }

    private func scanRoots() -> [MacFileRecord] {
        let enabledRoots = roots.filter(\.isEnabled)
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .typeIdentifierKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        var output: [MacFileRecord] = []

        for root in enabledRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root.url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }
                if shouldSkip(url: url, root: root, values: values) {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      let byteCount = values.fileSize.map(Int64.init),
                      isStable(modifiedAt: values.contentModificationDate) else {
                    continue
                }

                let relativePath = relativePath(for: url, root: root.url)
                output.append(MacFileRecord(
                    id: "\(root.id):\(relativePath)",
                    rootID: root.id,
                    url: url,
                    relativePath: relativePath,
                    filename: url.lastPathComponent,
                    status: .pending,
                    progress: 0,
                    byteCount: byteCount,
                    transferredByteCount: 0,
                    modifiedAt: values.contentModificationDate,
                    attempts: 0,
                    sentAt: nil,
                    trashedAt: nil,
                    deleteAfter: nil,
                    sentDeviceIDs: [],
                    lastError: nil
                ))
            }
        }

        return output
    }

    private func shouldSkip(url: URL, root: MacSyncRoot, values: URLResourceValues) -> Bool {
        let name = url.lastPathComponent
        if name == ".DS_Store" || name == ".Trash" || name.hasPrefix("~$") || name.hasSuffix(".tmp") || name.hasSuffix(".download") {
            return true
        }
        if values.isHidden == true {
            return true
        }
        if values.isPackage == true && url.standardizedFileURL != root.url.standardizedFileURL {
            return true
        }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            return true
        }
        return false
    }

    private func isStable(modifiedAt: Date?) -> Bool {
        guard let modifiedAt else { return true }
        return Date().timeIntervalSince(modifiedAt) > 2
    }

    private func resolvedEndpoint(for device: TaildropDevice) async throws -> URL {
        let current = devices.first(where: { $0.id == device.id }) ?? device
        let result = await reachabilityClient.check(device: current)
        guard result.status == .online,
              let port = result.resolvedPort,
              let endpoint = TaildropDevice.peerAPIURL(from: current.endpoint, preferredPort: port) else {
            markDevice(current.id, status: result.status, error: result.error)
            throw PhotoTransferError.taildropUnavailable
        }
        rememberPeerAPIPort(port, for: current.id)
        return endpoint
    }

    private func markDevice(_ id: TaildropDevice.ID, status: DeviceStatus, error: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].status = status
        devices[index].lastCheckedAt = Date()
        devices[index].lastError = error
        if status == .online {
            devices[index].lastReachableAt = Date()
        }
    }

    private func rememberOnline(_ id: TaildropDevice.ID) {
        markDevice(id, status: .online, error: nil)
    }

    private func rememberPeerAPIPort(_ port: Int, for id: TaildropDevice.ID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].peerAPIPort = port
    }

    private func deleteDateAfterSuccessfulTransfer(for record: MacFileRecord) -> Date? {
        guard autoDeleteDelay != .never, !isDeleteIgnored(record.url) else { return nil }
        if smartDeleteEnabled, isStorageLow {
            return Date().addingTimeInterval(24 * 60 * 60)
        }
        guard let interval = autoDeleteDelay.interval else { return nil }
        return Date().addingTimeInterval(interval)
    }

    private func processDueTrash() async {
        let now = Date()
        var changed: [MacFileRecord] = []
        for var record in records where record.status == .sent {
            guard let deleteAfter = record.deleteAfter, deleteAfter <= now, !isDeleteIgnored(record.url) else { continue }
            do {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: record.url, resultingItemURL: &resultingURL)
                record.status = .deleted
                record.trashedAt = now
                record.deleteAfter = nil
            } catch {
                record.lastError = error.localizedDescription
            }
            changed.append(record)
        }
        try? await manifestStore.upsert(changed)
        if !changed.isEmpty {
            records = await manifestStore.allRecords()
        }
    }

    private func isDeleteIgnored(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return ignoredDeleteFolders.contains { ignored in
            path == ignored.url.standardizedFileURL.path || path.hasPrefix(ignored.url.standardizedFileURL.path + "/")
        }
    }

    private func scheduleScan() {
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self.scanOnly()
            if self.automaticBackgroundSync && self.canSync {
                await self.syncNow()
            }
        }
    }

    private func startRetryLoop() {
        retryTask?.cancel()
        retryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.retryWhenDevicesReturn,
                          self.automaticBackgroundSync,
                          !self.failedRecords.isEmpty,
                          !self.isRunning,
                          !self.isPaused else { return }
                    self.statusMessage = "Checking failed transfers..."
                    Task { await self.retryFailed() }
                }
            }
        }
    }

    private func rebuildWatchers() {
        watchers.forEach { $0.cancel() }
        watchers = roots.filter(\.isEnabled).compactMap { root in
            RootWatcher(url: root.url) { [weak self] in
                Task { @MainActor in
                    guard self?.automaticBackgroundSync == true else { return }
                    self?.scheduleScan()
                }
            }
        }
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "TailSync is uploading files to Taildrop devices."
        )
    }

    private func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func applyUpdatedRecord(_ record: MacFileRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort(by: recordSort)
    }

    private func resetCurrentTransfer() {
        currentFilename = nil
        currentTargetName = nil
        currentProgress = 0
        currentTransferredBytes = 0
        currentTotalBytes = 0
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    private func recordSort(_ lhs: MacFileRecord, _ rhs: MacFileRecord) -> Bool {
        switch (lhs.modifiedAt, rhs.modifiedAt) {
        case let (left?, right?):
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private func mimeType(for url: URL) -> String {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mimeType = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mimeType
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

    private func saveRoots() {
        guard let data = try? JSONEncoder().encode(roots) else { return }
        UserDefaults.standard.set(data, forKey: rootsKey)
    }

    private func saveIgnoredDeleteFolders() {
        guard let data = try? JSONEncoder().encode(ignoredDeleteFolders) else { return }
        UserDefaults.standard.set(data, forKey: ignoredDeleteFoldersKey)
    }

    private static func loadRoots() -> [MacSyncRoot] {
        guard let data = UserDefaults.standard.data(forKey: "macSyncRoots"),
              let roots = try? JSONDecoder().decode([MacSyncRoot].self, from: data) else {
            return []
        }
        return roots
    }

    private static func loadIgnoredDeleteFolders() -> [MacIgnoredFolder] {
        guard let data = UserDefaults.standard.data(forKey: "macIgnoredDeleteFolders"),
              let folders = try? JSONDecoder().decode([MacIgnoredFolder].self, from: data) else {
            return []
        }
        return folders
    }

    private static var currentLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

actor MacSyncManifestStore {
    private let fileURL: URL
    private var manifest: MacSyncManifest

    init(filename: String = "mac-transfer-manifest.json") {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TailSync", isDirectory: true)
        self.fileURL = supportDirectory.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.macManifest.decode(MacSyncManifest.self, from: data) {
            self.manifest = decoded
        } else {
            self.manifest = MacSyncManifest()
        }
    }

    func allRecords() -> [MacFileRecord] {
        manifest.records.values.sorted { lhs, rhs in
            lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    func upsert(_ record: MacFileRecord) throws {
        manifest.records[record.id] = record
        try save()
    }

    func upsert(_ records: [MacFileRecord]) throws {
        for record in records {
            manifest.records[record.id] = record
        }
        try save()
    }

    func replace(_ records: [MacFileRecord]) throws {
        manifest.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.macManifest.encode(manifest)
        try data.write(to: fileURL, options: [.atomic])
    }
}

private final class RootWatcher {
    private let descriptor: CInt
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, change: @escaping @Sendable () -> Void) {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: change)
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}

enum MacByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension JSONEncoder {
    static var macManifest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var macManifest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
