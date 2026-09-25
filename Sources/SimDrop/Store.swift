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

    var showSideToolbar = UserDefaults.standard.object(forKey: "showSideToolbar") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showSideToolbar, forKey: "showSideToolbar")
            onSideToolbarChanged?(showSideToolbar)
        }
    }

    struct Outcome: Equatable {
        let id = UUID()
        let ok: Bool
        /// Devices the action ran on, so each side toolbar can show its own result.
        let udids: Set<String>
        /// Set when the action came from a side toolbar.
        let window: String?
    }

    /// The result of the most recent action.
    private(set) var lastOutcome: Outcome?

    /// Called with `true`/`false` when an action finishes, so the menu bar icon can flash.
    var onTransferFinished: ((Bool) -> Void)?
    var onSideToolbarChanged: ((Bool) -> Void)?

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
    //
    // Every action takes a `Target`. The menu uses `.checked`; a side toolbar uses `.window` so it only
    // ever acts on the simulator it's docked beside.

    enum Target {
        /// The simulators checked in the menu.
        case checked
        /// One specific device.
        case device(SimDevice)
        /// The simulator whose window has this title (Device Hub titles windows with the device name).
        case window(title: String?)
    }

    func send(_ urls: [URL], to target: Target = .checked) {
        guard !urls.isEmpty else { return }
        perform(on: target) { store, targets in
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
                for device in targets {
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

    func chooseFiles(for target: Target = .checked) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Send"
        NSApp.activate()
        if panel.runModal() == .OK { send(panel.urls, to: target) }
    }

    func pushMacClipboard(to target: Target = .checked) {
        perform(on: target) { store, targets in
            for device in targets {
                try await Simctl.syncPasteboard(from: "host", to: device.udid)
                store.append("Mac clipboard → \(device.name)")
            }
            return true
        }
    }

    func pullClipboard(from target: Target) {
        perform(on: target) { store, targets in
            for device in targets.prefix(1) {
                try await Simctl.syncPasteboard(from: device.udid, to: "host")
                store.append("\(device.name) clipboard → Mac")
            }
            return true
        }
    }

    func openURL(_ raw: String, on target: Target = .checked) {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        perform(on: target) { store, targets in
            for device in targets {
                try await Simctl.openURL(url, on: device.udid)
                store.append("Opened \(url) on \(device.name)")
            }
            return true
        }
    }

    func revealFilesFolder(on target: Target = .checked) {
        perform(on: target) { _, targets in
            let folder = try await Simctl.filesAppStorage(on: targets[0].udid)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            return true
        }
    }

    func clearLog() { log.removeAll() }

    // MARK: Helpers

    private func perform(on target: Target, _ work: @escaping @MainActor (SimDropStore, [SimDevice]) async throws -> Bool) {
        Task {
            busy = true
            defer { busy = false }
            // Resolve against a fresh device list so a just-booted simulator is found.
            await refresh()
            let window: String? = if case .window(let title) = target { title } else { nil }
            do {
                let targets = try resolve(target)
                finish(ok: try await work(self, targets), udids: Set(targets.map(\.udid)), window: window)
            } catch {
                append(error: error.localizedDescription)
                finish(ok: false, udids: [], window: window)
            }
        }
    }

    /// Never widens a toolbar's target: a window that can't be matched to exactly one device is an error,
    /// not a reason to fall back to every checked simulator.
    private func resolve(_ target: Target) throws -> [SimDevice] {
        switch target {
        case .checked:
            guard !targets.isEmpty else { throw SimDropError("No booted simulator selected") }
            return targets
        case .device(let device):
            guard let match = devices.first(where: { $0.udid == device.udid }) else {
                throw SimDropError("\(device.name) is no longer booted")
            }
            return [match]
        case .window(let title):
            guard let title else {
                throw SimDropError("Can't read this simulator window's name. Allow SimDrop in System Settings › Privacy & Security › Screen Recording.")
            }
            let matches = devices.filter { $0.name == title }
            switch matches.count {
            case 1: return matches
            case 0: throw SimDropError("No booted simulator named \(title)")
            default: throw SimDropError("More than one booted simulator is named \(title). Rename one so SimDrop can tell them apart.")
            }
        }
    }

    private func finish(ok: Bool, udids: Set<String>, window: String?) {
        lastOutcome = Outcome(ok: ok, udids: udids, window: window)
        onTransferFinished?(ok)
    }

    private func append(_ text: String) { push(LogEntry(isError: false, text: text)) }
    private func append(error text: String) { push(LogEntry(isError: true, text: text)) }
    private func push(_ entry: LogEntry) {
        log.insert(entry, at: 0)
        if log.count > 50 { log.removeLast(log.count - 50) }
    }
}
