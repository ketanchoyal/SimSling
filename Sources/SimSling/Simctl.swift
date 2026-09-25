import Foundation

struct SimDevice: Identifiable, Hashable, Sendable {
    let udid: String
    let name: String
    /// Human readable runtime, e.g. "iOS 27.0".
    let runtime: String
    var id: String { udid }
}

struct SimApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let name: String
    let dataContainer: URL?
    var id: String { bundleID }
}

struct SimSlingError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Process runner

enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private final class Box: @unchecked Sendable { var data = Data() }

    /// Runs a process off the main thread and collects its output.
    static func run(_ executable: String, _ arguments: [String], stdin: Data? = nil) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let input = stdin.map { _ in Pipe() }
                process.standardInput = input ?? FileHandle.nullDevice

                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let input, let stdin {
                    input.fileHandleForWriting.write(stdin)
                    try? input.fileHandleForWriting.close()
                }

                // Drain stderr concurrently so a chatty process can't fill the pipe and deadlock.
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: outData, stderr: errBox.data))
            }
        }
    }
}

// MARK: - simctl

enum Simctl {
    static let filesAppBundleID = "com.apple.DocumentsApp"

    @discardableResult
    static func run(_ arguments: [String], stdin: Data? = nil) async throws -> Data {
        let result = try await Shell.run("/usr/bin/xcrun", ["simctl"] + arguments, stdin: stdin)
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SimSlingError(message.isEmpty ? "simctl \(arguments.first ?? "") failed (\(result.status))" : message)
        }
        return result.stdout
    }

    static func bootedDevices() async throws -> [SimDevice] {
        struct List: Decodable {
            struct Device: Decodable { let udid: String; let name: String; let state: String }
            let devices: [String: [Device]]
        }
        let list = try JSONDecoder().decode(List.self, from: try await run(["list", "devices", "booted", "-j"]))
        return list.devices
            .flatMap { runtime, devices in
                devices.filter { $0.state == "Booted" }
                    .map { SimDevice(udid: $0.udid, name: $0.name, runtime: prettyRuntime(runtime)) }
            }
            .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-0" -> "iOS 27.0"
    static func prettyRuntime(_ identifier: String) -> String {
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        var parts = tail.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return tail }
        let platform = parts.removeFirst()
        return parts.isEmpty ? platform : "\(platform) \(parts.joined(separator: "."))"
    }

    /// User-installed apps on a device (what you'd want to seed with data).
    static func userApps(on udid: String) async throws -> [SimApp] {
        let data = try await run(["listapps", udid])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else {
            throw SimSlingError("Couldn't parse app list")
        }
        return plist.compactMap { bundleID, info in
            guard info["ApplicationType"] as? String == "User" else { return nil }
            let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? bundleID
            let container = (info["DataContainer"] as? String).flatMap(URL.init(string:))
            return SimApp(bundleID: bundleID, name: name, dataContainer: container)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The folder the Files app shows as "On My iPhone / On My iPad".
    static func filesAppStorage(on udid: String) async throws -> URL {
        let output = String(decoding: try await run(["get_app_container", udid, filesAppBundleID, "groups"]), as: UTF8.self)
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if columns.count == 2, columns[0] == "group.com.apple.FileProvider.LocalStorage" {
                return URL(fileURLWithPath: columns[1]).appendingPathComponent("File Provider Storage", isDirectory: true)
            }
        }
        throw SimSlingError("Files app storage not found on this simulator")
    }

    static func appDocuments(bundleID: String, on udid: String) async throws -> URL {
        let path = String(decoding: try await run(["get_app_container", udid, bundleID, "data"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).appendingPathComponent("Documents", isDirectory: true)
    }

    static func addMedia(_ files: [URL], on udid: String) async throws {
        try await run(["addmedia", udid] + files.map(\.path))
    }

    static func install(_ app: URL, on udid: String) async throws {
        try await run(["install", udid, app.path])
    }

    static func launch(_ bundleID: String, on udid: String) async throws {
        try await run(["launch", udid, bundleID])
    }

    static func openURL(_ url: String, on udid: String) async throws {
        try await run(["openurl", udid, url])
    }

    /// Syncs the full pasteboard (text, images, URLs…) between "host" and a device.
    static func syncPasteboard(from source: String, to destination: String) async throws {
        try await run(["pbsync", source, destination])
    }

    static func copyText(_ text: String, on udid: String) async throws {
        try await run(["pbcopy", udid], stdin: Data(text.utf8))
    }
}
