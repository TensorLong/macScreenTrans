import AppKit

enum StatusBarIcon {
    static func makeBadge() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        NSColor.systemBlue.setFill()
        path.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = "译" as NSString
        let textRect = NSRect(x: 2, y: 3, width: 20, height: 17)
        text.draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        image.isTemplate = false
        image.accessibilityDescription = "MacScreenTrans"
        return image
    }
}
