import AppKit
import ApplicationServices

/// Which simulator a Device Hub window shows: its device name, plus the runtime when known.
struct SimWindowIdentity: Equatable, Sendable {
    let name: String
    /// e.g. "iOS 27.0", in the same format as `SimDevice.runtime`.
    let runtime: String?

    /// Parses a window title. Accessibility titles look like "iPhone 17 Pro – iOS 27.0";
    /// window-list titles are just "iPhone 17 Pro".
    init(title: String) {
        let parts = title.components(separatedBy: " – ")
        if parts.count >= 2, let runtime = parts.last, runtime.contains(where: \.isNumber) {
            name = parts.dropLast().joined(separator: " – ")
            self.runtime = runtime
        } else {
            name = title
            runtime = nil
        }
    }
}

/// Reads simulator window titles. The window list only includes other apps' titles with Screen
/// Recording permission, so SimSling falls back to Accessibility, which window tools normally use.
@MainActor
enum WindowIdentity {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    private static var prompted = false

    /// Shows the system prompt to allow SimSling under Accessibility. Without `force`, asks at most
    /// once per launch.
    static func requestAccessibility(force: Bool = false) {
        guard force || !prompted else { return }
        prompted = true
        // "AXTrustedCheckOptionPrompt" is kAXTrustedCheckOptionPrompt, which Swift 6 flags as shared mutable state.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Finds the Accessibility title of the window of `pid` whose frame matches `frame`
    /// (top-left screen coordinates, as in the window list).
    static func accessibilityTitle(pid: pid_t, frame: CGRect) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            guard let title = value(window, kAXTitleAttribute) as? String, !title.isEmpty,
                  let position = point(value(window, kAXPositionAttribute)),
                  let size = size(value(window, kAXSizeAttribute))
            else { continue }
            let axFrame = CGRect(origin: position, size: size)
            if abs(axFrame.minX - frame.minX) < 3, abs(axFrame.minY - frame.minY) < 3,
               abs(axFrame.width - frame.width) < 3, abs(axFrame.height - frame.height) < 3 {
                return title
            }
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
