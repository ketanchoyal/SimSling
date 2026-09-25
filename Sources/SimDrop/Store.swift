import AppKit
import Observation

@MainActor
@Observable
final class SimDropStore {
    enum DestinationMode: String, CaseIterable, Identifiable {
        case auto = "Auto", files = "Files", media = "Photos", app = "App"
        var id: String { rawValue }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date = Date()
        let isError: Bool
        let text: String
    }

    private(set) var devices: [SimDevice] = []
    /// Devices are targeted unless the user switched them off, so newly booted sims are included by default.
    private(set) var excluded: Set<String> = []
    private(set) var apps: [SimApp] = []
    private(set) var log: [LogEntry] = []
    private(set) var busy = false

    var mode: DestinationMode = .auto {
        didSet { if mode == .app { Task { await loadApps() } } }
    }
    var appBundleID: String?
    var openFilesAfterCopy = UserDefaults.standard.object(forKey: "openFilesAfterCopy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openFilesAfterCopy, forKey: "openFilesAfterCopy") }
    }

    /// Called with `true`/`false` when a transfer finishes, so the menu bar icon can flash.
    var onTransferFinished: ((Bool) -> Void)?

    var targets: [SimDevice] { devices.filter { !excluded.contains($0.udid) } }

    func isTargeted(_ device: SimDevice) -> Bool { !excluded.contains(device.udid) }

    func setTargeted(_ device: SimDevice, _ on: Bool) {
        if on { excluded.remove(device.udid) } else { excluded.insert(device.udid) }
        if mode == .app { Task { await loadApps() } }
    }

    func refresh() async {
        do {
            devices = try await Simctl.bootedDevices()
        } catch {
            append(error: "Couldn't list simulators: \(error.localizedDescription)")
        }
        if mode == .app { await loadApps() }
    }

    /// Apps offered for the "App" destination come from the first targeted device.
    func loadApps() async {
        guard let device = targets.first else { apps = []; return }
        do {
            apps = try await Simctl.userApps(on: device.udid)
            if appBundleID == nil || !apps.contains(where: { $0.bundleID == appBundleID }) {
                appBundleID = apps.first?.bundleID
            }
        } catch {
            append(error: "Couldn't list apps: \(error.localizedDescription)")
        }
    }

    // MARK: Actions

    func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform { store in
            let destination: Destination
            switch store.mode {
            case .auto: destination = .auto
            case .files: destination = .files
            case .media: destination = .media
            case .app:
                guard let bundleID = store.appBundleID else { throw SimDropError("Pick an app first") }
                destination = .appDocuments(bundleID: bundleID)
            }
            let openFiles = store.openFilesAfterCopy
            let reports = await withTaskGroup(of: TransferReport.self) { group in
                for device in store.targets {
                    group.addTask { await Transfer.send(urls, to: device, destination: destination, openFilesApp: openFiles) }
                }
                var reports: [TransferReport] = []
                for await report in group { reports.append(report) }
                return reports
            }
            var ok = true
            for report in reports {
                for line in report.succeeded { store.append("\(report.device.name): \(line)") }
                for line in report.failed { store.append(error: "\(report.device.name): \(line)"); ok = false }
            }
            return ok
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Send"
        NSApp.activate()
        if panel.runModal() == .OK { send(panel.urls) }
    }

    func pushMacClipboard() {
        perform { store in
            for device in store.targets {
                try await Simctl.syncPasteboard(from: "host", to: device.udid)
                store.append("Mac clipboard → \(device.name)")
            }
            return true
        }
    }

    func pullClipboard(from device: SimDevice) {
        perform { store in
            try await Simctl.syncPasteboard(from: device.udid, to: "host")
            store.append("\(device.name) clipboard → Mac")
            return true
        }
    }

    func openURL(_ raw: String) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        perform { store in
            for device in store.targets {
                try await Simctl.openURL(url, on: device.udid)
                store.append("Opened \(url) on \(device.name)")
            }
            return true
        }
    }

    func revealFilesFolder() {
        perform { store in
            guard let device = store.targets.first else { throw SimDropError("No simulator selected") }
            let folder = try await Simctl.filesAppStorage(on: device.udid)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            return true
        }
    }

    func clearLog() { log.removeAll() }

    // MARK: Helpers

    private func perform(_ work: @escaping @MainActor (SimDropStore) async throws -> Bool) {
        Task {
            busy = true
            defer { busy = false }
            await refresh()
            guard !targets.isEmpty else {
                append(error: "No booted simulator selected")
                onTransferFinished?(false)
                return
            }
            do {
                onTransferFinished?(try await work(self))
            } catch {
                append(error: error.localizedDescription)
                onTransferFinished?(false)
            }
        }
    }

    private func append(_ text: String) { push(LogEntry(isError: false, text: text)) }
    private func append(error text: String) { push(LogEntry(isError: true, text: text)) }
    private func push(_ entry: LogEntry) {
        log.insert(entry, at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }
}
