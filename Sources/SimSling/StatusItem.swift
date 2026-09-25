import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SimSlingStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private lazy var sideToolbars = SideToolbarController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Screenshots.removeLeftovers()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        statusItem.button?.image = MenuBarIcon.image

        // The overlay handles both clicks and drops so the menu bar icon itself is a drop target.
        let overlay = StatusDropView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.togglePopover() }
        overlay.onDragHighlight = { button.highlight($0) }
        overlay.onDrop = { [weak self] urls in self?.store.send(urls) }
        button.addSubview(overlay)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuView(store: store))

        store.onTransferFinished = { [weak self] ok in self?.flash(ok) }
        store.onSideToolbarChanged = { [weak self] in self?.sideToolbars.setEnabled($0) }
        sideToolbars.setEnabled(store.showSideToolbar)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func flash(_ ok: Bool) {
        setIcon(ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            statusItem.button?.image = MenuBarIcon.image
        }
    }

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SimSling")
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}

/// Transparent view laid over the status bar button that accepts file drags.
final class StatusDropView: NSView {
    var onClick: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onDragHighlight: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        onDragHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onDragHighlight?(false) }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDragHighlight?(false)
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func fileURLs(from info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
