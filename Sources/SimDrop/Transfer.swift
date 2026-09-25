import Foundation
import UniformTypeIdentifiers

/// Where dropped files should end up on the simulator.
enum Destination: Hashable, Sendable {
    /// Photos/videos/vCards -> Photos & Contacts, .app bundles -> installed, everything else -> Files app.
    case auto
    /// Files app, "On My iPhone" (works for any file or folder).
    case files
    /// Photos / Contacts library via `simctl addmedia`.
    case media
    /// The Documents folder of an installed app's data container.
    case appDocuments(bundleID: String)

    var isAppDocuments: Bool {
        if case .appDocuments = self { return true }
        return false
    }
}

struct TransferReport: Sendable {
    let device: SimDevice
    let succeeded: [String]
    let failed: [String]
}

enum Transfer {
    enum Route: Sendable { case media, files, install }

    static func route(for url: URL) -> Route {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let ext = url.pathExtension.lowercased()
        if isDirectory.boolValue {
            return ext == "app" ? .install : .files
        }
        if let type = UTType(filenameExtension: ext) {
            // addmedia can't import SVG even though it's an image type.
            let isPhoto = type.conforms(to: .image) && !type.conforms(to: .svg)
            if isPhoto || type.conforms(to: .movie) || type.conforms(to: .vCard) { return .media }
        }
        return .files
    }

    /// Sends files to one device. Never throws: per-item failures are collected into the report.
    static func send(_ urls: [URL], to device: SimDevice, destination: Destination, openFilesApp: Bool) async -> TransferReport {
        var succeeded: [String] = []
        var failed: [String] = []

        var media: [URL] = [], files: [URL] = [], apps: [URL] = []
        for url in urls {
            switch destination {
            case .media: media.append(url)
            case .files, .appDocuments: files.append(url)
            case .auto:
                switch route(for: url) {
                case .media: media.append(url)
                case .files: files.append(url)
                case .install: apps.append(url)
                }
            }
        }

        if !media.isEmpty {
            do {
                try await Simctl.addMedia(media, on: device.udid)
                succeeded += media.map { "\($0.lastPathComponent) → Photos/Contacts" }
            } catch {
                failed += media.map { "\($0.lastPathComponent): \(error.localizedDescription)" }
            }
        }

        for app in apps {
            do {
                try await Simctl.install(app, on: device.udid)
                succeeded.append("\(app.lastPathComponent) installed")
            } catch {
                failed.append("\(app.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !files.isEmpty {
            do {
                let (folder, label) = try await targetFolder(for: destination, on: device)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for file in files {
                    do {
                        try await copy(file, into: folder)
                        succeeded.append("\(file.lastPathComponent) → \(label)")
                    } catch {
                        failed.append("\(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if openFilesApp, !destination.isAppDocuments {
                    try? await Simctl.launch(Simctl.filesAppBundleID, on: device.udid)
                }
            } catch {
                failed += files.map { "\($0.lastPathComponent): \(error.localizedDescription)" }
            }
        }

        return TransferReport(device: device, succeeded: succeeded, failed: failed)
    }

    private static func targetFolder(for destination: Destination, on device: SimDevice) async throws -> (URL, String) {
        if case .appDocuments(let bundleID) = destination {
            return (try await Simctl.appDocuments(bundleID: bundleID, on: device.udid), "\(bundleID)/Documents")
        }
        return (try await Simctl.filesAppStorage(on: device.udid), "Files")
    }

    /// Copies with rsync: Finder copies into a simulator's File Provider storage can end up
    /// as zero-byte files (see developer.apple.com/forums/thread/846994), rsync writes real bytes.
    private static func copy(_ source: URL, into folder: URL) async throws {
        let result = try await Shell.run("/usr/bin/rsync", ["-rt", source.path, folder.path + "/"])
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimDropError(message.isEmpty ? "rsync failed (\(result.status))" : message)
        }
    }
}
