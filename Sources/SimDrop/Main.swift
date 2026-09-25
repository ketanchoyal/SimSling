import AppKit

@main
enum Main {
    // NSApplication.delegate is weak; keep the delegate alive for the life of the app.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        // Finder passes -psn_… / -NS… flags when launching the app bundle; anything else is a CLI call.
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") && !$0.hasPrefix("-NS") }
        if !arguments.isEmpty {
            exit(CLI.runBlocking(Array(arguments)))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
