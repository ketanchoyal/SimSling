import SwiftUI

struct MenuView: View {
    @Bindable var store: SimSlingStore
    @State private var dropTargeted = false
    @State private var urlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if needsAccessibility { accessibilityNotice }
            devicesSection
            dropZone
            destinationSection
            Divider()
            shortcutsSection
            if !store.log.isEmpty {
                Divider()
                logSection
            }
        }
        .padding(16)
        .frame(width: 360)
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack {
            Label { Text("SimSling") } icon: { Image(nsImage: MenuBarIcon.image) }
                .font(.headline)
            Spacer()
            if store.busy { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh booted simulators")
            Menu {
                Toggle("Show Toolbar Beside Simulators", isOn: $store.showSideToolbar)
                Divider()
                Button("Quit SimSling") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
    }

    /// The side toolbars need Accessibility to tell simulator windows apart when several are booted.
    private var needsAccessibility: Bool {
        store.showSideToolbar && store.devices.count > 1 && !WindowIdentity.accessibilityTrusted
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Allow Accessibility", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
            Text("The toolbars beside each simulator need it to know which simulator they belong to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings") {
                WindowIdentity.requestAccessibility(force: true)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Send to").font(.caption).foregroundStyle(.secondary)
            if store.devices.isEmpty {
                Text("No booted simulators").foregroundStyle(.secondary)
            }
            ForEach(store.devices) { device in
                Toggle(isOn: Binding(get: { store.isTargeted(device) }, set: { store.setTargeted(device, $0) })) {
                    HStack {
                        Text(device.name)
                        Spacer()
                        Text(device.runtime).foregroundStyle(.secondary).font(.caption)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 26))
            Text("Drop files or folders here")
            Text("or onto the menu bar icon").font(.caption).foregroundStyle(.secondary)
            Button("Choose Files…") { store.chooseFiles() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Color.accentColor.opacity(0.1) : .clear))
        )
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            store.send(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Destination", selection: $store.mode) {
                ForEach(SimSlingStore.DestinationMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(destinationHint).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.mode == .app {
                Picker("App", selection: $store.appBundleID) {
                    if store.apps.isEmpty { Text("No user apps installed").tag(String?.none) }
                    ForEach(store.apps) { Text($0.name).tag(Optional($0.bundleID)) }
                }
            }
            if store.mode != .media && store.mode != .app {
                Toggle("Open Files app after copying", isOn: $store.openFilesAfterCopy)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }
        }
    }

    private var destinationHint: String {
        switch store.mode {
        case .auto: "Photos, videos and contacts go to their apps, .app bundles get installed, everything else lands in Files › On My iPhone."
        case .files: "Everything goes to Files › On My iPhone."
        case .media: "Import into the Photos and Contacts libraries."
        case .app: "Copy into the app's Documents folder in its data container."
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { store.pushMacClipboard() } label: { Label("Send clipboard", systemImage: "doc.on.clipboard") }
                Spacer()
                Menu {
                    ForEach(store.targets) { device in
                        Button(device.name) { store.pullClipboard(from: .device(device)) }
                    }
                } label: { Label("Get clipboard", systemImage: "arrow.down.doc") }
                    .fixedSize()
                    .disabled(store.targets.isEmpty)
            }
            HStack {
                TextField("Open URL or deep link…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.openURL(urlText) }
                Button("Open") { store.openURL(urlText) }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button { store.revealFilesFolder() } label: { Label("Show Files storage in Finder", systemImage: "folder") }
                .buttonStyle(.link)
                .font(.callout)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Activity").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.clearLog() }.buttonStyle(.link).font(.caption)
            }
            ForEach(store.log.prefix(6)) { entry in
                Label {
                    Text(entry.text).lineLimit(2).font(.caption)
                } icon: {
                    Image(systemName: entry.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(entry.isError ? .orange : .green)
                }
            }
        }
    }
}
