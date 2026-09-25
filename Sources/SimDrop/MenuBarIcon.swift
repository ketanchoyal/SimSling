import AppKit

/// The SimDrop logo (a phone with a drop falling onto its screen) as an 18pt template image,
/// so macOS tints it for light and dark menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()

            // Phone body
            let phone = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 0.75, width: 11, height: 16.5), xRadius: 3, yRadius: 3)
            phone.lineWidth = 1.5
            phone.stroke()

            // Dynamic Island
            NSBezierPath(roundedRect: NSRect(x: 7.6, y: 2.5, width: 2.8, height: 1.1), xRadius: 0.55, yRadius: 0.55).fill()

            // Drop
            let drop = NSRect(x: 6.1, y: 4.4, width: 5.8, height: 7.8)
            let bulb = NSPoint(x: drop.midX, y: drop.minY + drop.height * 0.64)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: drop.midX, y: drop.minY))
            path.curve(to: NSPoint(x: drop.maxX, y: bulb.y),
                       controlPoint1: NSPoint(x: drop.midX + drop.width * 0.18, y: drop.minY + drop.height * 0.22),
                       controlPoint2: NSPoint(x: drop.maxX, y: drop.minY + drop.height * 0.40))
            path.appendArc(withCenter: bulb, radius: drop.width / 2, startAngle: 0, endAngle: 180, clockwise: false)
            path.curve(to: NSPoint(x: drop.midX, y: drop.minY),
                       controlPoint1: NSPoint(x: drop.minX, y: drop.minY + drop.height * 0.40),
                       controlPoint2: NSPoint(x: drop.midX - drop.width * 0.18, y: drop.minY + drop.height * 0.22))
            path.fill()

            // Down arrow knocked out of the drop
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 9, y: 7.4))
            arrow.line(to: NSPoint(x: 9, y: 10.9))
            arrow.move(to: NSPoint(x: 7.6, y: 9.5))
            arrow.line(to: NSPoint(x: 9, y: 10.9))
            arrow.line(to: NSPoint(x: 10.4, y: 9.5))
            arrow.lineWidth = 1.2
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // Ripple where it lands
            let ripple = NSBezierPath(ovalIn: NSRect(x: 6.3, y: 13.4, width: 5.4, height: 1.7))
            ripple.lineWidth = 1
            ripple.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SimDrop"
        return image
    }()
}
