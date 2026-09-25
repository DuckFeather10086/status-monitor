import AppKit

enum NetworkMenuImage {
    static let size = NSSize(width: 72, height: 22)

    static func rate(_ bytes: Double) -> String {
        let units = ["B/s", "K/s", "M/s", "G/s", "T/s"]
        var value = bytes.isFinite ? max(0, bytes) : 0
        var index = 0
        while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
        value = min(999, value)
        return value < 10 && index > 0
            ? String(format: "%.1f%@", value, units[index])
            : "\(Int(value))\(units[index])"
    }

    // A template image keeps both rows in a real menu-bar label, at a fixed width.
    // macOS chooses the appropriate foreground for light/dark/selected states.
    static func make(download: Double, upload: Double) -> NSImage {
        let up = "↑ " + rate(upload)
        let down = "↓ " + rate(download)
        let image = NSImage(size: size, flipped: false) { bounds in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            (up as NSString).draw(at: NSPoint(x: 3, y: bounds.height / 2), withAttributes: attributes)
            (down as NSString).draw(at: NSPoint(x: 3, y: 0), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Upload \(rate(upload)), download \(rate(download))"
        return image
    }
}
