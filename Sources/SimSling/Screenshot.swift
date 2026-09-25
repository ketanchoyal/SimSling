import AppKit

/// Files for screenshots: captured into a temporary folder, then either handed off by drag
/// (and deleted) or saved to the Desktop, the way Simulator.app used to.
enum Screenshots {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SimSling Screenshots", isDirectory: true)

    /// Matches Simulator.app's naming: "Simulator Screenshot - iPhone 17 Pro - 2026-09-25 at 14.30.05.png".
    static func fileName(for device: SimDevice, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Simulator Screenshot - \(device.name) - \(formatter.string(from: date)).png"
    }

    static func capture(_ device: SimDevice) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(for: device))
        try await Simctl.screenshot(device.udid, to: url)
        return url
    }

    /// Moves a screenshot to the Desktop without overwriting anything; returns where it ended up.
    @discardableResult
    static func saveToDesktop(_ url: URL) throws -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let base = url.deletingPathExtension().lastPathComponent
        var destination = desktop.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = desktop.appendingPathComponent("\(base) \(counter).png")
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Deletes a dragged screenshot once the receiving app has had time to read it.
    static func deleteLater(_ url: URL, after delay: TimeInterval = 120) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Clears screenshots left over from a previous run.
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: folder)
    }

    static func playShutter() {
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play()
    }
}

/// A floating screenshot thumbnail. Drag it into any app to use it (the file is then deleted),
/// click to open it, or leave it and it saves to the Desktop after a few seconds.
final class ScreenshotThumbnail: NSPanel {
    let url: URL
    var onFinished: ((ScreenshotThumbnail) -> Void)?

    private var saveTimer: Timer?
    private var finished = false
    static let lifetime: TimeInterval = 5

    init(url: URL, image: NSImage, width: CGFloat) {
        self.url = url
        let aspect = image.size.height / max(image.size.width, 1)
        let size = NSSize(width: width, height: (width * aspect).rounded())
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size), image: image)
        view.owner = self
        contentView = view
    }

    override var canBecomeKey: Bool { false }

    func startTimer() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save(open: false) }
        }
    }

    func pauseTimer() {
        saveTimer?.invalidate()
        saveTimer = nil
    }

    func save(open: Bool) {
        guard !finished else { return }
        if let saved = try? Screenshots.saveToDesktop(url), open {
            NSWorkspace.shared.open(saved)
        }
        finish()
    }

    /// The screenshot was handed to another app (drag or copy): drop the temporary file later.
    func used() {
        guard !finished else { return }
        Screenshots.deleteLater(url)
        finish(animated: false)
    }

    func discard() {
        guard !finished else { return }
        try? FileManager.default.removeItem(at: url)
        finish()
    }

    func copyToPasteboard() {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL, image])
        used()
    }

    private func finish(animated: Bool = true) {
        finished = true
        pauseTimer()
        guard animated else { close(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    override func close() {
        orderOut(nil)
        onFinished?(self)
        onFinished = nil
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    weak var owner: ScreenshotThumbnail?
    private let image: NSImage
    private var mouseDownEvent: NSEvent?
    private var dragging = false

    init(frame: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolTip = "Drag into any app, click to open, or leave it to save to the Desktop"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Hovering keeps the thumbnail around, like the macOS screenshot thumbnail.
    override func mouseEntered(with event: NSEvent) { owner?.pauseTimer() }
    override func mouseExited(with event: NSEvent) { if !dragging { owner?.startTimer() } }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let owner, let start = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }

        dragging = true
        owner.pauseTimer()
        let item = NSPasteboardItem()
        item.setString(owner.url.absoluteString, forType: .fileURL)
        if let data = try? Data(contentsOf: owner.url) { item.setData(data, forType: .png) }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragItem], event: start, source: self)
        owner.alphaValue = 0   // the drag image stands in for the thumbnail
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        if !dragging, mouseDownEvent != nil { owner?.save(open: true) }
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.pauseTimer()
        let menu = NSMenu()
        menu.addItem(withTitle: "Save to Desktop", action: #selector(saveItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteItem), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        // Resume if the menu was dismissed without choosing anything.
        if let owner, owner.isVisible { owner.startTimer() }
    }

    @objc private func saveItem() { owner?.save(open: false) }
    @objc private func copyItem() { owner?.copyToPasteboard() }
    @objc private func deleteItem() { owner?.discard() }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        guard let owner else { return }
        if operation.isEmpty {
            // Dropped nowhere: bring the thumbnail back.
            owner.alphaValue = 1
            owner.startTimer()
        } else {
            owner.used()
        }
    }
}
