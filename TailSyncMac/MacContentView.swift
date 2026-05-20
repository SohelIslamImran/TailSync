import AppKit
import SwiftUI

struct MacMenuBarView: View {
    @Bindable var store: MacSyncStore
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Button("Open TailSync", action: openMainWindow)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(store.currentFilename ?? store.statusMessage)
                    .font(.headline)
                    .lineLimit(1)
                Text(store.currentTargetName.map { "Sending to \($0)" } ?? store.backgroundSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if store.isRunning {
                    ProgressView(value: store.currentProgress)
                    Text("\(MacByteFormat.string(store.currentTransferredBytes)) of \(MacByteFormat.string(store.currentTotalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(store.pendingRecords.count) pending, \(store.failedRecords.count) failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 280, alignment: .leading)

            Divider()
            Button("Sync Now") { Task { await store.syncNow() } }
                .disabled(!store.canSync)
            Button(store.isPaused ? "Resume Sync" : "Pause Sync") { store.togglePaused() }
            Button("Retry Failed") { Task { await store.retryFailed() } }
                .disabled(store.failedRecords.isEmpty)
            Divider()
            Button("Add Folder...") {
                store.addFolderFromPanel()
                openMainWindow()
            }
            SettingsLink { Text("Settings...") }
            Divider()
            Button("Quit TailSync") { NSApp.terminate(nil) }
        }
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
                SidebarRow(title: "Dashboard", systemImage: "gauge.with.dots.needle.33percent")
                    .tag(MacSidebarItem.dashboard)
                SidebarRow(title: "Folders", systemImage: "folder")
                    .tag(MacSidebarItem.folders)
                SidebarRow(title: "Devices", systemImage: "display.and.arrow.down")
                    .tag(MacSidebarItem.devices)
                SidebarRow(title: "History", systemImage: "clock.arrow.circlepath")
                    .tag(MacSidebarItem.history)
                SidebarRow(title: "Delete", systemImage: "trash")
                    .tag(MacSidebarItem.delete)
                SidebarRow(title: "Settings", systemImage: "gearshape")
                    .tag(MacSidebarItem.settings)
            }
            .listStyle(.sidebar)
            .navigationTitle("TailSync")
        } detail: {
            detailView
                .background(MacAppBackground())
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
        case .delete:
            MacDeleteView(store: store)
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
    case delete
    case settings
}

private struct MacDashboardView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeroPanel(store: store)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    MetricCard(title: "Pending", value: "\(store.pendingRecords.count)", systemImage: "tray", tint: .blue)
                    MetricCard(title: "Sent", value: "\(store.sentRecords.count)", systemImage: "checkmark.circle", tint: .green)
                    MetricCard(title: "Failed", value: "\(store.failedRecords.count)", systemImage: "exclamationmark.triangle", tint: .red)
                    MetricCard(title: "Synced", value: MacByteFormat.string(store.completedByteCount), systemImage: "externaldrive", tint: .teal)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Folders", subtitle: "Watched folders upload new and changed files automatically.")
                if store.roots.isEmpty {
                    EmptyActionView(
                        title: "No Folders",
                        subtitle: "Add a folder to keep it synced with your Taildrop devices.",
                        systemImage: "folder.badge.plus",
                        buttonTitle: "Add Folder"
                    ) {
                        store.addFolderFromPanel()
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.roots) { root in
                            FolderRow(root: root, store: store)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Folders")
    }
}

private struct MacDevicesView: View {
    @Bindable var store: MacSyncStore
    let edit: (TaildropDevice) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Devices", subtitle: "Auto Sync devices receive files whenever TailSync is running.")
                if store.devices.isEmpty {
                    EmptyActionView(
                        title: "No Devices",
                        subtitle: "Add a MagicDNS name or Tailscale IP to start uploading.",
                        systemImage: "display.and.arrow.down",
                        buttonTitle: "Add Device"
                    ) {
                        edit(TaildropDevice(id: UUID().uuidString, name: "New Device", endpoint: "", autoSync: true))
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.devices) { device in
                            DeviceCard(device: device, store: store, edit: edit)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Devices")
    }
}

private struct MacHistoryView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "History", subtitle: "Recent file state across every enabled Taildrop device.")
            Table(store.records) {
                TableColumn("File") { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.filename)
                            .font(.body.weight(.medium))
                        Text(record.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                TableColumn("Status") { record in StatusPill(status: record.status) }
                TableColumn("Size") { record in Text(MacByteFormat.string(record.byteCount)) }
                TableColumn("Devices") { record in Text("\(record.sentDeviceIDs.count)") }
                TableColumn("Error") { record in
                    Text(record.lastError ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(24)
        .navigationTitle("History")
    }
}

struct MacSettingsView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Settings", subtitle: store.backgroundSummary)
                VStack(spacing: 12) {
                    GlassToggleRow(
                        title: "Launch at login",
                        subtitle: "Start TailSync automatically when you sign in.",
                        systemImage: "power",
                        isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        )
                    )
                    GlassToggleRow(
                        title: "Watch folders in background",
                        subtitle: "Upload new files while TailSync remains open.",
                        systemImage: "folder.badge.gearshape",
                        isOn: $store.automaticBackgroundSync
                    )
                    GlassToggleRow(
                        title: "Retry when devices return",
                        subtitle: "Recheck failed transfers every few minutes.",
                        systemImage: "arrow.triangle.2.circlepath",
                        isOn: $store.retryWhenDevicesReturn
                    )
                    GlassToggleRow(
                        title: "Pause syncing",
                        subtitle: "Keep TailSync open without uploading.",
                        systemImage: "pause.circle",
                        isOn: $store.isPaused
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle("Settings")
    }
}

private struct MacDeleteView: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Delete", subtitle: "Files move to Trash only after every enabled device receives them.")
                VStack(spacing: 12) {
                    GlassOptionRow(systemImage: "timer", title: "Delay", subtitle: "Choose when synced files move to Trash.") {
                        Picker("Delete after sync", selection: $store.autoDeleteDelay) {
                            ForEach(AutoDeleteDelay.allCases) { delay in
                                Text(delay.title).tag(delay)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    GlassToggleRow(
                        title: "Smart delete on low storage",
                        subtitle: "When disk space is low, TailSync shortens delete delay to 24 hours.",
                        systemImage: "externaldrive.badge.icloud",
                        isOn: $store.smartDeleteEnabled
                    )
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionTitle(title: "Ignored Folders", subtitle: "Files in these folders never move to Trash automatically.")
                        Spacer()
                        Button {
                            store.addIgnoredDeleteFolderFromPanel()
                        } label: {
                            Label("Add Folder", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if store.ignoredDeleteFolders.isEmpty {
                        EmptyActionView(
                            title: "No Ignored Folders",
                            subtitle: "Add folders that should be protected from automatic delete.",
                            systemImage: "folder.badge.plus",
                            buttonTitle: "Add Folder"
                        ) {
                            store.addIgnoredDeleteFolderFromPanel()
                        }
                        .frame(minHeight: 240)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.ignoredDeleteFolders) { folder in
                                IgnoredFolderRow(folder: folder, store: store)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Delete")
    }
}

private struct SidebarRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 15, weight: .medium))
            .padding(.vertical, 4)
    }
}

private struct HeroPanel: View {
    @Bindable var store: MacSyncStore

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.blue.opacity(0.14))
                Image(systemName: store.isRunning ? "arrow.triangle.2.circlepath" : "paperplane.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 8) {
                Text(store.isRunning ? (store.currentFilename ?? "Syncing") : "TailSync")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text(store.currentTargetName.map { "Sending to \($0)" } ?? store.backgroundSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if store.isRunning {
                    ProgressView(value: store.currentProgress)
                    Text("\(MacByteFormat.string(store.currentTransferredBytes)) of \(MacByteFormat.string(store.currentTotalBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(spacing: 10) {
                Button(store.isRunning ? "Stop" : "Sync Now") {
                    if store.isRunning {
                        store.stopSync()
                    } else {
                        Task { await store.syncNow() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(width: 118)
                .disabled(!store.isRunning && !store.canSync)
                Button(store.isPaused ? "Resume" : "Pause") {
                    store.togglePaused()
                }
                .frame(width: 118)
            }
        }
        .padding(22)
        .glassPanel(cornerRadius: 18)
    }
}

private struct FolderRow: View {
    let root: MacSyncRoot
    @Bindable var store: MacSyncStore

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(systemImage: "folder.fill", tint: .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(root.title)
                    .font(.headline)
                Text(root.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            .toggleStyle(.switch)
            .labelsHidden()
            Button(role: .destructive) {
                store.removeRoot(root.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .rowCard()
    }
}

private struct DeviceCard: View {
    let device: TaildropDevice
    @Bindable var store: MacSyncStore
    let edit: (TaildropDevice) -> Void

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(systemImage: device.status.systemImage, tint: statusTint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(device.name)
                        .font(.headline)
                    StatusDot(status: device.status)
                }
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
            .labelsHidden()
            Button("Check") { Task { await store.checkDeviceStatus(device.id) } }
                .buttonStyle(.bordered)
                .frame(width: 76)
            Button("Edit") { edit(device) }
                .buttonStyle(.bordered)
                .frame(width: 76)
            Button(role: .destructive) {
                store.removeDevice(device.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .rowCard()
    }

    private var statusTint: Color {
        device.status == .online ? .green : device.status == .checking ? .blue : .orange
    }
}

private struct RecentRecordsView: View {
    let records: [MacFileRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Files")
                .font(.headline)
            if records.isEmpty {
                Text("No files scanned yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ForEach(records) { record in
                    HStack(spacing: 12) {
                        RowIcon(systemImage: icon(for: record), tint: tint(for: record))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.filename)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Text(record.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(MacByteFormat.string(record.byteCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        StatusPill(status: record.status)
                    }
                    if record.id != records.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(18)
        .glassPanel(cornerRadius: 14)
    }

    private func icon(for record: MacFileRecord) -> String {
        switch record.status {
        case .sent, .deleted: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .sending: "arrow.triangle.2.circlepath.circle.fill"
        case .pending: "doc.fill"
        }
    }

    private func tint(for record: MacFileRecord) -> Color {
        switch record.status {
        case .sent, .deleted: .green
        case .failed: .red
        case .sending: .blue
        case .pending: .secondary
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RowIcon(systemImage: systemImage, tint: tint)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassPanel(cornerRadius: 14)
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
        VStack(alignment: .leading, spacing: 18) {
            Text(device.name.isEmpty ? "Device" : device.name)
                .font(.title2.bold())
            VStack(spacing: 12) {
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
        .frame(width: 440)
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyActionView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            RowIcon(systemImage: systemImage, tint: .blue)
                .scaleEffect(1.35)
            Text(title)
                .font(.title.bold())
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(32)
        .glassPanel(cornerRadius: 18)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(18)
        .glassPanel(cornerRadius: 14)
    }
}

private struct GlassToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(systemImage: systemImage, tint: isOn ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            Button {
                withAnimation(.smooth(duration: 0.18)) {
                    isOn.toggle()
                }
            } label: {
                GlassSwitch(isOn: isOn)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
        }
        .rowCard()
    }
}

private struct GlassSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.blue.opacity(0.78) : Color.secondary.opacity(0.18))
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.65), lineWidth: 1)
                }
            Circle()
                .fill(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 3)
                .padding(4)
        }
        .frame(width: 58, height: 32)
    }
}

private struct GlassOptionRow<Content: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(systemImage: systemImage, tint: .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 18)
            content
        }
        .rowCard()
    }
}

private struct IgnoredFolderRow: View {
    let folder: MacIgnoredFolder
    @Bindable var store: MacSyncStore

    var body: some View {
        HStack(spacing: 14) {
            RowIcon(systemImage: "folder.fill.badge.minus", tint: .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.title)
                    .font(.headline)
                Text(folder.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(role: .destructive) {
                store.removeIgnoredDeleteFolder(folder.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .rowCard()
    }
}

private struct RowIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 42, height: 42)
            .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StatusPill: View {
    let status: TransferStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var tint: Color {
        switch status {
        case .sent, .deleted: .green
        case .failed: .red
        case .sending: .blue
        case .pending: .secondary
        }
    }
}

private struct StatusDot: View {
    let status: DeviceStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private var tint: Color {
        status == .online ? .green : status == .checking ? .blue : .orange
    }
}

private struct MacAppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.98, blue: 1.0),
                    Color(red: 0.98, green: 0.995, blue: 0.99),
                    Color(red: 0.92, green: 0.97, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.white.opacity(0.18)
        }
        .ignoresSafeArea()
    }
}

private extension View {
    func rowCard() -> some View {
        self
            .padding(14)
            .glassPanel(cornerRadius: 14)
    }

    func glassPanel(cornerRadius: CGFloat) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.74),
                                Color(red: 0.92, green: 0.98, blue: 1.0).opacity(0.54)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            }
            .shadow(color: Color.blue.opacity(0.06), radius: 24, x: 0, y: 14)
    }
}
