import AppKit
import SwiftUI

/// Pins a small toolbar panel next to every simulator window (Xcode 27 Device Hub, or the
/// classic Simulator.app) and keeps it glued there as the window moves.
@MainActor
final class SideToolbarController {
    static let hostBundleIDs: Set<String> = ["com.apple.dt.Devices", "com.apple.iphonesimulator"]

    private let store: SimSlingStore
    private var panels: [Int: SidePanel] = [:]   // keyed by the simulator's CGWindowID
    /// When each simulator window was last seen on screen.
    private var lastSeen: [Int: Date] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Simulator windows briefly drop out of the window list while moving between displays.
    /// Riding that out keeps the toolbar from blinking or being rebuilt mid-drag.
    private let hideAfter: TimeInterval = 0.35
    /// A panel whose window has been gone this long is discarded instead of kept for reuse.
    private let discardAfter: TimeInterval = 30

    init(store: SimSlingStore) {
        self.store = store
    }

    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        // Poll quickly while the simulator host is frontmost (the user may be dragging a window)
        // and slowly otherwise.
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.schedule()
                self?.tick()
            }
        })
        // Panels are on every Space, so hide them the moment the Space changes; the next tick
        // brings back the ones whose simulator is on the new Space.
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (number, panel) in self.panels {
                    panel.orderOut(nil)
                    self.lastSeen[number] = .distantPast
                }
                self.tick()
            }
        })
        schedule()
        tick()
    }

    private func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        lastSeen.removeAll()
    }

    private func schedule() {
        timer?.invalidate()
        let hostActive = Self.hostBundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        timer = Timer.scheduledTimer(withTimeInterval: hostActive ? 1.0 / 30 : 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private struct HostWindow {
        let number: Int
        let title: String?
        let frame: CGRect   // CoreGraphics coordinates: top-left origin of the primary display
    }

    private func tick() {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var zIndex: [Int: Int] = [:]   // 0 = frontmost
        var hosts: [HostWindow] = []
        let deviceNames = Set(store.devices.map(\.name))
        for (index, window) in info.enumerated() {
            guard let number = window[kCGWindowNumber as String] as? Int else { continue }
            zIndex[number] = index
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, isHost(pid),
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 150, frame.height >= 150
            else { continue }
            // Window titles need Screen Recording permission. With a title, only attach to windows that
            // are actually simulators; without one, attach to every large host window.
            let title = (window[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let title, !deviceNames.isEmpty, !deviceNames.contains(title) { continue }
            hosts.append(HostWindow(number: number, title: title, frame: frame))
        }

        var needsDeviceRefresh = false
        let now = Date()
        for host in hosts {
            lastSeen[host.number] = now
            let panel: SidePanel
            if let existing = panels[host.number] {
                panel = existing
            } else {
                panel = SidePanel(store: store)
                panels[host.number] = panel
                needsDeviceRefresh = true
            }
            panel.model.windowTitle = host.title
            position(panel, beside: host.frame)

            // Keep the panel directly above its simulator: in front of it, but behind any window
            // that covers the simulator.
            let panelZ = zIndex[panel.windowNumber]
            if panelZ == nil || panelZ != zIndex[host.number].map({ $0 - 1 }) {
                panel.order(.above, relativeTo: host.number)
            }
        }
        hideMissingPanels(now: now)
        if needsDeviceRefresh { Task { await store.refresh() } }
    }

    private var hostCache: [pid_t: Bool] = [:]

    /// Resolve by PID: Device Hub's entry in `NSWorkspace.runningApplications` reports pid -1,
    /// but looking the process up directly returns the right bundle ID.
    private func isHost(_ pid: pid_t) -> Bool {
        if let cached = hostCache[pid] { return cached }
        let app = NSRunningApplication(processIdentifier: pid)
        let result = Self.hostBundleIDs.contains(app?.bundleIdentifier ?? "")
        // Only cache live processes so a recycled PID can't be misclassified forever.
        if app != nil { hostCache[pid] = result }
        return result
    }

    /// Hides panels whose simulator window has been missing for a moment, and discards ones
    /// that have been gone for a long time. Hidden panels are reused if the window comes back.
    private func hideMissingPanels(now: Date) {
        for (number, panel) in panels {
            let missingFor = now.timeIntervalSince(lastSeen[number] ?? .distantPast)
            guard missingFor > hideAfter else { continue }
            if panel.isVisible { panel.orderOut(nil) }
            if missingFor > discardAfter {
                panels[number] = nil
                lastSeen[number] = nil
            }
        }
    }

    private func position(_ panel: SidePanel, beside cgFrame: CGRect) {
        guard let primary = NSScreen.screens.first else { return }
        let gap: CGFloat = 8
        // Flip from CoreGraphics (top-left) to AppKit (bottom-left) coordinates.
        let host = NSRect(x: cgFrame.minX, y: primary.frame.maxY - cgFrame.maxY, width: cgFrame.width, height: cgFrame.height)
        panel.hostFrame = host
        let size = panel.frame.size
        let screen = NSScreen.screens.max { overlap($0.frame, host) < overlap($1.frame, host) }
        let visible = screen?.visibleFrame ?? primary.visibleFrame

        var x = host.maxX + gap
        let dockLeft = x + size.width > visible.maxX                            // no room: dock on the left
        if dockLeft { x = host.minX - gap - size.width }
        panel.labelsOnLeft = dockLeft
        var y = host.maxY - size.height - 44                                     // just below the title bar
        y = min(max(y, visible.minY), visible.maxY - size.height)

        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != origin {
            panel.hideHoverLabel()
            panel.setFrameOrigin(origin)
        }
    }

    private func overlap(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }
}

@MainActor
@Observable
final class SidePanelModel {
    /// Title of the simulator window this panel is attached to (its device name), if readable.
    var windowTitle: String?

    /// ID of the button under the pointer, drives the hover highlight.
    var hovered: String?

    struct ButtonInfo { var title: String; var detail: String; var frame: CGRect }
    /// Toolbar buttons by ID, with frames in SwiftUI (top-left) coordinates of the hosting view.
    @ObservationIgnored var buttons: [String: ButtonInfo] = [:]
    @ObservationIgnored var dismissHover: (() -> Void)?
    @ObservationIgnored var showScreenshot: ((URL) -> Void)?
}

/// Hosting view that tracks the pointer even while SimSling is inactive. SwiftUI's `onHover` only
/// fires for the active app, and these panels never activate the app.
final class ToolbarHostingView: NSHostingView<SideToolbarView> {
    var onPointer: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onPointer?(isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y))
    }
}

/// Borderless, non-activating panel: clicking its buttons doesn't pull focus away from the simulator.
final class SidePanel: NSPanel {
    let model = SidePanelModel()

    init(store: SimSlingStore) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        level = .normal
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        acceptsMouseMovedEvents = true
        let hosting = ToolbarHostingView(rootView: SideToolbarView(store: store, model: model))
        contentView = hosting
        setContentSize(hosting.fittingSize)
        hosting.onPointer = { [weak self] point in self?.pointerMoved(to: point) }
        model.dismissHover = { [weak self] in self?.hideHoverLabel() }
        model.showScreenshot = { [weak self] url in self?.showScreenshot(url) }
    }

    /// The simulator window's frame in AppKit screen coordinates, kept current by the controller.
    var hostFrame: NSRect = .zero {
        didSet { if hostFrame.size != oldValue.size { layoutThumbnails() } }
    }

    // MARK: Screenshots

    private var thumbnails: [ScreenshotThumbnail] = []

    func showScreenshot(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        flash()
        let thumbnail = ScreenshotThumbnail(url: url, image: image, width: 110)
        thumbnail.onFinished = { [weak self] finished in
            guard let self else { return }
            self.removeChildWindow(finished)
            self.thumbnails.removeAll { $0 === finished }
            self.layoutThumbnails()
        }
        thumbnails.append(thumbnail)
        layoutThumbnails()
        // As child windows the thumbnails move with the toolbar, and so with the simulator.
        addChildWindow(thumbnail, ordered: .above)
        thumbnail.startTimer()
    }

    /// Stacks thumbnails up from the simulator's bottom-right corner, newest at the bottom.
    private func layoutThumbnails() {
        guard hostFrame != .zero else { return }
        var y = hostFrame.minY + 18
        for thumbnail in thumbnails.reversed() {
            let size = thumbnail.frame.size
            thumbnail.setFrameOrigin(NSPoint(x: (hostFrame.maxX - 18 - size.width).rounded(), y: y.rounded()))
            y += size.height + 10
        }
    }

    /// A quick white flash over the simulator, like Simulator.app's screenshot.
    private func flash() {
        guard hostFrame != .zero else { return }
        let flash = NSPanel(contentRect: hostFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        flash.backgroundColor = .clear
        flash.isOpaque = false
        flash.hasShadow = false
        flash.ignoresMouseEvents = true
        flash.isReleasedWhenClosed = false
        flash.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: hostFrame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.cgColor
        view.layer?.cornerRadius = 40
        flash.contentView = view
        flash.alphaValue = 0.75
        addChildWindow(flash, ordered: .above)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            flash.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.removeChildWindow(flash)
                flash.orderOut(nil)
            }
        })
    }

    // Lets the URL text field receive typing.
    override var canBecomeKey: Bool { true }

    /// Which side of the toolbar hover labels appear on: away from the simulator.
    var labelsOnLeft = false

    private let hoverLabel = HoverLabelWindow()

    /// `point` is in top-left coordinates of the content view, `nil` when the pointer leaves.
    private func pointerMoved(to point: CGPoint?) {
        guard let point, let (id, button) = model.buttons.first(where: {
            // Grow each frame over the padding and the gaps between buttons so the label doesn't flicker.
            $0.value.frame.insetBy(dx: -5, dy: -1.5).contains(point)
        }) else {
            hideHoverLabel()
            return
        }
        guard model.hovered != id else { return }
        model.hovered = id

        // SwiftUI frames are top-left based; the window is bottom-left based.
        let contentHeight = contentView?.bounds.height ?? frame.height
        let midY = frame.minY + contentHeight - button.frame.midY
        hoverLabel.show(title: button.title, detail: button.detail)
        let size = hoverLabel.frame.size
        let x = labelsOnLeft ? frame.minX - 6 - size.width : frame.maxX + 6
        hoverLabel.setFrameOrigin(NSPoint(x: x.rounded(), y: (midY - size.height / 2).rounded()))
        if hoverLabel.parent == nil { addChildWindow(hoverLabel, ordered: .above) }
    }

    func hideHoverLabel() {
        model.hovered = nil
        if hoverLabel.parent != nil { removeChildWindow(hoverLabel) }
        hoverLabel.orderOut(nil)
    }

    override func orderOut(_ sender: Any?) {
        hideHoverLabel()
        super.orderOut(sender)
    }
}

/// The small bubble that names a toolbar button while the pointer is over it.
final class HoverLabelWindow: NSPanel {
    private let hosting = NSHostingView(rootView: HoverLabel(title: "", detail: ""))

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        ignoresMouseEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = hosting
    }

    func show(title: String, detail: String) {
        hosting.rootView = HoverLabel(title: title, detail: detail)
        setContentSize(hosting.fittingSize)
    }
}

struct HoverLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 10.5)).opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 240, alignment: .leading)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.12).opacity(0.94)))
        .fixedSize(horizontal: true, vertical: true)
    }
}

struct SideToolbarView: View {
    @Bindable var store: SimSlingStore
    let model: SidePanelModel

    @State private var dropTargeted = false
    @State private var showURLField = false
    @State private var urlText = ""
    @State private var badge: Bool?   // true = success, false = failure, nil = hidden

    /// Every action from this toolbar targets only the simulator it sits beside.
    private var target: SimSlingStore.Target { .window(title: model.windowTitle) }
    private var deviceLabel: String { model.windowTitle ?? "this simulator" }

    var body: some View {
        VStack(spacing: 2) {
            tool("tray.and.arrow.down", "Send Files", "Pick files for \(deviceLabel), or drop them on this toolbar") {
                store.chooseFiles(for: target)
            }
            destinationMenu
            Divider().padding(.vertical, 3)
            tool("doc.on.clipboard", "Paste Mac Clipboard", "Put the Mac clipboard onto \(deviceLabel)") {
                store.pushMacClipboard(to: target)
            }
            tool("arrow.down.doc", "Copy Sim Clipboard", "Bring \(deviceLabel)'s clipboard to the Mac") {
                store.pullClipboard(from: target)
            }
            tool("link", "Open URL", "Open a URL or deep link on \(deviceLabel)") {
                model.dismissHover?()   // the popover replaces the label
                showURLField.toggle()
            }
                .popover(isPresented: $showURLField, arrowEdge: .trailing) { urlPopover }
            tool("camera", "Screenshot", "Capture \(deviceLabel)'s screen. Drag the thumbnail into any app, or leave it to save to the Desktop") {
                store.takeScreenshot(on: target) { url in model.showScreenshot?(url) }
            }
            tool("folder", "Show in Finder", "Open \(deviceLabel)'s Files app storage in Finder") { store.revealFilesFolder(on: target) }
        }
        .padding(5)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: dropTargeted ? 2 : 0.5)
        }
        .overlay { if let badge { badgeView(ok: badge) } }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            store.send(files, to: target)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: store.lastOutcome) { _, outcome in
            guard let outcome, outcome.window != nil, outcome.window == model.windowTitle else { return }
            withAnimation { badge = outcome.ok }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation { badge = nil }
            }
        }
        .fixedSize()
    }

    private var destinationMenu: some View {
        Menu {
            Picker("Destination", selection: $store.mode) {
                ForEach(SimSlingStore.DestinationMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: symbol(for: mode)).tag(mode)
                }
            }
            .pickerStyle(.inline)
            if store.mode == .app {
                Picker("App", selection: $store.appBundleID) {
                    ForEach(store.apps) { Text($0.name).tag(Optional($0.bundleID)) }
                }
            }
        } label: {
            ToolIcon(symbol: symbol(for: store.mode))
        }
        .menuStyle(.button)
        .buttonStyle(ToolButtonStyle(highlighted: model.hovered == "destination"))
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(HoverReport(id: "destination", title: "Destination: \(destinationTitle)", detail: "Files go to \(destinationHelp). Click to change.", model: model))
        .accessibilityLabel("Destination: \(destinationTitle)")
    }

    private var destinationTitle: String {
        switch store.mode {
        case .auto: "Auto Route"
        case .files: "To Files"
        case .media: "To Photos"
        case .app: "To App"
        }
    }

    private var destinationHelp: String {
        switch store.mode {
        case .auto: "Photos/Contacts, .app files get installed, the rest to Files"
        case .files: "Files › On My iPhone"
        case .media: "Photos and Contacts"
        case .app: "the \(store.apps.first { $0.bundleID == store.appBundleID }?.name ?? "selected") app's Documents folder"
        }
    }

    private var urlPopover: some View {
        HStack {
            TextField("myapp://path or https://…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(openURL)
            Button("Open", action: openURL)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func openURL() {
        store.openURL(urlText, on: target)
        showURLField = false
    }

    private func tool(_ symbol: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ToolIcon(symbol: symbol) }
            .buttonStyle(ToolButtonStyle(highlighted: model.hovered == symbol))
            .modifier(HoverReport(id: symbol, title: title, detail: detail, model: model))
            .accessibilityLabel(title)
            .accessibilityHint(detail)
    }

    private func badgeView(ok: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(ok ? .green : .orange)
            }
            .transition(.opacity)
    }

    private func symbol(for mode: SimSlingStore.DestinationMode) -> String {
        switch mode {
        case .auto: "wand.and.stars"
        case .files: "folder.badge.plus"
        case .media: "photo.on.rectangle"
        case .app: "app.badge"
        }
    }
}

private struct ToolIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

/// Registers a button's frame and label with the panel, which shows the label on hover.
private struct HoverReport: ViewModifier {
    let id: String
    let title: String
    let detail: String
    let model: SidePanelModel

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                model.buttons[id] = .init(title: title, detail: detail, frame: frame)
            }
            .onChange(of: title + detail, initial: true) {
                model.buttons[id, default: .init(title: title, detail: detail, frame: .zero)].title = title
                model.buttons[id]?.detail = detail
            }
    }
}

private struct ToolButtonStyle: ButtonStyle {
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : highlighted ? 0.1 : 0))
            )
    }
}
