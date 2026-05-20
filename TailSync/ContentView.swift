import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: TransferStore
    @State private var selectedList: RecordListKind?
    @State private var showingFileSourceSheet = false
    @State private var showingFilePicker = false
    @State private var showingPhotoPicker = false
    @State private var selectedFile: PickedFile?

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    HeaderView(store: store)
                    LibraryPanel(
                        store: store,
                        onShowPending: { selectedList = .pending },
                        onShowSent: { selectedList = .sent },
                        onShowFailed: { selectedList = .failed }
                    )
                    DevicesPanel(store: store)
                    OptionsPanel(store: store)
                    SendFilePanel { showingFileSourceSheet = true }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
        }
        .task {
            await store.refreshAuthorizationAndCounts()
            if store.authorizationStatus == .notDetermined {
                await store.requestPhotoAccess()
            }
        }
        .sheet(item: $selectedList) { kind in
            TransferRecordListSheet(kind: kind, records: records(for: kind), store: store)
        }
        .sheet(isPresented: $showingFileSourceSheet) {
            FileSourcePickerSheet(
                pickPhotos: {
                    showingFileSourceSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingPhotoPicker = true
                    }
                },
                pickFiles: {
                    showingFileSourceSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        showingFilePicker = true
                    }
                }
            )
        }
        .sheet(isPresented: $showingFilePicker) {
            DocumentPicker { url in
                selectedFile = PickedFile(url: url)
            }
        }
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoLibraryPicker { url in
                selectedFile = PickedFile(url: url)
            }
        }
        .sheet(item: $selectedFile) { file in
            FileSendSheet(file: file, store: store)
        }
        .animation(.smooth, value: store.pendingCount)
        .animation(.smooth, value: store.failedCount)
        .animation(.smooth, value: store.transferredCount)
    }

    private func records(for kind: RecordListKind) -> [TransferRecord] {
        switch kind {
        case .pending: store.pendingRecords
        case .failed: store.failedRecords
        case .sent: store.sentRecords
        }
    }
}

private struct PickedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private enum RecordListKind: String, Identifiable {
    case pending
    case failed
    case sent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "Pending"
        case .failed: "Failed"
        case .sent: "Sent"
        }
    }
}

private struct HeaderView: View {
    @Bindable var store: TransferStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TailSync")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("Sync new photos, videos, and files to your Taildrop devices.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    Task {
                        store.isRunning ? store.stopTransfer() : await store.startTransfer()
                    }
                } label: {
                    Image(systemName: store.isRunning ? "stop.fill" : "paperplane.fill")
                        .font(.headline.weight(.bold))
                        .frame(width: 48, height: 48)
                }
                .foregroundStyle(store.isRunning ? .red : .blue)
                .liquidGlass(cornerRadius: 18, interactive: true)
                .disabled(!store.isRunning && !store.canStartTransfer)
                .opacity((store.isRunning || store.canStartTransfer) ? 1 : 0.45)
            }

            if store.isRunning || !store.statusMessage.isEmpty {
                CurrentTransferPanel(
                    filename: store.currentFilename ?? store.statusMessage,
                    assetID: store.currentAssetID,
                    isVideo: store.currentAssetIsVideo,
                    targetName: store.currentTargetName,
                    progress: store.currentProgress,
                    transferredBytes: store.currentTransferredBytes,
                    totalBytes: store.currentTotalBytes
                )
            }
        }
        .padding(20)
        .liquidGlass(cornerRadius: 30, interactive: false)
    }
}

private struct CurrentTransferPanel: View {
    let filename: String
    let assetID: String?
    let isVideo: Bool
    let targetName: String?
    let progress: Double
    let transferredBytes: Int64
    let totalBytes: Int64

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            transferThumbnail
                .frame(width: 52, height: 52)
                .frame(minWidth: 52, maxWidth: 52, minHeight: 52, maxHeight: 52)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(filename.isEmpty ? "Ready" : filename)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 38, alignment: .trailing)
                    }
                }

                if progress > 0 {
                    ProgressView(value: progress)
                        .tint(.blue)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .padding(12)
        .background(.white.opacity(0.44), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var transferThumbnail: some View {
        ZStack {
            if let assetID {
                AssetThumbnail(assetID: assetID, isVideo: isVideo)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "doc.badge.arrow.up")
                    .foregroundStyle(.blue)
                    .frame(width: 52, height: 52)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if progress > 0 && progress < 1 {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(.blue.opacity(0.65), lineWidth: 2)
            }
        }
        .frame(width: 52, height: 52)
        .clipped()
    }

    private var subtitle: String {
        if totalBytes > 0 {
            return "\(ByteFormat.string(transferredBytes)) of \(ByteFormat.string(totalBytes))\(targetName.map { " to \($0)" } ?? "")"
        }
        return targetName.map { "Sending to \($0)" } ?? "Waiting for work"
    }
}

private struct LibraryPanel: View {
    let store: TransferStore
    let onShowPending: () -> Void
    let onShowSent: () -> Void
    let onShowFailed: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ByteFormat.string(store.completedByteCount))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("\(ByteFormat.string(store.totalByteCount)) total in library")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.requestPhotoAccess() }
                } label: {
                    Label(store.isAuthorized ? "Photos Ready" : "Allow Photos", systemImage: store.isAuthorized ? "checkmark.circle.fill" : "photo.badge.plus")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                MetricTile(value: "\(store.pendingCount)", title: "Pending", tint: .blue, action: onShowPending)
                MetricTile(value: "\(store.transferredCount)", title: "Sent", tint: .green, action: onShowSent)
                MetricTile(value: "\(store.failedCount)", title: "Failed", tint: .red, action: onShowFailed)
            }
        }
        .panelSurface()
    }
}

private struct DevicesPanel: View {
    @Bindable var store: TransferStore
    @State private var deviceToRemove: TaildropDevice?
    @State private var deviceToEdit: TaildropDevice?
    @State private var showingAddDevice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Devices", systemImage: "iphone.and.arrow.forward")

            if store.devices.isEmpty {
                ContentUnavailableView("No Devices", systemImage: "display.and.arrow.down", description: Text("Add a MagicDNS name or Tailscale IP to start syncing."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                ForEach(store.devices) { device in
                    DeviceRow(
                        device: device,
                        update: { store.updateDevice($0) },
                        edit: { deviceToEdit = device },
                        checkStatus: { Task { await store.checkDeviceStatus(device.id) } },
                        remove: { deviceToRemove = device }
                    )
                }
            }

            Button {
                showingAddDevice = true
            } label: {
                Label("Add Device", systemImage: "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .panelSurface()
        .sheet(item: $deviceToEdit) { device in
            DeviceEditSheet(device: device) { updatedDevice in
                store.updateDevice(updatedDevice)
            }
        }
        .sheet(isPresented: $showingAddDevice) {
            DeviceEditSheet(
                device: TaildropDevice(id: UUID().uuidString, name: "", endpoint: "", autoSync: true),
                title: "Add Device",
                saveTitle: "Add"
            ) { newDevice in
                store.addDevice(newDevice)
            }
        }
        .alert(
            "Remove this device?",
            isPresented: Binding(
                get: { deviceToRemove != nil },
                set: { if !$0 { deviceToRemove = nil } }
            )
        ) {
            if let deviceToRemove {
                Button("Remove \(deviceToRemove.name)", role: .destructive) {
                    store.removeDevice(deviceToRemove.id)
                    self.deviceToRemove = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TailSync will stop syncing to this device. Sent history remains in the transfer log.")
        }
    }
}

private struct DeviceRow: View {
    let device: TaildropDevice
    let update: (TaildropDevice) -> Void
    let edit: () -> Void
    let checkStatus: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: device.status.systemImage)
                    .foregroundStyle(statusTint)
                    .frame(width: 34, height: 34)
                    .background(statusTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline.weight(.semibold))
                    Text(device.displayAddress)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.status.title)
                            .foregroundStyle(statusTint)
                        if let lastError = device.lastError, !lastError.isEmpty, device.status == .taildropUnavailable || device.status == .invalidURL {
                            Text(lastError)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Toggle("Auto-sync", isOn: Binding(
                    get: { device.autoSync },
                    set: { enabled in
                        var copy = device
                        copy.autoSync = enabled
                        update(copy)
                    }
                ))
                    .labelsHidden()
            }
        }
        .padding(14)
        .background(.white.opacity(0.44), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            if device.status != .online && device.status != .checking {
                checkStatus()
            }
        }
        .contextMenu {
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }

            Button(action: checkStatus) {
                Label("Check Status", systemImage: "dot.radiowaves.left.and.right")
            }

            Button(role: .destructive, action: remove) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var statusTint: Color {
        switch device.status {
        case .online, .unknown: .green
        case .offline, .taildropUnavailable, .invalidURL: .orange
        case .checking: .blue
        }
    }
}

private struct DeviceEditSheet: View {
    let device: TaildropDevice
    let title: String
    let saveTitle: String
    let save: (TaildropDevice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftName: String
    @State private var draftEndpoint: String

    init(
        device: TaildropDevice,
        title: String = "Edit Device",
        saveTitle: String = "Save",
        save: @escaping (TaildropDevice) -> Void
    ) {
        self.device = device
        self.title = title
        self.saveTitle = saveTitle
        self.save = save
        _draftName = State(initialValue: device.name)
        _draftEndpoint = State(initialValue: device.displayAddress)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Device name", text: $draftName)
                    TextField("MagicDNS name or Tailscale IP", text: $draftEndpoint)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        var copy = device
                        copy.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        copy.endpoint = TaildropDevice.normalizedAddress(from: draftEndpoint)
                        copy.status = .unknown
                        copy.lastError = nil
                        save(copy)
                        dismiss()
                    }
                    .disabled(
                        draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !TaildropDevice.isValidAddress(draftEndpoint)
                    )
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct OptionsPanel: View {
    @Bindable var store: TransferStore
    @State private var showingIgnoredAlbums = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Auto Delete Options", systemImage: "trash")

            DeleteOptionRow(systemImage: "clock.badge.checkmark.fill") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delay")
                            .font(.subheadline.weight(.semibold))
                        Text("Originals are deleted only after every enabled device receives the file.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Delay", selection: $store.autoDeleteDelay) {
                        ForEach(AutoDeleteDelay.allCases) { delay in
                            Text(delay.title).tag(delay)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }

            DeleteOptionRow(systemImage: "internaldrive.fill") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Smart delete on low storage")
                            .font(.subheadline.weight(.semibold))
                        Text("TailSync can shorten the delay when the iPhone is running low on space.")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Smart delete on low storage", isOn: $store.smartDeleteEnabled)
                        .labelsHidden()
                }
            }

            Button {
                store.refreshAutoDeleteAlbums()
                showingIgnoredAlbums = true
            } label: {
                DeleteOptionRow(systemImage: "folder.badge.minus") {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ignored albums")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(ignoredAlbumsSubtitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .panelSurface()
        .sheet(isPresented: $showingIgnoredAlbums) {
            IgnoredAlbumsSheet(store: store)
        }
    }

    private var ignoredAlbumsSubtitle: String {
        let count = store.ignoredAutoDeleteAlbumIDs.count
        if count == 0 {
            return "Keep originals from selected albums."
        }
        return "\(count) album\(count == 1 ? "" : "s") protected from auto delete."
    }
}

private struct IgnoredAlbumsSheet: View {
    @Bindable var store: TransferStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingFolderPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("Photo Albums") {
                    if store.autoDeleteAlbums.isEmpty {
                        ContentUnavailableView("No Albums", systemImage: "photo.stack", description: Text("Create albums in Photos to exclude them from auto delete."))
                    } else {
                        ForEach(store.autoDeleteAlbums) { album in
                            Button {
                                store.setAutoDeleteIgnored(
                                    album.id,
                                    isIgnored: !store.ignoredAutoDeleteAlbumIDs.contains(album.id)
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: store.ignoredAutoDeleteAlbumIDs.contains(album.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(store.ignoredAutoDeleteAlbumIDs.contains(album.id) ? .blue : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.title)
                                            .foregroundStyle(.primary)
                                        Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Folders") {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label("Choose Folder", systemImage: "folder.badge.plus")
                    }

                    if store.ignoredAutoDeleteFolders.isEmpty {
                        Text("No folders ignored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.ignoredAutoDeleteFolders) { folder in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.title)
                                    .foregroundStyle(.primary)
                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    store.removeIgnoredAutoDeleteFolder(folder)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ignored Locations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                store.refreshAutoDeleteAlbums()
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result {
                    store.addIgnoredAutoDeleteFolders(urls)
                }
            }
        }
    }
}

private struct DeleteOptionRow<Content: View>: View {
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.white.opacity(0.44), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SendFilePanel: View {
    let send: () -> Void

    var body: some View {
        Button(action: send) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.arrow.up")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send Any File")
                        .font(.headline.weight(.semibold))
                    Text("Choose from Photos or Files and send to devices.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .liquidGlass(cornerRadius: 24, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct FileSourcePickerSheet: View {
    let pickPhotos: () -> Void
    let pickFiles: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SourceOptionButton(
                    title: "Photo Library",
                    subtitle: "Pick a photo or video from your gallery.",
                    systemImage: "photo.on.rectangle",
                    action: pickPhotos
                )

                SourceOptionButton(
                    title: "Files",
                    subtitle: "Pick any document or file from storage.",
                    systemImage: "folder",
                    action: pickFiles
                )
            }
            .padding(18)
            .background(AppBackground())
            .navigationTitle("Choose Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(250)])
    }
}

private struct SourceOptionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.white.opacity(0.44), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct TransferRecordListSheet: View {
    let kind: RecordListKind
    let records: [TransferRecord]
    @Bindable var store: TransferStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if records.isEmpty {
                    ContentUnavailableView(kind.title, systemImage: emptySystemImage)
                } else {
                    List(records) { record in
                        TransferRecordRow(record: record) {
                            Task { await store.resend(recordID: record.id) }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if kind == .failed, !records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Retry All") { Task { await store.retryFailed() } }
                    }
                }
                if kind == .sent, !records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Send Again All") { Task { await store.resendAllSent() } }
                    }
                }
            }
        }
    }

    private var emptySystemImage: String {
        switch kind {
        case .pending: "tray"
        case .failed: "checkmark.circle"
        case .sent: "paperplane"
        }
    }
}

private struct TransferRecordRow: View {
    let record: TransferRecord
    let resend: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AssetThumbnail(assetID: record.id, isVideo: record.mediaType == "Video")
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.filename)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Text(record.status.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }

                if record.status == .sending || record.status == .pending {
                    ProgressView(value: record.progress)
                        .tint(tint)
                }

                Text(detailText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(record.lastError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)

                if record.isTerminalSuccess || record.status == .failed {
                    Button(action: resend) {
                        Label(record.status == .failed ? "Retry" : "Send Again", systemImage: "arrow.clockwise")
                    }
                    .font(.caption.weight(.bold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var tint: Color {
        switch record.status {
        case .pending: .blue
        case .sending: .cyan
        case .sent: .green
        case .failed: .red
        case .deleted: .purple
        }
    }

    private var detailText: String {
        if let error = record.lastError, !error.isEmpty { return error }
        var parts = [record.mediaType]
        if let byteCount = record.byteCount, byteCount > 0 { parts.append(ByteFormat.string(byteCount)) }
        if !record.sentDeviceIDs.isEmpty { parts.append("\(record.sentDeviceIDs.count) device\(record.sentDeviceIDs.count == 1 ? "" : "s")") }
        if let deleteAfter = record.deleteAfter { parts.append("delete \(deleteAfter.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: " - ")
    }
}

private struct AssetThumbnail: View {
    let assetID: String
    let isVideo: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.blue.opacity(0.12))
                Image(systemName: isVideo ? "video.fill" : "photo.fill")
                    .foregroundStyle(.blue)
            }

            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .task(id: assetID) {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            let manager = PHCachingImageManager.default()
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            manager.requestImage(for: asset, targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill, options: options) { image, _ in
                self.image = image
            }
        }
    }
}

private struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: @MainActor @Sendable (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: @MainActor @Sendable (URL) -> Void

        init(onPick: @escaping @MainActor @Sendable (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: @MainActor @Sendable (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: @MainActor @Sendable (URL) -> Void

        init(onPick: @escaping @MainActor @Sendable (URL) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  let typeIdentifier = preferredTypeIdentifier(from: provider) else {
                return
            }

            let suggestedName = provider.suggestedName
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [onPick] url, _ in
                guard let url,
                      let copiedURL = Self.copyPickedFile(from: url, suggestedName: suggestedName, typeIdentifier: typeIdentifier) else {
                    return
                }
                Task { @MainActor in
                    onPick(copiedURL)
                }
            }
        }

        private func preferredTypeIdentifier(from provider: NSItemProvider) -> String? {
            let preferredTypes = [UTType.movie, .mpeg4Movie, .quickTimeMovie, .image, .jpeg, .png, .heic, .item]
            return preferredTypes
                .map(\.identifier)
                .first { provider.hasItemConformingToTypeIdentifier($0) }
        }

        nonisolated private static func copyPickedFile(from url: URL, suggestedName: String?, typeIdentifier: String) -> URL? {
            let filename = sanitizedFilename(
                suggestedName,
                fallbackExtension: UTType(typeIdentifier)?.preferredFilenameExtension ?? url.pathExtension
            )
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let destination = directory.appendingPathComponent(filename)

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                return destination
            } catch {
                return nil
            }
        }

        nonisolated private static func sanitizedFilename(_ suggestedName: String?, fallbackExtension: String) -> String {
            let trimmedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = fallbackExtension.isEmpty ? "dat" : fallbackExtension
            let base = trimmedName.isEmpty ? "\(UUID().uuidString).\(fallback)" : trimmedName
            let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            let sanitized = base.components(separatedBy: invalidCharacters).joined(separator: "_")
            return sanitized.contains(".") ? sanitized : "\(sanitized).\(fallback)"
        }
    }
}

private struct FileSendSheet: View {
    let file: PickedFile
    @Bindable var store: TransferStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDeviceIDs: Set<TaildropDevice.ID> = []
    @State private var isSending = false
    @State private var didFinish = false

    private var eligibleDevices: [TaildropDevice] {
        store.devices.filter { device in
            device.peerAPIURL != nil
        }
    }

    private var selectedDevices: [TaildropDevice] {
        eligibleDevices.filter { selectedDeviceIDs.contains($0.id) }
    }

    private var canSend: Bool {
        !selectedDevices.isEmpty && !store.isRunning && !isSending
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FileSendStatusCard(file: file, store: store)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Devices")
                            .font(.headline.weight(.bold))

                        VStack(spacing: 0) {
                            if eligibleDevices.isEmpty {
                                Text("Add a MagicDNS name or Tailscale IP before sending files.")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            } else {
                                ForEach(eligibleDevices) { device in
                                    FileSendDeviceRow(
                                        device: device,
                                        isSelected: selectedDeviceIDs.contains(device.id)
                                    ) {
                                        if selectedDeviceIDs.contains(device.id) {
                                            selectedDeviceIDs.remove(device.id)
                                        } else {
                                            selectedDeviceIDs.insert(device.id)
                                        }
                                    }
                                }
                            }
                        }
                        .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.white.opacity(0.45), lineWidth: 1)
                        }
                    }
                }
                .padding(18)
            }
            .background(AppBackground())
            .navigationTitle("Send File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(didFinish ? "Done" : "Send") {
                        if didFinish {
                            dismiss()
                            return
                        }
                        let targets = selectedDevices
                        isSending = true
                        Task {
                            await store.sendFile(url: file.url, to: targets)
                            isSending = false
                            didFinish = true
                        }
                    }
                    .disabled(!canSend && !didFinish)
                }
            }
            .onAppear {
                selectedDeviceIDs = Set(eligibleDevices.filter(\.autoSync).map(\.id))
                if selectedDeviceIDs.isEmpty {
                    selectedDeviceIDs = Set(eligibleDevices.map(\.id))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FileSendStatusCard: View {
    let file: PickedFile
    let store: TransferStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.arrow.up")
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.url.lastPathComponent)
                        .font(.headline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ByteFormat.string(fileSize))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if store.isRunning, store.currentFilename == file.url.lastPathComponent {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(progressDetail)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(Int(store.currentProgress * 100))%")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: store.currentProgress)
                        .tint(.blue)
                }
            } else if store.statusMessage.hasPrefix("File send failed") || store.statusMessage.hasPrefix("Sent ") {
                Text(store.statusMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(store.statusMessage.hasPrefix("Sent ") ? .green : .red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 20, interactive: false)
    }

    private var fileSize: Int64 {
        let values = try? file.url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private var progressDetail: String {
        "\(ByteFormat.string(store.currentTransferredBytes)) of \(ByteFormat.string(store.currentTotalBytes))\(store.currentTargetName.map { " to \($0)" } ?? "")"
    }
}

private struct FileSendDeviceRow: View {
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

private struct MetricTile: View {
    let value: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden()
        }
        .padding(14)
        .background(.white.opacity(0.44), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.bold))
    }
}

private enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.93, green: 0.97, blue: 1.0),
                Color(red: 0.98, green: 0.99, blue: 1.0),
                Color(red: 0.91, green: 0.96, blue: 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private extension View {
    func panelSurface() -> some View {
        self
            .padding(18)
            .liquidGlass(cornerRadius: 26, interactive: false)
    }

    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat, interactive: Bool) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.42), lineWidth: 1)
                }
        }
    }
}

#Preview {
    ContentView(
        store: TransferStore(
            photoLibrary: PhotoLibraryClient(),
            uploader: TailscaleUploader()
        )
    )
}
