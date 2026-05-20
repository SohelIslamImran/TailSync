import AppKit
import SwiftUI

struct MacMenuBarView: View {
    @Bindable var store: MacSyncStore
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Button("Open TailSync", action: openMainWindow)

            Divider()

            statusLabel
            if store.isRunning {
                ProgressView(value: store.currentProgress)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(store.pendingRecords.count) pending, \(store.failedRecords.count) failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Sync Now") {
                Task { await store.syncNow() }
            }
            .disabled(!store.canSync)

            Button(store.isPaused ? "Resume" : "Pause") {
                store.togglePaused()
            }

            Button("Retry Failed") {
                Task { await store.retryFailed() }
            }
            .disabled(store.failedRecords.isEmpty)

            Divider()

            Button("Add Folder...") {
                store.addFolderFromPanel()
                openMainWindow()
            }

            SettingsLink {
                Text("Settings...")
            }

            Divider()

            Button("Quit TailSync") {
                NSApp.terminate(nil)
            }
        }
    }

    private var statusLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.currentFilename ?? store.statusMessage)
                .font(.headline)
                .lineLimit(1)
            if let target = store.currentTargetName {
                Text("Sending to \(target)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 260, alignment: .leading)
    }

    private var progressText: String {
        "\(MacByteFormat.string(store.currentTransferredBytes)) of \(MacByteFormat.string(store.currentTotalBytes))"
    }
}

struct MacContentView: View {
    @Bindable var store: MacSyncStore
    @SceneStorage("macSelection") private var selection: MacSidebarItem = .dashboard
    @State private var showingDeviceEditor = false
    @State private var editingDevice: TaildropDevice?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dashboard", systemImage: "gauge")
                    .tag(MacSidebarItem.dashboard)
                Label("Folders", systemImage: "folder")
                    .tag(MacSidebarItem.folders)
                Label("Devices", systemImage: "display.and.arrow.down")
                    .tag(MacSidebarItem.devices)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(MacSidebarItem.history)
                Label("Settings", systemImage: "gearshape")
                    .tag(MacSidebarItem.settings)
            }
            .listStyle(.sidebar)
            .navigationTitle("TailSync")
        } detail: {
            detailView
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            store.addFolderFromPanel()
                        } label: {
                            Label("Add Folder", systemImage: "folder.badge.plus")
                        }

                        Button {
                            editingDevice = TaildropDevice(id: UUID().uuidString, name: "New Device", endpoint: "", autoSync: true)
                            showingDeviceEditor = true
                        } label: {
                            Label("Add Device", systemImage: "plus")
                        }

                        Button {
                            Task { await store.syncNow() }
                        } label: {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!store.canSync)

                        Button {
                            Task { await store.retryFailed() }
                        } label: {
                            Label("Retry Failed", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        }
                        .disabled(store.failedRecords.isEmpty)
                    }
                }
        }
        .sheet(isPresented: $showingDeviceEditor) {
            if let device = editingDevice {
                MacDeviceEditor(device: device) { updated in
                    if store.devices.contains(where: { $0.id == updated.id }) {
                        store.updateDevice(updated)
                    } else {
                        store.addDevice(updated)
                    }
                    showingDeviceEditor = false
                } cancel: {
                    showingDeviceEditor = false
                }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .dashboard:
            MacDashboardView(store: store)
        case .folders:
            MacFoldersView(store: store)
        case .devices:
            MacDevicesView(store: store) { device in
                editingDevice = device
                showingDeviceEditor = true
            }
        case .history:
            MacHistoryView(store: store)
        case .settings:
            MacSettingsView(store: store)
        }
    }
}

enum MacSidebarItem: String, Codable, Hashable {
    case dashboard
    case folders
    case devices
    case history
    case settings
}

private struct MacDashboardView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TailSync")
                            .font(.largeTitle.bold())
                        Text(store.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.isRunning ? "Stop" : "Sync Now") {
                        if store.isRunning {
                            store.stopSync()
                        } else {
                            Task { await store.syncNow() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.isRunning && !store.canSync)
                }

                if store.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.currentFilename ?? "Preparing")
                            .font(.headline)
                        Text("\(MacByteFormat.string(store.currentTransferredBytes)) of \(MacByteFormat.string(store.currentTotalBytes))\(store.currentTargetName.map { " to \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: store.currentProgress)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    MetricCard(title: "Pending", value: "\(store.pendingRecords.count)", systemImage: "tray")
                    MetricCard(title: "Sent", value: "\(store.sentRecords.count)", systemImage: "checkmark.circle")
                    MetricCard(title: "Failed", value: "\(store.failedRecords.count)", systemImage: "exclamationmark.triangle")
                    MetricCard(title: "Synced", value: MacByteFormat.string(store.completedByteCount), systemImage: "externaldrive")
                }

                RecentRecordsView(records: Array(store.records.prefix(8)))
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }
}

private struct MacFoldersView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        List {
            Section {
                if store.roots.isEmpty {
                    ContentUnavailableView("No Folders", systemImage: "folder.badge.plus", description: Text("Add folders to sync them to Taildrop devices."))
                } else {
                    ForEach(store.roots) { root in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(root.title)
                                Text(root.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { root.isEnabled },
                                set: { enabled in
                                    var updated = root
                                    updated.isEnabled = enabled
                                    store.updateRoot(updated)
                                }
                            ))
                            .labelsHidden()
                            Button(role: .destructive) {
                                store.removeRoot(root.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Folders")
    }
}

private struct MacDevicesView: View {
    @Bindable var store: MacSyncStore
    let edit: (TaildropDevice) -> Void

    var body: some View {
        List {
            if store.devices.isEmpty {
                ContentUnavailableView("No Devices", systemImage: "display.and.arrow.down", description: Text("Add a MagicDNS name or Tailscale IP."))
            } else {
                ForEach(store.devices) { device in
                    HStack {
                        Image(systemName: device.status.systemImage)
                            .foregroundStyle(device.status == .online ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.displayAddress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Auto Sync", isOn: Binding(
                            get: { device.autoSync },
                            set: { enabled in
                                var updated = device
                                updated.autoSync = enabled
                                store.updateDevice(updated)
                            }
                        ))
                        .toggleStyle(.switch)
                        Button("Check") {
                            Task { await store.checkDeviceStatus(device.id) }
                        }
                        Button("Edit") {
                            edit(device)
                        }
                        Button(role: .destructive) {
                            store.removeDevice(device.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("Devices")
    }
}

private struct MacHistoryView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        Table(store.records) {
            TableColumn("File") { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.filename)
                    Text(record.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TableColumn("Status") { record in
                Text(record.status.title)
            }
            TableColumn("Size") { record in
                Text(MacByteFormat.string(record.byteCount))
            }
            TableColumn("Devices") { record in
                Text("\(record.sentDeviceIDs.count)")
            }
            TableColumn("Error") { record in
                Text(record.lastError ?? "")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("History")
    }
}

struct MacSettingsView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        Form {
            Section("Sync") {
                Toggle("Pause syncing", isOn: $store.isPaused)
                Picker("Delete after sync", selection: $store.autoDeleteDelay) {
                    ForEach(AutoDeleteDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
            }

            Section("Ignored delete folders") {
                if store.ignoredDeleteFolders.isEmpty {
                    Text("No ignored folders.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.ignoredDeleteFolders) { folder in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(folder.title)
                                Text(folder.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                store.removeIgnoredDeleteFolder(folder.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Ignored Folder...") {
                    store.addIgnoredDeleteFolderFromPanel()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }
}

private struct RecentRecordsView: View {
    let records: [MacFileRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Files")
                .font(.headline)
            if records.isEmpty {
                Text("No files scanned yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records) { record in
                    HStack {
                        Image(systemName: icon(for: record))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.filename)
                            Text(record.status.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(MacByteFormat.string(record.byteCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for record: MacFileRecord) -> String {
        switch record.status {
        case .sent, .deleted:
            "checkmark.circle"
        case .failed:
            "exclamationmark.triangle"
        case .sending:
            "arrow.triangle.2.circlepath"
        case .pending:
            "doc"
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MacDeviceEditor: View {
    @State private var device: TaildropDevice
    let save: (TaildropDevice) -> Void
    let cancel: () -> Void

    init(device: TaildropDevice, save: @escaping (TaildropDevice) -> Void, cancel: @escaping () -> Void) {
        self._device = State(initialValue: device)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(device.name.isEmpty ? "Device" : device.name)
                .font(.title2.bold())

            Form {
                TextField("Name", text: $device.name)
                TextField("MagicDNS or Tailscale IP", text: $device.endpoint)
                Toggle("Auto Sync", isOn: $device.autoSync)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Save") {
                    device.endpoint = TaildropDevice.normalizedAddress(from: device.endpoint)
                    save(device)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !TaildropDevice.isValidAddress(device.endpoint))
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
