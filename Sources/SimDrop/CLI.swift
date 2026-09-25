import AppKit

enum CLI {
    static let usage = """
    usage: simdrop <command> [options]

    Commands:
      list                          List booted simulators
      apps                          List user-installed apps (first targeted simulator)
      send <path>...                Send files/folders (auto-routed, see below)
      clip-to-sim                   Push the Mac clipboard to the simulator(s)
      clip-from-sim                 Copy the simulator clipboard to the Mac
      open <url>                    Open a URL / deep link on the simulator(s)
      files-path                    Print the Files app "On My iPhone" folder

    Options:
      -d, --device <udid|name>      Target a simulator (repeatable). Default: all booted.
          --files                   send: put everything in Files › On My iPhone
          --media                   send: import into Photos / Contacts
          --app <bundle-id>         send: copy into the app's Documents folder
          --no-open                 send: don't open the Files app afterwards

    Auto routing: images/videos/.vcf -> Photos/Contacts, .app -> install, anything else -> Files.
    """

    private final class ExitCode: @unchecked Sendable { var value: Int32 = 0 }

    /// Runs the CLI on a background task while blocking the main thread until it finishes.
    static func runBlocking(_ arguments: [String]) -> Int32 {
        let code = ExitCode()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            code.value = await run(arguments)
            semaphore.signal()
        }
        semaphore.wait()
        return code.value
    }

    static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments[...]
        let command = args.popFirst() ?? "help"
        var deviceFilters: [String] = []
        var destination = Destination.auto
        var openFiles = true
        var positional: [String] = []

        while let arg = args.popFirst() {
            switch arg {
            case "-d", "--device":
                guard let value = args.popFirst() else { return fail("\(arg) needs a value") }
                deviceFilters.append(value)
            case "--files": destination = .files
            case "--media": destination = .media
            case "--app":
                guard let value = args.popFirst() else { return fail("--app needs a bundle id") }
                destination = .appDocuments(bundleID: value)
            case "--no-open": openFiles = false
            case "-h", "--help": print(usage); return 0
            default: positional.append(arg)
            }
        }

        do {
            if command == "help" || command == "-h" || command == "--help" {
                print(usage)
                return 0
            }

            let booted = try await Simctl.bootedDevices()
            let targets = deviceFilters.isEmpty ? booted : booted.filter { device in
                deviceFilters.contains { $0 == device.udid || $0.caseInsensitiveCompare(device.name) == .orderedSame }
            }

            if command == "list" {
                for device in booted { print("\(device.udid)  \(device.name) (\(device.runtime))") }
                return 0
            }
            guard !targets.isEmpty else { return fail("No matching booted simulator") }

            switch command {
            case "apps":
                for app in try await Simctl.userApps(on: targets[0].udid) { print("\(app.bundleID)  \(app.name)") }

            case "send":
                guard !positional.isEmpty else { return fail("send needs at least one path") }
                let urls = positional.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
                if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                    return fail("No such file: \(missing.path)")
                }
                var ok = true
                for device in targets {
                    let report = await Transfer.send(urls, to: device, destination: destination, openFilesApp: openFiles)
                    for line in report.succeeded { print("✓ \(device.name): \(line)") }
                    for line in report.failed { printError("✗ \(device.name): \(line)"); ok = false }
                }
                return ok ? 0 : 1

            case "clip-to-sim":
                for device in targets {
                    try await Simctl.syncPasteboard(from: "host", to: device.udid)
                    print("✓ Mac clipboard → \(device.name)")
                }

            case "clip-from-sim":
                try await Simctl.syncPasteboard(from: targets[0].udid, to: "host")
                print("✓ \(targets[0].name) clipboard → Mac")

            case "open":
                guard let url = positional.first else { return fail("open needs a URL") }
                for device in targets {
                    try await Simctl.openURL(url, on: device.udid)
                    print("✓ Opened \(url) on \(device.name)")
                }

            case "files-path":
                for device in targets { print(try await Simctl.filesAppStorage(on: device.udid).path) }

            default:
                return fail("Unknown command '\(command)'\n\n\(usage)")
            }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Int32 {
        printError("simdrop: \(message)")
        return 1
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
